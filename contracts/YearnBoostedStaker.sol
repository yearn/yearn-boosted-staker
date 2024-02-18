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

    // Account weight tracking state vars
    mapping(address account => AccountData data) public accountData;
    mapping(address account => mapping(uint week => WeightData weightData)) private accountWeeklyWeights;
    mapping(address account => mapping(uint week => WeightData weightDataToRealize)) public accountWeeklyToRealize;

    // Global weight tracking state vars
    uint16 public globalLastUpdateWeek;
    WeightData public globalGrowthRate;
    mapping(uint week => WeightData weightData) private globalWeeklyWeights;
    mapping(uint week => WeightData weightDataToRealize) public globalWeeklyToRealize;

    // Generic token interface
    uint public totalSupply;
    uint8 public immutable decimals;

    // Permissioned roles
    address public owner;
    address public pendingOwner;
    mapping(address account => mapping(address caller => ApprovalStatus approvalStatus)) public approvedCaller;
    mapping(address depositor => bool approved) public approvedWeightedDepositor;

    struct WeightData {
        uint128 weight;
        uint128 weightedElection;
    }

    struct AccountData {
        uint104 realizedStake;  // Amount of stake that has fully realized weight.
        uint104 pendingStake;   // Amount of stake that has not yet fully realized weight.
        uint16 lastUpdateWeek;  // Week of last sync.
        uint16 election;
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
    event ElectionSet(address indexed account, uint election);

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
        return _deposit(msg.sender, _amount, type(uint).max);
    }

    /**
        @notice Deposit tokens into the staking contract.
        @param _amount Amount of tokens to deposit.
    */
    function depositWithWeight(uint _amount, uint _election) external returns (uint) {
        require(_election <= 10_000, 'Too High');
        return _deposit(msg.sender, _amount, _election);
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
        
        return _deposit(_account, _amount, type(uint).max);
    }

    function _deposit(address _account, uint _amount, uint _election) internal returns (uint) {
        require(_amount > 1 && _amount < type(uint104).max >> 1, "invalid amount");

        uint systemWeek = getWeek();
        // Before going further, let's sync our account and global weights
        (AccountData memory acctData, WeightData memory accountWeightData) = _checkpointAccount(_account, systemWeek);
        WeightData memory globalWeight = _checkpointGlobal(systemWeek);

        if (_election != type(uint).max) (acctData, accountWeightData) = _setElection(_election, acctData, accountWeightData, systemWeek);

        uint128 weight = uint128(_amount >> 1);
        _amount = weight << 1; // This helps prevent balance/weight discrepencies.
        
        WeightData memory data = globalGrowthRate;
        data.weight += uint128(weight);
        data.weightedElection += uint128(weight * acctData.election);
        globalGrowthRate = data;

        acctData.pendingStake += uint104(weight);
        uint realizeWeek = systemWeek + MAX_STAKE_GROWTH_WEEKS;

        accountWeightData.weight += uint128(weight);
        accountWeightData.weightedElection = (accountWeightData.weight * acctData.election);
        accountWeeklyWeights[_account][systemWeek] = accountWeightData;
        
        data = accountWeeklyToRealize[_account][realizeWeek];
        data.weight += weight;
        data.weightedElection = data.weight * acctData.election;
        accountWeeklyToRealize[_account][realizeWeek] = data;

        data = globalWeeklyToRealize[realizeWeek];
        data.weight += uint128(weight);
        data.weightedElection += weight * acctData.election;
        globalWeeklyToRealize[realizeWeek] = data;

        data.weight = globalWeight.weight + uint128(weight);
        data.weightedElection = globalWeight.weightedElection + (weight * acctData.election);
        globalWeeklyWeights[systemWeek] = data;

        acctData.updateWeeksBitmap |= 1; // Flip bit at least-weighted position.
        accountData[_account] = acctData;
        totalSupply += _amount;
        
        stakeToken.transferFrom(msg.sender, address(this), uint(_amount));
        emit Deposit(_account, systemWeek, _amount, accountWeightData.weight, weight);
        
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
        require(_amount > 1 && _amount < type(uint104).max, "invalid amount");

        // Before going further, let's sync our account and global weights
        uint systemWeek = getWeek();
        (AccountData memory acctData, WeightData memory accountWeight) = _checkpointAccount(_account, systemWeek);
        WeightData memory globalWeight = _checkpointGlobal(systemWeek);

        uint128 weight = uint128(_amount >> 1);
        _amount = weight << 1;
        uint128 instantWeight = weight * uint128(_idx + 1);

        accountWeight.weight += instantWeight;
        accountWeight.weightedElection = accountWeight.weight * acctData.election;
        accountWeeklyWeights[_account][systemWeek] = accountWeight;

        globalWeight.weight += instantWeight;
        globalWeight.weightedElection += (instantWeight * acctData.election);
        globalWeeklyWeights[systemWeek] = globalWeight;
        
        if (_idx == MAX_STAKE_GROWTH_WEEKS) {
            acctData.realizedStake += uint104(weight);            
        }
        else {
            acctData.pendingStake += uint104(weight);

            WeightData memory data;
            
            data = globalGrowthRate;
            data.weight += weight;
            data.weightedElection += (weight * acctData.election);
            globalGrowthRate = data;

            uint realizeWeek = systemWeek + (MAX_STAKE_GROWTH_WEEKS - _idx);

            data = accountWeeklyToRealize[_account][realizeWeek];
            data.weight += weight;
            data.weightedElection = (data.weight * acctData.election);
            accountWeeklyToRealize[_account][realizeWeek] = data;

            data = globalWeeklyToRealize[realizeWeek];
            data.weight += weight;
            data.weightedElection += (weight * acctData.election);
            globalWeeklyToRealize[realizeWeek] = data;

            uint8 mask = uint8(1 << _idx);
            uint8 bitmap = acctData.updateWeeksBitmap;
            // Use bitwise or to ensure bit is flpped at target position.
            acctData.updateWeeksBitmap |= mask;
        }
        
        accountData[_account] = acctData;
        totalSupply += _amount;

        stakeToken.transferFrom(msg.sender, address(this), uint(_amount));
        emit Deposit(_account, systemWeek, _amount, accountWeight.weight, instantWeight);

        return _amount;
    }

    /**
        @notice Remove tokens from staking contract
        @dev During partial withdrawals, this will always remove from the least-weighted first.
     */
    function withdraw(uint _amount, address _receiver) external returns (uint) {
        return _withdraw(msg.sender, _amount, _receiver);
    }

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
        require(_amount > 1 && _amount < type(uint104).max, "invalid amount");
        uint systemWeek = getWeek();

        // Before going further, let's sync our account and global weights
        (AccountData memory acctData, WeightData memory accountWeight)= _checkpointAccount(_account, systemWeek);
        WeightData memory globalWeight = _checkpointGlobal(systemWeek);

        uint128 amountNeeded = uint128(_amount >> 1);
        _amount = amountNeeded << 1; // This helps prevent balance/weight discrepancies.

        // Perform withdrawal logic
        uint128 weightToRemove;

        (weightToRemove, acctData, amountNeeded) = _performWithdraw(_account, acctData, systemWeek, amountNeeded);

        uint128 pendingRemoved = uint128(_amount >> 1) - amountNeeded;
        if (amountNeeded > 0) {
            weightToRemove += amountNeeded * uint128(1 + MAX_STAKE_GROWTH_WEEKS);
            acctData.realizedStake -= uint104(amountNeeded);
            acctData.pendingStake = 0;
        }
        else{
            acctData.pendingStake -= uint104(pendingRemoved);
        }

        accountData[_account] = acctData;
        
        // Global Growth Rate
        WeightData memory data;
        data = globalGrowthRate;
        data.weight -= pendingRemoved;
        data.weightedElection -= (pendingRemoved * acctData.election);
        globalGrowthRate = data;
        
        // Global Weight
        globalWeight.weight -= weightToRemove;
        globalWeight.weightedElection -= (weightToRemove * acctData.election);
        globalWeeklyWeights[systemWeek] = globalWeight;

        // Account Weight
        accountWeight.weight -= weightToRemove;
        accountWeight.weightedElection = accountWeight.weight * acctData.election;
        accountWeeklyWeights[_account][systemWeek] = accountWeight;
        
        totalSupply -= _amount;

        emit Withdraw(_account, systemWeek, _amount, accountWeight.weight, weightToRemove);
        
        stakeToken.transfer(_receiver, _amount);

        return _amount;
    }

    /**
        @dev Split from main withdraw function to avoid stack too deep.
    */
    function _performWithdraw(
        address _account, 
        AccountData memory acctData, 
        uint systemWeek, 
        uint128 amountNeeded
    ) internal returns (
        uint128 weightToRemove, 
        AccountData memory, // acctData
        uint128             // amountNeeded
    ) {
        uint8 bitmap = acctData.updateWeeksBitmap;
        if (bitmap > 0) {
            WeightData memory data;
            for (uint128 weekIndex; weekIndex < MAX_STAKE_GROWTH_WEEKS;) {
                // Move right to left, checking each bit if there's an update for corresponding week.
                uint8 mask = uint8(1 << weekIndex);
                if (bitmap & mask == mask) {
                    uint weekToCheck = systemWeek + MAX_STAKE_GROWTH_WEEKS - weekIndex;
                    data = accountWeeklyToRealize[_account][weekToCheck];
                    uint128 pending = data.weight;
                    
                    if (amountNeeded > pending){
                        weightToRemove += pending * (weekIndex + 1);

                        accountWeeklyToRealize[_account][weekToCheck] = WeightData({
                            weight: 0,
                            weightedElection: 0
                        });

                        data = globalWeeklyToRealize[weekToCheck];
                        data.weight -= pending;
                        data.weightedElection -= (pending * acctData.election);
                        globalWeeklyToRealize[weekToCheck] = data;

                        bitmap = bitmap ^ mask;
                        amountNeeded -= pending;
                    }
                    else { 
                        // handle the case where we have more pending at this week than needed
                        weightToRemove += amountNeeded * uint128(weekIndex + 1);
                        // Update account. We already cached accountWeeklyToRealize as data above.
                        data.weight -= amountNeeded;
                        data.weightedElection = data.weight * acctData.election;
                        accountWeeklyToRealize[_account][weekToCheck] = data;
                        // Update global
                        data = globalWeeklyToRealize[weekToCheck];
                        data.weight -= amountNeeded;
                        data.weightedElection -= (amountNeeded * acctData.election);
                        globalWeeklyToRealize[weekToCheck] = data;
                        if (amountNeeded == pending) bitmap = bitmap ^ mask;
                        amountNeeded = 0;
                        break;
                    }
                }
                unchecked{ weekIndex++; }
            }
            acctData.updateWeeksBitmap = bitmap;
        }

        return (weightToRemove, acctData, amountNeeded);
    }


    /**
        @notice Set an election amount for an account. Expressed in BPS, to be consumed by external rewards distributors.
        @dev Elections are set in current week forward. Do not impact previous week.
    */
    function setElection(uint _election) external {
        require(_election <= 10_000, 'Too High');

        uint systemWeek = getWeek();
        // Sync all weights
        (AccountData memory acctData, WeightData memory data)= _checkpointAccount(msg.sender, systemWeek);
        (WeightData memory globalData)= _checkpointGlobal(getWeek());
        (acctData, data) = _setElection(_election, acctData, data, systemWeek);

        accountData[msg.sender] = acctData;
        accountWeeklyWeights[msg.sender][systemWeek] = data;
    }
        
    function _setElection(
        uint _election, 
        AccountData memory acctData, 
        WeightData memory accountWeightData, 
        uint systemWeek
    ) internal returns (AccountData memory, WeightData memory) {
        require(acctData.election != _election, "!Election Change");

        uint16 prevElection = acctData.election;
        acctData.election = uint16(_election);

        if (accountWeightData.weight == 0) {
            emit ElectionSet(msg.sender, _election);
            return (acctData, accountWeightData);
        }
        
        // Update AccountWeekly - past already done via checkpoint. Need just this week.
        accountWeightData.weightedElection = uint128(accountWeightData.weight * _election);

        // Update GlobalWeekly
        bool increase = _election > prevElection;
        uint128 diff;
        if (increase) {
            diff = uint128(_election - prevElection);
            globalWeeklyWeights[systemWeek].weightedElection += accountWeightData.weight * diff;
        }
        else {
            diff = uint128(prevElection - _election);
            globalWeeklyWeights[systemWeek].weightedElection -= accountWeightData.weight * diff;
        }
        
        uint8 bitmap = acctData.updateWeeksBitmap;
        if (bitmap > 0) {
            WeightData memory data;
            // Loop through all weeks to locate any necessary updates.
            // Update AccountRealizedWeek
            // Update GlobalRealizedWeek
            for (uint128 weekIndex; weekIndex < MAX_STAKE_GROWTH_WEEKS;) {
                uint8 mask = uint8(1 << weekIndex);
                if (bitmap & mask == mask) {
                    uint weekToCheck = systemWeek + MAX_STAKE_GROWTH_WEEKS - weekIndex;
                    data = accountWeeklyToRealize[msg.sender][weekToCheck];
                    uint128 w = data.weight;
                    data.weightedElection = uint128(w * _election);
                    accountWeeklyToRealize[msg.sender][weekToCheck] = data;

                    if (increase) {
                        globalWeeklyToRealize[weekToCheck].weightedElection += (w * diff);
                        globalGrowthRate.weightedElection += (acctData.pendingStake * diff);
                    }
                    else {
                        globalWeeklyToRealize[weekToCheck].weightedElection -= (w * diff);
                        globalGrowthRate.weightedElection -= (acctData.pendingStake * diff);
                    }
                }
                unchecked { weekIndex++; }
            }
        }

        emit ElectionSet(msg.sender, _election);
        return (acctData, accountWeightData);
    }
    
    /**
        @notice Get the current realized weight for an account
        @param _account Account to checkpoint.
        @return acctData Current account data.
        @return weightData Current account weightData.
        @dev Prefer to use this function over it's view counterpart for
             contract -> contract interactions.
    */
    function checkpointAccount(address _account) external returns (AccountData memory acctData, WeightData memory weightData) {
        (acctData, weightData) = _checkpointAccount(_account, getWeek());
        accountData[_account] = acctData;
    }

    /**
        @notice Checkpoint an account using a specified week limit.
        @dev    To use in the event that significant number of weeks have passed since last 
                heckpoint and single call becomes too expensive.
        @param _account Account to checkpoint.
        @param _week Week which we
        @return acctData Current account data.
        @return weightData Current account weightData.
    */
    function checkpointAccountWithLimit(address _account, uint _week) external returns (AccountData memory acctData, WeightData memory weightData) {
        uint systemWeek = getWeek();
        if (_week >= systemWeek) _week = systemWeek;
        
        (acctData, weightData) = _checkpointAccount(_account, _week);
        accountData[_account] = acctData;
    }

    function _checkpointAccount(address _account, uint _systemWeek) internal returns (AccountData memory, WeightData memory) {
        
        AccountData memory acctData = accountData[_account];

        uint lastUpdateWeek = acctData.lastUpdateWeek;

        if (_systemWeek == lastUpdateWeek) {
            return (acctData, accountWeeklyWeights[_account][lastUpdateWeek]);
        }

        require(_systemWeek > lastUpdateWeek, "specified week is older than last update.");

        uint104 pending = acctData.pendingStake; // deposited weight still growing.
        uint104 realized = acctData.realizedStake;

        WeightData memory data;

        if (pending == 0) {
            if (realized != 0) {
                data = accountWeeklyWeights[_account][lastUpdateWeek];
                while (lastUpdateWeek < _systemWeek) {
                    unchecked { lastUpdateWeek++; }
                    // Fill in any missing weeks with same data
                    accountWeeklyWeights[_account][lastUpdateWeek] = data;
                }
            }
            acctData.lastUpdateWeek = uint16(_systemWeek);
            return (acctData, data);
        }

        data = accountWeeklyWeights[_account][lastUpdateWeek];
        uint8 bitmap = acctData.updateWeeksBitmap;
        uint targetSyncWeek = min(_systemWeek, lastUpdateWeek + MAX_STAKE_GROWTH_WEEKS);

        // Populate data for missed weeks
        while (lastUpdateWeek < targetSyncWeek) {
            unchecked { lastUpdateWeek++; }
            data.weight += uint128(pending); // Increment weights by weekly growth factor.
            data.weightedElection = data.weight * acctData.election;
            accountWeeklyWeights[_account][lastUpdateWeek] = data;

            // Shift left on bitmap as we pass over each week.
            bitmap = bitmap << 1;
            if (bitmap & MAX_WEEK_BIT == MAX_WEEK_BIT){ // If left-most bit is true, we have something to realize; push pending to realized.
                // Do any updates needed to realize an amount for an account.

                WeightData memory realizedData = accountWeeklyToRealize[_account][lastUpdateWeek];
                pending -= uint104(realizedData.weight);
                realized += uint104(realizedData.weight);
                if (pending == 0) break; // All pending has been realized. No need to continue.
            }
        }

        // Populate data for missed weeks
        while (lastUpdateWeek < _systemWeek){
            unchecked { lastUpdateWeek++; }
            accountWeeklyWeights[_account][lastUpdateWeek] = data;
        }   

        return (
            AccountData({
                updateWeeksBitmap: bitmap,
                pendingStake: uint104(pending),
                realizedStake: uint104(realized),
                election: acctData.election,
                lastUpdateWeek: uint16(_systemWeek)
            }), data
        );
    }

    /**
        @notice View function to get the current weight for an account
    */
    function getAccountWeight(address account) external view returns (WeightData memory data) {
        return getAccountWeightAt(account, getWeek());
    }

    /**
        @notice Get the weight for an account in a given week
    */
    function getAccountWeightAt(address _account, uint _week) public view returns (WeightData memory data) {
        if (_week > getWeek()) return data;
        
        AccountData memory acctData = accountData[_account];

        uint104 pending = acctData.pendingStake;
        
        uint16 lastUpdateWeek = acctData.lastUpdateWeek;

        if (lastUpdateWeek >= _week) return accountWeeklyWeights[_account][_week]; 

        WeightData memory data = accountWeeklyWeights[_account][lastUpdateWeek];

        if (pending == 0) return data;

        uint8 bitmap = acctData.updateWeeksBitmap;

        uint128 weight = data.weight;

        while (lastUpdateWeek < _week) { // Populate data for missed weeks
            unchecked { lastUpdateWeek++; }
            data.weight += pending; // Increment weight by 1 week

            // Our bitmap is used to determine if week has any amount to realize.
            bitmap = bitmap << 1;
            if (bitmap & MAX_WEEK_BIT == MAX_WEEK_BIT){ // If left-most bit is true, we have something to realize; push pending to realized.
                pending -= uint104(accountWeeklyToRealize[_account][lastUpdateWeek].weight);
                if (pending == 0) break; // All pending has now been realized, let's exit.
            }            
        }
        
        data.weightedElection = data.weight * acctData.election;
        return data;
    }

    /**
        @notice Get the current total system weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
    */
    function checkpointGlobal() external returns (WeightData memory data) {
        uint systemWeek = getWeek();
        return _checkpointGlobal(systemWeek);
    }

    /**
        @notice Get the current total system weight
        @dev Also updates local storage values for total weights. Using
             this function over it's `view` counterpart is preferred for
             contract -> contract interactions.
    */
    function _checkpointGlobal(uint systemWeek) internal returns (WeightData memory data) {
        // These two share a storage slot.
        uint16 lastUpdateWeek = globalLastUpdateWeek;

        WeightData memory rate = globalGrowthRate;

        data = globalWeeklyWeights[lastUpdateWeek];

        if (data.weight == 0) {
            globalLastUpdateWeek = uint16(systemWeek);
            return data;
        }

        if (lastUpdateWeek == systemWeek){
            return data;
        }

        while (lastUpdateWeek < systemWeek) {
            unchecked { lastUpdateWeek++; }
            // Increment
            data.weight += rate.weight;
            data.weightedElection += rate.weightedElection;
            globalWeeklyWeights[lastUpdateWeek] = data;

            // Decrement
            WeightData memory realize = globalWeeklyToRealize[lastUpdateWeek];
            rate.weight -= realize.weight;
            rate.weightedElection -= realize.weightedElection;
        }

        globalGrowthRate = rate;
        globalLastUpdateWeek = uint16(systemWeek);

        return data;
    }

    /**
        @notice Get the system weight for current week.
    */
    function getGlobalWeight() external view returns (WeightData memory data) {
        return getGlobalWeightAt(getWeek());
    }

    /**
        @notice Get the system weight for a specified week in the past.
        @dev querying a week in the future will always return 0.
        @param week the week number to query global weight for.
    */
    function getGlobalWeightAt(uint week) public view returns (WeightData memory data) {
        uint systemWeek = getWeek();
        if (week > systemWeek) return data;

        // Read these together since they are packed in the same slot.
        uint16 lastUpdateWeek = globalLastUpdateWeek;

        WeightData memory rate = globalGrowthRate;

        if (week <= lastUpdateWeek) return globalWeeklyWeights[week];

        data = globalWeeklyWeights[lastUpdateWeek];

        if (rate.weight == 0) {
            return data;
        }

        while (lastUpdateWeek < week) {
            unchecked { lastUpdateWeek++; }
            // Increment
            data.weight += rate.weight;
            data.weightedElection += rate.weightedElection;

            // Decrement
            WeightData memory realize = globalWeeklyToRealize[lastUpdateWeek];
            rate.weight -= realize.weight;
            rate.weightedElection -= realize.weightedElection;
        }

        return data;
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
        @notice Returns the balance of underlying staked tokens for an account
        @param _account Account to query balance.
        @return balance of account.
    */
    function getElection(address _account) external view returns (uint) {
        return accountData[_account].election;
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