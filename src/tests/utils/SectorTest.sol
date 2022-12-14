// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import { Test } from "forge-std/Test.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract SectorTest is Test {
	address manager = address(101);
	address guardian = address(102);
	address treasury = address(103);
	address owner = address(this);

	address user1 = address(201);
	address user2 = address(202);
	address user3 = address(203);
	address self = address(this);

	function _accessErrorString(bytes32 role, address account)
		internal
		pure
		returns (bytes memory)
	{
		return
			bytes(
				abi.encodePacked(
					"AccessControl: account ",
					Strings.toHexString(uint160(account), 20),
					" is missing role ",
					Strings.toHexString(uint256(role), 32)
				)
			);
	}
}
