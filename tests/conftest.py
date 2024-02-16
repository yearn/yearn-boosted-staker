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
def rando(accounts):
    accounts[9].balance += int(100e18)
    assert accounts[9].balance > 0
    yield accounts[9]

@pytest.fixture(scope="session")
def yprisma():
    yield Contract('0xe3668873D944E4A949DA05fc8bDE419eFF543882')

@pytest.fixture(scope="session")
def prisma():
    yield Contract('0xdA47862a83dac0c112BA89c6abC2159b95afd71C')

@pytest.fixture(scope="session")
def yprisma_whale(accounts, fee_receiver, user, yprisma, user2, rando):
    whale = accounts['0x69833361991ed76f9e8DBBcdf9ea1520fEbFb4a7']
    whale.balance += 10 ** 18
    yprisma.transfer(user, 100_000 * 10 ** 18, sender=whale)
    yprisma.transfer(user2, 100_000 * 10 ** 18, sender=whale)
    yprisma.transfer(fee_receiver, 100_000 * 10 ** 18, sender=whale)
    yprisma.transfer(rando, 100_000 * 10 ** 18, sender=whale)
    yield whale

@pytest.fixture(scope="session")
def yvmkusd():
    yield Contract('0x04AeBe2e4301CdF5E9c57B01eBdfe4Ac4B48DD13')

@pytest.fixture(scope="session")
def dai_whale(accounts):
    whale = accounts['0x075e72a5eDf65F0A5f44699c7654C1a76941Ddc8']
    whale.balance += 10 ** 18
    yield whale

@pytest.fixture(scope="session")
def dai():
    yield Contract('0x6B175474E89094C44Da98b954EedeAC495271d0F')

@pytest.fixture(scope="session")
def yvmkusd_whale(accounts, yvmkusd, fee_receiver):
    whale = accounts['0x93A62dA5a14C80f265DAbC077fCEE437B1a0Efde']
    whale.balance += 10 ** 18
    yvmkusd.transfer(fee_receiver, 20_000 * 10 ** 18, sender=whale)
    yield whale

@pytest.fixture(scope="session")
def staker(project, yprisma, user, gov, prisma_vault):
    start_time = Contract('0x5d17eA085F2FF5da3e6979D5d26F1dBaB664ccf8').startTime()
    start_time = 0
    staker = user.deploy(
        project.YearnBoostedStaker, 
        yprisma, 
        4, # <-- Number of growth weeks
        start_time,
        gov
    )
    yield staker

@pytest.fixture(scope="session")
def prisma_vault():
    yield Contract('0x06bDF212C290473dCACea9793890C5024c7Eb02c')

@pytest.fixture(scope="session")
def gov_token(yprisma):
    yield yprisma

@pytest.fixture(scope="session")
def stable_token(yvmkusd):
    yield yvmkusd

@pytest.fixture(scope="session")
def rewards(project, user, staker, gov_token, stable_token, gov):
    rewards_contract = user.deploy(
        project.TwoTokenRewardDistributor,
        staker,
        gov_token,
        stable_token,
        gov
    )
    yield rewards_contract

@pytest.fixture(scope="session")
def fee_receiver():
    yield Contract(YEARN_FEE_RECEIVER)