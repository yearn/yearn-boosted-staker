// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

interface IFactory {
    function deploy(address, uint, uint, address) external returns (address);
    function deploy(address, address) external returns (address);
}

/// @title YBS Registry
/// @author Yearn Finance
/// @notice Deploys and endorses set of new YBS contracts.
contract YBSRegistry{

    string public constant VERSION = "1.0.0";
    address public owner;
    address public pendingOwner;
    Factories public factories;
    address[] public tokens;
    uint public numTokens;
    mapping(address => Deployment) public deployments;
    mapping(address => bool) approvedDeployers;

    event NewDeployment(address indexed yearnBoostedStaker, address indexed rewardDistributor, address indexed utilities);
    event DeployerApproved(address indexed deployer, bool indexed approved);
    event DistributorUpdated(address indexed token, address indexed distributor);
    event UtilitiesUpdated(address indexed token, address indexed utilities);
    event FactoriesUpdated(address indexed ybsFactory, address indexed rewardFactory, address indexed utilsFactory);
    event OwnershipTransferred(address indexed owner);

    struct Deployment {
        address yearnBoostedStaker;
        address rewardDistributor;
        address utilities;
    }

    struct Factories {
        IFactory yearnBoostedStaker;
        IFactory rewardDistributor;
        IFactory utilities;
    }

    constructor (
        address _owner, 
        IFactory _ybsFactory,
        IFactory _rewardFactory, 
        IFactory _utilsFactory, 
        address[] memory _approvedDeployers
    ) {
        owner = _owner;
        factories = Factories({
            yearnBoostedStaker: _ybsFactory,
            rewardDistributor: _rewardFactory,
            utilities: _utilsFactory
        });
        for (uint i; i < _approvedDeployers.length; i++) {
            _approveDeployer(_approvedDeployers[i], true);
        }
    }

    function approveDeployer(address _deployer, bool _approved) external {
        require(msg.sender == owner, "!authorized");
        return _approveDeployer(_deployer, _approved);
    } 

    function _approveDeployer(address _deployer, bool _approved) internal {
        if (approvedDeployers[_deployer] == _approved) return;
        approvedDeployers[_deployer] = _approved;
        emit DeployerApproved(_deployer, _approved);
    }

    /**
     * @notice Creates a new YBS Staker.
     * @param _token The token to stake.
     * @param _max_stake_growth_weeks Amount of stake growth transitions.
     * @param _start_time Timestamp at which to start the week counter.
     * @param _reward_token Token to be distributed to stakers via rewards distirbutor.
     */
    function createNewDeployment(
        address _token,
        uint _max_stake_growth_weeks,
        uint _start_time,
        address _reward_token
    ) external returns (address ybs, address distributor, address utils) {
        require(isApprovedDeployer(msg.sender), "!authorized");
        require(deployments[_token].yearnBoostedStaker == address(0), "already exists");
        
        Factories memory _factories = factories;
        
        ybs = _factories.yearnBoostedStaker.deploy(
            _token, _max_stake_growth_weeks, _start_time, owner
        );

        distributor = _factories.rewardDistributor.deploy(
            ybs,
            _reward_token
        );

        utils = _factories.utilities.deploy(
            ybs,
            distributor
        );

        deployments[_token] = Deployment({
            yearnBoostedStaker: ybs,
            rewardDistributor: distributor,
            utilities: utils
        });

        tokens.push(_token);
        numTokens += 1;

        emit NewDeployment(ybs, distributor, utils);

        return (ybs, distributor, utils);
    }

    /**
        @notice Modify the reward distributor contract for a specified deployment.
        @param _token Token value used to identify deployment.
        @param _distributor New rewards distributor contract.
    */
    function updateRewardDistributor(address _token, address _distributor) external {
        require(msg.sender == owner, "!authorized");
        Deployment storage deployment = deployments[_token];
        require(deployment.yearnBoostedStaker != address(0), "invalid token");
        deployment.rewardDistributor = _distributor;
        emit DistributorUpdated(_token, _distributor);
    }

    /**
        @notice Modify the utilities contract for a specified deployment.
        @param _token Token value used to identify deployment.
        @param _utils New utilities contract.
    */
    function updateUtilities(address _token, address _utils) external {
        require(msg.sender == owner, "!authorized");
        Deployment storage deployment = deployments[_token];
        require(deployment.yearnBoostedStaker != address(0), "invalid token");
        deployment.utilities = _utils;
        emit UtilitiesUpdated(_token, _utils);
    }

    /**
        @notice Update the deployer factories for each of the 3 YBS contracts.
        @param _ybsFactory New ybs factory to be used for future deployments.
        @param _rewardFactory New reward factory to be used for future deployments.
        @param _utilsFactory New utils factory to be used for future deployments.
    */
    function updateFactories(IFactory _ybsFactory, IFactory _rewardFactory, IFactory _utilsFactory) external {
        require(msg.sender == owner, "!authorized");
        factories = Factories({
            yearnBoostedStaker: _ybsFactory,
            rewardDistributor: _rewardFactory,
            utilities: _utilsFactory
        });
        emit FactoriesUpdated(address(_ybsFactory), address(_rewardFactory), address(_utilsFactory));
    }

    /**
        @notice Check whether an address is approved to deploy via registry.
        @param _deployer Address to check.
        @return approved status of checked address.
    */
    function isApprovedDeployer(address _deployer) public view returns (bool) {
        if (_deployer == owner) return true;
        return approvedDeployers[_deployer];
    }

    /**
        @notice Set a pending owner which can later be accepted.
        @param _pendingOwner Address of the new owner.
    */
    function transferOwnership(address _pendingOwner) external {
        require(msg.sender == owner, "!authorized");
        pendingOwner = _pendingOwner;
    }

    /**
        @notice Allow pending owner to accept ownership
    */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "!authorized");
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(msg.sender);
    }
}