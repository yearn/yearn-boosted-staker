// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import {YearnBoostedStaker} from "../YearnBoostedStaker.sol";

interface IYBSRewardsFactory {
    function deploy(address ybs, address rewardToken) external returns (address);
}

interface IYBSUtilsFactory {
    function deploy(address ybs, address rewardDistributor) external returns (address);
}

/// @title Deploys set of new YBS contracts
contract YBSFactory{

    address public governance;
    string public constant VERSION = "1.0.0";
    IYBSRewardsFactory public immutable REWARDS_FACTORY;
    IYBSUtilsFactory public immutable UTILS_FACTORY;
    mapping(address => Deployment) public deployments;
    mapping(address => bool) approvedDeployers;
    address[] public tokens;
    uint public numTokens;

    event DeployerApproved(address indexed deployer, bool indexed approved);
    event YBSDeployed(address yearnBoostedStaker, address rewardsDistributor, address utilities);
    event DistributorUpdated(address indexed token, address indexed distributor);
    event UtilitiesUpdated(address indexed token, address indexed utilities);

    struct Deployment {
        address yearnBoostedStaker;
        address rewardsDistributor;
        address utilities;
    }

    constructor (address _governance, IYBSRewardsFactory _rewardsFactory, IYBSUtilsFactory _utilsFactory, address[] memory _approvedDeployers) {
        governance = _governance;
        REWARDS_FACTORY = _rewardsFactory;
        UTILS_FACTORY = _utilsFactory;
        for (uint i; i < _approvedDeployers.length; i++) {
            _approveDeployer(_approvedDeployers[i], true);
        }
    }

    function approveDeployer(address _deployer, bool _approved) external {
        require(msg.sender == governance, "!authorized");
        return _approveDeployer(_deployer, _approved);
    } 

    function _approveDeployer(address _deployer, bool _approved) internal {
        if (approvedDeployers[_deployer] == _approved) return;
        approvedDeployers[_deployer] = _approved;
        emit DeployerApproved(_deployer, _approved);
    }

    /**
     * @notice Creates a new YBS Staker.
     * @param _token The token to stake
     * @param _max_stake_growth_weeks Amount of stake growth transitions.
     * @param _start_time Timestamp at which to start the week counter.
     */
    function deployNewYBS(
        address _token,
        uint _max_stake_growth_weeks,
        uint _start_time,
        address _reward_token
    ) external returns (address ybs, address distributor, address utils) {
        require(isApprovedDeployer(msg.sender), "!authorized");
        require(deployments[_token].yearnBoostedStaker == address(0), "already exists");
        tokens.push(_token);
        numTokens += 1;
        return
            _deployNewYBS(
                _token,
                _max_stake_growth_weeks,
                _start_time,
                governance,
                _reward_token
            );
    }

    function _deployNewYBS(
        address _token,
        uint _max_stake_growth_weeks,
        uint _start_time,
        address _governance,
        address _reward_token
    ) internal returns (address ybs, address distributor, address utils) {
        
        ybs = address(new YearnBoostedStaker(
            _token, _max_stake_growth_weeks, _start_time, _governance
        ));

        distributor = REWARDS_FACTORY.deploy(
            ybs,
            _reward_token
        );

        utils = UTILS_FACTORY.deploy(
            ybs,
            distributor
        );

        deployments[_token] = Deployment({
            yearnBoostedStaker: ybs,
            rewardsDistributor: distributor,
            utilities: utils
        });

        emit YBSDeployed(ybs, distributor, utils);

        return (ybs, distributor, utils);
    }

    function updateRewardsDistributor(address _token, address _distributor) external {
        require(msg.sender == governance, "!authorized");
        Deployment storage deployment = deployments[_token];
        require(deployment.yearnBoostedStaker != address(0), "invalid token");
        deployment.rewardsDistributor = _distributor;
        emit DistributorUpdated(_token, _distributor);
    }

    function updateUtilities(address _token, address _utils) external {
        require(msg.sender == governance, "!authorized");
        Deployment storage deployment = deployments[_token];
        require(deployment.yearnBoostedStaker != address(0), "invalid token");
        deployment.utilities = _utils;
        emit UtilitiesUpdated(_token, _utils);
    }

    function isApprovedDeployer(address _deployer) public view returns (bool) {
        if (_deployer == governance) return true;
        return approvedDeployers[_deployer];
    }
}