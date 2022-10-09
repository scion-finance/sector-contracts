// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import { SectorTest } from "../utils/SectorTest.sol";
import { PostOffice } from "../../postOffice/PostOffice.sol";
import { LayerZeroPostman, chainPair } from "../../postOffice/LayerZeroPostman.sol";
import { MultichainPostman } from "../../postOffice/MultichainPostman.sol";
import { IERC20Metadata as IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../interfaces/MsgStructs.sol";

import "hardhat/console.sol";

contract PostOfficeTest is SectorTest {
	PostOffice postOffice;
	LayerZeroPostman LZpostman;
	MultichainPostman MCpostman;

	string AVAX_RPC_URL = vm.envString('FUJI_RPC_URL');
	// uint256 AVAX_BLOCK = vm.envUint("AVAX_BLOCK");
	uint256 avaxFork;
	address AVAX_LAYERZERO_ENDPOINT = 0x93f54D755A063cE7bB9e6Ac47Eccc8e33411d706;
	address AVAX_MULTICHAIN_ENDPOINT = 0xC10Ef9F491C9B59f936957026020C321651ac078;

	IERC20 usdc = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);
	IERC20 avax = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);

	function setUp() public {
		avaxFork = vm.createFork(AVAX_RPC_URL);
		vm.selectFork(avaxFork);

        chainPair[] memory pairArray = new chainPair[](2);
        pairArray[0] = chainPair(4002, 10112);
        pairArray[1] = chainPair(43113, 10106);

		postOffice = new PostOffice();
		LZpostman = new LayerZeroPostman(AVAX_LAYERZERO_ENDPOINT, address(postOffice), pairArray);


        vm.deal(address(LZpostman), 100e18);
	}

	function testSendMessage() public {
		address _srcVault = user1;
		address _dstVault = 0xC10Ef9F491C9B59f936957026020C321651ac078;
		address _dstPostman = 0xa271D197D378d10B79637A03310F6304A8efc3CE;
		Message memory _msg = Message(1000, _srcVault, address(0), uint16(block.chainid));

		// postman with id == 1
		postOffice.addPostman(address(LZpostman));

        console.log(address(LZpostman));

		// postman with id == 2
		postOffice.addPostman(_dstPostman);

		// set new client with postmen to send messages to ethereum mainnet
		postOffice.addClient(_srcVault, 1, 2, uint16(block.chainid));
		postOffice.addClient(_dstVault, 1, 2, 43113);

		vm.startPrank(_srcVault);

		postOffice.sendMessage(_dstVault, _msg, messageType.DEPOSIT);

		vm.stopPrank();
	}
}
