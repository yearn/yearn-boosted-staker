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
    fr_account = accounts[fee_receiver.address]
    fr_account.balance += 10 ** 18
    yprisma.approve(staker, 2**256-1, sender=user)
    yprisma.approve(staker, 2**256-1, sender=user2)
    yprisma.approve(rewards, 2**256-1, sender=fr_account)
    yvmkusd.approve(rewards, 2**256-1, sender=fr_account)

    # Deposit to staker
    amt = 5_000 * 10 ** 18
    staker.deposit(amt, sender=user)
    staker.deposit(amt, sender=user2)

    staker.setElection(7_500, sender=user)
    staker.setElection(2_500, sender=user2)

    # Deposit to rewards
    amt = 1_000 * 10 ** 18
    rewards.depositRewards(amt, amt, sender=fr_account)
    week = rewards.getWeek()
    assert amt == rewards.weeklyRewardInfo(week).amountGov
    assert amt == rewards.weeklyRewardInfo(week).amountStable

    # Attempt a claim
    with ape.reverts():
        tx = rewards.claim(sender=user)

    assert rewards.getClaimableAt(user,0).tokenGovAmount == 0
    assert rewards.getClaimableAt(user,0).tokenStablesAmount == 0
    assert rewards.getClaimableAt(user,1).tokenGovAmount == 0
    assert rewards.getClaimableAt(user,1).tokenStablesAmount == 0

    chain.pending_timestamp += WEEK
    chain.mine()

    # Week 1: Deposit to rewards
    staker.setElection(5_500, sender=user2)

    for i in range(5):
        amt = i * 1_000 * 10 ** 18
        rewards.depositRewards(amt, amt, sender=fr_account)
        week = rewards.getWeek()
        assert amt == rewards.weeklyRewardInfo(week).amountGov
        assert amt == rewards.weeklyRewardInfo(week).amountStable
        chain.pending_timestamp += WEEK
        chain.mine()


    rewards.getSuggestedClaimRange(user)
    
    tx = rewards.claimWithRange(0,2,sender=user)

def test_claim_blocked_in_current_week(user, accounts, staker, gov, user2, yprisma):
    pass

def test_multiple_deposits_in_week(user, accounts, staker, gov, user2, yprisma):
    pass

def test_get_suggested_week(user, accounts, staker, gov, user2, yprisma):
    pass

def check_invariants(user, accounts, staker, gov, user2, yprisma):
    pass

def test_prevent_limit_claim_from_lowering_last_claim_week():
    pass

def test_claims_when_start_week_is_set_gt_zero():
    pass