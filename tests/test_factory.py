from ape import chain, project, Contract


WEEK = 60 * 60 * 24 * 7

def test_factory(
    user, staker, user2, user3, stable_token,rewards, gov, factory, yprisma, yvmkusd, rando
):
    tx = factory.deployNewYBS(
        yprisma, # _token,
        4,       # _max_stake_growth_weeks,
        0,       # _start_time,
        yvmkusd, # _reward_token
        sender=gov
    )

    event = list(tx.decode_logs(factory.YBSDeployed))[0]

    assert False
    # Check adding / removing deployer
    # Check deployment permissions
    # Check deployments mapping
