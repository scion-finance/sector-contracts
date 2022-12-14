// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import { MockERC20 as ERC20 } from "./MockERC20.sol";
import { Test } from "forge-std/Test.sol";

import { SafeETH } from "../../libraries/SafeETH.sol";

import "hardhat/console.sol";

/// @notice Minimalist and modern Wrapped Ether implementation.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/tokens/WETH.sol)
/// @author Inspired by WETH9 (https://github.com/dapphub/ds-weth/blob/master/src/weth9.sol)
contract WETH is ERC20("Wrapped Ether", "WETH", 18), Test {
	using SafeETH for address;

	event Deposit(address indexed from, uint256 amount);

	event Withdrawal(address indexed to, uint256 amount);

	function deposit() public payable virtual {
		_mint(msg.sender, msg.value);

		emit Deposit(msg.sender, msg.value);
	}

	function withdraw(uint256 amount) public virtual {
		_burn(msg.sender, amount);

		emit Withdrawal(msg.sender, amount);
		deal(address(this), amount);
		msg.sender.safeTransferETH(amount);
	}

	receive() external payable virtual {
		deposit();
	}
}
