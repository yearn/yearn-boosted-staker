// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20, YBSUtilities, IRewardsDistributor, IYearnBoostedStaker} from "../utils/YBSUtilities.sol";


/// @title Deploys Rewards Distributor Contract
contract YBSUtilsFactory{

    string public constant VERSION = "1.0.0";

    function deploy(
        address _ybs,
        address _rewardsDistributor
    ) external returns (address utils) {
        uint256 salt = uint256(uint160(address(msg.sender)));
        bytes memory bytecode = type(YBSUtilities).creationCode;
        bytes memory bytecodeWithArgs = abi.encodePacked(
            bytecode,
            abi.encode(_ybs, _rewardsDistributor)
        );
        address deployedAddress;
        assembly {
            deployedAddress := create2(0, add(bytecodeWithArgs, 0x20), mload(bytecodeWithArgs), salt)
        }
        require(deployedAddress != address(0), "Failed to deploy contract");

        return deployedAddress;
    }
}