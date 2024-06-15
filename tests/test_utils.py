from ape import chain, project, Contract
from ape.utils import ZERO_ADDRESS

WEEK = 60 * 60 * 24 * 7

def test_utils_from_start(
    user, staker, user2, user3, reward_token ,rewards, utils, stake_and_deposit_rewards, deposit_rewards
):
    if staker.totalSupply() > 0:
        return
    print(f'In week: {utils.getWeek()}')
    stake_token_price = 17 * 10 ** 16 # $0.17
    reward_token_price = 10 ** 18
    stake_and_deposit_rewards()

    users = [user, user2, user3]
    for u in users:
        assert staker.balanceOf(u) > 0
        assert 0 == utils.getUserActiveBoostMultiplier(u)
        assert 0 == utils.getUserProjectedBoostMultiplier(u)
        assert 0 == utils.getUserActiveApr(u, stake_token_price, reward_token_price)
        assert 0 == utils.getUserProjectedApr(u, stake_token_price, reward_token_price)

    global_active_apr = utils.getGlobalActiveApr(stake_token_price, reward_token_price)
    global_projected_apr = utils.getGlobalProjectedApr(stake_token_price, reward_token_price)
    assert 0 == utils.getGlobalActiveBoostMultiplier()
    assert 0 == utils.getGlobalProjectedBoostMultiplier()
    assert 0 == global_active_apr
    assert 0 == global_projected_apr
    print('global active apr', utils.getWeek(), global_active_apr/1e18)
    print('global projected apr', utils.getWeek(), global_projected_apr/1e18)

    chain.pending_timestamp += WEEK
    chain.mine()
    print(f'⏰ Advanced to week: {utils.getWeek()}')

    for u in users:
        assert staker.balanceOf(u) > 0
        # User should still have
        assert 0 == utils.getUserActiveBoostMultiplier(u)
        assert 0 < utils.getUserProjectedBoostMultiplier(u)
        assert 0 == utils.getUserActiveApr(u, stake_token_price, reward_token_price)
        # Should be 0 until we push rewards!
        assert 0 == utils.getUserProjectedApr(u, stake_token_price, reward_token_price)

    global_active_apr = utils.getGlobalActiveApr(stake_token_price, reward_token_price)
    global_projected_apr = utils.getGlobalProjectedApr(stake_token_price, reward_token_price)
    assert 0 == utils.getGlobalActiveBoostMultiplier()
    assert 0 < utils.getGlobalProjectedBoostMultiplier()
    assert 0 == global_active_apr
    # Should be 0 until we push rewards!
    assert 0 == global_projected_apr

    week = rewards.getWeek() - 1
    assert rewards.pushableRewards(week) > 0
    rewards.pushRewards(week,sender=user)

    # OK now projected APRs should work!
    global_active_apr = utils.getGlobalActiveApr(stake_token_price, reward_token_price)
    global_projected_apr = utils.getGlobalProjectedApr(stake_token_price, reward_token_price)
    user_proj_apr = utils.getUserProjectedApr(user, stake_token_price, reward_token_price)
    assert user_proj_apr > 0
    assert global_projected_apr > 0
    print('global active apr', utils.getWeek(), global_active_apr/1e18)
    print('global projected apr', utils.getWeek(), global_projected_apr/1e18)

    unstaking_user = user3
    staker.unstake(staker.balanceOf(unstaking_user), unstaking_user,sender=unstaking_user)

    # User+global APR should increase after user unstaked
    assert user_proj_apr < utils.getUserProjectedApr(user, stake_token_price, reward_token_price)
    assert global_projected_apr < utils.getGlobalProjectedApr(stake_token_price, reward_token_price)

    assert utils.weeklyRewardAmountAt(utils.getWeek()) > 0
    deposit_rewards()
    chain.pending_timestamp += WEEK
    chain.mine()
    print(f'⏰ Advanced to week: {utils.getWeek()}')

    for u in users:
        if u == unstaking_user:
            assert 0 == utils.getUserActiveBoostMultiplier(u)
            assert 0 == utils.getUserProjectedBoostMultiplier(u)
            continue
        assert staker.balanceOf(u) > 0
        assert 0 < utils.getUserActiveBoostMultiplier(u)
        assert 0 < utils.getUserProjectedBoostMultiplier(u)
        # We should be earning this week
        assert 0 < utils.getUserActiveApr(u, stake_token_price, reward_token_price)
        # No rewards deposited yet, so projected should be 0
        assert 0 == utils.getUserProjectedApr(u, stake_token_price, reward_token_price)

    global_active_apr = utils.getGlobalActiveApr(stake_token_price, reward_token_price)
    global_projected_apr = utils.getGlobalProjectedApr(stake_token_price, reward_token_price)

    assert utils.getGlobalActiveBoostMultiplier() > 0
    assert utils.getGlobalProjectedBoostMultiplier() > 0
    assert global_active_apr > 0
    assert global_projected_apr == 0

    deposit_rewards()
    global_active_apr = utils.getGlobalActiveApr(stake_token_price, reward_token_price)
    global_projected_apr = utils.getGlobalProjectedApr(stake_token_price, reward_token_price)
    assert global_projected_apr > 0
    assert utils.getUserProjectedApr(user, stake_token_price, reward_token_price) > 0
    print('global active apr', utils.getWeek(), global_active_apr/1e18)
    print('global projected apr', utils.getWeek(), global_projected_apr/1e18)

    assert False

def test_utils_from_start(
    old_utils, accounts, user, staker, user2, user3, strategy, reward_token ,rewards, utils, stake_and_deposit_rewards, deposit_rewards
):
    if old_utils == ZERO_ADDRESS:
        return
    receiver = accounts['0x584BffC5F51CcAe39aD69F1c399743620e619C2B']
    receiver.balance += 10**18
    reward_token_underlying = Contract(reward_token.asset())
    reward_token_underlying.approve(reward_token, 2 ** 256-1, sender=receiver)
    reward_token.approve(rewards, 2 ** 256-1, sender=receiver)
    reward_token.deposit(reward_token_underlying.balanceOf(receiver), receiver, sender=receiver)
    bal = reward_token.balanceOf(receiver)
    rewards.depositReward(bal, sender=receiver)
    stake_token_price = 2965 * 10 ** 14
    reward_token_price = 10 ** 18

    apr_after_fee = utils.getUserProjectedAprWithFee( 
        strategy, 
        stake_token_price, 
        reward_token_price,
        False # Hide unboosted
    )

    example_user = '0x4c745138025Fe0D3b16cbe449e7cAC5e5BEA2E3C'
    user_apr_with_hidden = utils.getUserProjectedAprWithFee( 
        example_user, 
        stake_token_price, 
        reward_token_price,
        True # Hide unboosted
    )
    user_apr = utils.getUserProjectedAprWithFee( 
        example_user, 
        stake_token_price, 
        reward_token_price,
        False # Hide unboosted
    )
    assert False