// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IBase, HarvestSwapParms } from "../mixins/IBase.sol";
import { ILending } from "../mixins/ILending.sol";
import { IUniFarm, SafeERC20, IERC20 } from "../mixins/IUniFarm.sol";
import { BaseStrategy } from "./BaseStrategy.sol";
import { IWETH } from "../../interfaces/uniswap/IWETH.sol";
import { UniUtils, IUniswapV2Pair } from "../../libraries/UniUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Strategy } from "../../interfaces/Strategy.sol";
import { Auth } from "../../common/Auth.sol";

// import "hardhat/console.sol";

// @custom: alphabetize dependencies to avoid linearization conflicts
abstract contract HLPCore is Auth, Strategy, ReentrancyGuard, IBase, ILending, IUniFarm {
	using UniUtils for IUniswapV2Pair;
	using SafeERC20 for IERC20;

	event Deposit(address sender, uint256 amount);
	event Redeem(address sender, uint256 amount);
	event Harvest(uint256 harvested); // this is actual the tvl before harvest
	event Rebalance(uint256 shortPrice, uint256 tvlBeforeRebalance, uint256 positionOffset);
	event EmergencyWithdraw(address indexed recipient, IERC20[] tokens);
	event UpdatePosition();

	event RebalanceLoan(address indexed sender, uint256 startLoanHealth, uint256 updatedLoanHealth);
	event setMinLoanHealth(uint256 loanHealth);
	event SetMaxDefaultPriceMismatch(uint256 maxDefaultPriceMismatch);
	event SetRebalanceThreshold(uint256 rebalanceThreshold);
	event SetMaxTvl(uint256 maxTvl);
	event SetSafeCollateralRaio(uint256 collateralRatio);

	uint256 constant MIN_LIQUIDITY = 1000;
	uint256 public constant maxPriceOffset = 2000; // maximum offset for rebalanceLoan & manager  methods 20%
	uint256 constant BPS_ADJUST = 10000;

	uint256 public lastHarvest; // block.timestamp;

	IERC20 private _underlying;
	IERC20 private _short;

	uint256 public maxDefaultPriceMismatch = 100; // 1%
	uint256 public constant maxAllowedMismatch = 300; // manager cannot set user-price mismatch to more than 3%
	uint256 public minLoanHealth = 1.15e18; // how close to liquidation we get

	uint16 public rebalanceThreshold = 400; // 4% of lp

	uint256 private _maxTvl;
	uint256 private _safeCollateralRatio = 8000; // 80%

	uint256 public constant version = 1;

	address public vault;

	modifier onlyVault() {
		require(msg.sender == vault, "Strat: ONLY_VAULT");
		_;
	}

	modifier checkPrice(uint256 maxSlippage) {
		if (maxSlippage == 0)
			maxSlippage = maxDefaultPriceMismatch;
			// manager accounts cannot set maxSlippage bigger than maxPriceOffset
		else
			require(
				maxSlippage <= maxPriceOffset || hasRole(GUARDIAN, msg.sender),
				"HLP: MAX_MISMATCH"
			);
		require(getPriceOffset() <= maxSlippage, "HLP: PRICE_MISMATCH");
		_;
	}

	function __HedgedLP_init_(
		address underlying_,
		address short_,
		uint256 maxTvl_
	) internal initializer {
		_underlying = IERC20(underlying_);
		_short = IERC20(short_);

		_underlying.safeApprove(address(this), type(uint256).max);

		// init params
		setMaxTvl(maxTvl_);

		// emit default settings events
		emit setMinLoanHealth(minLoanHealth);
		emit SetMaxDefaultPriceMismatch(maxDefaultPriceMismatch);
		emit SetRebalanceThreshold(rebalanceThreshold);
		emit SetSafeCollateralRaio(_safeCollateralRatio);

		// TODO should we add a revoke aprovals methods?
		_addLendingApprovals();
		_addFarmApprovals();

		isInitialized = true;
	}

	function safeCollateralRatio() public view override returns (uint256) {
		return _safeCollateralRatio;
	}

	function setSafeCollateralRatio(uint256 safeCollateralRatio_) public onlyOwner {
		require(safeCollateralRatio_ >= 1000 && safeCollateralRatio_ <= 8500, "HLP: BAD_INPUT");
		_safeCollateralRatio = safeCollateralRatio_;
		emit SetSafeCollateralRaio(safeCollateralRatio_);
	}

	function decimals() public view returns (uint8) {
		return IERC20Metadata(address(_underlying)).decimals();
	}

	// OWNER CONFIG
	function setMinLoanHeath(uint256 minLoanHealth_) public onlyOwner {
		require(minLoanHealth_ > 1e18, "HLP: BAD_INPUT");
		minLoanHealth = minLoanHealth_;
		emit setMinLoanHealth(minLoanHealth_);
	}

	// guardian can adjust max default price mismatch if needed
	function setMaxDefaultPriceMismatch(uint256 maxDefaultPriceMismatch_)
		public
		onlyRole(GUARDIAN)
	{
		require(maxDefaultPriceMismatch_ >= 25, "HLP: BAD_INPUT"); // no less than .25%
		require(
			msg.sender == owner || maxAllowedMismatch >= maxDefaultPriceMismatch_,
			"HLP: BAD_INPUT"
		);
		maxDefaultPriceMismatch = maxDefaultPriceMismatch_;
		emit SetMaxDefaultPriceMismatch(maxDefaultPriceMismatch_);
	}

	function setRebalanceThreshold(uint16 rebalanceThreshold_) public onlyOwner {
		// rebalance threshold should not be lower than 1% (2% price move)
		require(rebalanceThreshold_ >= 100, "HLP: BAD_INPUT");
		rebalanceThreshold = rebalanceThreshold_;
		emit SetRebalanceThreshold(rebalanceThreshold_);
	}

	function setMaxTvl(uint256 maxTvl_) public onlyRole(GUARDIAN) {
		_maxTvl = maxTvl_;
		emit SetMaxTvl(maxTvl_);
	}

	// PUBLIC METHODS

	function short() public view override returns (IERC20) {
		return _short;
	}

	function underlying() public view override returns (IERC20) {
		return _underlying;
	}

	// public method that anyone can call if loan health falls below minLoanHealth
	// this method will succeed only when loanHealth is below minimum
	function rebalanceLoan() public nonReentrant {
		// limit offset to maxPriceOffset manager to prevent misuse
		if (hasRole(GUARDIAN, msg.sender)) {} else if (hasRole(MANAGER, msg.sender))
			require(getPriceOffset() <= maxPriceOffset, "HLP: MAX_MISMATCH");
			// public methods need more protection agains griefing
			// NOTE: this may prevent gelato bots from executing the tx in the case of
			// a sudden price spike on a CEX
		else require(getPriceOffset() <= maxDefaultPriceMismatch, "HLP: PRICE_MISMATCH");

		uint256 _loanHealth = loanHealth();
		require(_loanHealth <= minLoanHealth, "HLP: SAFE");
		_rebalanceLoan(_loanHealth);
	}

	function _rebalanceLoan(uint256 _loanHealth) internal {
		(uint256 underlyingLp, ) = _getLPBalances();
		uint256 collateral = _getCollateralBalance();

		// get back to our target _safeCollateralRatio
		uint256 targetHealth = (10000 * 1e18) / _safeCollateralRatio;
		uint256 addCollateral = (1e18 * ((collateral * targetHealth) / _loanHealth - collateral)) /
			((targetHealth * 1e18) / _getCollateralFactor() + 1e18);

		// remove lp
		(uint256 underlyingBalance, uint256 shortBalance) = _decreaseULpTo(
			underlyingLp - addCollateral
		);

		_repay(shortBalance);
		_lend(underlyingBalance);
		emit RebalanceLoan(msg.sender, _loanHealth, loanHealth());
	}

	// deposit underlying and recieve lp tokens
	function deposit(uint256 underlyingAmnt) external onlyVault nonReentrant returns (uint256) {
		if (underlyingAmnt == 0) return 0; // cannot deposit 0

		if (underlyingAmnt < _underlying.balanceOf(address(this))) revert NonZeroFloat();

		uint256 tvl = getAndUpdateTVL();
		require(underlyingAmnt + tvl <= getMaxTvl(), "STRAT: OVER_MAX_TVL");
		uint256 startBalance = _getLiquidity();
		// this method should not change % allocation to lp vs collateral
		_increasePosition(underlyingAmnt);
		uint256 endBalance = _getLiquidity();
		return endBalance - startBalance;
	}

	/// @notice decreases position based to desired LP amount
	/// @dev ** does not rebalance remaining portfolio
	/// @param removeLp amount of lp amount to remove
	function redeem(uint256 removeLp, address recipient)
		public
		onlyVault
		returns (uint256 amountTokenOut)
	{
		// this is the full amount of LP tokens totalSupply of shares is entitled to
		_decreasePosition(removeLp);

		// TODO make sure we never have any extra underlying dust sitting around
		// all 'extra' underlying should allways be transferred back to the vault

		unchecked {
			amountTokenOut = _underlying.balanceOf(address(this));
		}
		_underlying.safeTransfer(recipient, amountTokenOut);
		emit Redeem(msg.sender, amountTokenOut);
	}

	/// @notice decreases position based on current ratio
	/// @dev ** does not rebalance any part of portfolio
	function _decreasePosition(uint256 removeLp) internal {
		uint256 collateralBalance = _updateAndGetCollateralBalance();
		uint256 shortPosition = _updateAndGetBorrowBalance();

		uint256 totalLp = _getLiquidity();

		uint256 redeemAmnt = (collateralBalance * removeLp) / totalLp;
		uint256 repayAmnt = (shortPosition * removeLp) / totalLp;

		// remove lp
		(, uint256 sLp) = _removeLp(removeLp);
		_tradeExact(repayAmnt, sLp, address(_short), address(_underlying));
		_repay(repayAmnt);
		_redeem(redeemAmnt);
	}

	function _tradeExact(
		uint256 target,
		uint256 balance,
		address exactToken,
		address token
	) internal returns (uint256 tokenOut, uint256 tokenIn) {
		if (target > balance)
			tokenIn = pair()._swapTokensForExactTokens(target - balance, token, exactToken);
		else if (balance > target)
			tokenOut = pair()._swapExactTokensForTokens(balance - target, exactToken, token);
	}

	/// @notice decreases position proportionally based on current position ratio
	// ** does not rebalance remaining portfolio
	function _increasePosition(uint256 underlyingAmnt) internal {
		if (underlyingAmnt < MIN_LIQUIDITY) revert MinLiquidity(); // avoid imprecision
		uint256 tvl = getAndUpdateTVL() - underlyingAmnt;

		// if this is the first deposit, we use our desire ratio
		if (tvl == 0) {
			uint256 addULp = _totalToLp(underlyingAmnt);
			uint256 borrowAmnt = _underlyingToShort(addULp);
			uint256 collateralAmnt = underlyingAmnt - addULp;
			_lend(collateralAmnt);
			_borrow(borrowAmnt);
			uint256 liquidity = _addLiquidity(addULp, borrowAmnt);
			_depositIntoFarm(liquidity);
			return;
		}

		{
			uint256 collateralBalance = _updateAndGetCollateralBalance();
			uint256 shortPosition = _updateAndGetBorrowBalance();

			// else we use whatever the current ratio is
			(, uint256 sLp) = _getLPBalances();
			uint256 addSLp = (underlyingAmnt * sLp) / tvl;
			uint256 collateralAmnt = (collateralBalance * underlyingAmnt) / tvl;
			uint256 borrowAmnt = (shortPosition * underlyingAmnt) / tvl;

			_lend(collateralAmnt);
			_borrow(borrowAmnt);

			_increaseLpPosition(addSLp);
		}
	}

	// use the return of the function to estimate pending harvest via staticCall
	function harvest(
		HarvestSwapParms[] calldata uniParams,
		HarvestSwapParms[] calldata lendingParams
	)
		external
		onlyRole(MANAGER)
		checkPrice(0)
		nonReentrant
		returns (uint256[] memory farmHarvest, uint256[] memory lendHarvest)
	{
		(uint256 startTvl, , , , , ) = getTVL();
		if (uniParams.length != 0) farmHarvest = _harvestFarm(uniParams);
		if (lendingParams.length != 0) lendHarvest = _harvestLending(lendingParams);

		// compound our lp position
		_increasePosition(underlying().balanceOf(address(this)));
		emit Harvest(startTvl);
	}

	function rebalance(uint256 maxSlippage)
		external
		onlyRole(MANAGER)
		checkPrice(maxSlippage)
		nonReentrant
	{
		// call this first to ensure we use an updated borrowBalance when computing offset
		uint256 tvl = getAndUpdateTVL();
		uint256 positionOffset = getPositionOffset();

		// don't rebalance unless we exceeded the threshold
		require(positionOffset > rebalanceThreshold, "HLP: REB-THRESH"); // maybe next time...

		if (tvl == 0) return;
		uint256 targetUnderlyingLP = _totalToLp(tvl);

		// add .1% room for fees
		_rebalancePosition((targetUnderlyingLP * 999) / 1000, tvl - targetUnderlyingLP);
		emit Rebalance(_shortToUnderlying(1e18), positionOffset, tvl);
	}

	// note: one should call harvest immediately before close position
	function closePosition(uint256 maxSlippage) public checkPrice(maxSlippage) onlyRole(GUARDIAN) {
		_closePosition();
		emit UpdatePosition();
	}

	// in case of emergency - remove LP
	function removeLiquidity(uint256 removeLp, uint256 maxSlippage)
		public
		checkPrice(maxSlippage)
		onlyRole(GUARDIAN)
	{
		_removeLiquidity(removeLp);
		emit UpdatePosition();
	}

	// in case of emergency - withdraw lp tokens from farm
	function withdrawFromFarm() public onlyRole(GUARDIAN) {
		_withdrawFromFarm(_getFarmLp());
		emit UpdatePosition();
	}

	// in case of emergency - withdraw stuck collateral
	function redeemCollateral(uint256 repayAmnt, uint256 withdrawAmnt) public onlyRole(GUARDIAN) {
		_repay(repayAmnt);
		_redeem(withdrawAmnt);
		emit UpdatePosition();
	}

	function _closePosition() internal {
		_decreaseULpTo(0);
		uint256 shortPosition = _updateAndGetBorrowBalance();
		uint256 shortBalance = _short.balanceOf(address(this));
		if (shortPosition > shortBalance) {
			pair()._swapTokensForExactTokens(
				shortPosition - shortBalance,
				address(_underlying),
				address(_short)
			);
		} else if (shortBalance > shortPosition) {
			pair()._swapExactTokensForTokens(
				shortBalance - shortPosition,
				address(_short),
				address(_underlying)
			);
		}
		_repay(_short.balanceOf(address(this)));
		uint256 collateralBalance = _updateAndGetCollateralBalance();
		_redeem(collateralBalance);
		uint256 balance = _underlying.balanceOf(address(this));
		return _underlying.safeTransfer(vault, balance);
	}

	function _decreaseULpTo(uint256 targetUnderlyingLP)
		internal
		returns (uint256 underlyingRemove, uint256 shortRemove)
	{
		(uint256 underlyingLp, ) = _getLPBalances();
		if (targetUnderlyingLP >= underlyingLp) return (0, 0); // nothing to withdraw
		uint256 liquidity = _getLiquidity();
		uint256 targetLiquidity = (liquidity * targetUnderlyingLP) / underlyingLp;
		uint256 removeLp = liquidity - targetLiquidity;
		uint256 liquidityBalance = pair().balanceOf(address(this));
		if (removeLp > liquidityBalance) _withdrawFromFarm(removeLp - liquidityBalance);
		return removeLp == 0 ? (0, 0) : _removeLiquidity(removeLp);
	}

	function _removeLp(uint256 removeLp)
		internal
		returns (uint256 underlyingRemove, uint256 shortRemove)
	{
		// TODO ensure that we never have LP not in farm
		_withdrawFromFarm(removeLp);
		return _removeLiquidity(removeLp);
	}

	function _rebalancePosition(uint256 targetUnderlyingLP, uint256 targetCollateral) internal {
		uint256 targetBorrow = _underlyingToShort(targetUnderlyingLP);
		// we already updated tvl
		uint256 currentBorrow = _getBorrowBalance();

		// borrow funds or repay loan
		if (targetBorrow > currentBorrow) {
			// remove extra lp (we may need to remove more in order to add more collateral)
			_decreaseULpTo(
				_needUnderlying(targetUnderlyingLP, targetCollateral) > 0 ? 0 : targetUnderlyingLP
			);
			// add collateral
			_adjustCollateral(targetCollateral);
			_borrow(targetBorrow - currentBorrow);
		} else if (targetBorrow < currentBorrow) {
			// remove all of lp so we can repay loan
			_decreaseULpTo(0);
			uint256 repayAmnt = min(_short.balanceOf(address(this)), currentBorrow - targetBorrow);
			if (repayAmnt > 0) _repay(repayAmnt);
			// remove extra collateral
			_adjustCollateral(targetCollateral);
		}
		_increaseLpPosition(targetBorrow);
	}

	///////////////////////////
	//// INCREASE LP POSITION
	///////////////////////
	function _increaseLpPosition(uint256 targetShortLp) internal {
		uint256 uBalance = _underlying.balanceOf(address(this));
		uint256 sBalance = _short.balanceOf(address(this));

		// here we make sure we don't add extra lp
		(, uint256 shortLP) = _getLPBalances();
		if (targetShortLp <= shortLP) return;

		uint256 addShort = targetShortLp - shortLP;
		uint256 addUnderlying = _shortToUnderlying(addShort);

		(uint256 tokenOut, uint256 tokenIn) = _tradeExact(
			targetShortLp,
			sBalance,
			address(_short),
			address(_underlying)
		);

		uBalance += tokenOut - tokenIn;

		// we know that now our short balance is exact sBalance = sAmnt
		// if we don't have enough underlying, we need to decrase sAmnt slighlty
		// TODO have trades account for slippage
		if (uBalance < addUnderlying) {
			addUnderlying = uBalance;
			addShort = _underlyingToShort(uBalance);
			// if we have short dust, we can leave it for next rebalance
		} else if (uBalance > addUnderlying) {
			// if we have extra underlying, lend it back to avoid extra float
			_lend(uBalance - addUnderlying);
		}

		if (addUnderlying == 0) return;

		// add liquidity
		// don't need to use min with underlying and short because we did oracle check
		// amounts are exact because we used swap price above
		uint256 liquidity = _addLiquidity(addUnderlying, addShort);
		_depositIntoFarm(liquidity);
	}

	function _needUnderlying(uint256 tragetUnderlying, uint256 targetCollateral)
		internal
		view
		returns (uint256)
	{
		uint256 collateralBalance = _getCollateralBalance();
		if (targetCollateral < collateralBalance) return 0;
		(uint256 underlyingLp, ) = _getLPBalances();
		uint256 uBalance = tragetUnderlying > underlyingLp ? tragetUnderlying - underlyingLp : 0;
		uint256 addCollateral = targetCollateral - collateralBalance;
		if (uBalance >= addCollateral) return 0;
		return addCollateral - uBalance;
	}

	// TVL

	function getMaxTvl() public view override returns (uint256) {
		// we don't want to get precise max borrow amaount available,
		// we want to stay at least a getCollateralRatio away from max borrow
		return min(_maxTvl, _oraclePriceOfShort(_maxBorrow() + _getBorrowBalance()));
	}

	function getAndUpdateTVL() public returns (uint256 tvl) {
		uint256 collateralBalance = _updateAndGetCollateralBalance();
		uint256 shortPosition = _updateAndGetBorrowBalance();
		uint256 borrowBalance = _shortToUnderlying(shortPosition);
		uint256 shortP = _short.balanceOf(address(this));
		uint256 shortBalance = shortP == 0 ? 0 : _shortToUnderlying(shortP);
		(uint256 underlyingLp, ) = _getLPBalances();
		uint256 underlyingBalance = _underlying.balanceOf(address(this));
		tvl =
			collateralBalance +
			underlyingLp *
			2 -
			borrowBalance +
			underlyingBalance +
			shortBalance;
	}

	// We can include a checkPrice(0) here for extra security
	// but it's not necessary with latestvault updates
	function balanceOfUnderlying() public view returns (uint256 assets) {
		(assets, , , , , ) = getTVL();
	}

	function getTotalTVL() public view returns (uint256 tvl) {
		(tvl, , , , , ) = getTVL();
	}

	function getTVL()
		public
		view
		returns (
			uint256 tvl,
			uint256 collateralBalance,
			uint256 borrowPosition,
			uint256 borrowBalance,
			uint256 lpBalance,
			uint256 underlyingBalance
		)
	{
		collateralBalance = _getCollateralBalance();
		borrowPosition = _getBorrowBalance();
		borrowBalance = _shortToUnderlying(borrowPosition);

		uint256 shortPosition = _short.balanceOf(address(this));
		uint256 shortBalance = shortPosition == 0 ? 0 : _shortToUnderlying(shortPosition);

		(uint256 underlyingLp, uint256 shortLp) = _getLPBalances();
		lpBalance = underlyingLp + _shortToUnderlying(shortLp);

		underlyingBalance = _underlying.balanceOf(address(this));

		tvl = collateralBalance + lpBalance - borrowBalance + underlyingBalance + shortBalance;
	}

	function getLPBalances() public view returns (uint256 underlyingLp, uint256 shortLp) {
		return _getLPBalances();
	}

	function getLiquidity() public view returns (uint256) {
		return _getLiquidity();
	}

	function getPositionOffset() public view returns (uint256 positionOffset) {
		(, uint256 shortLp) = _getLPBalances();
		uint256 borrowBalance = _getBorrowBalance();
		uint256 shortBalance = shortLp + _short.balanceOf(address(this));

		if (shortBalance == borrowBalance) return 0;
		// if short lp > 0 and borrowBalance is 0 we are off by inf, returning 100% should be enough
		if (borrowBalance == 0) return 10000;

		// this is the % by which our position has moved from beeing balanced
		positionOffset = shortBalance > borrowBalance
			? ((shortBalance - borrowBalance) * BPS_ADJUST) / borrowBalance
			: ((borrowBalance - shortBalance) * BPS_ADJUST) / borrowBalance;
	}

	function getPriceOffset() public view returns (uint256 offset) {
		uint256 minPrice = _shortToUnderlying(1e18);
		uint256 maxPrice = _oraclePriceOfShort(1e18);
		(minPrice, maxPrice) = maxPrice > minPrice ? (minPrice, maxPrice) : (maxPrice, minPrice);
		offset = ((maxPrice - minPrice) * BPS_ADJUST) / maxPrice;
	}

	// used to estimate the expected return of lp tokens for first deposit
	function collateralToUnderlying() external view returns (uint256) {
		(uint256 uR, uint256 sR, ) = pair().getReserves();
		(uR, sR) = address(_underlying) == pair().token0() ? (uR, sR) : (sR, uR);
		uint256 lp = pair().totalSupply();
		return (_totalToLp(1e18) * lp) / uR;
	}

	// UTILS

	function _totalToLp(uint256 total) internal view returns (uint256) {
		uint256 cRatio = getCollateralRatio();
		return (total * cRatio) / (BPS_ADJUST + cRatio);
	}

	// this is the current uniswap price
	function _shortToUnderlying(uint256 amount) internal view returns (uint256) {
		return amount == 0 ? 0 : _quote(amount, address(_short), address(_underlying));
	}

	// this is the current uniswap price
	function _underlyingToShort(uint256 amount) internal view returns (uint256) {
		return amount == 0 ? 0 : _quote(amount, address(_underlying), address(_short));
	}

	/**
	 * @dev Returns the smallest of two numbers.
	 */
	function min(uint256 a, uint256 b) internal pure returns (uint256) {
		return a < b ? a : b;
	}

	error NonZeroFloat();
	error MinLiquidity();
}