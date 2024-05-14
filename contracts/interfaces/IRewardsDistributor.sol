// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRewardsDistributor {
    // Structs
    struct AccountInfo {
        address recipient; // Who rewards will be sent to.
        uint96 lastClaimWeek;
    }

    // Events
    event RewardDeposited(uint indexed week, address indexed depositor, uint rewardAmount);
    event RewardsClaimed(address indexed account, uint indexed week, uint rewardAmount);
    event RecipientConfigured(address indexed account, address indexed recipient);
    event ClaimerApproved(address indexed account, address indexed claimer, bool approved);

    // Functions
    function staker() external view returns (address);
    function rewardToken() external view returns (address);
    function depositReward(uint _amount) external;
    function depositRewardFrom(address _target, uint _amount) external;
    function claim() external returns (uint amountClaimed);
    function claimFor(address _account) external returns (uint amountClaimed);
    function claimWithRange(uint _claimStartWeek, uint _claimEndWeek) external returns (uint amountClaimed);
    function claimWithRangeFor(address _account, uint _claimStartWeek, uint _claimEndWeek) external returns (uint amountClaimed);
    function computeSharesAt(address _account, uint _week) external view returns (uint rewardShare);
    function getClaimable(address _account) external view returns (uint claimable);
    function getTotalClaimableByRange(address _account, uint _claimStartWeek, uint _claimEndWeek) external view returns (uint claimable);
    function getSuggestedClaimRange(address _account) external view returns (uint claimStartWeek, uint claimEndWeek);
    function getClaimableAt(address _account, uint _week) external view returns (uint rewardAmount);
    function configureRecipient(address _recipient) external;
    function approveClaimer(address _claimer, bool _approved) external;
    function getWeek() external view returns (uint);
    function weeklyRewardAmount(uint) external view returns (uint);
    function pushRewards(uint _week) external returns (bool);
}
