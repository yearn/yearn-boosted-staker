import pytest
import ape
from ape import chain, Contract
from ape.types import ContractLog
import time
import os
from web3 import Web3, HTTPProvider
from hexbytes import HexBytes
import json
from ape.utils import ZERO_ADDRESS
from utils.constants import (
    YEARN_FEE_RECEIVER, 
    MAX_INT, 
    ApprovalStatus, 
    ZERO_ADDRESS
)

# we default to local node
w3 = Web3(HTTPProvider(os.getenv("CHAIN_PROVIDER", "http://127.0.0.1:8545")))

# Accounts
@pytest.fixture(scope="session")
def gov(accounts):
    gov = accounts['0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52']
    gov.balance += 10 ** 18
    # accounts[0].transfer(gov, 10**18)
    yield gov

@pytest.fixture(scope="session")
def ylockers(accounts):
    gov = accounts['0x4444AAAACDBa5580282365e25b16309Bd770ce4a']
    gov.balance += 10 ** 18
    # accounts[0].transfer(gov, 10**18)
    yield gov
    
@pytest.fixture(scope="session")
def user(accounts):
    accounts[1].balance += int(100e18)
    assert accounts[1].balance > 0
    yield accounts[1]

@pytest.fixture(scope="session")
def user2(accounts):
    accounts[2].balance += int(100e18)
    assert accounts[2].balance > 0
    yield accounts[2]

@pytest.fixture(scope="session")
def user3(accounts):
    accounts[3].balance += int(100e18)
    assert accounts[3].balance > 0
    yield accounts[3]

@pytest.fixture(scope="session")
def rando(accounts):
    accounts[9].balance += int(100e18)
    assert accounts[9].balance > 0
    yield accounts[9]

@pytest.fixture(scope="session")
def yprisma():
    yield Contract('0xe3668873D944E4A949DA05fc8bDE419eFF543882')

@pytest.fixture(scope="session")
def strategy(token, yprisma, ycrv):
    if token == yprisma:
        return Contract('0xA323CCcbCbaDe7806ca5bB9951bebD89A7882bf8')
    if token == ycrv:
        return Contract('0xBdF157c3bad2164Ce6F9dc607fd115374010c5dC')

@pytest.fixture(scope="session")
def ycrv():
    yield Contract('0xFCc5c47bE19d06BF83eB04298b026F81069ff65b')

@pytest.fixture(scope="session")
def token(ycrv, yprisma):
    yield ycrv

@pytest.fixture(scope="session")
def prisma():
    yield Contract('0xdA47862a83dac0c112BA89c6abC2159b95afd71C')

@pytest.fixture(scope="session")
def token_whale(accounts, fee_receiver, user, yprisma, ycrv, user2, user3, rando, gov, token):
    if token == yprisma:
        whale = accounts['0x69833361991ed76f9e8DBBcdf9ea1520fEbFb4a7']
    if token == ycrv:
        whale = accounts['0x71E47a4429d35827e0312AA13162197C23287546']
    whale.balance += 10 ** 18
    token.transfer(user, 100_000 * 10 ** 18, sender=whale)
    token.transfer(user2, 100_000 * 10 ** 18, sender=whale)
    token.transfer(user3, 100_000 * 10 ** 18, sender=whale)
    token.transfer(fee_receiver, 200_000 * 10 ** 18, sender=whale)
    token.transfer(rando, 100_000 * 10 ** 18, sender=whale)
    token.transfer(gov, 100_000 * 10 ** 18, sender=whale)
    yield whale

@pytest.fixture(scope="session")
def reward_token_whale(accounts, fee_receiver, yprisma, ycrv, token):
    if token == yprisma:
        whale = accounts[fee_receiver.address]
    if token == ycrv:
        whale = accounts['0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7']
    whale.balance += 10 ** 18
    yield whale

@pytest.fixture(scope="session")
def mkusd():
    yield Contract('0x4591DBfF62656E7859Afe5e45f6f47D3669fBB28')

@pytest.fixture(scope="session")
def yvmkusd():
    yield Contract('0x04AeBe2e4301CdF5E9c57B01eBdfe4Ac4B48DD13')

@pytest.fixture(scope="session")
def dai_whale(accounts):
    whale = accounts['0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf']
    whale.balance += 10 ** 18
    yield whale

@pytest.fixture(scope="session")
def dai():
    yield Contract('0x6B175474E89094C44Da98b954EedeAC495271d0F')

@pytest.fixture(scope="session")
def yvmkusd_whale(accounts, yvmkusd, fee_receiver, mkusd):
    whale = accounts['0x93A62dA5a14C80f265DAbC077fCEE437B1a0Efde']
    sp = accounts['0xed8B26D99834540C5013701bB3715faFD39993Ba']
    sp.balance += 10 ** 18
    mkusd.approve(yvmkusd, 2**256-1, sender=sp)
    yvmkusd.deposit(mkusd.balanceOf(sp), whale, sender=sp)
    whale.balance += 10 ** 18
    yvmkusd.transfer(fee_receiver, 100_000 * 10 ** 18, sender=whale)
    yield whale

@pytest.fixture(scope="session")
def old_utils(project, token, user, gov, registry):
    deployments = registry.deployments(token)
    utils = deployments['utilities']
    if utils == ZERO_ADDRESS:
        yield ZERO_ADDRESS
    yield Contract(utils)

@pytest.fixture(scope="session")
def staker(project, token, user, gov, registry):
    deployments = registry.deployments(token)
    ybs = deployments['yearnBoostedStaker']
    if ybs != ZERO_ADDRESS:
        return Contract(ybs)
    # Not already deployed, so deploy new
    MAX_GROWTH_WEEKS = 4
    start_time = 0
    staker = user.deploy(
        project.YearnBoostedStaker, 
        token, 
        MAX_GROWTH_WEEKS,
        start_time,
        gov,
    )
    return staker

@pytest.fixture(scope="session")
def prisma_vault():
    yield Contract('0x06bDF212C290473dCACea9793890C5024c7Eb02c')

@pytest.fixture(scope="session")
def gov_token(yprisma):
    yield yprisma


@pytest.fixture(scope="session")
def yvcrvusd():
    yield Contract('0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F')

@pytest.fixture(scope="session")
def reward_token(yvmkusd, ycrv, token, yprisma, yvcrvusd):
    if token == ycrv:
        yield yvcrvusd
    if token == yprisma:
        yield yvmkusd

@pytest.fixture(scope="session")
def strategy():
    return Contract('0xBdF157c3bad2164Ce6F9dc607fd115374010c5dC')

@pytest.fixture(scope="session")
def rewards(project, registry, user, token, staker, gov_token, gov, reward_token):
    deployments = registry.deployments(token)
    yield project.SingleTokenRewardDistributor.at(deployments.rewardDistributor)
    # rewards_contract = user.deploy(
    #     project.SingleTokenRewardDistributor,
    #     staker,
    #     reward_token,
    # )
    # yield rewards_contract

@pytest.fixture(scope="session")
def utils(project, registry, staker, token, rewards, user):
    deployments = registry.deployments(token)
    # yield project.YBSUtilities.at(deployments.utilities)
    utils = user.deploy(
        project.YBSUtilities,
        deployments.yearnBoostedStaker,
        deployments.rewardDistributor,
    )
    yield utils

@pytest.fixture(scope="session")
def fee_receiver(rewards, accounts, gov_token, reward_token):
    fee_receiver = YEARN_FEE_RECEIVER
    fr_account = accounts[fee_receiver]
    fr_account.balance += 20 ** 18
    gov_token.approve(rewards, 2**256-1, sender=fr_account)
    reward_token.approve(rewards, 2**256-1, sender=fr_account)
    yield Contract(fee_receiver)

@pytest.fixture(scope="session")
def fee_receiver_acc(rewards, accounts, gov_token, reward_token):
    fee_receiver = YEARN_FEE_RECEIVER
    fr_account = accounts[fee_receiver]
    fr_account.balance += 20 ** 18
    gov_token.approve(rewards, 2**256-1, sender=fr_account)
    reward_token.approve(rewards, 2**256-1, sender=fr_account)
    yield fr_account

@pytest.fixture(scope="function")
def stake_and_deposit_rewards(user, accounts, staker, gov, user3, user2, token, reward_token_whale, reward_token, rewards, token_whale):
    
    token.approve(staker, 2**256-1, sender=user)
    token.approve(staker, 2**256-1, sender=user2)
    token.approve(staker, 2**256-1, sender=gov)
    token.approve(staker, 2**256-1, sender=user3)
    token.approve(rewards, 2**256-1, sender=reward_token_whale)
    reward_token.approve(rewards, 2**256-1, sender=reward_token_whale)
    # Enable stakes
    owner = accounts[staker.owner()]
    owner.balance += 10**18
    staker.setWeightedStaker(gov, True, sender=owner)
    rewards.configureRecipient(ZERO_ADDRESS, sender=user)

    def stake_and_deposit_rewards(
            user=user, reward_token_whale=reward_token_whale,
            staker=staker, user2=user2, user3=user3, rewards=rewards
        ):
        # stake to staker
        amt = 100 * 10 ** 18
        staker.stake(amt, sender=user)
        staker.stake(50 * 10 ** 18, sender=user2)
        staker.stake(30 * 10 ** 18, sender=user3)

        # Deposit to rewards
        amt = 1_000 * 10 ** 18
        rewards.depositReward(amt, sender=reward_token_whale)
    
    yield stake_and_deposit_rewards

@pytest.fixture(scope="function")
def deposit_rewards(yvmkusd_whale, rewards, fee_receiver, accounts):
    fr_account = accounts[fee_receiver.address]
    def deposit_rewards(rewards=rewards, fr_account=fr_account):
        amt = 1_000 * 10 ** 18
        rewards.depositReward(amt, sender=fr_account)
    yield deposit_rewards

@pytest.fixture(scope="session")
def registry(project, yprisma, user, gov, rando):
    yield Contract('0x262be1d31d0754399d8d5dc63B99c22146E9f738')
    # approved_deployers = [rando]
    # ybs_factory = user.deploy(
    #     project.YBSFactory
    # )
    # reward_factory = user.deploy(
    #     project.YBSRewardFactory
    # )
    # utils_factory = user.deploy(
    #     project.YBSUtilsFactory
    # )
    # registry = user.deploy(
    #     project.YBSRegistry, 
    #     gov,
    #     ybs_factory,
    #     reward_factory,
    #     utils_factory,
    #     approved_deployers,    # approved deployers
    # )
    # yield registry
    # yield Contract('0x262be1d31d0754399d8d5dc63B99c22146E9f738')