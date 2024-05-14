// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IYBSUtilities {
    // Constants
    function PRECISION() external view returns (uint);
    function WEEKS_PER_YEAR() external view returns (uint);

    // Immutables
    function MAX_STAKE_GROWTH_WEEKS() external view returns (uint);
    function TOKEN() external view returns (IERC20);
    function YBS() external view returns (address);
    function REWARDS_DISTRIBUTOR() external view returns (address);

    // Calculation functions
    function getUserActiveBoostMultiplier(address _user) external view returns (uint);
    function getUserProjectedBoostMultiplier(address _user) external view returns (uint);
    function getUserActiveApr(address _account, uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint);
    function getUserProjectedApr(address _account, uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint);

    function getGlobalActiveBoostMultiplier() external view returns (uint);
    function getGlobalProjectedBoostMultiplier() external view returns (uint);
    function getGlobalActiveApr(uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint);
    function getGlobalProjectedApr(uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint);

    function getGlobalMinMaxActiveApr(uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint min, uint max);
    function getGlobalMinMaxProjectedApr(uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint min, uint max);

    // Stake-related functions
    function getAccountStakeAmountAt(address _account, uint _week) external view returns (uint);
    function getGlobalStakeAmountAt(uint _week) external view returns (uint);

    // Reward functions
    function activeRewardAmount() external view returns (uint);
    function projectedRewardAmount() external view returns (uint);
    function weeklyRewardAmountAt(uint _week) external view returns (uint);

    // Time function
    function getWeek() external view returns (uint);
}