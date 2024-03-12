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
    accounts, 
    fee_receiver, 
    fee_receiver_acc,
    rewards, 
    staker, 
    gov, 
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
        {   # SIMULATION 1
            'num_weeks': 1,
            'reward_amount': 8_000 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                100 * 10 ** 18, 
                200 * 10 ** 18, 
                500 * 10 ** 18
            ],
            'expected': [1000, 2000, 5000]
        },
        {   # SIMULATION 2
            'num_weeks': 20,
            'reward_amount': 50_000 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                50 * 10 ** 18, 
                320 * 10 ** 18, 
                400 * 10 ** 18
            ],
            'expected': [3246, 20779, 25974]
        },
        {   # SIMULATION 3
            'num_weeks': 3,
            'reward_amount': 15_000 * 10 ** 18,
            'users': [user, user2, user3],
            'amounts': [
                12_000 * 10 ** 18, 
                10_000 * 10 ** 18, 
                16_000 * 10 ** 18
            ],
            'expected': [4736, 3947, 6315]
        }
    ]
    
    for data in simulation_data:
        snap = chain.snapshot()
        simulate_with_data(data, rewards, staker, chain, yprisma, fee_receiver_acc)
        chain.restore(snap)

def simulate_with_data(data, rewards, staker, chain, yprisma, fee_receiver_acc):
    for i, u in enumerate(data['users']):
        yprisma.approve(staker, 2**256-1, sender=u)
        amount = data['amounts'][i]
        staker.deposit(amount, sender=u)

    # Deposit new rewards
    rewards.depositReward(data['reward_amount'], sender=fee_receiver_acc)
    for i in range(data['num_weeks']):
        chain.pending_timestamp += WEEK
        chain.mine()

    for i, u in enumerate(data['users']):
        actual = rewards.getTotalClaimableByRange(u, 0, data['num_weeks'])
        expected = data['expected']
        e = expected[i]
        a = int(actual/1e18)
        assert e == a

    return 

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

    # Deposit to staker
    amt = 5_000 * 10 ** 18
    staker.deposit(amt, sender=user)
    staker.deposit(amt, sender=user2)

    # Deposit to rewards
    amt = 1_000 * 10 ** 18
    rewards.depositReward(amt, sender=fee_receiver)
    week = rewards.getWeek()
    assert amt == rewards.weeklyRewardAmount(week)

    # Attempt a claim
    with ape.reverts():
        tx = rewards.claim(sender=user)

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

def test_multiple_deposits_in_week(user, accounts, staker, gov, user2, yprisma, gov_token, stable_token,rewards, fee_receiver, setup_rewards):
    amt = 1_000 * 10 ** 18
    
    week = rewards.getWeek()
    
    amt1 = rewards.weeklyRewardAmount(week)
    rewards.depositReward(amt, sender=fee_receiver)
    assert amt1 < rewards.weeklyRewardAmount(week)
    amt1 = rewards.weeklyRewardAmount(week)
    rewards.depositReward(amt, sender=fee_receiver)
    assert amt1 < rewards.weeklyRewardAmount(week)

    assert stable_token.balanceOf(rewards) > 0

    chain.pending_timestamp += WEEK
    chain.mine()

    rewards.claim(sender=user)
    rewards.claim(sender=user2)

    assert stable_token.balanceOf(rewards) == 0
    assert gov_token.balanceOf(rewards) == 0

def test_get_suggested_week(user, accounts, staker, gov, user2, yprisma, rewards,fee_receiver, setup_rewards):
    amt = 1000 * 10 ** 18
    assert rewards.getSuggestedClaimRange(user).claimStartWeek == 0
    assert rewards.getSuggestedClaimRange(user).claimEndWeek == 0

    weeks = 2
    for i in range(weeks):
        chain.pending_timestamp += WEEK
        chain.mine()
        rewards.depositReward(amt, sender=fee_receiver)

    assert rewards.getSuggestedClaimRange(user).claimStartWeek == 0
    assert rewards.getSuggestedClaimRange(user).claimEndWeek == weeks - 1

def test_prevent_limit_claim_from_lowering_last_claim_week():
    pass

def test_zero_weight_in_bucket(user, accounts, staker, gov, user2, yprisma, rewards,fee_receiver, gov_token, stable_token):
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
    staker.deposit(amt, sender=user)
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
        gov
    )
    rewards = user.deploy(
        project.SingleTokenRewardDistributor,
        staker,
        stable_token,
        gov
    )
    yprisma = gov_token
    yprisma.approve(staker, 2**256-1, sender=user)
    yprisma.approve(staker, 2**256-1, sender=user2)

    # Deposit to staker
    amt = 5_000 * 10 ** 18
    staker.deposit(amt, sender=user)
    staker.deposit(amt, sender=user2)

    # Deposit to rewards    
    amt = 1_000 * 10 ** 18

    gov_token.approve(rewards, 2**256-1, sender=fee_receiver)
    stable_token.approve(rewards, 2**256-1, sender=fee_receiver)
    rewards.depositReward(amt, sender=fee_receiver)
    
    week = rewards.getWeek()
    assert amt == rewards.weeklyRewardAmount(week)

    # Attempt a claim
    with ape.reverts():
        tx = rewards.claim(sender=user)

    assert rewards.getClaimableAt(user,0) == 0
    assert rewards.getClaimableAt(user,1) == 0

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
    
    current_week = rewards.getWeek()
    assert rewards.getClaimableAt(user, current_week - 1) > 0
    assert rewards.getClaimableAt(user, current_week - 2) > 0

    a, b = rewards.getSuggestedClaimRange(user)
    tx = rewards.claimWithRange(a, b, sender=user)
    print(f'⛽️ {tx.gas_used}')
    a, b = rewards.getSuggestedClaimRange(user2)
    tx = rewards.claimWithRange(a, b, sender=user2)
    print(f'⛽️ {tx.gas_used}')
    stable_bal = stable_token.balanceOf(rewards)/1e18
    assert stable_bal < 4000