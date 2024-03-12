// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";

interface IToken {
    function decimals() external view returns(uint8);
}

contract YearnBoostedStaker {
    using SafeERC20 for IERC20;

    uint public immutable MAX_STAKE_GROWTH_WEEKS;
    uint8 public immutable MAX_WEEK_BIT;
    uint public immutable START_TIME;
    IERC20 public immutable stakeToken;

    // Account weight tracking state vars.
    mapping(address account => AccountData data) public accountData;
    mapping(address account => mapping(uint week => uint weight)) private accountWeeklyWeights;
    mapping(address account => mapping(uint week => uint amount)) public accountWeeklyToRealize;

    // Global weight tracking stats vars.
    uint112 public globalGrowthRate;
    uint16 public globalLastUpdateWeek;
    mapping(uint week => uint weight) private globalWeeklyWeights;
    mapping(uint week => uint weightToRealize) private globalWeeklyToRealize;

    // Generic token interface.
    uint public totalSupply;
    uint8 public immutable decimals;

    // Permissioned roles
    address public owner;
    address public pendingOwner;
    mapping(address account => mapping(address caller => ApprovalStatus approvalStatus)) public approvedCaller;
    mapping(address depositor => bool approved) public approvedWeightedDepositor;

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

    event Deposit(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightAdded);
    event Withdraw(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightRemoved);
    event ApprovedCallerSet(address indexed account, address indexed caller, ApprovalStatus status);
    event WeightedDepositorSet(address indexed depositor, bool approved);
    event OwnershipTransferred(address indexed newOwner);

    /**
        @param _token The token to be staked.
        @param _max_stake_growth_weeks The number of weeks a stake will grow for.
                            Not including desposit week.
        @param _start_time  allows deployer to optionally set a custom start time.
                            useful if needed to line up with week count in another system.
                            Passing a value of 0 will start at block.timestamp.
    */
    constructor(address _token, uint _max_stake_growth_weeks, uint _start_time, address _owner) {
        owner = _owner;
        emit OwnershipTransferred(_owner);
        stakeToken = IERC20(_token);
        decimals = IToken(_token).decimals();
        require(
            _max_stake_growth_weeks > 0 &&
            _max_stake_growth_weeks <= 7,
            "Invalid weeks"
        );
        MAX_STAKE_GROWTH_WEEKS = _max_stake_growth_weeks;
        MAX_WEEK_BIT = uint8(1 << MAX_STAKE_GROWTH_WEEKS);
        if (_start_time == 0){
            START_TIME = block.timestamp;
        }
        else {
            require(_start_time <= block.timestamp, "!Past");
            START_TIME = _start_time;
        }
    }

    /**
        @notice Deposit tokens into the staking contract.
        @param _amount Amount of tokens to deposit.
    */
    function deposit(uint _amount) external returns (uint) {
        return _deposit(msg.sender, _amount);
    }

    function depositFor(address _account, uint _amount) external returns (uint) {
        if (msg.sender != _account) {
            ApprovalStatus status = approvedCaller[_account][msg.sender];
            require(
                status == ApprovalStatus.DepositAndWithdraw ||
                status == ApprovalStatus.DepositOnly,
                "!Permission"
            );
        }
        
        return _deposit(_account, _amount);
    }

    function _deposit(address _account, uint _amount) internal returns (uint) {
        require(_amount > 1 && _amount < type(uint112).max, "invalid amount");

        // Before going further, let's sync our account and global weights
        uint systemWeek = getWeek();
        (AccountData memory acctData, uint accountWeight) = _checkpointAccount(_account, systemWeek);
        uint112 globalWeight = uint112(_checkpointGlobal(systemWeek));

        uint weight = _amount >> 1;
        _amount = weight << 1; // This helps prevent balance/weight discrepencies.
        
        acctData.pendingStake += uint112(weight);
        globalGrowthRate += uint112(weight);

        uint realizeWeek = systemWeek + MAX_STAKE_GROWTH_WEEKS;
        uint previous = accountWeeklyToRealize[_account][realizeWeek];

        // modify weekly realizations and bitmap
        accountWeeklyToRealize[_account][realizeWeek] = previous + weight;
        accountWeeklyWeights[_account][systemWeek] = accountWeight + weight;
        globalWeeklyToRealize[realizeWeek] += weight;
        globalWeeklyWeights[systemWeek] = globalWeight + weight;
        acctData.updateWeeksBitmap |= 1; // Use bitwise or to ensure bit is flipped at least weighted position.
        accountData[_account] = acctData;
        totalSupply += _amount;
        
        stakeToken.transferFrom(msg.sender, address(this), uint(_amount));
        emit Deposit(_account, systemWeek, _amount, accountWeight + weight, weight);
        
        return _amount;
    }

    /**
        @notice Allows an option for an approved helper to deposit to any account at any weight week.
        @dev A deposit using this method only effects weight in current and future weeks. It does not backfill prior weeks.
        @param _amount Amount to deposit
        @param _idx Index of the week to deposit to relative to current week. E.g. 0 = current week, 4 = current plus 4 growth weeks.
        @return amount number of tokens deposited
    */
    function depositAsWeighted(address _account, uint _amount, uint _idx) external returns (uint) {
        require(
            approvedWeightedDepositor[msg.sender],
            "!approvedDepositor"
        );
        require(_idx <= MAX_STAKE_GROWTH_WEEKS, "Invalid week index.");
        require(_amount > 1 && _amount < type(uint112).max, "invalid amount");

        // Before going further, let's sync our account and global weights
        uint systemWeek = getWeek();
        (AccountData memory acctData, uint accountWeight) = _checkpointAccount(_account, systemWeek);
        uint112 globalWeight = uint112(_checkpointGlobal(systemWeek));

        uint weight = _amount >> 1;
        _amount = weight << 1;
        uint instantWeight = weight * (_idx + 1);

        accountWeeklyWeights[_account][systemWeek] = accountWeight + instantWeight;
        globalWeeklyWeights[systemWeek] = globalWeight + instantWeight;
        
        if (_idx == MAX_STAKE_GROWTH_WEEKS) {
            acctData.realizedStake += uint112(weight);            
        }
        else {
            acctData.pendingStake += uint112(weight);
            globalGrowthRate += uint112(weight);
            uint realizeWeek = systemWeek + (MAX_STAKE_GROWTH_WEEKS - _idx);
            uint previous = accountWeeklyToRealize[_account][realizeWeek];
            accountWeeklyToRealize[_account][realizeWeek] = previous + weight;
            globalWeeklyToRealize[realizeWeek] += weight;

            uint8 mask = uint8(1 << _idx);
            uint8 bitmap = acctData.updateWeeksBitmap;
            // Use bitwise or to ensure bit is flpped at target position.
            acctData.updateWeeksBitmap |= mask;
        }
        
        accountData[_account] = acctData;
        totalSupply += _amount;

        stakeToken.transferFrom(msg.sender, address(this), uint(_amount));
        emit Deposit(_account, systemWeek, _amount, accountWeight + instantWeight, instantWeight);

        return _amount;
    }

    /**
        @notice Withdraw tokens from staking contract.
        @dev During partial withdrawals, this will always remove from the least-weighted first.
    */
    function withdraw(uint _amount, address _receiver) external returns (uint) {
        return _withdraw(msg.sender, _amount, _receiver);
    }

    /**
        @notice Withdraw tokens from staking contract on behalf of another user.
        @dev During partial withdrawals, this will always remove from the least-weighted first.
    */
    function withdrawFor(address _account, uint _amount, address _receiver) external returns (uint) {
        if (msg.sender != _account) {
            ApprovalStatus status = approvedCaller[_account][msg.sender];
            require(
                status == ApprovalStatus.DepositAndWithdraw ||
                status == ApprovalStatus.WithdrawOnly,
                "!Permission"
            );
        }
        return _withdraw(_account, _amount, _receiver);
    }

    function _withdraw(address _account, uint _amount, address _receiver) internal returns (uint) {
        require(_amount > 1 && _amount < type(uint112).max, "invalid amount");
        uint systemWeek = getWeek();

        // Before going further, let's sync our account and global weights
        (AccountData memory acctData, ) = _checkpointAccount(_account, systemWeek);
        _checkpointGlobal(systemWeek);

        // Here we do work to withdraw from most recent (least weighted) deposits first
        uint8 bitmap = acctData.updateWeeksBitmap;
        uint weightToRemove;

        uint amountNeeded = _amount >> 1;
        _amount = amountNeeded << 1; // This helps prevent balance/weight discrepencies.

        if (bitmap > 0) {
            for (uint weekIndex; weekIndex < MAX_STAKE_GROWTH_WEEKS;) {
                // Move right to left, checking each bit if there's an update for corresponding week.
                uint8 mask = uint8(1 << weekIndex);
                if (bitmap & mask == mask) {
                    uint weekToCheck = systemWeek + MAX_STAKE_GROWTH_WEEKS - weekIndex;
                    uint pending = accountWeeklyToRealize[_account][weekToCheck];
                    
                    if (amountNeeded > pending){
                        weightToRemove += pending * (weekIndex + 1);
                        accountWeeklyToRealize[_account][weekToCheck] = 0;
                        globalWeeklyToRealize[weekToCheck] -= pending;
                        bitmap = bitmap ^ mask;
                        amountNeeded -= pending;
                    }
                    else { 
                        // handle the case where we have more pending than needed
                        weightToRemove += amountNeeded * (weekIndex + 1);
                        accountWeeklyToRealize[_account][weekToCheck] -= amountNeeded;
                        globalWeeklyToRealize[weekToCheck] -= amountNeeded;
                        if (amountNeeded == pending) bitmap = bitmap ^ mask;
                        amountNeeded = 0;
                        break;
                    }
                }
                unchecked{weekIndex++;}
            }
            acctData.updateWeeksBitmap = bitmap;
        }
        
        uint pendingRemoved = (_amount >> 1) - amountNeeded;
        if (amountNeeded > 0) {
            weightToRemove += amountNeeded * (1 + MAX_STAKE_GROWTH_WEEKS);
            acctData.realizedStake -= uint112(amountNeeded);
            acctData.pendingStake = 0;
        }
        else{
            acctData.pendingStake -= uint112(pendingRemoved);
        }
        
        accountData[_account] = acctData;

        globalGrowthRate -= uint112(pendingRemoved);
        globalWeeklyWeights[systemWeek] -= weightToRemove;
        uint newAccountWeight = accountWeeklyWeights[_account][systemWeek] - weightToRemove;
        accountWeeklyWeights[_account][systemWeek] = newAccountWeight;
        
        totalSupply -= _amount;

        emit Withdraw(_account, systemWeek, _amount, newAccountWeight, weightToRemove);
        
        stakeToken.transfer(_receiver, _amount);
        
        return _amount;
    }
    
    /**
        @notice Get the current realized weight for an account
        @param _account Account to checkpoint.
        @return acctData Most recent account data written to storage.
        @return weight Most current account weight.
        @dev Prefer to use this function over it's view counterpart for
             contract -> contract interactions.
    */
    function checkpointAccount(address _account) external returns (AccountData memory acctData, uint weight) {
        (acctData, weight) = _checkpointAccount(_account, getWeek());
        accountData[_account] = acctData;
    }

    /**
        @notice Checkpoint an account using a specified week limit.
        @dev    To use in the event that significant number of weeks have passed since last 
                heckpoint and single call becomes too expensive.
        @param _account Account to checkpoint.
        @param _week Week which we want to checkpoint to.
        @return acctData Most recent account data written to storage.
        @return weight Account weight for provided week.
    */
    function checkpointAccountWithLimit(address _account, uint _week) external returns (AccountData memory acctData, uint weight) {
        uint systemWeek = getWeek();
        if (_week >= systemWeek) _week = systemWeek;
        (acctData, weight) = _checkpointAccount(_account, _week);
        accountData[_account] = acctData;
    }

    function _checkpointAccount(address _account, uint _systemWeek) internal returns (AccountData memory acctData, uint weight){
        acctData = accountData[_account];
        uint lastUpdateWeek = acctData.lastUpdateWeek;

        if (_systemWeek == lastUpdateWeek) {
            return (acctData, accountWeeklyWeights[_account][lastUpdateWeek]);
        }

        require(_systemWeek > lastUpdateWeek, "specified week is older than last update.");

        uint pending = uint(acctData.pendingStake);
        uint realized = acctData.realizedStake;

        if (pending == 0) {
            if (realized != 0) {
                weight = accountWeeklyWeights[_account][lastUpdateWeek];
                while (lastUpdateWeek < _systemWeek) {
                    unchecked{lastUpdateWeek++;}
                    // Fill in any missing weeks
                    accountWeeklyWeights[_account][lastUpdateWeek] = weight;
                }
            }
            accountData[_account].lastUpdateWeek = uint16(_systemWeek);
            acctData.lastUpdateWeek = uint16(_systemWeek);
            return (acctData, weight);
        }

        weight = accountWeeklyWeights[_account][lastUpdateWeek];
        uint8 bitmap = acctData.updateWeeksBitmap;
        uint targetSyncWeek = min(_systemWeek, lastUpdateWeek + MAX_STAKE_GROWTH_WEEKS);

        // Populate data for missed weeks
        while (lastUpdateWeek < targetSyncWeek) {
            unchecked{ lastUpdateWeek++; }
            weight += pending; // Increment weights by weekly growth factor.
            accountWeeklyWeights[_account][lastUpdateWeek] = weight;

            // Shift left on bitmap as we pass over each week.
            bitmap = bitmap << 1;
            if (bitmap & MAX_WEEK_BIT == MAX_WEEK_BIT){ // If left-most bit is true, we have something to realize; push pending to realized.
                // Do any updates needed to realize an amount for an account.
                uint toRealize = accountWeeklyToRealize[_account][lastUpdateWeek];
                pending -= toRealize;
                realized += toRealize;
                if (pending == 0) break; // All pending has been realized. No need to continue.
            }
        }

        // Fill in any missed weeks.
        while (lastUpdateWeek < _systemWeek){
            unchecked{lastUpdateWeek++;}
            accountWeeklyWeights[_account][lastUpdateWeek] = weight;
        }   

        // Write new account data to storage.
        acctData = AccountData({
            updateWeeksBitmap: bitmap,
            pendingStake: uint112(pending),
            realizedStake: uint112(realized),
            lastUpdateWeek: uint16(_systemWeek)
        });
    }

    /**
        @notice View function to get the current weight for an account
    */
    function getAccountWeight(address account) external view returns (uint) {
        return getAccountWeightAt(account, getWeek());
    }

    /**
        @notice Get the weight for an account in a given week
    */
    function getAccountWeightAt(address _account, uint _week) public view returns (uint) {
        if (_week > getWeek()) return 0;
        
        AccountData memory acctData = accountData[_account];

        uint pending = uint(acctData.pendingStake);
        
        uint16 lastUpdateWeek = acctData.lastUpdateWeek;

        if (lastUpdateWeek >= _week) return accountWeeklyWeights[_account][_week]; 

        uint weight = accountWeeklyWeights[_account][lastUpdateWeek];
        if (pending == 0) return weight;

        uint8 bitmap = acctData.updateWeeksBitmap;

        while (lastUpdateWeek < _week) { // Populate data for missed weeks
            unchecked{lastUpdateWeek++;}
            weight += pending; // Increment weight by 1 week

            // Our bitmap is used to determine if week has any amount to realize.
            bitmap = bitmap << 1;
            if (bitmap & MAX_WEEK_BIT == MAX_WEEK_BIT){ // If left-most bit is true, we have something to realize; push pending to realized.
                pending -= accountWeeklyToRealize[_account][lastUpdateWeek];
                if (pending == 0) break; // All pending has now been realized, let's exit.
            }            
        }
        
        return weight;
    }

    /**
        @notice Get the current total system weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
    */
    function checkpointGlobal() external returns (uint) {
        uint systemWeek = getWeek();
        return _checkpointGlobal(systemWeek);
    }

    /**
        @notice Get the current total system weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
    */
    function _checkpointGlobal(uint systemWeek) internal returns (uint) {
        // These two share a storage slot.
        uint16 lastUpdateWeek = globalLastUpdateWeek;
        uint rate = globalGrowthRate;

        uint weight = globalWeeklyWeights[lastUpdateWeek];

        if (weight == 0) {
            globalLastUpdateWeek = uint16(systemWeek);
            return 0;
        }

        if (lastUpdateWeek == systemWeek){
            return weight;
        }

        while (lastUpdateWeek < systemWeek) {
            unchecked{lastUpdateWeek++;}
            weight += rate;
            globalWeeklyWeights[lastUpdateWeek] = weight;
            rate -= globalWeeklyToRealize[lastUpdateWeek];
        }

        globalGrowthRate = uint112(rate);
        globalLastUpdateWeek = uint16(systemWeek);

        return weight;
    }

    /**
        @notice Get the system weight for current week.
    */
    function getGlobalWeight() external view returns (uint) {
        return getGlobalWeightAt(getWeek());
    }

    /**
        @notice Get the system weight for a specified week in the past.
        @dev querying a week in the future will always return 0.
        @param week the week number to query global weight for.
    */
    function getGlobalWeightAt(uint week) public view returns (uint) {
        uint systemWeek = getWeek();
        if (week > systemWeek) return 0;

        // Read these together since they are packed in the same slot.
        uint16 lastUpdateWeek = globalLastUpdateWeek;
        uint rate = globalGrowthRate;

        if (week <= lastUpdateWeek) return globalWeeklyWeights[week];

        uint weight = globalWeeklyWeights[lastUpdateWeek];
        if (rate == 0) {
            return weight;
        }

        while (lastUpdateWeek < week) {
            unchecked {lastUpdateWeek++;}
            weight += rate;
            rate -= globalWeeklyToRealize[lastUpdateWeek];
        }

        return weight;
    }

    /**
        @notice Returns the balance of underlying staked tokens for an account
        @param _account Account to query balance.
        @return balance of account.
    */
    function balanceOf(address _account) external view returns (uint) {
        AccountData memory acctData = accountData[_account];
        return 2 * (acctData.pendingStake + acctData.realizedStake);
    }

    /**
        @notice Allow another address to deposit or withdraw on behalf of. Useful for zaps and other functionality.
        @param _caller Address of the caller to approve or unapprove.
        @param _status Enum representing various approval status states.
    */
    function setApprovedCaller(address _caller, ApprovalStatus _status) external {
        approvedCaller[msg.sender][_caller] = _status;
        emit ApprovedCallerSet(msg.sender, _caller, _status);
    }

    /**
        @notice Allow owner to specify an account which has ability to depositAsWeighted.
        @param _depositor Address of account with depositor permissions.
        @param _approved Approve or unapprove the depositor.
    */
    function setWeightedDepositor(address _depositor, bool _approved) external {
        require(msg.sender == owner, "!authorized");
        approvedWeightedDepositor[_depositor] = _approved;
        emit WeightedDepositorSet(_depositor, _approved);
    }

    /**
        @notice Set a pending owner which can later be accepted.
        @param _pendingOwner Address of the new owner.
    */
    function transferOwnership(address _pendingOwner) external {
        require(msg.sender == owner, "!authorized");
        pendingOwner = _pendingOwner;
    }

    /**
        @notice Allow pending owner to accept ownership
    */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "!authorized");
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(msg.sender);
    }

    function sweep(address _token) external {
        require(msg.sender == owner, "!authorized");
        uint amount = IERC20(_token).balanceOf(address(this));
        if (_token == address(stakeToken)) {
            amount = amount - totalSupply;
        }
        if (amount > 0) IERC20(_token).safeTransfer(owner, amount);
    }

    function getWeek() public view returns (uint week) {
        unchecked{
            return (block.timestamp - START_TIME) / 1 weeks;
        }
    }

    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}