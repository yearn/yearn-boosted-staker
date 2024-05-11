// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {YearnBoostedStaker} from "../YearnBoostedStaker.sol";


/// @title Deploys Rewards Distributor Contract
contract YBSFactory{

    string public constant VERSION = "1.0.0";

    function deploy(
        address _token,
        uint _max_stake_growth_weeks,
        uint _start_time,
        address _owner
    ) external returns (address distributor) {
        return address(new YearnBoostedStaker(
            _token,
            _max_stake_growth_weeks,
            _start_time,
            _owner
        ));
    }
}