// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;
import "../interfaces/IYearnBoostedStaker.sol";

/**
    @title Week Start
    @dev Provides a unified `START_TIME` and `getWeek` aligned with the staker.
 */
contract WeekStart {
    uint256 public immutable START_TIME;

    constructor(IYearnBoostedStaker staker) {
        START_TIME = staker.START_TIME();
    }

    function getWeek() public view returns (uint256 week) {
        return (block.timestamp - START_TIME) / 1 weeks;
    }
}
