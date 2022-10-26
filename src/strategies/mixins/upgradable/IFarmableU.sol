// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { IUniswapV2Router01 } from "../../../interfaces/uniswap/IUniswapV2Router01.sol";
import { IBaseU, HarvestSwapParams } from "./IBaseU.sol";

abstract contract IFarmableU is IBaseU {
	event HarvestedToken(address indexed token, uint256 amount);

	function _swap(
		IUniswapV2Router01 router,
		HarvestSwapParams calldata swapParams,
		address fromToken,
		uint256 amount
	) internal {
		address out = swapParams.path[swapParams.path.length - 1];
		// ensure malicious harvester is not trading with wrong tokens
		// TODO should we add more validation to prevent malicious path?
		require(
			((swapParams.path[0] == address(fromToken) && (out == address(short()))) ||
				out == address(underlying())),
			"IFarmable: BAD_PATH"
		);
		router.swapExactTokensForTokens(
			amount,
			swapParams.min,
			swapParams.path, // optimal route determined externally
			address(this),
			swapParams.deadline
		);
	}
}
