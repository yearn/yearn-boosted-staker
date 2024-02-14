import ape, pytest
from ape import chain, project, Contract
from decimal import Decimal
import numpy as np
import time
from utils.constants import MAX_INT, ApprovalStatus, ZERO_ADDRESS


WEEK = 60 * 60 * 24 * 7

def test_checkpoint_with_limit(user, accounts, staker, gov, user2, yprisma):
    yprisma.approve(staker, MAX_INT, sender=user)
    yprisma.approve(staker, MAX_INT, sender=user2)
    amount = 100 * 10 ** 18
    
    staker.deposit(amount, sender=user)
    bal = staker.balanceOf(user)
    print(bal)
    print(staker.accountData(user))
    assert staker.accountData(user).pendingStake > 0
    assert staker.totalSupply() > 0
    assert bal > 0
    staker.checkpointAccount(user, sender=user)

    chain.pending_timestamp += 4 * WEEK
    chain.mine()

    staker.checkpointAccount(user, sender=user)
    assert staker.getWeek() == staker.accountData(user).lastUpdateWeek

    with ape.reverts():
        staker.checkpointAccountWithLimit(user, staker.getWeek() - 1, sender=user)
    
    staker.checkpointAccountWithLimit(user, staker.getWeek(), sender=user)

    # Check current weight has been reset to week 0 power
    data = staker.getAccountWeight(user)
    assert data.weight == amount * 2.5

    staker.withdraw(amount, user, sender=user)



def test_sequenced_deposits_and_withdrawals(user, accounts, staker, gov, user2, yprisma, prisma, dai, dai_whale):
    gas_analysis = {
        'withdrawals_sum': 0,
        'withdrawals_count': 0,
        'deposit_sum': 0,
        'deposit_count': 0,
        'grand_total': 0,
        'weighted_deposit_sum': 0,
        'weighted_deposit_count': 0,
    }
    yprisma.approve(staker, MAX_INT, sender=user)
    yprisma.approve(staker, MAX_INT, sender=user2)


    """
        This test is designed to mock the state changes in python code to help validate the results
        we get in solidity. It does this by dynamically operating on the staker contract with an
        arbitrary set of user actions defined in the ACTIVITY dict, and mirroring the expected state
        updates inside the python test itself before comparing results.

        Each action corresponds to a key which serves as the "week_index". Or, the number of weeks from
        today that the actions in the corresponding list will be simulated in.

        Each action will be fed into a loop that.... 
        1. advances chain state to the target week      
        1. mock the outcome of the action in python code
        3. perform action
        4. check results match
        5. make sure system invariants are enforced.
    """
    ACTIVITY = {
        0 :
            [
                {'type': 'withdrawal', 'user': user, 'amount': 0},
                {'type': 'weighted_deposit', 'user': user, 'idx': 2, 'amount': 2 * 10 ** 18},
                {'type': 'deposit', 'user': user, 'amount': 2},
                {'type': 'withdrawal', 'user': user, 'amount': 2},
                {'type': 'deposit', 'user': user, 'amount': 10 * 10 ** 18 + 1}, # w = 50; p = 50
                {'type': 'deposit', 'user': user2, 'amount': 200 * 10 ** 18 + 1}, # w = 100; p = 100;
                # {'type': 'withdrawal', 'user': user, 'amount': 2},
            ]
        ,
        1 :
            [
                {'type': 'deposit', 'user': user, 'amount': 100 * 10 ** 18 + 1}, # w = 50 + 100 = 150; p = 100
                {'type': 'withdrawal', 'user': user2, 'amount': 20 * 10 ** 18 + 1}, # w = 180; p = 90;
            ]
        ,
        3 :
            [
                {'type': 'deposit', 'user': user, 'amount': 100 * 10 ** 18}, # w = 150 + 100 + 50 = 300; p = 150
                {'type': 'withdrawal', 'user': user, 'amount': 100 * 10 ** 18}, # w = 300 - 50 = 250; p = 100
                {'type': 'withdrawal', 'user': user2, 'amount': 60 * 10 ** 18}, # w = 180 + 90 - 30 = 
            ]
        ,
        4 :
            [
                {'type': 'deposit', 'user': user, 'amount': 50 * 10 ** 18},
                {'type': 'withdrawal', 'user': user2, 'amount': 75 * 10 ** 18},
            ]
        ,
        5 :
            [
                {'type': 'deposit', 'user': user, 'amount': 1 * 10 ** 18},
                {'type': 'withdrawal', 'user': user2, 'amount': 1 * 10 ** 18},
                {'type': 'weighted_deposit', 'user': user, 'idx': 2, 'amount': 2 * 10 ** 18},
            ]
        ,
        6 :
            [
                {'type': 'deposit', 'user': user, 'amount': 1 * 10 ** 18},
                {'type': 'withdrawal', 'user': user2, 'amount': 1 * 10 ** 18},
                {'type': 'weighted_deposit', 'user': user2, 'idx': 4, 'amount': 2 * 10 ** 18},
            ]
        ,
        11 :
            [
                {'type': 'withdrawal', 'user': user, 'amount': 1 * 10 ** 18},
                {'type': 'withdrawal', 'user': user2, 'amount': 1 * 10 ** 18},
                {'type': 'weighted_deposit', 'user': user2, 'idx': 0, 'amount': 1 * 10 ** 18},
            ]
        ,
        17 :
            [
                {'type': 'withdrawal', 'user': user, 'amount': 'everything'},
                {'type': 'withdrawal', 'user': user2, 'amount': 'everything'},
            ]
        ,
        18 :
            [
                {'type': 'deposit', 'user': user, 'amount': 10 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 10 * 10 ** 18},
            ]
        ,
        19 :
            [
                {'type': 'deposit', 'user': user, 'amount': 10 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 10 * 10 ** 18},
            ]
        ,
        20 :
            [
                {'type': 'deposit', 'user': user, 'amount': 10 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 10 * 10 ** 18},
            ]
        ,
        21 :
            [
                {'type': 'deposit', 'user': user, 'amount': 10 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 10 * 10 ** 18},
            ]
        ,
        25 :
            [
                {'type': 'deposit', 'user': user, 'amount': 2 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 2 * 10 ** 18},
            ]
        ,
        29 :
            [
                {'type': 'withdraw', 'user': user2, 'amount': 2 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 2 * 10 ** 18}, # THIS IS TRIGGERING THE CHECK
            ]
        ,
        37 :
            [
                {'type': 'withdraw', 'user': user2, 'amount': 2 * 10 ** 18},
                {'type': 'deposit', 'user': user2, 'amount': 2 * 10 ** 18},
            ]
        ,
    }

    start_week = staker.getWeek()
    
    # We will use this data structure to create expected
    # user weight data
    user_data = {
        user.address: {
            'balance_of': 0,
            'weight': 0,
            'realized': 0,
            'pending': 0,
            'map': [0,0,0,0,0], # each index represents a week, and item represents the pending amount
            'start_balance': yprisma.balanceOf(user.address),
            'deposited_with_weight': 0,
        },
        user2.address: {
            'balance_of': 0,
            'weight': 0,
            'realized': 0,
            'pending': 0,
            'map': [0,0,0,0,0], # each index represents a week, and item represents the pending amount
            'start_balance': yprisma.balanceOf(user2.address),
            'deposited_with_weight': 0,
        },
    }
    global_growth = 0
    global_weight = 0
    last_week = 0
    MAX_STAKE_GROWTH_WEEKS = staker.MAX_STAKE_GROWTH_WEEKS()

    # Allow gov to make weighted deposits
    staker.setWeightedDepositor(gov, True, sender=gov)
    yprisma.approve(staker, 2 ** 256 -1, sender=gov)

    for week_index in ACTIVITY:
        to_advance = week_index - last_week
        user_data = advance_with_data(to_advance, staker, user_data)
        last_week = week_index
        if staker.getWeek() - start_week == week_index:
            actions = ACTIVITY[week_index]
            for action in actions:
                if 'revert' in action and action['revert']:
                    assert False
                u = action['user']
                amt = action['amount']
                if action['type'] == 'weighted_deposit':
                    if amt == 0:
                        with ape.reverts():
                            tx = staker.depositAsWeighted(u, amt, idx, sender=gov)
                        continue
                    user_data[u.address]['deposited_with_weight'] += amt
                    idx = action['idx']
                    assert idx <= MAX_STAKE_GROWTH_WEEKS
                    weight =  amt // 2
                    user_data[u.address]['balance_of'] += weight * 2
                    instant_weight = int(weight * (idx + 1))
                    if idx == MAX_STAKE_GROWTH_WEEKS:
                        user_data[u.address]['weight'] += instant_weight
                        user_data[u.address]['realized'] += weight
                        global_weight += instant_weight
                    else:
                        weight = amt // 2
                        user_data[u.address]['weight'] += instant_weight
                        user_data[u.address]['pending'] += weight
                        user_data[u.address]['map'][idx] += weight
                        global_weight += instant_weight
                        global_growth += weight
                    tx = staker.depositAsWeighted(u, amt, idx, sender=gov)
                    event = list(tx.decode_logs(staker.Deposit))[0]
                    print(f'Weight added: {event.weightAdded}')
                    assert event.account == u.address
                    assert event.week == staker.getWeek()
                    assert event.amount == amt
                    data = staker.getAccountWeight(u)
                    assert event.newUserWeight == user_data[u.address]['weight'] == data.weight
                    assert event.weightAdded == instant_weight
                    gas_analysis['weighted_deposit_count'] += 1
                    gas_analysis['weighted_deposit_sum'] += tx.gas_used
                    gas_analysis['grand_total'] += tx.gas_used
                if action['type'] == 'deposit':
                    if amt == 0:
                        with ape.reverts():
                            tx = staker.deposit(amt, sender=u)
                        continue
                    weight = amt // 2
                    user_data[u.address]['balance_of'] += weight * 2
                    user_data[u.address]['weight'] += weight
                    user_data[u.address]['pending'] += weight
                    user_data[u.address]['map'][0] += weight
                    global_weight += weight
                    global_growth += weight
                    tx = staker.deposit(amt, sender=u)
                    event = list(tx.decode_logs(staker.Deposit))[0]
                    print(f'Weight added: {event.weightAdded}')
                    assert event.account == u.address
                    assert event.week == staker.getWeek()
                    assert event.amount == amt // 2 * 2
                    data = staker.getAccountWeight(u)
                    assert event.newUserWeight == user_data[u.address]['weight'] == data.weight
                    assert event.weightAdded == weight
                    gas_analysis['deposit_count'] += 1
                    gas_analysis['deposit_sum'] += tx.gas_used
                    gas_analysis['grand_total'] += tx.gas_used
                if action['type'] == 'withdrawal':
                    if amt == 0:
                        with ape.reverts():
                            tx = staker.withdraw(amt, u, sender=u)
                        continue
                    if amt == 'everything':
                        amt = staker.balanceOf(u)
                        action['amount'] = amt
                    amount_needed = amt // 2
                    user_data[u.address]['balance_of'] -= amount_needed * 2
                    weight_to_reduce = 0
                    # Update amount map
                    for i, a in enumerate(user_data[u.address]['map'][:-1]):
                        if a == 0:
                            continue
                        if amount_needed > a:
                            weight_to_reduce += (i + 1) * a
                            user_data[u.address]['map'][i] -= a
                            user_data[u.address]['pending'] -= a
                            amount_needed -= a
                        else:
                            weight_to_reduce += (i + 1) * amount_needed
                            user_data[u.address]['map'][i] -= amount_needed
                            user_data[u.address]['pending'] -= amount_needed
                            amount_needed = 0
                            break

                    if amount_needed > 0:
                        weight_to_reduce += amount_needed * 5 # 5 is max boost multiplier
                        user_data[u.address]['realized'] -= amount_needed
                        assert user_data[u.address]['realized'] >= 0
                        
                    user_data[u.address]['weight'] -= weight_to_reduce
                    global_weight -= weight_to_reduce
                    global_growth -= amt // 2
                    tx = staker.withdraw(amt, u, sender=u)
                    event = list(tx.decode_logs(staker.Withdraw))[0]
                    print(f'Weight removed: {event.weightRemoved}')
                    assert event.weightRemoved == weight_to_reduce
                    assert event.newUserWeight == user_data[u.address]['weight']
                    assert event.week == staker.getWeek()
                    assert event.account == u.address
                    gas_analysis['withdrawals_count'] += 1
                    gas_analysis['withdrawals_sum'] += tx.gas_used
                    gas_analysis['grand_total'] += tx.gas_used

                print('⛽️', action['type'], f'{tx.gas_used:,}')
                print_state(week_index, action, staker, user_data[u.address], u.address)

            check_invariants(accounts, staker, user_data, yprisma)

    print(f'⛽️ Gas Analysis ⛽️')
    print(gas_analysis)
    gas_analysis
    weighted_deposit_avg = gas_analysis['weighted_deposit_sum']/gas_analysis['weighted_deposit_count']
    deposit_avg = gas_analysis['deposit_sum']/gas_analysis['deposit_count']
    withdraw_avg = gas_analysis['withdrawals_sum']/gas_analysis['withdrawals_count']
    print(f'deposit_avg {deposit_avg:,.0f}')
    print(f'weighted_deposit_avg {weighted_deposit_avg:,.0f}')
    print(f'withdraw_avg {withdraw_avg:,.0f}')
    print(f'⛽️⛽️⛽️')

def print_state(week_index, action, staker, data, user_address):
    w = data['weight'] / 1e18
    r = data['realized'] / 1e18
    p = data['pending'] / 1e18
    map = [x / 1e18 for x in data['map']]

    actual_w = staker.getAccountWeight(user_address).weight / 1e18
    actual_r = staker.accountData(user_address)['realizedStake'] / 1e18
    actual_p = staker.accountData(user_address)['pendingStake'] / 1e18
    actual_m = staker.accountData(user_address)['updateWeeksBitmap']

    # Here we do work to build a list of realized
    byte_string = format(actual_m, '08b')[::-1] # Reverse byte string so that it matches the order of our mock
    actual_m = [int(char) for char in byte_string[:5]] # This converts our map into
    new_map = []
    for i, m in enumerate(actual_m):
        realize_week = staker.getWeek() + (len(actual_m) - 1 - i) # realize_week
        data = staker.accountWeeklyToRealize(user_address, realize_week)
        amt = data.weight
        new_map.append(amt/10**18)
    
    action_type = action['type']
    action_amount = action['amount']
    print(f'--- {staker.getWeek()} {user_address} ----')
    print(f'➡️ {week_index} {action_type}: {action_amount/1e18}')
    print('balance:', staker.balanceOf(user_address)/1e18)
    print('weight', w, '|', actual_w)
    print('realized', r, '|', actual_r)
    print('pending', p, '|' ,actual_p)
    print('map', map, '|', new_map)
    print('-------')

def check_invariants(accounts, staker, user_data, yprisma):
    # user weights sum to global weight
    # each user balance is sum of his pending + realized
    sum_user_weight = 0
    total_balance = 0
    for u in user_data:
        starting_balance = user_data[u]['start_balance']
        realized = user_data[u]['realized']
        pending = user_data[u]['pending']
        sum_user_weight += user_data[u]['weight']
        weight = user_data[u]['weight']
        deposited_with_weight = user_data[u]['deposited_with_weight']
        user_balance = staker.balanceOf(u)
        total_balance += user_balance
        print(u, user_balance)
        print(u, (realized + pending) * 2)
        print(u, user_data[u]['balance_of'])
        assert user_balance == (realized + pending) * 2
        assert user_balance == user_data[u]['balance_of']
        assert user_balance == pytest.approx((realized + pending) * 2, abs=4)
        Decimal(user_balance) == Decimal((realized + pending) * 2) # Convert to decimal so we can preserve precision
        assert int(Decimal(user_balance) * Decimal(2.5)) >= weight # Weight can never be more than 2.5x boost
        assert user_balance <= starting_balance
        assert yprisma.balanceOf(u) <= starting_balance + deposited_with_weight # Make sure user never got a surplus
        data = staker.getAccountWeight(u)
        assert data.weight == weight
        if staker.accountData(u)['realizedStake'] != realized:
            # it's possible for these to be out of sync based on checkpoint
            print(f"{u} {staker.accountData(u)['realizedStake']} | Contract call")
            print(f"{u} {realized} | Manual")
            staker.checkpointAccount(u, sender=accounts[u])
            assert staker.accountData(u)['realizedStake'] == realized
        assert staker.accountData(u)['realizedStake'] == realized
        assert staker.accountData(u)['pendingStake'] == pending
        if staker.balanceOf(u) == 0:
            assert pending == 0
            assert realized == 0
            assert weight == 0
        if weight == 0:
            assert staker.balanceOf(u) == 0
        if pending == 0 or realized == user_balance / 2:
            assert weight == realized * 5


    assert total_balance == staker.totalSupply()
    data = staker.getGlobalWeight()
    assert data.weight == sum_user_weight

def try_invalid_stuff(gov, staker, yprisma, user):
    amount = 100 * 10 ** 18
    yprisma.approve(staker, MAX_INT, sender=user)
    tx = staker.setWeightedDepositor(user, True, sender=gov)
    tx = staker.depositAsWeighted(user, amount, 4, sender=user)
    with ape.reverts():
        tx = staker.depositAsWeighted(user, amount, 5, sender=user)

    with ape.reverts():
        tx = staker.withdraw(user, amount + 1, 4, sender=user)

    tx = staker.withdraw(user, amount, 4, sender=user)

    yprisma.approve(staker, MAX_INT, sender=user)
    with ape.reverts():
        tx = staker.deposit(user, amount + 1, 4, sender=user)


def advance(num_weeks, staker, users):
    for i in range(0, num_weeks):
        chain.pending_timestamp += WEEK
        chain.mine()
        week = staker.getWeek()
        
        global_weight = staker.getGlobalWeightAt(week)
        print(f'-- Week {week} --')
        print(f'Global weight: {global_weight}')
        for u in users:
            data = staker.getAccountWeight(u)
            user_weight = data.weight
            print(f'User weight: {u} {user_weight}')
        # assert global_weight == amount_sized * min(week, 8)
        # assert user_weight == amount_sized * min(week, 8)
        
def advance_with_data(num_weeks, staker, user_data):
    for i in range(0, num_weeks):
        chain.pending_timestamp += WEEK
        chain.mine()
        week = staker.getWeek()
        
        global_weight = staker.getGlobalWeightAt(week)
        for u in user_data:
            map = user_data[u]['map']
            pending = sum(map[0:4])
            user_data[u]['weight'] += pending
            user_data[u]['pending'] -= map[-2] 
            user_data[u]['realized'] += map[-2]
            
            # write new map. shift right, inserting 0 on left, dropping number on right
            user_data[u]['map'] = [0] + map[:-1]
    
    return user_data

def test_approved_caller(staker, user, user2, rando, gov, yprisma, accounts):
    amount = 1_000 * 10 ** 18
    yprisma.approve(staker, MAX_INT, sender=rando)
    yprisma.approve(staker, MAX_INT, sender=user2)
    yprisma.approve(staker, MAX_INT, sender=user)

    with ape.reverts():
        staker.depositFor(user, amount, sender=user2)
        staker.depositFor(user, amount, sender=rando)

    staker.setApprovedCaller(rando, ApprovalStatus.DEPOSIT_AND_WITHDRAW, sender=user)
    staker.setApprovedCaller(user2, ApprovalStatus.DEPOSIT_ONLY, sender=user)

    # Deposit on behalf of user
    data = staker.getAccountWeight(user)
    user_before = data.weight
    data = staker.getAccountWeight(rando)
    rando_before = data.weight
    staker.depositFor(user, amount, sender=rando)
    staker.depositFor(user, amount, sender=user2)

    assert user_before < staker.getAccountWeight(user).weight
    assert rando_before == staker.getAccountWeight(rando).weight

    staker.setApprovedCaller(rando, ApprovalStatus.NONE, sender=user)
    staker.setApprovedCaller(user2, ApprovalStatus.NONE, sender=user)

    with ape.reverts():
        staker.depositFor(user, amount, sender=user2)
        staker.depositFor(user, amount, sender=rando)

    # Withdraw on behalf of user
    amount = int(amount/3)
    data = staker.getAccountWeight(user)
    user_before = data.weight
    staker.setApprovedCaller(rando, ApprovalStatus.WITHDRAW_ONLY, sender=user)
    staker.setApprovedCaller(user2, ApprovalStatus.DEPOSIT_AND_WITHDRAW, sender=user)
    data = staker.getAccountWeight(rando)
    rando_before = data.weight
    staker.withdrawFor(user, amount, user, sender=rando)
    staker.withdrawFor(user, amount, user, sender=user2)

    data = staker.getAccountWeight(user)
    assert user_before > data.weight

    staker.setApprovedCaller(rando, ApprovalStatus.NONE, sender=user)
    staker.setApprovedCaller(user2, ApprovalStatus.DEPOSIT_ONLY, sender=user)

    with ape.reverts():
        staker.withdrawFor(user, amount, user, sender=user2)
        staker.withdrawFor(user, amount, user, sender=rando)

def test_set_weighted_depositor(staker, user, user2, rando, gov, yprisma, accounts):
    MAX_STAKE_GROWTH_WEEKS = staker.MAX_STAKE_GROWTH_WEEKS()
    amount = 100 * 10 ** 18
    idx = 3
    yprisma.approve(staker, MAX_INT, sender=rando)
    yprisma.approve(staker, MAX_INT, sender=user2)
    yprisma.approve(staker, MAX_INT, sender=user)
    yprisma.approve(staker, MAX_INT, sender=gov)

    assert staker.approvedWeightedDepositor(gov) == False
    assert staker.approvedWeightedDepositor(user) == False

    tx = staker.setWeightedDepositor(gov, True, sender=gov)
    event = list(tx.decode_logs(staker.WeightedDepositorSet))[0]
    assert event.depositor == gov.address
    assert staker.approvedWeightedDepositor(gov) == True

    tx = staker.setWeightedDepositor(user, True, sender=gov)
    event = list(tx.decode_logs(staker.WeightedDepositorSet))[0]
    assert event.depositor == user.address
    assert staker.approvedWeightedDepositor(user) == True

    tx = staker.setWeightedDepositor(user, False, sender=gov)
    event = list(tx.decode_logs(staker.WeightedDepositorSet))[0]
    assert event.depositor == user.address
    assert staker.approvedWeightedDepositor(user) == False

    with ape.reverts():
        staker.depositAsWeighted(user, amount, idx, sender=user2)
        staker.depositAsWeighted(user, amount, idx, sender=rando)

    amount = yprisma.balanceOf(gov)

    tx = staker.depositAsWeighted(gov, amount, idx, sender=gov)
    event = list(tx.decode_logs(staker.Deposit))[0]
    weight = amount / 2
    data = staker.getAccountWeight(gov)
    new_weight = data.weight
    instant_weight = int(amount / 2 * (idx + 1))
    assert event.account == gov.address
    assert event.newUserWeight == new_weight
    assert event.amount == amount
    assert event.weightAdded == instant_weight


    actual_m = staker.accountData(user)['updateWeeksBitmap']

    # Here we do work to build a list of realized
    byte_string = format(actual_m, '08b')[::-1] # Reverse byte string so that it matches the order of our mock
    actual_m = [int(char) for char in byte_string[:5]] # This converts our map into
    new_map = []
    for i, m in enumerate(actual_m):
        realize_week = staker.getWeek() + (len(actual_m) - 1 - i) # realize_week
        data = staker.accountWeeklyToRealize(gov, realize_week)
        amt = data.weight
        new_map.append(amt/1e18)    
    print(new_map)
    assert new_map[3] == weight / 1e18

    balance = staker.balanceOf(gov)
    tx = staker.setWeightedDepositor(user2, True, sender=gov)
    tx = staker.depositAsWeighted(user2, amount, 2, sender=user2)
    chain.pending_timestamp += WEEK
    chain.mine()
    tx = staker.withdraw(balance, user2, sender=user2)
    

def test_change_owner(staker, user, user2, rando, gov, yprisma, accounts):
    with ape.reverts():
        staker.transferOwnership(user2, sender=user2)
        staker.transferOwnership(user2, sender=rando)

    tx = staker.transferOwnership(user, sender=gov)
    tx = staker.acceptOwnership(sender=user)
    event = list(tx.decode_logs(staker.OwnershipTransferred))[0]
    assert event.newOwner == user.address

    with ape.reverts():
        staker.transferOwnership(user, sender=gov)
        staker.acceptOwnership(sender=gov)

    tx = staker.transferOwnership(gov, sender=user)
    tx = staker.acceptOwnership(sender=gov)
    event = list(tx.decode_logs(staker.OwnershipTransferred))[0]
    assert event.newOwner == gov.address

def test_sweep(staker, user, user2, rando, gov, yprisma, dai, dai_whale):
    amount = 50 * 10 ** 18
    yprisma.approve(staker, amount, sender=user)
    tx = staker.deposit(amount, sender=user)

    yprisma.transfer(staker, amount, sender=user)

    assert yprisma.balanceOf(staker) > staker.totalSupply()

    with ape.reverts():
        staker.sweep(yprisma, sender=user)

    before = yprisma.balanceOf(gov)
    staker.sweep(yprisma, sender=gov)
    assert yprisma.balanceOf(gov) > before
    assert yprisma.balanceOf(staker) >= amount

    dai.transfer(staker, amount, sender=dai_whale)

    assert dai.balanceOf(staker) > 0
    before = dai.balanceOf(gov)
    staker.sweep(dai, sender=gov)
    assert dai.balanceOf(gov) > before
    assert dai.balanceOf(staker) == 0
    

def test_basic_election(staker, user, yprisma):
    amount = 50 * 10 ** 18
    new_election = 10_000
    yprisma.approve(staker, amount, sender=user)

    # Test election with no weight
    assert staker.getElection(user) == 0
    assert staker.getAccountWeight(user).weightedElection == 0 
    
    tx = staker.setElection(new_election, sender=user)
    event = list(tx.decode_logs(staker.ElectionSet))[0]
    assert event.account == user.address
    assert event.election == new_election
    assert staker.getElection(user) == new_election
    assert staker.getAccountWeight(user).weightedElection == 0 

    tx = staker.deposit(amount, sender=user)
    assert staker.getElection(user) == new_election

    for i in range(1, 10):
        staker.checkpointAccount(user, sender=user)
        if i <= 5 :
            weighted_election = scale(amount) * new_election * (i * 0.5)
        else:
            weighted_election = scale(amount) * new_election * 2.5
        assert scale(staker.getAccountWeight(user).weightedElection) == float(weighted_election)
        chain.pending_timestamp += WEEK
        chain.mine()

    tx = staker.withdraw(staker.balanceOf(user), user, sender=user)
    assert staker.getAccountWeight(user).weightedElection == 0

def test_election_change(staker, user, yprisma):
    amount = 50 * 10 ** 18
    new_election = 5_000
    yprisma.approve(staker, amount, sender=user)

    # Test election with no weight
    assert staker.getElection(user) == 0
    assert staker.getAccountWeight(user).weightedElection == 0 
    
    tx = staker.setElection(new_election, sender=user)
    assert staker.getElection(user) == new_election
    assert staker.getAccountWeight(user).weightedElection == 0 

    tx = staker.deposit(amount, sender=user)
    assert staker.getElection(user) == new_election

    for i in range(1, 2):
        staker.checkpointAccount(user, sender=user)
        weighted_election = scale(amount) * new_election * (i * 0.5)
        assert scale(staker.getAccountWeight(user).weightedElection) == float(weighted_election)

        chain.pending_timestamp += WEEK
        chain.mine()

    data = staker.getAccountWeight(user)
    w = data.weight
    calculated_weight = data.weightedElection // 10**18 / new_election
    assert data.weight // 10**18 == calculated_weight

    new_election = 800
    tx = staker.setElection(new_election, sender=user)
    data = staker.getAccountWeight(user)
    assert w == data.weight
    assert calculated_weight == scale(data.weightedElection) / new_election
    assert scale(data.weight) == scale(data.weightedElection) / new_election

    tx = staker.withdraw(staker.balanceOf(user), user, sender=user)
    assert staker.getAccountWeight(user).weightedElection == 0 
    assert staker.getAccountWeight(user).weight == 0

def test_election_no_change(staker, user):
    new_election = 1_000
    tx = staker.setElection(new_election, sender=user)
    with ape.reverts():
        tx = staker.setElection(new_election, sender=user)
    # Test raising election
    # Test lowering election
    # Test setting election to same as current value
    # Test setting election with different account
    # Test setting election with 0 weight account
        # Should result in no diffs
    # Test condition where we have TVL but there is 0 total weightedElected for a given week
    # Test that weight backfills went through as expected on checkpoint (caught a bug that slipped by original test)

def test_checkpoint_abandoned_acct(staker, yprisma, user):
    """
        Here we time travel many weeks into future and ensure user's weights
        are updated appropriately for current and all future weeks.
    """
    amount = 50 * 10 ** 18
    new_election = 5_000
    yprisma.approve(staker, amount, sender=user)

    # Test election with no weight
    assert staker.getElection(user) == 0
    assert staker.getAccountWeight(user).weightedElection == 0 
    
    tx = staker.setElection(new_election, sender=user)
    event = list(tx.decode_logs(staker.ElectionSet))[0]
    assert event.account == user.address
    assert event.election == new_election
    assert staker.getElection(user) == new_election
    
    start_global = staker.getGlobalWeight()
    w = 0
    weekly_gain = amount // 2
    tx = staker.deposit(amount, sender=user)

    weeks_to_travel = 20
    start_week = staker.getWeek()
    

    for i in range(weeks_to_travel + 1):
        global_data = staker.getGlobalWeight()
        weekly_gain = amount // 2
        data = staker.getAccountWeight(user)
        if i <= 4:
            w += weekly_gain
        else:
            w = amount * 2.5
        assert scale(global_data.weight) == scale(start_global.weight) + scale(w)
        assert scale(global_data.weightedElection) == scale(global_data.weight) * new_election
        assert scale(data.weightedElection) == scale(w) * new_election
        assert scale(data.weight) == scale(w)
        chain.pending_timestamp += WEEK
        chain.mine()

    w = 0
    for i in range(weeks_to_travel + 1):
        last_update = staker.accountData(user).lastUpdateWeek
        assert start_week == last_update
        assert staker.getWeek() > last_update
        data = staker.getAccountWeightAt(user, start_week + i)
        if i <= 4:
            w += weekly_gain
        else:
            w = amount * 2.5
        assert scale(data.weightedElection) == scale(w) * new_election
        assert data.weight == w

    assert False

def scale(value):
    return value / 10 ** 18