// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import "interfaces/IYearnBoostedStaker.sol";
import "utils/WeekStart.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";


contract SingleTokenRewardDistributor is WeekStart {
    using SafeERC20 for IERC20;

    uint constant MAX_BPS = 10_000;
    uint constant PRECISION = 1e18;
    IYearnBoostedStaker public immutable staker;
    IERC20 public immutable rewardToken;
    uint public immutable START_WEEK;
    address public owner;
    uint public weightedDepositIndex;

    struct AccountInfo {
        address recipient; // Who rewards will be sent to. Cheaper to store here than in dedicated mapping.
        uint64 lastClaimWeek;
    }

    mapping(uint week => uint amount) public weeklyRewardAmount;
    mapping(address account => uint week) public accountClaimWeek;
    mapping(address account => AccountInfo info) public accountInfo;
    mapping(address account => mapping(address claimer => bool approved)) public approvedClaimer;
    
    event RewardDeposited(uint indexed week, address indexed depositor, uint rewardAmount);
    event RewardsClaimed(address indexed account, uint indexed week, uint rewardAmount);
    event AccountConfigured(address indexed account, address indexed recipient);
    event WeightedDepositIndexSet(uint indexed idx);
    event OwnerSet(address indexed owner);

    /**
        @notice Allow permissionless deposits to the current week.
        @param _staker the staking contract to use for weight calculations.
        @param _rewardToekn address of reward token.
        @param _owner account with ability to enabled weighted staker deposits.
    */
    constructor(
        IYearnBoostedStaker _staker,
        IERC20 _rewardToekn,
        address _owner
    )
        WeekStart(_staker) {
        staker = _staker;
        rewardToken = _rewardToekn;
        owner = _owner;
        START_WEEK = staker.getWeek();
    }

    /**
        @notice Allow permissionless deposits to the current week.
        @param _amount the amount of reward token to deposit.
    */
    function depositReward(uint _amount) external {
        _depositReward(msg.sender, _amount);
    }

    /**
        @notice Allow permissionless deposits to the current week from any address with approval.
        @param _target the address to pull tokens from.
        @param _amount the amount of reward token to deposit.
    */
    function depositRewardFrom(address _target, uint _amount) external {
        _depositReward(_target, _amount);
    }

    function _depositReward(address _target, uint _amount) internal {
        uint week = getWeek();

        if (_amount > 0) {
            rewardToken.transferFrom(_target, address(this), _amount);
            weeklyRewardAmount[week] += _amount;
            emit RewardDeposited(week, _target, _amount);
        }
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user. All claims will retrieve 
                both tokens if available.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claim() external returns (uint amountClaimed) {
        uint currentWeek = getWeek();
        currentWeek = currentWeek == 0 ? 0 : currentWeek - 1;
        return _claimWithRange(msg.sender, 0, currentWeek);
    }

    /**
        @notice Claim on behalf of another account. Retrieves all owed rewards since the last week touched by the user. 
                All claims will retrieve both tokens if available.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimFor(address _account) external returns (uint amountClaimed) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        uint currentWeek = getWeek();
        currentWeek = currentWeek == 0 ? 0 : currentWeek - 1;
        return _claimWithRange(_account, 0, currentWeek);
    }

    /**
        @notice Claim rewards within a range of specified past weeks.
        @param _claimStartWeek the min week to search and rewards.
        @param _claimEndWeek the max week in which to search for an claim rewards.
        @dev    IMPORTANT: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
                may claim. Will result in the user being locked out (total loss) of rewards for any weeks prior.
    */
    function claimWithRange(
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint amountClaimed) {
        return _claimWithRange(msg.sender, _claimStartWeek, _claimEndWeek);
    }

    /**
        @notice Claim on behalf of another account for a range of specified past weeks.
        @param _account Account of which to make the claim on behalf of.
        @param _claimStartWeek The min week to search and rewards.
        @param _claimEndWeek The max week in which to search for an claim rewards.
        @dev    IMPORTANT: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
                may claim. Will result in the user being locked out (total loss) of rewards for any weeks prior.
        @dev    Useful to target specific weeks with known reward amounts. Claiming via this function will tend 
                to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimWithRangeFor(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint amountClaimed) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        return _claimWithRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _claimWithRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal returns (uint amountClaimed) {

        AccountInfo storage info = accountInfo[_account];

        // Sanitize inputs
        _claimStartWeek = info.lastClaimWeek == 0 ? START_WEEK : info.lastClaimWeek;
        uint currentWeek = getWeek();
        require(_claimStartWeek <= _claimEndWeek, "claimStartWeek > claimEndWeek");
        require(_claimEndWeek < currentWeek, "claimEndWeek >= currentWeek");
        require(_claimStartWeek >= info.lastClaimWeek, "claimStartWeek too low");
        amountClaimed = _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
        
        _claimEndWeek += 1;
        info.lastClaimWeek = uint64(_claimEndWeek);
        address recipient = info.recipient == address(0) ? _account : info.recipient;
        
        if (amountClaimed > 0) {
            rewardToken.transfer(recipient, amountClaimed);
            emit RewardsClaimed(_account, _claimEndWeek, amountClaimed);
        }
    }

    /**
        @notice Helper function used to determine overal share of rewards at a particular week.
        @dev    Computing account weight ratio in past weeks is accurate. However, current week 
                estimates will not accurate until the week is finalized.
        @dev    Results scaled to PRECSION.
    */
    function computeWeightRatio(address _account) external view returns (uint rewardShare) {
        return _computeWeightRatioAt(_account, getWeek());
    }

    function computeWeightRatioAt(address _account, uint _week) external view returns (uint rewardShare) {
        if (_week > getWeek()) return 0;
        return _computeWeightRatioAt(_account, _week);
    }

    function _computeWeightRatioAt(address _account, uint _week) internal view returns (uint rewardShare) {
        uint acctWeight = staker.getAccountWeightAt(_account, _week);
        if (acctWeight == 0) return 0; // User has no weight.
        uint globalWeight = staker.getGlobalWeightAt(_week);
        return acctWeight * PRECISION / globalWeight;
    }

    /**
        @dev Returns sum of both token types earned with the specified range of weeks.
    */
    function getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external view returns (uint claimable) {
        uint currentWeek = getWeek();
        if (_claimEndWeek >= currentWeek) _claimEndWeek = currentWeek;
        return _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal view returns (uint claimableAmount) {
        for (uint i = _claimStartWeek; i <= _claimEndWeek; i++) {
            uint claimable = getClaimableAt(_account, i);
            claimableAmount += claimable;
        }
    }

    function claimable(address _account) external view returns (uint claimable) {
        (uint claimStartWeek, uint claimEndWeek) = getSuggestedClaimRange(_account);
        return _getTotalClaimableByRange(claimStartWeek, claimEndWeek);
    }

    /**
        @notice Helper function returns suggested start and end range for claim weeks.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
    */
    function getSuggestedClaimRange(address _account) public view returns (uint claimStartWeek, uint claimEndWeek) {
        uint currentWeek = getWeek();
        if (currentWeek == 0) return (0, 0);
        bool canClaim;
        uint lastClaimWeek = accountInfo[_account].lastClaimWeek;
        
        claimStartWeek = START_WEEK > lastClaimWeek ? START_WEEK : lastClaimWeek;

        // Loop from old towards recent.
        for (claimStartWeek; claimStartWeek <= currentWeek; claimStartWeek++) {
            if (getClaimableAt(_account, claimStartWeek) > 0) {
                canClaim = true;
                break;
            }
        }

        if (!canClaim) return (0,0);

        // Loop backwards from recent week towards old. Skip current week.
        for (claimEndWeek = currentWeek - 1; claimEndWeek > claimStartWeek; claimEndWeek--) {
            if (getClaimableAt(_account, claimEndWeek) > 0) {
                break;
            }
        }

        return (claimStartWeek, claimEndWeek);
    }

    /**
        @notice Returns suggested start and end range for claim weeks.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
        @param _account The account to claim for.
        @param _week The past week to claim for.
    */
    function getClaimableAt(
        address _account, 
        uint _week
    ) public view returns (uint rewardAmount) {
        uint currentWeek = getWeek();
        if(_week >= currentWeek) return 0;
        if(_week < accountInfo[_account].lastClaimWeek) return 0;
        uint rewardShare = _computeWeightRatioAt(_account, _week);
        uint totalWeeklyAmount = weeklyRewardAmount[_week];
        rewardAmount = totalWeeklyAmount == 0 ? 0 : rewardShare * totalWeeklyAmount / PRECISION;
    }

    function _onlyClaimers(address _account) internal returns (bool approved) {
        return approvedClaimer[_account][msg.sender] || _account == msg.sender;
    }

    /**
        @notice User may configure their account to set a custom reward recipient.
        @param _recipient   Wallet to receive tokens on behalf of the account. Zero address will result in all tokens
                            being transferred directly to the account holder.
    */
    function configureRecipient(address _recipient) external {
        accountInfo[msg.sender].recipient = _recipient;
        emit AccountConfigured(msg.sender, _recipient);
    }

    /**
        @notice Used by owner to control instant boost level of weighted deposits.
        @dev    Supplying an idx of 0 is least weighted. Max available index is equal to MAX_STAKE_GROWTH_WEEKS
                value in the staker, and amounts to instant full boost.
        @param _idx The index that all weighted deposits should use.
    */
    function setWeightedDepositIndex(uint _idx) external {
        require(msg.sender == owner);
        require(_idx <= staker.MAX_STAKE_GROWTH_WEEKS(), "too high");
        weightedDepositIndex = _idx;
        emit WeightedDepositIndexSet(_idx);
    }

    /**
        @notice Set new owner address.
        @param _owner New owner address
    */
    function setOwner(address _owner) external {
        require(msg.sender == owner);
        owner = _owner;
        emit OwnerSet(_owner);
    }
}