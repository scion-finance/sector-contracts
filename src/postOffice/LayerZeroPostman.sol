// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.16;

import { ILayerZeroReceiver } from "../interfaces/adapters/ILayerZeroReceiver.sol";
import { ILayerZeroEndpoint } from "../interfaces/adapters/ILayerZeroEndpoint.sol";
import { ILayerZeroUserApplicationConfig } from "../interfaces/adapters/ILayerZeroUserApplicationConfig.sol";
// import { IPostOffice } from "../interfaces/postOffice/IPostOffice.sol";
import { IPostman } from "../interfaces/postOffice/IPostman.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { XChainIntegrator } from "../common/XChainIntegrator.sol";
import "../interfaces/MsgStructs.sol";

struct chainPair {
	uint16 from;
	uint16 to;
}

contract LayerZeroPostman is
	ILayerZeroReceiver,
	ILayerZeroUserApplicationConfig,
	IPostman,
	Ownable
{
	ILayerZeroEndpoint public endpoint;
	// IPostOffice public immutable postOffice;

	// map original chainIds to layerZero's chainIds
	mapping(uint16 => uint16) chains;

	constructor(address _layerZeroEndpoint, chainPair[] memory chainPairArr) {
		endpoint = ILayerZeroEndpoint(_layerZeroEndpoint);

		uint256 length = chainPairArr.length;
		for (uint256 i = 0; i < length; ) {
			chainPair memory pair = chainPairArr[i];
			chains[pair.from] = pair.to;

			unchecked {
				i++;
			}
		}
	}

	function deliverMessage(
		Message calldata _msg,
		address _dstVautAddress,
		address _dstPostman,
		messageType _messageType,
		uint16 _dstChainId
	) external {
		// if (msg.sender != address(postOffice)) revert OnlyPostOffice();
		if (address(this).balance == 0) revert NoBalance();

		bytes memory payload = abi.encode(_msg, _dstVautAddress, _messageType);

		// encode adapterParams to specify more gas for the destination
		uint16 version = 1;
		uint256 gasForDestinationLzReceive = 350000;
		bytes memory adapterParams = abi.encodePacked(version, gasForDestinationLzReceive);

		(uint256 messageFee, ) = endpoint.estimateFees(
			uint16(chains[_dstChainId]),
			address(this),
			payload,
			false,
			adapterParams
		);
		if (address(this).balance < messageFee) revert InsufficientBalanceToSendMessage();

		// send LayerZero message
		endpoint.send{ value: messageFee }( // {value: messageFee} will be paid out of this contract!
			uint16(chains[_dstChainId]), // destination chainId
			abi.encodePacked(_dstPostman), // destination address of postman on dst chain
			payload, // abi.encode()'ed bytes
			payable(this), // (msg.sender will be this contract) refund address (LayerZero will refund any extra gas back to caller of send()
			address(0x0), // 'zroPaymentAddress' unused for this mock/example
			adapterParams // 'adapterParams' unused for this mock/example
		);
	}

	function lzReceive(
		uint16 _srcChainId,
		bytes memory,
		uint64, /*_nonce*/
		bytes memory _payload
	) external override {
		// lzReceive can only be called by the LayerZero endpoint
		if (msg.sender != address(endpoint)) revert Unauthorized();

		// decode payload sent from source chain
		(Message memory _msg, address _dstVaultAddress, uint16 _messageType) = abi.decode(
			_payload,
			(Message, address, uint16)
		);

		emit MessageReceived(_msg.sender, _msg.value, _dstVaultAddress, _messageType, _srcChainId);

		// Send message to dst vault
		XChainIntegrator(_dstVaultAddress).receiveMessage(_msg, messageType(_messageType));
	}

	// With this access control structure we need a way to vault set chain.
	function setChain(uint16 _chainId, uint16 _lzChainId) external onlyOwner {
		chains[_chainId] = _lzChainId;
	}

	function setConfig(
		uint16,
		uint16 _dstChainId,
		uint256 _configType,
		bytes memory _config
	) external override onlyOwner {
		endpoint.setConfig(
			chains[_dstChainId],
			endpoint.getSendVersion(address(this)),
			_configType,
			_config
		);
	}

	function getConfig(
		uint16,
		uint16 _chainId,
		address,
		uint256 _configType
	) external view returns (bytes memory) {
		return
			endpoint.getConfig(
				endpoint.getSendVersion(address(this)),
				_chainId,
				address(this),
				_configType
			);
	}

	function setSendVersion(uint16 version) external override onlyOwner {
		endpoint.setSendVersion(version);
	}

	function setReceiveVersion(uint16 version) external override onlyOwner {
		endpoint.setReceiveVersion(version);
	}

	function getSendVersion() external view returns (uint16) {
		return endpoint.getSendVersion(address(this));
	}

	function getReceiveVersion() external view returns (uint16) {
		return endpoint.getReceiveVersion(address(this));
	}

	function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override {
		// do nth
	}

	// allow this contract to receive ether
	fallback() external payable {}

	receive() external payable {}

	/* EVENTS */
	event MessageReceived(
		address srcVaultAddress,
		uint256 amount,
		address dstVaultAddress,
		uint16 messageType,
		uint256 srcChainId
	);

	/* ERRORS */
	error Unauthorized();
	error NoBalance();
	error InsufficientBalanceToSendMessage();
	error OnlyPostOffice();
}
