// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYearnBoostedStaker} from "../interfaces/IYearnBoostedStaker.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract YBSUtilities {
    uint constant public PRECISION = 1e18;
    uint constant public FEE = 1e17; // 10%
    uint immutable STAKE_TOKEN_DECIMALS;
    uint immutable REWARD_TOKEN_DECIMALS;
    uint constant WEEKS_PER_YEAR = 52;
    uint public immutable MAX_STAKE_GROWTH_WEEKS;
    IERC20 public immutable STAKE_TOKEN;
    IERC20 public immutable REWARD_TOKEN;
    IYearnBoostedStaker public immutable YBS;
    IRewardDistributor public immutable REWARDS_DISTRIBUTOR;

    constructor(
        IYearnBoostedStaker _ybs,
        IRewardDistributor _rewardsDistributor
    ) {
        YBS = _ybs;
        REWARDS_DISTRIBUTOR = _rewardsDistributor;
        STAKE_TOKEN = YBS.stakeToken();
        STAKE_TOKEN_DECIMALS = YBS.decimals();
        REWARD_TOKEN = _rewardsDistributor.rewardToken();
        REWARD_TOKEN_DECIMALS = IERC20Metadata(
            address(_rewardsDistributor.rewardToken())
        ).decimals();
        MAX_STAKE_GROWTH_WEEKS = YBS.MAX_STAKE_GROWTH_WEEKS();
    }

    // Boost multiplier based on last week's finalization
    function getUserActiveBoostMultiplier(
        address _user
    ) external view returns (uint) {
        uint currentWeek = getWeek();
        // Ignore current week stake
        uint balance = scaleDecimals(
            YBS.balanceOf(_user) -
            getAccountStakeAmountAt(_user, currentWeek),
            STAKE_TOKEN_DECIMALS
        );
        if (balance == 0) return 0;
        // Ignore last week weight
        uint weight = scaleDecimals(
            adjustedAccountWeightAt(_user, currentWeek - 1),
            STAKE_TOKEN_DECIMALS
        );
        if (weight == 0) return 0;
        return (weight * PRECISION) / balance;
    }

    // Boost multiplier if week were to end today
    function getUserProjectedBoostMultiplier(
        address _user
    ) external view returns (uint) {
        uint currentWeek = getWeek();
        uint balance = scaleDecimals(
            YBS.balanceOf(_user),
            STAKE_TOKEN_DECIMALS
        );
        if (balance == 0) return 0;
        uint weight = scaleDecimals(
            adjustedAccountWeightAt(_user, currentWeek),
            STAKE_TOKEN_DECIMALS
        );
        if (weight == 0) return 0;
        return (weight * PRECISION) / balance;
    }

    /// @notice Compute a users APR for the active week.
    /// @param  _account Account to lookup.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getUserActiveApr(
        address _account,
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) public view returns (uint) {
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint currentWeek = getWeek();
        if (currentWeek == 0) return 0;

        uint rewardsAmount = scaleDecimals(
            activeRewardAmount(),
            REWARD_TOKEN_DECIMALS
        );
        if (rewardsAmount == 0) return 0;

        uint userShare = REWARDS_DISTRIBUTOR.computeSharesAt(
            _account,
            currentWeek - 1
        );
        if (userShare == 0) return 0;
        uint userRewards = userShare * rewardsAmount;
        if (userRewards == 0) return 0;
        uint userStakedBalance = YBS.balanceOf(_account);
        uint toRemove = getAccountStakeAmountAt(_account, currentWeek);
        if (_hideUnboosted && currentWeek > 0) toRemove += getAccountStakeAmountAt(_account, currentWeek - 1);
        if (toRemove >= userStakedBalance) return 0;
        userStakedBalance = scaleDecimals(
            userStakedBalance - toRemove,
            STAKE_TOKEN_DECIMALS
        );
        if (userStakedBalance == 0) return 0;
        uint precisionOffset = REWARDS_DISTRIBUTOR.PRECISION() / PRECISION;
        return
            ((_rewardTokenPrice * userRewards) * WEEKS_PER_YEAR) /
            (userStakedBalance * _stakeTokenPrice) /
            precisionOffset;
    }

    /// @notice Compute a users APR for the projected week.
    /// @param  _account Account to lookup.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getUserProjectedApr(
        address _account,
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) public view returns (uint) {
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint currentWeek = getWeek();
        if (currentWeek == 0) return 0;
        uint rewardsAmount = scaleDecimals(
            projectedRewardAmount(),
            REWARD_TOKEN_DECIMALS
        );
        if (rewardsAmount == 0) return 0;
        uint userShare = REWARDS_DISTRIBUTOR.computeSharesAt(
            _account,
            currentWeek
        );
        if (userShare == 0) return 0;
        uint userRewards = userShare * rewardsAmount;
        if (userRewards == 0) return 0;
        uint userStakedBalance = YBS.balanceOf(_account);
        if (_hideUnboosted){
            uint toRemove = getAccountStakeAmountAt(_account, currentWeek);
            if (toRemove >= userStakedBalance) return 0;
            userStakedBalance -= toRemove;
        }
        scaleDecimals(
            userStakedBalance,
            STAKE_TOKEN_DECIMALS
        );
        if (userStakedBalance == 0) return 0;
        uint precisionOffset = REWARDS_DISTRIBUTOR.PRECISION() / PRECISION;
        return
            ((_rewardTokenPrice * userRewards) * WEEKS_PER_YEAR) /
            (userStakedBalance * _stakeTokenPrice) /
            precisionOffset;
    }

    /// @notice Compute active global boost multipler.
    /// @dev    Uses weight as finalized at end of prior week.
    ///         Removes from consideration any stakes made in current week.
    function getGlobalActiveBoostMultiplier() public view returns (uint) {
        uint currentWeek = getWeek();
        uint supply = scaleDecimals(
            YBS.totalSupply() -
            getGlobalStakeAmountAt(currentWeek),
            STAKE_TOKEN_DECIMALS
        );
        if (supply == 0) return 0;
        uint weight = scaleDecimals(
            adjustedGlobalWeightAt(currentWeek - 1),
            STAKE_TOKEN_DECIMALS
        );
        if (weight == 0) return 0;
        return (weight * PRECISION) / supply;
    }

    /// @notice Compute projected boost multipler. Unfinalized until end of current week.
    /// @dev    Uses the current weight and supply.
    function getGlobalProjectedBoostMultiplier() public view returns (uint) {
        uint currentWeek = getWeek();
        uint supply = scaleDecimals(
            YBS.totalSupply(),
            STAKE_TOKEN_DECIMALS
        );
        if (supply == 0) return 0;
        uint weight = scaleDecimals(
            adjustedGlobalWeightAt(currentWeek),
            STAKE_TOKEN_DECIMALS
        );
        if (weight == 0) return 0;
        return (weight * PRECISION) / supply;
    }

    /// @notice Compute the global projected APR for the active week.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getGlobalActiveApr(
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) public view returns (uint) {
        if (getGlobalActiveBoostMultiplier() == 0) return 0;
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint currentWeek = getWeek();
        if (currentWeek == 0) return 0;
        uint rewardsAmount = scaleDecimals(
            activeRewardAmount(),
            REWARD_TOKEN_DECIMALS
        );
        if (rewardsAmount == 0) return 0;
        // Get total supply, but reduce by amount that has been staked in current + prior weeks.
        uint toRemove = getGlobalStakeAmountAt(currentWeek);
        if (_hideUnboosted && currentWeek > 0) toRemove += getGlobalStakeAmountAt(currentWeek - 1);
        uint supply = YBS.totalSupply();
        if (toRemove >= supply) return 0; // This condition may occur due to withdrawal churn.
        supply = scaleDecimals(
            supply - toRemove,
            STAKE_TOKEN_DECIMALS
        );
        return (((rewardsAmount * _rewardTokenPrice * PRECISION) /
            (supply * _stakeTokenPrice)) * WEEKS_PER_YEAR);
    }

    /// @notice Compute the global projected APR for the projected week.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getGlobalProjectedApr(
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) public view returns (uint) {
        if (_stakeTokenPrice == 0 || _rewardTokenPrice == 0) return 0;
        uint currentWeek = getWeek();
        uint rewardsAmount = scaleDecimals(
            projectedRewardAmount(),
            REWARD_TOKEN_DECIMALS
        );
        if (rewardsAmount == 0) return 0;
        uint supply = YBS.totalSupply();
        if (_hideUnboosted){
            uint toRemove = getGlobalStakeAmountAt(currentWeek);
            if (toRemove >= supply) return 0;
            supply -= toRemove;
        }
        supply = scaleDecimals(supply, STAKE_TOKEN_DECIMALS);
        return (((rewardsAmount * _rewardTokenPrice * PRECISION) /
            (supply * _stakeTokenPrice)) * WEEKS_PER_YEAR);
    }

    /// @notice Compute the min and max APR for active week.
    /// @param  _active Set to true to retrieve active, or false for projected.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getGlobalMinMaxActiveApr(
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) external view returns (uint min, uint max) {
        return getGlobalMinMaxApr(true, _stakeTokenPrice, _rewardTokenPrice, _hideUnboosted);
    }

    /// @notice Compute the min and max APR for projected week.
    /// @param  _active Set to true to retrieve active, or false for projected.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getGlobalMinMaxProjectedApr(
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) external view returns (uint min, uint max) {
        return getGlobalMinMaxApr(false, _stakeTokenPrice, _rewardTokenPrice, _hideUnboosted);
    }

    /// @notice Compute the min and max APR possible for either active or projected week.
    /// @param  _active Set to true to retrieve active, or false for projected.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getGlobalMinMaxApr(
        bool _active,
        uint _stakeTokenPrice,
        uint _rewardTokenPrice,
        bool _hideUnboosted
    ) internal view returns (uint min, uint max) {
        uint avgApr = _active
            ? getGlobalActiveApr(_stakeTokenPrice, _rewardTokenPrice, _hideUnboosted)
            : getGlobalProjectedApr(_stakeTokenPrice, _rewardTokenPrice, _hideUnboosted);

        if (avgApr == 0) return (0, 0);

        uint avgBoost = _active
            ? getGlobalActiveBoostMultiplier()
            : getGlobalProjectedBoostMultiplier();

        if (avgBoost == 0) return (0, 0);
        uint minApr = (avgApr * minBoost()) / avgBoost;
        uint maxApr = (avgApr * maxBoost()) / avgBoost;
        return (minApr, maxApr);
    }

    /// @notice Get total amount of stake that occurred at a particular week.
    /// @param  _account Account to lookup.
    /// @param  _week Week to lookup.
    function getAccountStakeAmountAt(
        address _account,
        uint _week
    ) public view returns (uint) {
        uint regularStake = 2 *
            YBS
                .accountWeeklyToRealize(
                    _account,
                    _week + MAX_STAKE_GROWTH_WEEKS
                )
                .weightPersistent;
        return regularStake + YBS.accountWeeklyMaxStake(_account, _week);
    }

    /// @notice Get total amount of stake that occurred at a particular week.
    /// @param  _week Week to lookup.
    function getGlobalStakeAmountAt(uint _week) public view returns (uint) {
        uint regularStake = 2 *
            YBS
                .globalWeeklyToRealize(_week + MAX_STAKE_GROWTH_WEEKS)
                .weightPersistent;
        return regularStake + YBS.globalWeeklyMaxStake(_week);
    }

    /// @notice Minimum possible boost for the system that is eligible for rewards.
    function minBoost() public pure returns (uint) {
        return PRECISION; // 1x is the min
    }

    /// @notice Max possible boost for the system. 
    function maxBoost() public view returns (uint) {
        return (minBoost() * (MAX_STAKE_GROWTH_WEEKS + 1)) / 2;
    }

    /// @notice Adjusted global weight is the global weight for a given week 
    ///         minus the sum of stakes that occured in same week.
    /// @param  _account Account to lookup.
    /// @param  _week Week to lookup.
    function adjustedAccountWeightAt(
        address _account,
        uint _week
    ) public view returns (uint) {
        uint acctWeight = YBS.getAccountWeightAt(_account, _week);
        if (acctWeight == 0) return 0;
        return
            acctWeight -
            YBS
                .accountWeeklyToRealize(
                    _account,
                    _week + MAX_STAKE_GROWTH_WEEKS
                )
                .weightPersistent;
    }

    /// @notice Adjusted global weight is the global weight for a given week 
    ///         minus the sum of stakes that occured in same week.
    /// @param  _week Week to lookup.
    function adjustedGlobalWeightAt(uint _week) public view returns (uint) {
        uint globalWeight = YBS.getGlobalWeightAt(_week);
        if (globalWeight == 0) return 0;
        return
            globalWeight -
            YBS
                .globalWeeklyToRealize(_week + MAX_STAKE_GROWTH_WEEKS)
                .weightPersistent;
    }

    function activeRewardAmount() public view returns (uint) {
        uint week = getWeek();
        if (week == 0) return 0;
        return weeklyRewardAmountAt(week - 1);
    }

    function projectedRewardAmount() public view returns (uint) {
        uint week = getWeek();
        return weeklyRewardAmountAt(week);
    }

    function weeklyRewardAmountAt(uint _week) public view returns (uint) {
        return REWARDS_DISTRIBUTOR.weeklyRewardAmount(_week);
    }

    /// @notice Get user's active APR with 10% performance fee applied.
    ///         NOTE: This  is only relevant for computing APR/APY of auto-compounder strategy according to same methodology as other stakers.
    /// @param  _account Account for which to lookup APR.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getUserActiveAprWithFee(address _account, uint _stakeTokenPrice, uint _rewardTokenPrice, bool _hideUnboosted) external view returns (uint) {
        uint apr = getUserActiveApr(_account, _stakeTokenPrice, _rewardTokenPrice, _hideUnboosted);
        return apr * (PRECISION - FEE) / PRECISION;
    }

    /// @notice Get user's projected APR with 10% performance fee applied.
    ///         NOTE: This  is only relevant for computing APR/APY of auto-compounder strategy according to same methodology as other stakers.
    /// @param  _account Account for which to lookup APR.
    /// @param  _stakeTokenPrice Price of stake token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _rewardTokenPrice Price of reward token. Suggest to multiply by 1e18 to improve precision.
    /// @param  _hideUnboosted Specify false to include stakes below 1x boost and true to remove them from consideration.
    function getUserProjectedAprWithFee(address _account, uint _stakeTokenPrice, uint _rewardTokenPrice, bool _hideUnboosted) external view returns (uint) {
        uint apr = getUserProjectedApr(_account, _stakeTokenPrice, _rewardTokenPrice, _hideUnboosted);
        return apr * (PRECISION - FEE) / PRECISION;
    }

    function convertAprToApy(uint _apr) public view returns (uint) {
        return _apr;
    }

    function getWeek() public view returns (uint) {
        return YBS.getWeek();
    }

    function scaleDecimals(
        uint256 amount,
        uint256 currentDecimals
    ) public pure returns (uint256) {
        require(currentDecimals <= 18, "Bad Decimals");

        if (currentDecimals == 18) {
            return amount;
        }
        uint256 decimalsToScale = 18 - currentDecimals;
        return amount * 10 ** decimalsToScale;
    }
}