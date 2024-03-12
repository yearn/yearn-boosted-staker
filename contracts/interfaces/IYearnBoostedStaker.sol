// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";

interface IYearnBoostedStaker {
    struct AccountData {
        uint112 realizedStake;  // Amount of stake that has fully realized weight.
        uint112 pendingStake;   // Amount of stake that has not yet fully realized weight.
        uint16 lastUpdateWeek;  // Week of last sync.

        // One byte member to represent weeks in which an account has pending weight changes.
        // A bit is set to true when the account has a non-zero token balance to be realized in
        // the corresponding week. We use this as a "map", allowing us to reduce gas consumption
        // by avoiding unnecessary lookups on weeks which an account has zero pending stake.
        //
        // Example: 01000001
        // The left-most bit represents the final week of pendingStake.
        // Therefore, we can see that account has stake updates to process only in weeks 7 and 1.
        uint8 updateWeeksBitmap;
    }

    enum ApprovalStatus {
        None,               // 0. Default value, indicating no approval
        DepositOnly,        // 1. Approved for deposit only
        WithdrawOnly,       // 2. Approved for withdrawal only
        DepositAndWithdraw  // 3. Approved for both deposit and withdrawal
    }

    function owner() external view returns (address);
    function MAX_STAKE_GROWTH_WEEKS() external view returns (uint);
    function START_TIME() external view returns (uint);
    function stakeToken() external view returns (IERC20);
    function totalSupply() external view returns (uint);
    function accountData(address account) external view returns (AccountData memory data);
    function globalGrowthRate() external view returns (uint rate);
    function globalWeeklyWeights(uint week) external view returns (uint weight);
    function approvedCaller(address account, address caller) external view returns (ApprovalStatus);
    function approvedWeightedDepositor(address depositor) external view returns (bool);
    /**
        @notice Deposit tokens into the staking contract.
        @param _amount Amount of tokens to deposit.
    */
    function deposit(uint _amount) external returns (uint);
    function depositFor(address _account, uint _amount) external returns (uint);
    function depositAsWeighted(address _account, uint _amount, uint _idx) external returns (uint);
    function withdraw(uint _amount, address _receiver) external returns (uint);
    function withdrawFor(address _account, uint _amount, address _receiver) external returns (uint);
    /**
        @notice Get the current realized weight for an account
        @param _account Account to checkpoint.
        @return acctData Most recent account data written to storage.
        @return weight Current account weight.
        @dev Prefer to use this function over it's view counterpart for
             contract -> contract interactions.
    */
    function checkpointAccount(address _account) external returns (AccountData memory acctData, uint weight);
    function checkpointAccountWithLimit(address _account, uint _week) external returns (AccountData memory acctData, uint weight);
    /**
        @notice View function to get the current weight for an account
    */
    function getAccountWeight(address account) external view returns (uint);
    /**
        @notice Get the weight for an account in a given week
    */
    function getAccountWeightAt(address _account, uint _week) external view returns (uint weight);
    /**
        @notice Get the current total system weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
    */
    function checkpointGlobal() external returns (uint weight);
    /**
        @notice Get the system weight for current week.
    */
    function getGlobalWeight() external view returns (uint weight);
    /**
        @notice Get the system weight for a specified week in the past.
        @dev querying a week in the future will always return 0.
        @param week the week number to query global weight for.
    */
    function getGlobalWeightAt(uint week) external view returns (uint weight);
    /**
        @notice Returns the balance of underlying staked tokens for an account
        @param _account Account to query balance.
        @return balance of account.
    */
    function balanceOf(address _account) external view returns (uint balance);

    /**
        @notice Allow another address to deposit or withdraw on behalf of. Useful for zaps and other functionality.
        @param _caller Address of the caller to approve or unapprove.
        @param _status Enum representing various approval status states.
    */
    function setApprovedCaller(address _caller, ApprovalStatus _status) external;
    /**
        @notice Allow owner to specify an account which has ability to depositAsWeighted.
        @param _depositor Address of account with depositor permissions.
        @param _approved Approve or unapprove the depositor.
    */
    function setWeightedDepositor(address _depositor, bool _approved) external;

    /**
        @notice Set a pending owner which can later be accepted.
        @param _pendingOwner Address of the new owner.
    */
    function transferOwnership(address _pendingOwner) external;

    /**
        @notice Allow pending owner to accept ownership
    */
    function acceptOwnership() external;
    function sweep(address _token) external;
    function getWeek() external view returns (uint week);

}