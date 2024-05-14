// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IYearnBoostedStaker {
    struct AccountData {
        uint112 realizedStake;
        uint112 pendingStake;
        uint16 lastUpdateWeek;
        uint8 updateWeeksBitmap;
    }

    struct ToRealize {
        uint112 weightPersistent;
        uint112 weight;
    }

    enum ApprovalStatus {
        None,
        StakeOnly,
        UnstakeOnly,
        StakeAndUnstake
    }

    // State variables
    function MAX_STAKE_GROWTH_WEEKS() external view returns (uint);
    function MAX_WEEK_BIT() external view returns (uint8);
    function START_TIME() external view returns (uint);
    function stakeToken() external view returns (IERC20);
    function globalGrowthRate() external view returns (uint112);
    function globalLastUpdateWeek() external view returns (uint16);
    function totalSupply() external view returns (uint);
    function decimals() external view returns (uint8);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function approvedCaller(address account, address caller) external view returns (ApprovalStatus);
    function approvedWeightedStaker(address staker) external view returns (bool);
    function accountWeeklyToRealize(address account, uint week) external view returns (ToRealize memory);
    function globalWeeklyToRealize(uint week) external view returns (ToRealize memory);
    function accountWeeklyMaxStake(address account, uint week) external view returns (uint);
    function globalWeeklyMaxStake(uint week) external view returns (uint);

    // Events
    event Stake(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightAdded);
    event Unstake(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightRemoved);
    event ApprovedCallerSet(address indexed account, address indexed caller, ApprovalStatus status);
    event WeightedStakerSet(address indexed staker, bool approved);
    event OwnershipTransferred(address indexed newOwner);

    // Functions
    function stake(uint _amount) external returns (uint);
    function stakeFor(address _account, uint _amount) external returns (uint);
    function stakeAsMaxWeighted(address _account, uint _amount) external returns (uint);
    function unstake(uint _amount, address _receiver) external returns (uint);
    function unstakeFor(address _account, uint _amount, address _receiver) external returns (uint);

    function checkpointAccount(address _account) external returns (AccountData memory acctData, uint weight);
    function checkpointAccountWithLimit(address _account, uint _week) external returns (AccountData memory acctData, uint weight);

    function getAccountWeight(address account) external view returns (uint);
    function getAccountWeightAt(address _account, uint _week) external view returns (uint);

    function checkpointGlobal() external returns (uint);
    function getGlobalWeight() external view returns (uint);
    function getGlobalWeightAt(uint week) external view returns (uint);

    function getAccountWeightRatio(address _account) external view returns (uint);
    function getAccountWeightRatioAt(address _account, uint _week) external view returns (uint);

    function balanceOf(address _account) external view returns (uint);
    function setApprovedCaller(address _caller, ApprovalStatus _status) external;
    function setWeightedStaker(address _staker, bool _approved) external;

    function transferOwnership(address _pendingOwner) external;
    function acceptOwnership() external;

    function sweep(address _token) external;
    function getWeek() external view returns (uint);
}