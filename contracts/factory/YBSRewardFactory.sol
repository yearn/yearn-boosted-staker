// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20, SingleTokenRewardDistributor, IYearnBoostedStaker} from "../SingleTokenRewardDistributor.sol";


/// @title Deploys Rewards Distributor Contract
contract YBSRewardFactory{

    string public constant VERSION = "1.0.0";

    /**
        @notice Deploy new YBS Reward contract.
        @dev We use CREATE2 to generate deterministic deployments based on msg.sender.
    */
    function deploy(
        address _ybs,
        address _reward_token
    ) external returns (address distributor) {

        uint256 salt = uint256(uint160(address(msg.sender)));
        bytes memory bytecode = type(SingleTokenRewardDistributor).creationCode;
        bytes memory bytecodeWithArgs = abi.encodePacked(
            bytecode,
            abi.encode(_ybs, _reward_token)
        );
        address deployedAddress;
        assembly {
            deployedAddress := create2(0, add(bytecodeWithArgs, 0x20), mload(bytecodeWithArgs), salt)
        }
        require(deployedAddress != address(0), "Failed to deploy contract");

        return deployedAddress;
    }
}