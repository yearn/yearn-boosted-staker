from ape import chain, project, Contract
import ape 
from utils.constants import (
    ZERO_ADDRESS,
)

WEEK = 60 * 60 * 24 * 7

def test_factory(
    user, staker, user2, user3, stable_token,rewards, gov, registry, yprisma, yvmkusd, rando
):
    
    registry.balance += 10**18
    factories = registry.factories()
    ybs_factory = project.YBSFactory.at(factories.yearnBoostedStaker)
    reward_factory = project.YBSRewardFactory.at(factories.rewardDistributor)
    utils_factory = project.YBSUtilsFactory.at(factories.utilities)
    
    ### Perform direct deployments from factories, and cache resulting address
    snap = chain.snapshot()
    tx = ybs_factory.deploy(
        yprisma,
        4, 
        0,
        gov,
        sender=registry
    )
    temp_ybs = tx.return_value
    tx = reward_factory.deploy(
        temp_ybs,
        yvmkusd, 
        sender=registry
    )
    temp_reward = tx.return_value
    tx = utils_factory.deploy(
        temp_ybs,
        temp_reward, 
        sender=registry
    )
    temp_utils = tx.return_value

    chain.restore(snap)

    # Deploy from registry
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

    # Check that registry deployment addresses match the direct deployment addresses
    assert ybs.address == temp_ybs
    assert rewards.address == temp_reward
    assert utils.address == temp_utils

    assert ybs.address == rewards.staker()
    assert ybs.stakeToken() == utils.TOKEN()

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

    # Test CREATE2 blocks identical deployment based on msg.sender
    with ape.reverts():
        tx = ybs_factory.deploy(
            yprisma,
            4, 
            0,
            gov,
            sender=registry
        )
    # CREATE2 permits identical deployment based on different msg.sender  
    tx = ybs_factory.deploy(
        yprisma,
        4, 
        0,
        gov,
        sender=user
    )
    with ape.reverts():
        tx = reward_factory.deploy(
            deployment.yearnBoostedStaker,
            yvmkusd, 
            sender=registry
        )
    tx = reward_factory.deploy(
        deployment.yearnBoostedStaker,
        yvmkusd, 
        sender=user
    )
    with ape.reverts():
        tx = utils_factory.deploy(
            deployment.yearnBoostedStaker,
            deployment.rewardDistributor, 
            sender=registry
        )
    tx = utils_factory.deploy(
        deployment.yearnBoostedStaker,
        deployment.rewardDistributor, 
        sender=user
    )
    
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
        deployment = registry.deployments(token)
        assert deployment.yearnBoostedStaker != ZERO_ADDRESS
        assert deployment.rewardDistributor != ZERO_ADDRESS
        assert deployment.utilities != ZERO_ADDRESS

    assert user != registry.owner()
    registry.transferOwnership(user, sender=gov)
    registry.acceptOwnership(sender=user)
    assert user == registry.owner()