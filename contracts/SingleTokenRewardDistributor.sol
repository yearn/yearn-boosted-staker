// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import "utils/WeekStart.sol";
import {IYearnBoostedStaker} from "interfaces/IYearnBoostedStaker.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";


contract SingleTokenRewardDistributor is WeekStart {
    using SafeERC20 for IERC20;

    uint constant PRECISION = 1e18;
    IYearnBoostedStaker public immutable staker;
    IERC20 public immutable rewardToken;
    uint public immutable START_WEEK;
    uint immutable MAX_STAKE_GROWTH_WEEKS;

    struct AccountInfo {
        address recipient; // Who rewards will be sent to. Cheaper to store here than in dedicated mapping.
        uint96 lastClaimWeek;
    }

    mapping(uint week => uint amount) public weeklyRewardAmount;
    mapping(address account => AccountInfo info) public accountInfo;
    mapping(address account => mapping(address claimer => bool approved)) public approvedClaimer;
    
    event RewardDeposited(uint indexed week, address indexed depositor, uint rewardAmount);
    event RewardsClaimed(address indexed account, uint indexed week, uint rewardAmount);
    event RecipientConfigured(address indexed account, address indexed recipient);
    event ClaimerApproved(address indexed account, address indexed, bool approved);
    event RewardPushed(uint indexed fromWeek, uint indexed toWeek, uint amount);

    /**
        @param _staker the staking contract to use for weight calculations.
        @param _rewardToken address of reward token to be used.
    */
    constructor(
        IYearnBoostedStaker _staker,
        IERC20 _rewardToken
    )
        WeekStart(_staker) {
        staker = _staker;
        rewardToken = _rewardToken;
        START_WEEK = staker.getWeek();
        MAX_STAKE_GROWTH_WEEKS = staker.MAX_STAKE_GROWTH_WEEKS();
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
        if (_amount > 0) {
            uint week = getWeek();
            weeklyRewardAmount[week] += _amount;
            rewardToken.safeTransferFrom(_target, address(this), _amount);
            emit RewardDeposited(week, _target, _amount);
        }
    }

    /**
        @notice Push inaccessible rewards to current week.
        @dev    In rare circumstances, rewards may have been deposited to a week where no adjusted weight exists.
                This function allows us to recover rewards to the current week.
        @param _week the week to push rewards from.
        @return true if operation was successful.
    */
    function pushRewards(uint _week) external returns (bool) {
        uint week = getWeek();
        // The following logic prevents unrecoverable rewards by blocking deposits to weeks where we know
        // there will be no users with a claim. This has to do with the security measure 
        // implemented in `computeSharesAt`, blocking amounts from earning rewards in their 
        // first week after staking.
        uint amount = pushableRewards(_week);
        if(amount == 0) return false;
        weeklyRewardAmount[_week] = 0;
        weeklyRewardAmount[week] += amount;
        emit RewardPushed(_week, week, amount);
        return true;
    }

    /**
        @notice Helper view function to check if any rewards are pushable.
        @param _week the week to push rewards from.
        @return uint representing rewards amount that is pushable.
    */
    function pushableRewards(uint _week) public view returns (uint) {
        uint week = getWeek();
        if(_week >= week) return 0;
        if(adjustedGlobalWeightAt(_week) != 0) return 0;
        return weeklyRewardAmount[_week];
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user.
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
        @dev    WARNING: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
                may claim will result in the user being locked out (total loss) of rewards for any weeks prior.
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
        uint currentWeek = getWeek();
        if(_claimEndWeek >= currentWeek) return 0;

        AccountInfo storage info = accountInfo[_account];
        
        // Sanitize inputs
        uint _minStartWeek = info.lastClaimWeek == 0 ? START_WEEK : info.lastClaimWeek;
        _claimStartWeek = max(_minStartWeek, _claimStartWeek);
        if(_claimStartWeek > _claimEndWeek) return 0;
        
        amountClaimed = _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
        
        _claimEndWeek += 1;
        info.lastClaimWeek = uint96(_claimEndWeek);
        address recipient = info.recipient == address(0) ? _account : info.recipient;
        
        if (amountClaimed > 0) {
            rewardToken.safeTransfer(recipient, amountClaimed);
            emit RewardsClaimed(_account, _claimEndWeek, amountClaimed);
        }
    }

    /**
        @notice Helper function used to determine overal share of rewards at a particular week.
        @dev    IMPORTANT: This calculation cannot be relied upon to return strictly the users weight
                against global weight as it implements custom logic to ignore the first week of each deposit.
        @dev    Computing shares in past weeks is accurate. However, current week computations will not 
                be accurate until week is finalized.
        @dev    Results scaled to PRECSION.
    */
    function computeSharesAt(address _account, uint _week) public view returns (uint) {
        require(_week <= getWeek(), "Invalid week");
        // As a security measure, we don't distribute rewards to YBS deposits on their first full week of staking.
        // To acheive this, we lookup the weight that was added in the target week and ignore it.
        uint adjAcctWeight = adjustedAccountWeightAt(_account, _week);
        if (adjAcctWeight == 0) return 0;
        
        uint adjGlobalWeight = adjustedGlobalWeightAt(_week);
        if (adjGlobalWeight == 0) return 0;

        return adjAcctWeight * PRECISION / adjGlobalWeight;
    }

    function adjustedAccountWeightAt(address _account, uint _week) public view returns (uint) {
        uint acctWeight = staker.getAccountWeightAt(_account, _week);
        if (acctWeight == 0) return 0;
        return acctWeight - staker.accountWeeklyToRealize(_account, _week + MAX_STAKE_GROWTH_WEEKS).weightPersistent;
    }

    function adjustedGlobalWeightAt(uint _week) public view returns (uint) {
        uint globalWeight = staker.getGlobalWeightAt(_week);
        if (globalWeight == 0) return 0;
        return globalWeight - staker.globalWeeklyToRealize(_week + MAX_STAKE_GROWTH_WEEKS).weightPersistent;
    }

    /**
        @notice Get the sum total number of claimable tokens for a user across all his claimable weeks.
    */
    function getClaimable(address _account) external view returns (uint claimable) {
        (uint claimStartWeek, uint claimEndWeek) = getSuggestedClaimRange(_account);
        return _getTotalClaimableByRange(_account, claimStartWeek, claimEndWeek);
    }

    /**
        @notice Returns sum of tokens earned with a specified range of weeks.
        @param _account Account to query.
        @param _claimStartWeek Week to begin querying from.
        @param _claimEndWeek Week to end querying at.
    */
    function getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external view returns (uint claimable) {
        uint currentWeek = getWeek();
        if (_claimEndWeek > currentWeek) _claimEndWeek = currentWeek;
        return _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal view returns (uint claimableAmount) {
        for (uint i = _claimStartWeek; i <= _claimEndWeek; ++i) {
            claimableAmount += getClaimableAt(_account, i);
        }
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
        @notice Get the reward amount available at a given week index.
        @param _account The account to check.
        @param _week The past week to check.
    */
    function getClaimableAt(
        address _account, 
        uint _week
    ) public view returns (uint rewardAmount) {
        if(_week >= getWeek()) return 0;
        if(_week < accountInfo[_account].lastClaimWeek) return 0;
        uint rewardShare = computeSharesAt(_account, _week);
        uint totalWeeklyAmount = weeklyRewardAmount[_week];
        rewardAmount = rewardShare * totalWeeklyAmount / PRECISION;
    }

    function _onlyClaimers(address _account) internal view returns (bool approved) {
        return approvedClaimer[_account][msg.sender] || _account == msg.sender;
    }

    /**
        @notice User may configure their account to set a custom reward recipient.
        @param _recipient   Wallet to receive rewards on behalf of the account. Zero address will result in all 
                            rewards being transferred directly to the account holder.
    */
    function configureRecipient(address _recipient) external {
        accountInfo[msg.sender].recipient = _recipient;
        emit RecipientConfigured(msg.sender, _recipient);
    }

    /**
        @notice Allow account to specify addresses to claim on their behalf.
        @param _claimer Claimer to approve or revoke
        @param _approved True to approve, False to revoke.
    */
    function approveClaimer(address _claimer, bool _approved) external {
        approvedClaimer[msg.sender][_claimer] = _approved;
        emit ClaimerApproved(msg.sender, _claimer, _approved);
    }

    function max(uint a, uint b) internal pure returns (uint) {
        return a < b ? b : a;
    }
}