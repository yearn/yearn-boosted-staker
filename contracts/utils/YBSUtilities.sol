// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/IERC20.sol";

import "../interfaces/IYearnBoostedStaker.sol";
import "../interfaces/IRewardsDistributor.sol";

contract YBSUtilities {

    uint constant PRECISION = 1e18;
    uint public immutable MAX_STAKE_GROWTH_WEEKS;
    IERC20 public immutable TOKEN;
    IYearnBoostedStaker public immutable YBS;
    IRewardsDistributor public immutable REWARDS_DISTRIBUTOR;

    constructor(
        IYearnBoostedStaker _ybs,
        IRewardsDistributor _rewardsDistributor
    ) {
        YBS = _ybs;
        REWARDS_DISTRIBUTOR = _rewardsDistributor;
        TOKEN = YBS.stakeToken();
        MAX_STAKE_GROWTH_WEEKS = YBS.MAX_STAKE_GROWTH_WEEKS();
    }

    function getUserBoostMultiplier(address _user) external view returns (uint) {
        uint balance = YBS.balanceOf(_user);
        if (balance == 0) return 0;
        uint weight = YBS.getAccountWeight(_user);
        if (weight == 0) return 0;
        return weight * PRECISION / balance;
    }

    function getGlobalAverageBoostMultiplier() public view returns (uint) {
        uint supply = YBS.totalSupply();
        if (supply == 0) return 0;
        uint weight = YBS.getGlobalWeight();
        if (weight == 0) return 0;
        return weight * PRECISION / supply;
    }
    

    // Can only get for current week. pr
    function getGlobalAverageApr(uint _stakeTokenPrice, uint _rewardTokenPrice) public view returns (uint) {
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint week = getWeek();
        if(week == 0) return 0;
        week -= 1;
        uint rewardsAmount = weeklyRewardAmountAt(week);
        if (rewardsAmount == 0) return 0;
        uint supply = YBS.totalSupply();
        if (supply == 0) return 0;
        return (
            rewardsAmount * 
            _rewardTokenPrice * 
            PRECISION /
            (supply * _stakeTokenPrice)
        );
    }

    function getGlobalMinMaxApr(uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint min, uint max) {
        uint avgApr = getGlobalAverageApr(_stakeTokenPrice, _rewardTokenPrice);
        if(avgApr == 0) return (0, 0);
        uint avgBoost = getGlobalAverageBoostMultiplier();
        if(avgBoost == 0) return (0, 0);
        uint minApr = avgApr * _minBoost() / avgBoost;
        uint maxApr = avgApr * _maxBoost() / avgBoost;
        return (minApr, maxApr);
    }

    function _minBoost() internal pure returns (uint) {
        return PRECISION / 2;
    }

    function _maxBoost() internal view returns (uint) {
        return _minBoost() * (MAX_STAKE_GROWTH_WEEKS + 1);
    }

    
    function getUserApr(address _account, uint _stakeTokenPrice, uint _rewardTokenPrice) external view returns (uint) {
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint week = getWeek();
        if(week == 0) return 0;
        week -= 1;
        return getUserAprAt(_account, week, _stakeTokenPrice, _rewardTokenPrice);
    }

    // Pass in week from last week to find active apr
    function getUserAprAt(address _account, uint _week, uint _stakeTokenPrice, uint _rewardTokenPrice) public view returns (uint) {
        uint rewardsAmount = weeklyRewardAmountAt(_week);
        if (rewardsAmount == 0) return 0;
        uint userShare = REWARDS_DISTRIBUTOR.computeSharesAt(_account, _week);
        if (userShare == 0) return 0;
        uint userRewards = userShare * rewardsAmount;
        if (userRewards == 0) return 0;
        uint userStakedBalance = YBS.balanceOf(_account);
        if (userStakedBalance == 0) return 0;
        return (_rewardTokenPrice * userRewards) / (userStakedBalance * _stakeTokenPrice);
    }
    
    function weeklyRewardAmount() external view returns (uint) {
        uint week = getWeek();
        if(week == 0) return 0;
        week -= 1;
        return weeklyRewardAmountAt(week);
    }

    function weeklyRewardAmountAt(uint _week) public view returns (uint) {
        return REWARDS_DISTRIBUTOR.weeklyRewardAmount(_week);
    }

    function getWeek() public view returns (uint) {
        return YBS.getWeek();
    }
}