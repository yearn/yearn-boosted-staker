import ape, pytest
from ape import chain, project, Contract
from decimal import Decimal
import numpy as np
from utils.constants import (
    YEARN_FEE_RECEIVER, 
    MAX_INT, 
    ApprovalStatus, 
    ZERO_ADDRESS,
    WEEK
)


WEEK = 60 * 60 * 24 * 7

def test_taget_weight_user(
    user,
    fee_receiver_acc,
    rewards, 
    staker,
    user2, 
    user3,
    yprisma,
    yprisma_whale,
    yvmkusd,
    yvmkusd_whale
):

    # These data values all come from the simulation spreadsheet
    # We supply inputs and expected outputs, then test to make sure the contract values align
    simulation_data = [
        {   
            'num_weeks': 0, # How many weeks forward to simulate
            'reward_amount': 300 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                100 * 10 ** 18, 
                0 * 10 ** 18, 
                300 * 10 ** 18
            ],
            'expected': [0, 0, 0]
        },
        {   
            'num_weeks': 1,
            'reward_amount': 400 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                200 * 10 ** 18, 
                300 * 10 ** 18, 
                300 * 10 ** 18
            ],
            'expected': [100, 0, 300]
        },
        {   
            'num_weeks': 2,
            'reward_amount': 500 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                100 * 10 ** 18, 
                200 * 10 ** 18, 
                0 * 10 ** 18
            ],
            'expected': [125, 107, 267]
        }
    ]
    
    for data in simulation_data:
        simulate_with_data(data, rewards, staker, yprisma, fee_receiver_acc)


def simulate_with_data(data, rewards, staker, yprisma, fee_receiver_acc):
    week = rewards.getWeek()

    # Stake
    for i, u in enumerate(data['users']):
        if yprisma.allowance(u, staker) < 2**200:
            yprisma.approve(staker, 2**256-1, sender=u)
        amount = data['amounts'][i]
        if amount > 1:
            staker.stake(amount, sender=u)

    # Deposit rewards
    rewards.depositReward(data['reward_amount'], sender=fee_receiver_acc)

    advance_chain(WEEK)

    # Test expected amount claimable
    for i, u in enumerate(data['users']):
        # actual = rewards.getTotalClaimableByRange(u, 0, data['num_weeks'])
        actual = rewards.getClaimableAt(u, week)
        expected = data['expected']
        e = expected[i]
        a = actual//1e18
        assert e == a

def advance_chain(seconds):
    chain.pending_timestamp += seconds
    chain.mine()

def test_basic_claim(
    user, 
    accounts, 
    fee_receiver, 
    rewards, 
    staker, 
    gov, 
    user2, 
    yprisma,
    yprisma_whale,
    yvmkusd,
    yvmkusd_whale
):
    yprisma.approve(staker, 2**256-1, sender=user)
    yprisma.approve(staker, 2**256-1, sender=user2)

    # stake to staker
    amt = 5_000 * 10 ** 18
    staker.stake(amt, sender=user)
    staker.stake(amt, sender=user2)

    # Deposit to rewards
    amt = 1_000 * 10 ** 18
    rewards.depositReward(amt, sender=fee_receiver)
    week = rewards.getWeek()
    assert amt == rewards.weeklyRewardAmount(week)

    assert rewards.getClaimableAt(user,0) == 0
    assert rewards.getClaimableAt(user,1) == 0

    chain.pending_timestamp += WEEK
    chain.mine()

    # Deposit rewards
    for i in range(5):
        amt = i * 1_000 * 10 ** 18
        rewards.depositReward(amt, sender=fee_receiver)
        week = rewards.getWeek()
        assert amt == rewards.weeklyRewardAmount(week)
        assert amt == rewards.weeklyRewardAmount(week)
        chain.pending_timestamp += WEEK
        chain.mine()
    
    rewards.weeklyRewardAmount(5)
    assert rewards.getClaimableAt(user, 5) > 0
    assert rewards.getClaimableAt(user2, 5) > 0
    assert rewards.getClaimableAt(user, 5) > 0
    assert rewards.getClaimableAt(user2, 5) > 0

    tx = rewards.claimWithRange(0,5,sender=user)
    tx = rewards.claimWithRange(0,5,sender=user2)

    stable_bal = yvmkusd.balanceOf(rewards)/1e18
    gov_bal = yprisma.balanceOf(rewards)/1e18
    print(stable_bal, gov_bal)
    assert stable_bal < 4000

    for i in range(10):
        amt = i * 100 * 10 ** 18
        rewards.depositReward(amt, sender=fee_receiver)
        week = rewards.getWeek()
        assert amt == rewards.weeklyRewardAmount(week)
        assert amt == rewards.weeklyRewardAmount(week)
        chain.pending_timestamp += WEEK
        chain.mine()

def test_multiple_reward_deposits_in_week(user, staker, user2, user3, stable_token,rewards, fee_receiver, stake_and_deposit_rewards):
    amt = 1_000 * 10 ** 18
    
    stake_and_deposit_rewards()

    # Skip a week to overcome the 1-week reward ramp up
    chain.pending_timestamp += WEEK
    chain.mine()

    week = rewards.getWeek()
    amt1 = rewards.weeklyRewardAmount(week)
    rewards.depositReward(amt, sender=fee_receiver)
    assert amt1 < rewards.weeklyRewardAmount(week)
    amt1 = rewards.weeklyRewardAmount(week)
    rewards.depositReward(amt, sender=fee_receiver)
    assert amt1 < rewards.weeklyRewardAmount(week)
    assert stable_token.balanceOf(rewards) > 0

    # Skip a week to become eligible for rewards
    chain.pending_timestamp += WEEK
    chain.mine()

    tx = rewards.claim(sender=user)
    event = list(tx.decode_logs(rewards.RewardsClaimed))[0]
    assert event.account == user.address
    assert event.rewardAmount > 0
    assert event.week > 0
    tx = rewards.claim(sender=user2)
    event = list(tx.decode_logs(rewards.RewardsClaimed))[0]
    assert event.account == user2.address
    assert event.rewardAmount > 0
    assert event.week > 0

    tx = rewards.claim(sender=user3)
    event = list(tx.decode_logs(rewards.RewardsClaimed))[0]
    assert event.account == user3.address
    assert event.rewardAmount > 0
    assert event.week > 0

    pushable = 0
    for i in range(0,staker.getWeek()):
        pushable += rewards.pushableRewards(i)

    # Some rewards were burned, so lets
    assert stable_token.balanceOf(rewards) // 1e18 == pushable // 1e18

def test_get_suggested_week(user, accounts, staker, gov, user2, yprisma, rewards,fee_receiver, stake_and_deposit_rewards):

    stake_and_deposit_rewards()

    amt = 1000 * 10 ** 18
    assert rewards.getSuggestedClaimRange(user).claimStartWeek == 0
    assert rewards.getSuggestedClaimRange(user).claimEndWeek == 0

    weeks = 5
    for i in range(weeks):
        chain.pending_timestamp += WEEK
        chain.mine()
        rewards.depositReward(amt, sender=fee_receiver)

    assert rewards.getSuggestedClaimRange(user).claimStartWeek == 1
    assert rewards.getSuggestedClaimRange(user).claimEndWeek == weeks - 1

def test_prevent_limit_claim_from_lowering_last_claim_week():
    pass

def test_zero_weight_in_bucket(user, accounts, staker, gov, user2, yprisma, rewards, fee_receiver, gov_token, stable_token):
    """
    Expected behavior is return of 0, no revert on view functions.
    """
    assert rewards.getSuggestedClaimRange(user).claimStartWeek == 0
    assert rewards.getSuggestedClaimRange(user).claimEndWeek == 0

    amt = 100 * 10 ** 18
    rewards.depositReward(amt, sender=fee_receiver)

    chain.pending_timestamp += WEEK
    chain.mine()
    
    assert rewards.getClaimableAt(user, 0) == 0

    tx = rewards.claimWithRange(0,0,sender=user)

    yprisma.approve(staker, 2**256-1, sender=user)
    amt = 10_000 * 10 ** 18
    staker.stake(amt, sender=user)
    rewards.depositReward(amt, sender=fee_receiver)

    chain.pending_timestamp += WEEK
    chain.mine()

    tx = rewards.claim(sender=user)

def test_governance_seize_tokens_when_zero_weight():
    pass

def test_claims_when_start_week_is_set_gt_zero(
    staker, 
    user2, fee_receiver_acc,
    fee_receiver, 
    gov_token, 
    stable_token, 
    gov, 
    user,
    yprisma_whale,
    yvmkusd_whale
):
    start_time = Contract('0x5d17eA085F2FF5da3e6979D5d26F1dBaB664ccf8').startTime()
    staker = user.deploy(
        project.YearnBoostedStaker, 
        gov_token, 
        4, # <-- Number of growth weeks
        start_time,
        gov,
    )
    rewards = user.deploy(
        project.SingleTokenRewardDistributor,
        staker,
        stable_token
    )
    yprisma = gov_token
    yprisma.approve(staker, 2**256-1, sender=user)
    yprisma.approve(staker, 2**256-1, sender=user2)

    # stake to staker
    amt = 5_000 * 10 ** 18
    staker.stake(amt, sender=user)
    staker.stake(amt, sender=user2)

    # Deposit to rewards    
    amt = 1_000 * 10 ** 18

    gov_token.approve(rewards, 2**256-1, sender=fee_receiver)
    stable_token.approve(rewards, 2**256-1, sender=fee_receiver)
    rewards.depositReward(amt, sender=fee_receiver)
    
    week = rewards.getWeek()
    assert amt == rewards.weeklyRewardAmount(week)

    assert rewards.getClaimableAt(user,0) == 0
    assert rewards.getClaimableAt(user,1) == 0

    assert rewards.getTotalClaimableByRange(user,week,week) == 0

    assert rewards.getClaimableAt(user, week) == 0

    chain.pending_timestamp += WEEK
    chain.mine()

    # Week 1: Deposit to rewards
    weeks = 5
    for i in range(weeks):
        amt = i * 500 * 10 ** 18
        if i == 0:
            amt = 500 * 10 ** 18
        rewards.depositReward(amt, sender=fee_receiver_acc)
        week = rewards.getWeek()
        assert amt == rewards.weeklyRewardAmount(week)
        chain.pending_timestamp += WEEK
        chain.mine()
    
    rewards.depositReward(amt, sender=fee_receiver_acc)
    
    current_week = rewards.getWeek()
    assert rewards.getClaimableAt(user, current_week - 1) > 0
    assert rewards.getClaimableAt(user, current_week - 2) > 0

    a, b = rewards.getSuggestedClaimRange(user)
    assert b < current_week
    tx = rewards.claimWithRange(a, b, sender=user)
    print(f'⛽️ {tx.gas_used}')
    a, b = rewards.getSuggestedClaimRange(user2)
    assert b < current_week
    tx = rewards.claimWithRange(a, b, sender=user2)
    print(f'⛽️ {tx.gas_used}')
    stable_bal = stable_token.balanceOf(rewards)/1e18
    assert stable_bal < 4000

    assert rewards.getClaimableAt(user, current_week) == 0
    assert rewards.getTotalClaimableByRange(user,current_week,current_week) == 0
    assert rewards.getTotalClaimableByRange(user2,current_week,current_week) == 0


def test_push_rewards(
    staker, 
    user2, fee_receiver_acc,
    fee_receiver, 
    gov_token, 
    stable_token, 
    gov, 
    user,
    yprisma_whale,
    yvmkusd_whale,
    rewards,
    yprisma
):
    
    yprisma.approve(staker, 2**256-1, sender=user)
    num_weeks = 5
    
    for i in range(0, num_weeks):
        week = rewards.getWeek()
        amt = 10_000 * 10 ** 18
        rewards.depositReward(amt, sender=fee_receiver)
        if week > 0:
            if week == 1:
                staker.stake(10 ** 18, sender=user)
            push_week = week - 1
            pushable = rewards.pushableRewards(push_week)
            push_week_amt = rewards.weeklyRewardAmount(push_week)
            current_week_amt = rewards.weeklyRewardAmount(week)
            if week > 2:
                assert pushable == 0
            else:
                assert pushable > 0
            if pushable > 0:
                assert push_week_amt > 0
                rewards.pushRewards(push_week, sender=user)
                assert rewards.weeklyRewardAmount(push_week) == 0
                assert rewards.weeklyRewardAmount(week) == current_week_amt + pushable
                assert rewards.adjustedGlobalWeightAt(push_week) == 0
            else:
                assert rewards.adjustedGlobalWeightAt(push_week) > 0
                assert push_week_amt > 0
                rewards.pushRewards(push_week, sender=user)
                assert rewards.weeklyRewardAmount(push_week) > 0
                assert current_week_amt == rewards.weeklyRewardAmount(week)
        chain.pending_timestamp += WEEK
        chain.mine()

def test_rewards_withdrawals(
    staker,
    user,
    user2,
    user3,
    gov,
    yvmkusd,
    rewards,
    yprisma,
    stake_and_deposit_rewards,
):
    data = {}
    # Setup multiple user deposits
    stake_and_deposit_rewards()

    # Advance some weeks
    # Test the invariant that computeSharesAt never changes as result of a user unstaking
    # In this first loop we stake for our users, add rewards, and cache the r
    num_weeks = 10
    for i in range(0, num_weeks):
        reward_bal = yvmkusd.balanceOf(rewards)
        supply = staker.totalSupply()
        stake_and_deposit_rewards()
        if i % 2 == 0:
            staker.stakeAsMaxWeighted(user3, 1_000 * 10 ** 18, sender=gov)
            staker.stakeAsMaxWeighted(gov, 1_000 * 10 ** 18, sender=gov)
        assert yvmkusd.balanceOf(rewards) > reward_bal
        assert staker.totalSupply() > supply
        # Build our cache
        data[i] = {}
        data[i][user.address] = rewards.computeSharesAt(user, i)
        data[i][user2.address] = rewards.computeSharesAt(user2, i)
        data[i][user3.address] = rewards.computeSharesAt(user3, i)
        chain.pending_timestamp += WEEK
        chain.mine()

    # Now we do our withdrawals and loop back to check after each one
    rewards.claim(sender=user)
    staker.unstake(int(staker.balanceOf(user)), user, sender=user)

    for i in range(0, num_weeks):
        assert data[i][user.address] == rewards.computeSharesAt(user, i)
        assert data[i][user2.address] == rewards.computeSharesAt(user2, i)
        assert data[i][user3.address] == rewards.computeSharesAt(user3, i)

    rewards.claim(sender=user2)
    staker.unstake(int(staker.balanceOf(user2)), user2, sender=user2)

    for i in range(0, num_weeks):
        assert data[i][user.address] == rewards.computeSharesAt(user, i)
        assert data[i][user2.address] == rewards.computeSharesAt(user2, i)
        assert data[i][user3.address] == rewards.computeSharesAt(user3, i)

    rewards.claim(sender=user3)
    staker.unstake(int(staker.balanceOf(user3)), user3, sender=user3)