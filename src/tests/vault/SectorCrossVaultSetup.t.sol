// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { SectorTest } from "../utils/SectorTest.sol";
import { SCYVault } from "../mocks/MockScyVault.sol";
import { SCYVaultSetup } from "./SCYVaultSetup.sol";
import { WETH } from "../mocks/WETH.sol";
import { SectorBase, SectorVault, BatchedWithdraw, RedeemParams, DepositParams, ISCYStrategy, AuthConfig, FeeConfig } from "../../vaults/SectorVault.sol";
import { MockERC20, IERC20 } from "../mocks/MockERC20.sol";
import { Endpoint } from "../mocks/MockEndpoint.sol";
import { SectorCrossVault, Request } from "../../vaults/SectorCrossVault.sol";
import { LayerZeroPostman, chainPair } from "../../postOffice/LayerZeroPostman.sol";
import { MultichainPostman } from "../../postOffice/MultichainPostman.sol";

import "forge-std/console.sol";
import "forge-std/Vm.sol";

contract SectorCrossVaultTestSetup is SectorTest {
	// ISCYStrategy strategy1;
	// ISCYStrategy strategy2;
	// ISCYStrategy strategy3;

	uint16 chainId;

	WETH underlying;

	SectorCrossVault xVault;
	SectorVault childVault;
	SectorVault nephewVault;

	LayerZeroPostman postmanLz;
	MultichainPostman postmanMc;

	function depositXVault(address acc, uint256 amount) public {
		vm.deal(acc, amount);

		vm.startPrank(acc);

		// Get some ERC20 for user
		underlying.deposit{ value: amount }();
		underlying.approve(address(xVault), amount);

		// Deposit into XVault
		xVault.deposit(amount, address(user1));

		vm.stopPrank();
	}

	function xvaultDepositIntoVaults(
		Request[] memory requests,
		uint256 amount,
		uint256 msgsSent,
		uint256 bridgeEvents,
		bool assertOn
	) public {
		vm.recordLogs();
		// Deposit into a vault
		vm.prank(manager);
		xVault.depositIntoVaults(requests);

		Vm.Log[] memory entries = vm.getRecordedLogs();

		if (!assertOn) return;

		assertEq(xVault.totalChildHoldings(), amount, "XVault accounting is correct");
		// assertEq(childVault.underlyingBalance(address(xVault)), amount);
		assertGe(
			entries.length,
			requests.length,
			"Has to be emitted at least the number of requests events"
		);

		assertEventCount(entries, "BridgeAsset(uint16,uint16,uint256)", bridgeEvents);
		assertEventCount(
			entries,
			"MessageSent(uint256,address,uint16,uint8,address)",
			msgsSent
		);
	}

	function xvaultWithdrawFromVaults(
		Request[] memory requests,
		uint256 msgSent,
		uint256 withdrawEvent,
		bool assertOn
	) public {
		uint[] memory shares = new uint[](requests.length);
		for (uint256 i = 0; i < requests.length; i++) {
			SectorVault vault = SectorVault(requests[i].vaultAddr);
			shares[i] = vault.balanceOf(address(xVault));
		}

		vm.recordLogs();
		vm.prank(manager);
		xVault.withdrawFromVaults(requests);

		if (!assertOn) return;

		uint256 requestTimestamp = block.timestamp;

		// Move forward in time and space
		vm.roll(block.number + 100);
		vm.warp(block.timestamp + 100);

		for (uint256 i = 0; i < requests.length; i++) {
			SectorVault vault = SectorVault(requests[i].vaultAddr);
			// uint256 share = shares[i];
			uint256 value = (shares[i] * requests[i].amount) / 100;

			(uint16 vaultChainId, , ) = xVault.addrBook(address(vault));
			// On same chain as xVault
			if (vaultChainId == chainId) {
				assertEq(vault.pendingWithdraw(), value, "Pending value must be equal to expected");

				(uint256 ts, uint256 sh, uint256 val) = vault.withdrawLedger(address(xVault));

				assertEq(ts, requestTimestamp, "Withdraw timestamp must be equal to expected");
				assertEq(sh, shares[i], "Shares must be equal to expected");
				assertEq(val, value, "Value assets must be equal to expected");
			}
		}

		Vm.Log[] memory entries = vm.getRecordedLogs();

		assertEventCount(entries, "RequestWithdraw(address,address,uint256)", withdrawEvent);
		assertEventCount(entries, "MessageSent(uint256,address,uint16,uint8,address)", msgSent);
	}

	function xvaultHarvestVault(
		uint256 lDeposit,
		uint256 cDeposit,
		uint256 pAnswers,
		uint256 rAnswers,
		uint256 mSent,
		bool assertOn
	) public {
		vm.recordLogs();
		vm.prank(manager);
		xVault.harvestVaults();

		(
			uint256 localDeposit,
			uint256 crossDeposit,
			uint256 pendingAnswers,
			uint256 receivedAnswers
		) = xVault.harvestLedger();

		if (!assertOn) return;

		assertEq(localDeposit, lDeposit, "Local depoist must be equal to total deposited");
		assertEq(crossDeposit, cDeposit, "Cross deposit value must be expected");
		assertEq(
			pendingAnswers,
			pAnswers,
			"Pending answers must be equal to number of cross vaults"
		);
		assertEq(receivedAnswers, rAnswers, "Received answers must be expected");

		Vm.Log[] memory entries = vm.getRecordedLogs();

		assertEventCount(entries, "MessageSent(uint256,address,uint16,uint8,address)", mSent);
	}


	function assertEventCount(
		Vm.Log[] memory entries,
		string memory eventEncoder,
		uint256 count
	) public {
		uint256 foundEvents = 0;
		for (uint256 i = 0; i < entries.length; i++) {
			if (entries[i].topics[0] == keccak256(bytes(eventEncoder))) foundEvents++;
		}
		assertEq(foundEvents, count, string.concat("Events don't match for ", eventEncoder));
	}
}
