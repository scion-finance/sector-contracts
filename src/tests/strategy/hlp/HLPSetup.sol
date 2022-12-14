// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { ICompound } from "strategies/mixins/ICompound.sol";
import { ICompPriceOracle } from "interfaces/compound/ICompPriceOracle.sol";
import { ISimpleUniswapOracle } from "interfaces/uniswap/ISimpleUniswapOracle.sol";

import { HLPConfig, HarvestSwapParams, NativeToken } from "interfaces/Structs.sol";
import { SCYVault, HLPVault, Strategy, AuthConfig, FeeConfig } from "strategies/hlp/HLPVault.sol";
import { HLPCore } from "strategies/hlp/HLPCore.sol";
import { IERC20Metadata as IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MasterChefCompMulti } from "strategies/hlp/MasterChefCompMulti.sol";

import { SCYStratUtils } from "../common/SCYStratUtils.sol";
import { UniswapMixin } from "../common/UniswapMixin.sol";

import "forge-std/StdJson.sol";

import "hardhat/console.sol";

contract HLPSetup is SCYStratUtils, UniswapMixin {
	using stdJson for string;

	string TEST_STRATEGY = "USDC-MOVR-SOLAR-WELL";

	uint256 currentFork;

	HLPCore strategy;

	Strategy strategyConfig;
	HLPConfig config;
	string contractType;

	struct HLPConfigJSON {
		address a_underlying;
		address b_short;
		address c_uniPair;
		address d1_cTokenLend;
		address d2_cTokenBorrow;
		address e1_farmToken;
		uint256 e2_farmId;
		address e3_uniFarm;
		address f_farmRouter;
		address[] h_harvestPath;
		address l1_comptroller;
		address l2_lendRewardToken;
		address[] l3_lendRewardPath;
		address l4_lendRewardRouter;
		uint256 n_nativeToken;
		string o_contract;
		string x_chain;
	}

	// TODO we can return a full array for a given chain
	// and test all strats...
	function getConfig(string memory symbol) public returns (HLPConfig memory _config) {
		string memory root = vm.projectRoot();
		string memory path = string.concat(root, "/ts/config/strategies.json");
		string memory json = vm.readFile(path);
		// bytes memory names = json.parseRaw(".strats");
		// string[] memory strats = abi.decode(names, (string[]));
		bytes memory strat = json.parseRaw(string.concat(".", symbol));
		HLPConfigJSON memory stratJson = abi.decode(strat, (HLPConfigJSON));

		_config.underlying = stratJson.a_underlying;
		_config.short = stratJson.b_short;
		_config.uniPair = stratJson.c_uniPair;
		_config.cTokenLend = stratJson.d1_cTokenLend; // collateral token
		_config.cTokenBorrow = stratJson.d2_cTokenBorrow; // collateral token
		_config.farmToken = stratJson.e1_farmToken;
		_config.farmId = stratJson.e2_farmId;
		_config.uniFarm = stratJson.e3_uniFarm;
		_config.farmRouter = stratJson.f_farmRouter;
		_config.comptroller = stratJson.l1_comptroller;
		_config.lendRewardToken = stratJson.l2_lendRewardToken;
		_config.lendRewardRouter = stratJson.l4_lendRewardRouter;
		_config.nativeToken = NativeToken(stratJson.n_nativeToken);

		harvestParams.path = stratJson.h_harvestPath;
		harvestLendParams.path = stratJson.l3_lendRewardPath;
		contractType = stratJson.o_contract;

		string memory RPC_URL = vm.envString(string.concat(stratJson.x_chain, "_RPC_URL"));
		uint256 BLOCK = vm.envUint(string.concat(stratJson.x_chain, "_BLOCK"));

		currentFork = vm.createFork(RPC_URL, BLOCK);
		vm.selectFork(currentFork);
	}

	function setUp() public {
		config = getConfig(TEST_STRATEGY);

		// TODO use JSON
		underlying = IERC20(config.underlying);

		/// todo should be able to do this via address and mixin
		strategyConfig.symbol = "TST";
		strategyConfig.name = "TEST";
		strategyConfig.yieldToken = config.uniPair;
		strategyConfig.underlying = IERC20(config.underlying);
		strategyConfig.maxTvl = type(uint128).max;

		vault = SCYVault(
			new HLPVault(
				AuthConfig(owner, guardian, manager),
				FeeConfig(treasury, .1e18, 0),
				strategyConfig
			)
		);

		mLp = vault.MIN_LIQUIDITY();
		config.vault = address(vault);

		AuthConfig memory authConfig = AuthConfig(owner, guardian, manager);

		if (compare(contractType, "MasterChefCompMulti"))
			strategy = new MasterChefCompMulti(authConfig, config);

		vault.initStrategy(address(strategy));
		underlying.approve(address(vault), type(uint256).max);

		configureUtils(config.underlying, address(strategy));
		configureUniswapMixin(config.uniPair, config.short);
		// deposit(mLp);
	}

	function rebalance() public override {
		uint256 priceOffset = strategy.getPriceOffset();
		strategy.rebalance(priceOffset);
		assertApproxEqAbs(strategy.getPositionOffset(), 0, 2, "position offset after rebalance");
	}

	function harvest() public override {
		if (!strategy.harvestIsEnabled()) return;
		vm.warp(block.timestamp + 1 * 60 * 60 * 24);
		harvestParams.min = 0;
		harvestParams.deadline = block.timestamp + 1;

		harvestLendParams.min = 0;
		harvestLendParams.deadline = block.timestamp + 1;

		strategy.getAndUpdateTVL();
		uint256 tvl = strategy.getTotalTVL();

		HarvestSwapParams[] memory farmParams = new HarvestSwapParams[](1);
		farmParams[0] = harvestParams;

		HarvestSwapParams[] memory lendParams = new HarvestSwapParams[](1);
		lendParams[0] = harvestLendParams;

		uint256 vaultTvl = vault.getTvl();

		(uint256[] memory harvestAmnts, uint256[] memory harvestLendAmnts) = vault.harvest(
			vaultTvl,
			vaultTvl / 10,
			farmParams,
			lendParams
		);

		uint256 newTvl = strategy.getTotalTVL();
		assertGt(harvestAmnts[0], 0);
		assertGt(harvestLendAmnts[0], 0);
		assertGt(newTvl, tvl);
	}

	function noRebalance() public override {
		uint256 priceOffset = strategy.getPriceOffset();
		vm.expectRevert(HLPCore.RebalanceThreshold.selector);
		vm.prank(manager);
		strategy.rebalance(priceOffset);
	}

	function adjustPrice(uint256 fraction) public override {
		ICompPriceOracle oracle = ICompound(address(strategy)).oracle();
		address cToken = address(ICompound(address(strategy)).cTokenBorrow());
		uint256 price = oracle.getUnderlyingPrice(cToken);
		moveHlpPrice(
			config.uniPair,
			cToken,
			config.underlying,
			config.short,
			address(oracle),
			fraction
		);
		uint256 newPrice = oracle.getUnderlyingPrice(cToken);
		assertApproxEqRel(newPrice, (price * fraction) / 1e18, .001e18);
	}

	function adjustOraclePrice(uint256 fraction) public {
		ICompPriceOracle oracle = ICompound(address(strategy)).oracle();
		address cToken = address(ICompound(address(strategy)).cTokenBorrow());
		uint256 price = (fraction * oracle.getUnderlyingPrice(cToken)) / 1e18;
		mockHlpOraclePrice(address(oracle), cToken, price);
	}

	function compare(string memory str1, string memory str2) public pure returns (bool) {
		return keccak256(abi.encodePacked(str1)) == keccak256(abi.encodePacked(str2));
	}
}
