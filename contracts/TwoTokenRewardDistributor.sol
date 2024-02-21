// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import "interfaces/IYearnBoostedStaker.sol";
import "utils/WeekStart.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";


contract TwoTokenRewardDistributor is WeekStart {
    using SafeERC20 for IERC20;

    uint constant MAX_BPS = 10_000;
    uint constant PRECISION = 1e18;
    IYearnBoostedStaker public immutable staker;
    IERC20 public immutable token1;
    IERC20 public immutable token2;
    uint public immutable START_WEEK;
    address public owner;
    uint public weightedDepositIndex;

    struct RewardInfo {
        uint128 amountToken1;
        uint128 amountToken2;
    }

    struct AccountInfo {
        address recipient; // Who rewards will be sent to. Cheaper to store here than in dedicated mapping.
        bool autoStake;
        uint64 lastClaimWeek;
    }

    mapping(uint week => RewardInfo rewardInfo) public weeklyRewardInfo;
    mapping(address account => uint week) public accountClaimWeek;
    mapping(address account => AccountInfo info) public accountInfo;
    mapping(address account => mapping(address claimer => bool approved)) public approvedClaimer;
    
    event RewardDeposited(uint indexed week, address indexed depositor, uint amountToken11, uint amountToken2);
    event RewardsClaimed(address indexed account, uint indexed week, uint amountToken11, uint amountToken2);
    event AccountConfigured(address indexed account, address recipient, bool indexed autoStake);
    event WeightedDepositIndexSet(uint indexed idx);
    event OwnerSet(address indexed owner);

    /**
        @notice Allow permissionless deposits to the current week.
        @param _staker the staking contract to use for weight calculations.
        @param _token1 must be the stake token used by the staking contract.
        @param _token2 additional reward token.
        @param _owner account with ability to enabled weighted staker deposits.
    */
    constructor(
        IYearnBoostedStaker _staker,
        IERC20 _token1, 
        IERC20 _token2,
        address _owner
    )
        WeekStart(_staker) {
        staker = _staker;
        token1 = _token1;
        token2 = _token2;
        owner = _owner;
        START_WEEK = staker.getWeek();
        token1.approve(address(staker), type(uint).max);
    }

    /**
        @notice Allow permissionless deposits to the current week.
        @param _amountToken1 the amount of token1 to receive.
        @param _amountToken2 the amount of token2 to receive.
    */
    function depositRewards(uint _amountToken1, uint _amountToken2) external {
        _depositRewards(msg.sender, _amountToken1, _amountToken2);
    }

    /**
        @notice Allow permissionless deposits to the current week from any address with approval.
        @param _target the address to pull tokens from.
        @param _amountToken1 the amount of token1 to receive.
        @param _amountToken2 the amount of token2 to receive.
    */
    function depositRewardsFrom(address _target, uint _amountToken1, uint _amountToken2) external {
        _depositRewards(_target, _amountToken1, _amountToken2);
    }

    function _depositRewards(address _target, uint _amountToken1, uint _amountToken2) internal {
        uint week = getWeek();

        RewardInfo storage info = weeklyRewardInfo[week];
        if (_amountToken1 > 0) {
            token1.transferFrom(_target, address(this), _amountToken1);
            info.amountToken1 += uint128(_amountToken1);
        }
        if (_amountToken2 > 0) {
            token2.transferFrom(_target, address(this), _amountToken2);
            info.amountToken2 += uint128(_amountToken2);
        }
        
        emit RewardDeposited(week, _target, _amountToken1, _amountToken2);
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user. All claims will retrieve 
                both tokens if available.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claim() external returns (uint amountToken1, uint amountToken2) {
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
    function claimFor(address _account) external returns (uint amountToken1, uint amountToken2) {
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
    ) external returns (uint amountToken1, uint amountToken2) {
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
    ) external returns (uint amountToken1, uint amountToken2) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        return _claimWithRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _claimWithRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal returns (uint amountToken1, uint amountToken2) {

        AccountInfo storage info = accountInfo[_account];

        // Sanitize inputs
        _claimStartWeek = info.lastClaimWeek == 0 ? START_WEEK : info.lastClaimWeek;
        uint currentWeek = getWeek();
        require(_claimStartWeek <= _claimEndWeek, "claimStartWeek > claimEndWeek");
        require(_claimEndWeek < currentWeek, "claimEndWeek >= currentWeek");
        require(_claimStartWeek >= info.lastClaimWeek, "claimStartWeek too low");
        (amountToken1, amountToken2) = _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
        
        _claimEndWeek += 1;
        info.lastClaimWeek = uint64(_claimEndWeek);
        address recipient = info.recipient == address(0) ? _account : info.recipient;
        
        if (amountToken1 > 0) {
            if (info.autoStake) {
                if (staker.approvedWeightedDepositor(address(this))) {
                    staker.depositAsWeighted(_account, amountToken1, weightedDepositIndex);
                }
                else {
                    staker.depositFor(_account, amountToken1);
                }
            }
            else{
                token1.transfer(recipient, amountToken1);
            }
        }
        if (amountToken2 > 0) token2.transfer(recipient, amountToken2);
        if (amountToken1 > 0 || amountToken2 > 0) {
            emit RewardsClaimed(_account, _claimEndWeek, amountToken1, amountToken2);
        }
    }

    /**
        @notice Helper function used to determine overal share of rewards at a particular week.
        @dev    Computing shares in past weeks is accurate. However, current week computations will not accurate 
                as week the is not yet finalized.
        @dev    Results scaled to PRECSION.
    */
    function computeSharesAt(address _account, uint _week) public view returns (uint token1Share, uint token2Share) {
        require(_week <= getWeek(), "Invalid week");
        IYearnBoostedStaker.WeightData memory acctWeight = staker.getAccountWeightAt(_account, _week);
        if (acctWeight.weight == 0) return (0, 0); // User has no weight.
        IYearnBoostedStaker.WeightData memory globalWeight = staker.getGlobalWeightAt(_week);
        return _computeSharesFromWeight(acctWeight, globalWeight);
    }

    function _computeSharesFromWeight(
        IYearnBoostedStaker.WeightData memory _acctWeight,
        IYearnBoostedStaker.WeightData memory _globalWeight
    ) internal view returns (uint token1Share, uint token2Share) {
        if (_acctWeight.weight == 0) return (0, 0);
        if (_globalWeight.weight == 0) return (0, 0);
        
        // No zero check necessary on global weighted election since the presence of account weighted election.
        if (_acctWeight.weightedElection != 0) token2Share = _acctWeight.weightedElection * PRECISION / _globalWeight.weightedElection;
        
        uint max = _acctWeight.weight * MAX_BPS;
        if (max == _acctWeight.weightedElection) return (0, token2Share); // Early exit if no token1 election.

        uint adjustedAccountWeightedElection = max - _acctWeight.weightedElection;
        uint adjustedGlobalWeightedElection = _globalWeight.weight * MAX_BPS - _globalWeight.weightedElection;
        if (adjustedGlobalWeightedElection == 0) return (0, token2Share); // Should never be true.
        token1Share = adjustedAccountWeightedElection * PRECISION / adjustedGlobalWeightedElection;
    }

    /**
        @dev Returns sum of both token types earned with the specified range of weeks.
    */
    function getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external view returns (uint totalAmountToken1, uint totalAmountToken2) {
        uint currentWeek = getWeek();
        if (_claimEndWeek >= currentWeek) _claimEndWeek = currentWeek;
        return _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal view returns (uint totalAmountToken1, uint totalAmountToken2) {
        for (uint i = _claimStartWeek; i <= _claimEndWeek; i++) {
            (uint amountToken1, uint amountToken2) = getClaimableAt(_account, i);
            totalAmountToken1 += amountToken1;
            totalAmountToken2 += amountToken2;
        }
    }

    /**
        @notice Helper function returns suggested start and end range for claim weeks.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
    */
    function getSuggestedClaimRange(address _account) external view returns (uint claimStartWeek, uint claimEndWeek) {
        uint currentWeek = getWeek();
        if (currentWeek == 0) return (0, 0);
        bool canClaim;
        uint lastClaimWeek = accountInfo[_account].lastClaimWeek;
        
        claimStartWeek = START_WEEK > lastClaimWeek ? START_WEEK : lastClaimWeek;

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
    ) public view returns (uint amountToken1, uint amountToken2) {
        uint currentWeek = getWeek();
        if(_week >= currentWeek) return (0, 0);
        if(_week < accountInfo[_account].lastClaimWeek) return (0, 0);
        (uint shareToken1, uint shareToken2) = computeSharesAt(_account, _week);
        RewardInfo memory info = weeklyRewardInfo[_week];
        amountToken1 = info.amountToken1 == 0 ? 0 : shareToken1 * info.amountToken1 / PRECISION;
        amountToken2 = info.amountToken2 == 0 ? 0 : shareToken2 * info.amountToken2 / PRECISION;
    }

    function _onlyClaimers(address _account) internal returns (bool approved) {
        return approvedClaimer[_account][msg.sender] || _account == msg.sender;
    }

    /**
        @notice Returns whether an account is auto-staking their rewards on claim, 
                and if so, how many extra weeks of boost they receive when doing so.
        @param _account Account to search for.
        @return autoStake True when user has token1 claims configured to be staked.
        @return numWeeks number of extra boosted weeks recevied when auto-staking.
    */
    function getAccountAutoStake(address _account) external view returns (bool autoStake, uint numWeeks) {
        return (
            staker.approvedWeightedDepositor(address(this)) && accountInfo[_account].autoStake, 
            numWeeks = weightedDepositIndex
        );
    }

    /**
        @notice User may configure their account to set a custom token recipient and/or autostake all of their 
                token1 rewards directly into the staking contract.
        @param _recipient   Wallet to receive tokens on behalf of the account. Zero address will result in all tokens
                            being transferred directly to the account holder.
        @param _autoStake   If true, the rewards contract is instructed to deposit yield directly to the staker at
                            the extra boosted weight index if enabled.
    */
    function configureAccount(address _recipient, bool _autoStake) external {
        AccountInfo storage info = accountInfo[msg.sender];
        info.recipient = _recipient;
        info.autoStake = _autoStake;
        emit AccountConfigured(msg.sender, _recipient, _autoStake);
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