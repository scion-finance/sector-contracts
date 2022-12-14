// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { ICollateral } from "interfaces/imx/IImpermax.sol";
import { IMX, IMXCore } from "strategies/imx/IMX.sol";
import { IERC20Metadata as IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { levConvexSetup, SCYStratUtils } from "./levConvexSetup.sol";

import "hardhat/console.sol";

contract levConvexUnit is levConvexSetup {
	// function getAmnt() public view override(levConvexSetup, SCYStratUtils) returns (uint256) {
	// 	return levConvexSetup.getAmnt();
	// }

	// function deposit(address user, uint256 amnt) public override(levConvexSetup, SCYStratUtils) {
	// 	levConvexSetup.deposit(user, amnt);
	// }

	function testDepositLevConvex() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		withdrawEpoch(user1, 1e18);
		uint256 loss = amnt - underlying.balanceOf(user1);
		console.log("year loss", (12 * (10000 * loss)) / amnt);
		console.log("maxTvl", strategy.getMaxTvl());
	}

	function testAdjustLeverage() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		uint16 targetLev = 500;
		strategy.adjustLeverage(targetLev);
		assertApproxEqAbs(strategy.getLeverage(), targetLev, 1);
		assertEq(strategy.leverageFactor(), strategy.getLeverage() - 100);

		assertEq(underlying.balanceOf(strategy.credAcc()), 0);

		deposit(user1, amnt);
		targetLev = 500;
		strategy.adjustLeverage(targetLev);
		assertGt(strategy.loanHealth(), 1e18);
		assertApproxEqAbs(strategy.getLeverage(), targetLev, 1);
		assertEq(strategy.leverageFactor(), strategy.getLeverage() - 100);
	}

	function testAdjustLeverageUp() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		uint16 targetLev = 800;
		strategy.adjustLeverage(targetLev);
		assertGt(strategy.loanHealth(), 1e18);
		assertApproxEqAbs(strategy.getLeverage(), targetLev, 2);
		assertEq(strategy.leverageFactor(), strategy.getLeverage() - 100);
		assertEq(underlying.balanceOf(strategy.credAcc()), 0);
	}

	function testHarvestDev() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		harvest();
	}

	function testDepositFuzz(uint256 fuzz) public {
		uint256 min = getAmnt() / 2;
		fuzz = bound(fuzz, min, vault.getMaxTvl() - mLp);
		deposit(user1, fuzz);
		assertApproxEqRel(vault.underlyingBalance(user1), fuzz, .02e18);
	}

	function testDepositWithdrawPartial(uint256 fuzz) public {
		uint256 depAmnt = 3 * getAmnt();
		uint256 min = depAmnt / 4;
		uint256 wAmnt = bound(fuzz, min, depAmnt - min);

		deposit(user1, depAmnt);

		// fast forward 1 block
		vm.roll(block.number + 1);
		withdrawEpoch(user1, (1e18 * wAmnt) / depAmnt);
		assertApproxEqRel(underlying.balanceOf(user1), wAmnt, .011e18);

		vm.roll(block.number + 1);
		withdrawEpoch(user1, 1e18);

		// price should not be off by more than 1%
		assertApproxEqRel(underlying.balanceOf(user1), depAmnt, .011e18);
	}

	function testWithdrawWithNoBalance() public {
		vm.prank(user1);
		vm.expectRevert("ERC20: transfer amount exceeds balance");
		getEpochVault(vault).requestRedeem(1);
	}

	function testWithdrawMoreThanBalance() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		uint256 balance = vault.balanceOf(user1);
		vm.prank(user1);
		vm.expectRevert("ERC20: transfer amount exceeds balance");
		getEpochVault(vault).requestRedeem(balance + 1);
	}

	function testCloseVaultPosition() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		vm.prank(guardian);
		vault.closePosition(0, 0);
		uint256 floatBalance = vault.uBalance();
		assertApproxEqRel(floatBalance, amnt, .005e18);
		assertEq(underlying.balanceOf(address(vault)), floatBalance);
	}

	function testAccounting() public {
		uint256 amnt = getAmnt();
		// strategy.adjustLeverage(400);

		deposit(user1, amnt);
		// TODO curve price changes?
		// strategy.adjustLeverage(700);
		uint256 startBalance = vault.underlyingBalance(user1);
		assertApproxEqRel(vault.underlyingBalance(user1), amnt, .011e18, "first balance");

		uint256 amnt2 = (1e18 * amnt) / 1e18;
		deposit(user2, amnt2);
		assertApproxEqRel(vault.underlyingBalance(user2), amnt2, .011e18, "second balance");

		// TODO curve price changes?
		uint256 balance = vault.underlyingBalance(user1);

		assertApproxEqRel(balance, startBalance, .001e18, "first balance should not decrease");
		// vault.closePosition(0, 0);
		withdrawEpoch(user1, 1e18);
		assertApproxEqRel(underlying.balanceOf(user1), amnt, .0038e18, "final user1 bal");

		vm.roll(block.number + 1);

		withdrawEpoch(user2, 1e18);
		assertApproxEqRel(underlying.balanceOf(user2), amnt, .0075e18, "final user2 bal");
	}

	function testManagerWithdraw() public {
		uint256 amnt = getAmnt();
		deposit(user1, amnt);
		uint256 shares = vault.totalSupply();
		vm.prank(guardian);

		vault.withdrawFromStrategy(shares, 0);

		uint256 floatBalance = vault.uBalance();
		assertApproxEqRel(floatBalance, amnt, .0038e18);
		assertEq(underlying.balanceOf(address(vault)), floatBalance);
		vm.roll(block.number + 1);
		skip(1000);
		vm.prank(manager);
		vault.depositIntoStrategy(floatBalance, 0);
	}
}
