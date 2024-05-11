from ape import chain, project, Contract
import ape 
from utils.constants import (
    ZERO_ADDRESS,
)

WEEK = 60 * 60 * 24 * 7

def test_factory(
    user, staker, user2, user3, stable_token,rewards, gov, registry, yprisma, yvmkusd, rando
):
    tx = registry.createNewDeployment(
        yprisma, # _token,
        4,       # _max_stake_growth_weeks,
        0,       # _start_time,
        yvmkusd, # _reward_token
        sender=gov
    )

    event = list(tx.decode_logs(registry.NewDeployment))[0]

    assert registry.numTokens() > 0

    ybs = project.YearnBoostedStaker.at(event.yearnBoostedStaker)
    rewards = project.SingleTokenRewardDistributor.at(event.rewardDistributor)
    utils = project.YBSUtilities.at(event.utilities)

    assert ybs.address == rewards.staker()
    assert ybs.stakeToken() == utils.TOKEN()

    factories = registry.factories()
    deployment = registry.deployments(yprisma)

    # Prevent a duplicate deployment
    with ape.reverts():
        tx = registry.createNewDeployment(
            yprisma, # _token,
            4,       # _max_stake_growth_weeks,
            0,       # _start_time,
            yvmkusd, # _reward_token
            sender=gov
        )

    # Prevent an unauthorized deployment
    with ape.reverts():
        tx = registry.createNewDeployment(
            yvmkusd, # _token,
            4,       # _max_stake_growth_weeks,
            0,       # _start_time,
            yprisma, # _reward_token
            sender=user
        )

    registry.approveDeployer(user, True, sender=gov)
    
    # Check adding / removing deployer
    tx = registry.approveDeployer(user, True, sender=gov)
    event = list(tx.decode_logs(registry.DeployerApproved))[0]
    assert event.approved == True

    tx = registry.createNewDeployment(
        yvmkusd, # _token,
        4,       # _max_stake_growth_weeks,
        0,       # _start_time,
        yprisma, # _reward_token
        sender=user
    )

    # Check deployment permissions

    # Check deployments mapping
    assert registry.numTokens() == 2

    for i in range(0, registry.numTokens()):
        token = registry.tokens(i)
        deployment = registry.deployment(token)
        assert deployment.yearnBoostedStaker != ZERO_ADDRESS
        assert deployment.rewardDistributor != ZERO_ADDRESS
        assert deployment.utilities != ZERO_ADDRESS

    assert user != registry.owner()
    registry.transferOwnership(user, sender=gov)
    registry.acceptOwnership(sender=user)
    assert user == registry.owner()