// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20, SingleTokenRewardDistributor, IYearnBoostedStaker} from "../SingleTokenRewardDistributor.sol";


/// @title Deploys Rewards Distributor Contract
contract YBSRewardsFactory{

    string public constant VERSION = "1.0.0";

    function deploy(
        address _ybs,
        address _reward_token
    ) external returns (address distributor) {
        return address(new SingleTokenRewardDistributor(
            IYearnBoostedStaker(_ybs),
            IERC20(_reward_token)
        ));
    }
}