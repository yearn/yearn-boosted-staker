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
        return address(new YBSUtilities(
            IYearnBoostedStaker(_ybs),
            IRewardsDistributor(_rewardsDistributor)
        ));
    }
}