// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "interfaces/iface.sol";
import "@eigenlayer/contracts/interfaces/IEigenPodManager.sol";
import "@eigenlayer/contracts/interfaces/IDelayedWithdrawalRouter.sol";
import "@eigenlayer/contracts/interfaces/IEigenPod.sol";
import "@eigenlayer/contracts/libraries/BeaconChainProofs.sol";

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract PodOwner is IPodOwner, Initializable, OwnableUpgradeable {
    using Address for address;
    
    receive() external payable { }
    constructor() { _disableInitializers(); }

    function initialize(address _eigenPodManager) initializer public {
        __Ownable_init();

        IEigenPodManager(_eigenPodManager).createPod();
    }

    function execute(address target, bytes memory data) override onlyOwner external returns(bytes memory) {
        return target.functionCall(data);
    }
}

/**
 * @title Bedrock EigenLayer Restaking Contract
 *
 * Description:
 *  This contract manages restaking on eigenlayer, including:
 *      1. createPod for native staking
 *      2. withdraws rewards from eigenpod to staking contract.
 */
contract Restaking is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using Address for address;

    bytes32 public constant OPERATOR_ROLE= keccak256("OPERATOR_ROLE");

    /// @dev the EigenLayer EigenPodManager contract
    address public eigenPodManager;
    /// @dev The EigenPod owned by this contract
    address public eigenPod;
    /// @dev the DelegationManager contract
    address public delegationManager;
    /// @dev the StrategyManager contract
    address public strategyManager;
    /// @dev the DelayedWithdrawalRouter contract
    address public delayedWithdrawalRouter;
    /// @dev record pending withdrawal amount from EigenPod to DelayedWithdrawalRouter 
    uint256 private pendingWithdrawal;
    // @dev staking contract address
    address public stakingAddress;

    // @dev PodOwner upgradable beacon
    UpgradeableBeacon public beacon;

    // @dev pods owners
    IPodOwner [] public podOwners;

    // @dev onlySelf requirement
    modifier onlySelf() {
       if (msg.sender != address(this))
            revert();
        _;
    }

    /**
     * @dev forward to staking contract
     */
    receive() external payable { }
    constructor() { _disableInitializers(); }

    /**
     * @dev initialization 
     */
    /*
    function initialize(
        address _eigenPodManager,
        address _delegationManager,
        address _strategyManager,
        address _delayedWithdrawalRouter
    ) initializer public {
        require(_eigenPodManager != address(0x0), "SYS026");
        require(_delegationManager!= address(0x0), "SYS027");
        require(_strategyManager!= address(0x0), "SYS028");
        require(_delayedWithdrawalRouter!= address(0x0), "SYS029");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);

        // Assign to local variable
        eigenPodManager = _eigenPodManager;
        delegationManager = _delegationManager;
        strategyManager = _strategyManager;
        delayedWithdrawalRouter = _delayedWithdrawalRouter;

        // Deploy new EigenPod
        IEigenPodManager(eigenPodManager).createPod();

        // Save off the EigenPod address
        eigenPod = address(IEigenPodManager(eigenPodManager).getPod(address(this)));
    }
   */

    /**
     * @dev UPDATE(20240130): to set a variable after upgrades
     * use upgradeAndCall to initializeV2
     */ 
     /*
    function initializeV2(address stakingAddress_) reinitializer(2) public {
        stakingAddress = stakingAddress_;
    }
   */

    /**
     * @dev UPDATE(20240330): to init upgradable beacon/beaconproxy
     */
    function initializeV3(address impl) reinitializer(3) public {
        beacon = new UpgradeableBeacon(impl);
        podOwners.push(IPodOwner(address(this)));
    }

    /**
     * @dev upgradeBeacon
     */
    function upgradeBeacon(address impl) onlyRole(DEFAULT_ADMIN_ROLE) external {
        beacon.upgradeTo(impl);
    }

    /**
     * @dev call delegation operations
     */
    function callDelegationManager(uint256 podId, bytes memory data) external onlyRole(OPERATOR_ROLE) returns(bytes memory) {
        IPodOwner podOwner = podOwners[podId];
        return podOwner.execute(delegationManager, data); // execute delegation operations
    }

    /**
     * @dev get amount withdrawed from eigenpod to IDelayedRouter
     */
    function getPendingWithdrawalAmount(
    ) external view returns (uint256) {
        return pendingWithdrawal;
    }

    /**
     * @dev create pod
     */ 
    function createPod() external onlyRole(DEFAULT_ADMIN_ROLE) {
        BeaconProxy proxy = new BeaconProxy(address(beacon),
                                            abi.encodeWithSignature("initialize(address)", eigenPodManager)
                                           );

        IPodOwner podOwner = IPodOwner(address(proxy));
        podOwners.push(podOwner);
    }

    /**
     * @dev get total pods
     */
    function getTotalPods() external view returns (uint256) {
        return podOwners.length;
    }

    /**
     * @dev get i-th eigenpod address
     */
    function getPod(uint256 i) external view returns (address) {
        IPodOwner podOwner = podOwners[i];
        return address(IEigenPodManager(eigenPodManager).getPod(address(podOwner)));
    }


    /**
     * ======================================================================================
     * 
     *  PRIMARY POD FUNCTIONS
     *
     * ======================================================================================
     */

    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function withdrawBeforeRestaking() external {
        uint256 diff = _withdrawBeforeRestaking();
        emit Pending(diff);
    }

    /**
     * @notice Called in order to withdraw delayed withdrawals made to the caller that have passed the `withdrawalDelayBlocks` period.
     * @param maxNumberOfWithdrawalsToClaim Used to limit the maximum number of withdrawals to loop through claiming.
     */
    function claimDelayedWithdrawals(
        uint256 maxNumberOfWithdrawalsToClaim
    ) external nonReentrant {
        uint256 diff = _claimDelayedWithdrawals(maxNumberOfWithdrawalsToClaim);
        emit Claimed(diff);
    }


    /**
     * ======================================================================================
     * 
     *  INTERNAL PODS FUNCTIONS
     *
     * ======================================================================================
     */

    function _withdrawBeforeRestaking() internal returns (uint256) {
        uint256 totalDiff;

        for (uint256 i=0;i< podOwners.length;i++) {
            IPodOwner podOwner = podOwners[i];
            address pod = address(IEigenPodManager(eigenPodManager).getPod(address(podOwner)));

            uint256 balanceBefore = address(pod).balance;
            podOwner.execute(pod, 
                             abi.encodeWithSignature("withdrawBeforeRestaking()")); // use podOwner to execute withdrawBeforeRestaking
            uint256 diff = balanceBefore - address(pod).balance;

            totalDiff += diff;
        }

        pendingWithdrawal += totalDiff;
        return totalDiff;
    }

    function _claimDelayedWithdrawals(uint256 maxNumberOfWithdrawalsToClaim) internal returns(uint256) {
        uint256 totalDiff;

        for (uint256 i=0;i< podOwners.length;i++) {
            IPodOwner podOwner = podOwners[i];

            if (IDelayedWithdrawalRouter(delayedWithdrawalRouter).getClaimableUserDelayedWithdrawals(address(podOwner)).length > 0) {
                // watch staking address balance change
                uint256 balanceBefore = address(stakingAddress).balance;
                podOwner.execute(delayedWithdrawalRouter, 
                                 abi.encodeWithSignature("claimDelayedWithdrawals(address,uint256)", stakingAddress, maxNumberOfWithdrawalsToClaim)); // use podOwner to execute claimDelayedWithdrawals
                uint256 diff = address(stakingAddress).balance - balanceBefore;
                totalDiff += diff;
            }
        }

        pendingWithdrawal -= totalDiff;
        return totalDiff;
    }

    // @dev the magic to make restaking contract compatible to IPodOwner
    //  so we can unify the the method to handle eigenpods. 
    //  Access to this function must be limited to the contract itself.
    function execute(address target, bytes memory data) onlySelf external returns(bytes memory) {
        return target.functionCall(data);
    }

    /**
     * ======================================================================================
     * 
     * EVENTS
     *
     * ======================================================================================
     */
    event Claimed(uint256 amount);
    event Pending(uint256 amount);
}