// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import "interfaces/IYearnBoostedStaker.sol";
import "utils/WeekStart.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";


contract TwoTokenRewardDistributor is WeekStart {
    using SafeERC20 for IERC20;

    uint constant MAX_BPS = 10_000;
    uint constant PRECISION = 1e8;
    IYearnBoostedStaker public immutable staker;
    IERC20 public immutable govToken;
    IERC20 public immutable stableToken;
    uint public immutable START_WEEK;
    address public gov;
    uint public weightedDepositIndex;

    struct RewardInfo {
        uint128 amountGov;
        uint128 amountStable;
    }

    struct AccountInfo {
        bool autoStake;
        uint64 lastClaimWeek;
    }

    mapping(uint week => RewardInfo rewardInfo) public weeklyRewardInfo;
    mapping(address account => uint week) public accountClaimWeek;
    mapping(address account => AccountInfo info) public accountInfo;
    mapping(address account => mapping(address claimer => bool approved)) public approvedClaimer;
    
    event RewardDeposited(uint indexed week, address indexed depositor, uint govTokenAmount, uint stableTokenAmount);
    event RewardsClaimed(address indexed account, uint indexed week, uint govTokenAmount, uint stableTokenAmount);
    event AutoStakeSet(address indexed account, bool indexed autoStake);
    event WeightedDepositIndexSet(uint indexed idx);
    event GovernanceSet(address indexed gov);

    constructor(
        IYearnBoostedStaker _staker,
        IERC20 _govToken, 
        IERC20 _stableToken,
        address _gov
    )
        WeekStart(_staker) {
        staker = _staker;
        govToken = _govToken;
        stableToken = _stableToken;
        gov = _gov;
        START_WEEK = staker.getWeek();
        govToken.approve(address(staker), type(uint).max);
    }

    /**
        @notice Allow permissionless deposits to the current week.
        @param _amountGov the amount of governance tokens to receive.
        @param _amountStable the amount of stable tokens to receive.
    */
    function depositRewards(uint _amountGov, uint _amountStable) external {
        _depositRewards(msg.sender, _amountGov, _amountStable);
    }

    /**
        @notice Allow permissionless deposits to the current week from any address with approval.
        @param _target the address to pull tokens from.
        @param _amountGov the amount of governance tokens to receive.
        @param _amountStable the amount of stable tokens to receive.
    */
    function depositRewardsFrom(address _target, uint _amountGov, uint _amountStable) external {
        _depositRewards(_target, _amountGov, _amountStable);
    }

    function _depositRewards(address _target, uint _amountGov, uint _amountStable) internal {
        uint week = getWeek();

        RewardInfo memory info = weeklyRewardInfo[week];
        if (_amountGov > 0) {
            govToken.transferFrom(_target, address(this), _amountGov);
            info.amountGov += uint128(_amountGov);
        }
        if (_amountStable > 0) {
            stableToken.transferFrom(_target, address(this), _amountStable);
            info.amountStable += uint128(_amountStable);
        }

        weeklyRewardInfo[week] = info;
        
        emit RewardDeposited(week, _target, _amountGov, _amountStable);
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user. All claims will retrieve 
                both tokens if available.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claim() external returns (uint tokenGovAmount, uint tokenStablesAmount) {
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
    function claimFor(address _account) external returns (uint tokenGovAmount, uint tokenStablesAmount) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        uint currentWeek = getWeek();
        currentWeek = currentWeek == 0 ? 0 : currentWeek - 1;
        return _claimWithRange(_account, 0, currentWeek);
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user. Retrieves both tokens if available.
        @dev    Claiming via this function will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimWithRange(
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint tokenGovAmount, uint tokenStablesAmount) {
        return _claimWithRange(msg.sender, _claimStartWeek, _claimEndWeek);
    }

    /**
        @notice Claim on behalf of another account. Claims all owed rewards since the last week touched by the user. 
                Retrieves both tokens if available.
        @dev    Claiming via this function will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimWithRangeFor(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint tokenGovAmount, uint tokenStablesAmount) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        return _claimWithRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _claimWithRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal returns (uint tokenGovAmount, uint tokenStablesAmount) {
        AccountInfo memory info = accountInfo[_account];
        // Sanitize inputs
        if (_claimStartWeek < START_WEEK) _claimStartWeek = START_WEEK;
        if (_claimStartWeek < info.lastClaimWeek) _claimStartWeek = info.lastClaimWeek;
        uint currentWeek = getWeek();
        require(_claimStartWeek < currentWeek, "claimStartWeek >= currentWeek");
        require(_claimEndWeek < currentWeek, "claimEndWeek >= currentWeek");
        require(_claimStartWeek >= info.lastClaimWeek, "claimStartWeek too low");
        (tokenGovAmount, tokenStablesAmount) = _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek + 1);
        if (info.autoStake && tokenGovAmount > 0) {
            if (staker.approvedWeightedDepositor(address(this))) {
                staker.depositAsWeighted(_account, tokenGovAmount, weightedDepositIndex);
            }
            else {
                staker.depositFor(_account, tokenGovAmount);
            }
            
        }
        else{
            govToken.transfer(_account, tokenGovAmount);
        }
        if (tokenStablesAmount > 0) stableToken.transfer(_account, tokenGovAmount);
        _claimEndWeek += 1;
        info.lastClaimWeek = uint64(_claimEndWeek);
        accountInfo[_account] = info;
        if (tokenGovAmount > 0 || tokenStablesAmount > 0) {
            emit RewardsClaimed(_account, _claimEndWeek, tokenGovAmount, tokenStablesAmount);
        }
    }

    function computeSharesAt(address _account, uint _week) public view returns (uint govTokenShare, uint stableTokenShare) {
        require(_week <= getWeek(), "Invalid week");
        IYearnBoostedStaker.WeightData memory acctWeight = staker.getAccountWeightAt(_account, _week);
        if (acctWeight.weight == 0) return (0, 0); // User has no weight.
        IYearnBoostedStaker.WeightData memory globalWeight = staker.getGlobalWeightAt(_week);
        return computeSharesFromWeight(acctWeight, globalWeight);
    }

    function computeSharesFromWeight(
        IYearnBoostedStaker.WeightData memory _acctWeight,
        IYearnBoostedStaker.WeightData memory _globalWeight
    ) public view returns (uint govTokenShare, uint stableTokenShare) {
        if (_acctWeight.weight == 0) return (0, 0);
        if (_globalWeight.weight == 0) return (0, 0);
        
        // No zero check necessary on global weighted election since the presence of account weighted election.
        if (_acctWeight.weightedElection != 0) stableTokenShare = _acctWeight.weightedElection * PRECISION / _globalWeight.weightedElection;
        
        uint max = _acctWeight.weight * MAX_BPS;
        if (max == _acctWeight.weightedElection) return (0, stableTokenShare); // Early exit if no gov token election.

        uint adjustedAccountWeightedElection = max - _acctWeight.weightedElection;
        uint adjustedGlobalWeightedElection = _globalWeight.weight * MAX_BPS - _globalWeight.weightedElection;
        if (adjustedGlobalWeightedElection == 0) return (0, stableTokenShare); // Should never be true.
        govTokenShare = adjustedAccountWeightedElection * PRECISION / adjustedGlobalWeightedElection;
    }

    /**
        @dev Returns total earned in each of the weeks.
    */
    function _getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) public view returns (uint totalGovAmount, uint totalStableAmount) {
        for (uint i = _claimStartWeek; i < _claimEndWeek; i++) {
            (uint govAmount, uint stableAmount) = getClaimableAt(_account, i);
            totalGovAmount += govAmount;
            totalStableAmount += stableAmount;
        }
    }

    function _onlyClaimers(address _account) internal returns (bool approved) {
        return approvedClaimer[_account][msg.sender] || _account == msg.sender;
    }

    /**
        @notice Returns suggested start and end range for claim weeks.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
    */
    function getSuggestedClaimRange(address _account) external view returns (uint claimStartWeek, uint claimEndWeek) {
        uint currentWeek = getWeek();
        if (currentWeek == 0) return (0, 0);
        bool canClaim;
        uint lastClaimWeek = accountInfo[_account].lastClaimWeek;
        
        claimStartWeek = START_WEEK > lastClaimWeek ? START_TIME : lastClaimWeek;

        // Loop from old towards recent.
        for (claimStartWeek; claimStartWeek <= currentWeek; claimStartWeek++) {
            (uint a, uint b) = getClaimableAt(_account, claimStartWeek);
            if ((a > 0) || (b > 0)) {
                canClaim = true;
                break;
            }
        }

        if (!canClaim) return (0,0);

        // Loop backwards from recent week towards old. Skip current week.
        for (claimEndWeek = currentWeek - 1; claimEndWeek > claimStartWeek; claimEndWeek--) {
            (uint a, uint b) = getClaimableAt(_account, claimEndWeek);
            if ((a > 0) || (b > 0)) {
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
    ) public view returns (uint tokenGovAmount, uint tokenStablesAmount) {
        uint currentWeek = getWeek();
        if(_week >= currentWeek) return (0, 0);
        if(_week < accountInfo[_account].lastClaimWeek) return (0, 0);
        (uint shareGov, uint shareStable) = computeSharesAt(_account, _week);
        RewardInfo memory info = weeklyRewardInfo[_week];
        tokenGovAmount = info.amountGov == 0 ? 0 : shareGov * info.amountGov / PRECISION;
        tokenStablesAmount = info.amountStable == 0 ? 0 : shareStable * info.amountStable / PRECISION;
    }

    /**
        @notice User may choose to autostake all of their governance tokens rewards directly into the staking contract.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
    */
    function setAutoStake(bool _autoStake) external {
        accountInfo[msg.sender].autoStake = _autoStake;
        emit AutoStakeSet(msg.sender, _autoStake);
    }

    /**
        @notice Used by governance to control instant boost level of weighted deposits.
        @dev    Supplying an idx of 0 is least weighted. Max available index is equal to MAX_STAKE_GROWTH_WEEKS
                value in the staker, and amounts to instant full boost.
        @param _idx The index that all weighted deposits should use.
    */
    function setWeightedDepositIndex(uint _idx) external {
        require(msg.sender == gov);
        require(_idx <= staker.MAX_STAKE_GROWTH_WEEKS(), "too high");
        weightedDepositIndex = _idx;
        emit WeightedDepositIndexSet(_idx);
    }

    /**
        @notice Set new governance address.
        @param _gov New governance address
    */
    function setGovernance(address _gov) external {
        require(msg.sender == gov);
        gov = _gov;
        emit GovernanceSet(_gov);
    }
}