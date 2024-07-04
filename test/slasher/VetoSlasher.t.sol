// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {VaultFactory} from "src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "src/contracts/SlasherFactory.sol";
import {NetworkRegistry} from "src/contracts/NetworkRegistry.sol";
import {OperatorRegistry} from "src/contracts/OperatorRegistry.sol";
import {MetadataService} from "src/contracts/service/MetadataService.sol";
import {NetworkMiddlewareService} from "src/contracts/service/NetworkMiddlewareService.sol";
import {OptInService} from "src/contracts/service/OptInService.sol";

import {Vault} from "src/contracts/vault/Vault.sol";
import {NetworkRestakeDelegator} from "src/contracts/delegator/NetworkRestakeDelegator.sol";
import {FullRestakeDelegator} from "src/contracts/delegator/FullRestakeDelegator.sol";
import {Slasher} from "src/contracts/slasher/Slasher.sol";
import {VetoSlasher} from "src/contracts/slasher/VetoSlasher.sol";

import {IVault} from "src/interfaces/vault/IVault.sol";
import {SimpleCollateral} from "test/mocks/SimpleCollateral.sol";
import {Token} from "test/mocks/Token.sol";
import {VaultConfigurator} from "src/contracts/VaultConfigurator.sol";
import {IVaultConfigurator} from "src/interfaces/IVaultConfigurator.sol";
import {INetworkRestakeDelegator} from "src/interfaces/delegator/INetworkRestakeDelegator.sol";
import {IFullRestakeDelegator} from "src/interfaces/delegator/IFullRestakeDelegator.sol";
import {IBaseDelegator} from "src/interfaces/delegator/IBaseDelegator.sol";

import {IVaultStorage} from "src/interfaces/vault/IVaultStorage.sol";
import {IVetoSlasher} from "src/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "src/interfaces/slasher/IBaseSlasher.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VetoSlasherTest is Test {
    using Math for uint256;

    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    NetworkRegistry networkRegistry;
    OperatorRegistry operatorRegistry;
    MetadataService operatorMetadataService;
    MetadataService networkMetadataService;
    NetworkMiddlewareService networkMiddlewareService;
    OptInService networkVaultOptInService;
    OptInService operatorVaultOptInService;
    OptInService operatorNetworkOptInService;

    SimpleCollateral collateral;
    VaultConfigurator vaultConfigurator;

    Vault vault;
    FullRestakeDelegator delegator;
    VetoSlasher slasher;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        networkRegistry = new NetworkRegistry();
        operatorRegistry = new OperatorRegistry();
        operatorMetadataService = new MetadataService(address(operatorRegistry));
        networkMetadataService = new MetadataService(address(networkRegistry));
        networkMiddlewareService = new NetworkMiddlewareService(address(networkRegistry));
        networkVaultOptInService = new OptInService(address(networkRegistry), address(vaultFactory));
        operatorVaultOptInService = new OptInService(address(operatorRegistry), address(vaultFactory));
        operatorNetworkOptInService = new OptInService(address(operatorRegistry), address(networkRegistry));

        address vaultImpl =
            address(new Vault(address(delegatorFactory), address(slasherFactory), address(vaultFactory)));
        vaultFactory.whitelist(vaultImpl);

        address networkRestakeDelegatorImpl = address(
            new NetworkRestakeDelegator(
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory)
            )
        );
        delegatorFactory.whitelist(networkRestakeDelegatorImpl);

        address fullRestakeDelegatorImpl = address(
            new FullRestakeDelegator(
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory)
            )
        );
        delegatorFactory.whitelist(fullRestakeDelegatorImpl);

        address slasherImpl = address(
            new Slasher(
                address(vaultFactory),
                address(networkMiddlewareService),
                address(networkVaultOptInService),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(slasherFactory)
            )
        );
        slasherFactory.whitelist(slasherImpl);

        address vetoSlasherImpl = address(
            new VetoSlasher(
                address(vaultFactory),
                address(networkMiddlewareService),
                address(networkVaultOptInService),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(networkRegistry),
                address(slasherFactory)
            )
        );
        slasherFactory.whitelist(vetoSlasherImpl);

        Token token = new Token("Token");
        collateral = new SimpleCollateral(address(token));

        collateral.mint(token.totalSupply());

        vaultConfigurator =
            new VaultConfigurator(address(vaultFactory), address(delegatorFactory), address(slasherFactory));
    }

    function test_Create(uint48 epochDuration, uint48 vetoDuration, uint48 executeDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, type(uint48).max));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        slasher = _getSlasher(address(vault), vetoDuration, executeDuration);

        assertEq(slasher.VAULT_FACTORY(), address(vaultFactory));
        assertEq(slasher.NETWORK_MIDDLEWARE_SERVICE(), address(networkMiddlewareService));
        assertEq(slasher.NETWORK_VAULT_OPT_IN_SERVICE(), address(networkVaultOptInService));
        assertEq(slasher.OPERATOR_VAULT_OPT_IN_SERVICE(), address(operatorVaultOptInService));
        assertEq(slasher.OPERATOR_NETWORK_OPT_IN_SERVICE(), address(operatorNetworkOptInService));
        assertEq(slasher.vault(), address(vault));
        assertEq(slasher.SHARES_BASE(), 1e18);
        assertEq(slasher.NETWORK_REGISTRY(), address(networkRegistry));
        assertEq(slasher.vetoDuration(), vetoDuration);
        assertEq(slasher.executeDuration(), executeDuration);
        assertEq(slasher.slashRequestsLength(), 0);
        vm.expectRevert();
        slasher.slashRequests(0);
        assertEq(slasher.resolverSetEpochsDelay(), 3);
        assertEq(slasher.resolverSharesAt(address(this), address(this), 0), 0);
        assertEq(slasher.resolverShares(address(this), address(this)), 0);
        assertEq(slasher.hasVetoed(alice, 0), false);
    }

    function test_CreateRevertNotVault(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverSetEpochsDelay
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, type(uint48).max));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        resolverSetEpochsDelay = bound(resolverSetEpochsDelay, 3, type(uint256).max);
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault,) = _getVaultAndDelegator(epochDuration);

        vm.expectRevert(IBaseSlasher.NotVault.selector);
        slasherFactory.create(
            1,
            true,
            abi.encode(
                address(1),
                abi.encode(
                    IVetoSlasher.InitParams({
                        vetoDuration: vetoDuration,
                        executeDuration: executeDuration,
                        resolverSetEpochsDelay: resolverSetEpochsDelay
                    })
                )
            )
        );
    }

    function test_CreateRevertInvalidExecuteDuration(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint256 resolverSetEpochsDelay
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, type(uint48).max));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        uint48 executeDuration = 0;
        resolverSetEpochsDelay = bound(resolverSetEpochsDelay, 3, type(uint256).max);
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault,) = _getVaultAndDelegator(epochDuration);

        vm.expectRevert(IVetoSlasher.InvalidExecuteDuration.selector);
        slasherFactory.create(
            1,
            true,
            abi.encode(
                address(vault),
                abi.encode(
                    IVetoSlasher.InitParams({
                        vetoDuration: vetoDuration,
                        executeDuration: executeDuration,
                        resolverSetEpochsDelay: resolverSetEpochsDelay
                    })
                )
            )
        );
    }

    function test_CreateRevertInvalidSlashDuration(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverSetEpochsDelay
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, type(uint48).max));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        resolverSetEpochsDelay = bound(resolverSetEpochsDelay, 3, type(uint256).max);
        vm.assume(vetoDuration + executeDuration > epochDuration);

        (vault,) = _getVaultAndDelegator(epochDuration);

        vm.expectRevert(IVetoSlasher.InvalidSlashDuration.selector);
        slasherFactory.create(
            1,
            true,
            abi.encode(
                address(vault),
                abi.encode(
                    IVetoSlasher.InitParams({
                        vetoDuration: vetoDuration,
                        executeDuration: executeDuration,
                        resolverSetEpochsDelay: resolverSetEpochsDelay
                    })
                )
            )
        );
    }

    function test_CreateRevertInvalidResolverSetEpochsDelay(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverSetEpochsDelay
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, type(uint48).max));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        resolverSetEpochsDelay = bound(resolverSetEpochsDelay, 0, 2);
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault,) = _getVaultAndDelegator(epochDuration);

        vm.expectRevert(IVetoSlasher.InvalidResolverSetEpochsDelay.selector);
        slasherFactory.create(
            1,
            true,
            abi.encode(
                address(vault),
                abi.encode(
                    IVetoSlasher.InitParams({
                        vetoDuration: vetoDuration,
                        executeDuration: executeDuration,
                        resolverSetEpochsDelay: resolverSetEpochsDelay
                    })
                )
            )
        );
    }

    function test_RequestSlash(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 operatorNetworkLimit2,
        uint256 slashAmount1,
        uint256 slashAmount2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        operatorNetworkLimit2 = bound(operatorNetworkLimit2, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);
        slashAmount2 = bound(slashAmount2, 1, type(uint256).max);
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);
        _registerOperator(bob);

        _optInOperatorVault(alice);
        _optInOperatorVault(bob);

        _optInOperatorNetwork(alice, address(network));
        _optInOperatorNetwork(bob, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);
        _setNetworkLimit(alice, network, networkLimit - 1);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);
        _setOperatorNetworkLimit(alice, network, bob, operatorNetworkLimit2);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1 - 1);
        _setOperatorNetworkLimit(alice, network, bob, operatorNetworkLimit2 - 1);

        _optInNetworkVault(network);

        assertEq(0, _requestSlash(alice, network, alice, slashAmount1));

        (
            address network_,
            address operator_,
            uint256 amount_,
            uint48 vetoDeadline_,
            uint48 executeDeadline_,
            uint256 vetoedShares_,
            bool completed_
        ) = slasher.slashRequests(0);

        assertEq(network_, network);
        assertEq(operator_, alice);
        assertEq(amount_, slashAmount1);
        assertEq(vetoDeadline_, uint48(blockTimestamp + slasher.vetoDuration()));
        assertEq(executeDeadline_, uint48(blockTimestamp + slasher.vetoDuration() + slasher.executeDuration()));
        assertEq(vetoedShares_, 0);
        assertEq(completed_, false);

        assertEq(1, _requestSlash(alice, network, bob, slashAmount2));

        (network_, operator_, amount_, vetoDeadline_, executeDeadline_, vetoedShares_, completed_) =
            slasher.slashRequests(1);

        assertEq(network_, network);
        assertEq(operator_, bob);
        assertEq(amount_, slashAmount2);
        assertEq(vetoDeadline_, uint48(blockTimestamp + slasher.vetoDuration()));
        assertEq(executeDeadline_, uint48(blockTimestamp + slasher.vetoDuration() + slasher.executeDuration()));
        assertEq(vetoedShares_, 0);
        assertEq(completed_, false);
    }

    function test_RequestSlashRevertInsufficientSlash(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 operatorNetworkLimit2,
        uint256 slashAmount1,
        uint256 slashAmount2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        operatorNetworkLimit2 = bound(operatorNetworkLimit2, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);
        slashAmount2 = bound(slashAmount2, 1, type(uint256).max);
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);
        _registerOperator(bob);

        _optInOperatorVault(alice);
        _optInOperatorVault(bob);

        _optInOperatorNetwork(alice, address(network));
        _optInOperatorNetwork(bob, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);
        _setNetworkLimit(alice, network, networkLimit - 1);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);
        _setOperatorNetworkLimit(alice, network, bob, operatorNetworkLimit2);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1 - 1);
        _setOperatorNetworkLimit(alice, network, bob, operatorNetworkLimit2 - 1);

        _optInNetworkVault(network);

        vm.expectRevert(IVetoSlasher.InsufficientSlash.selector);
        _requestSlash(alice, network, alice, 0);
    }

    function test_setResolverSharesBoth(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverShares1,
        uint256 resolverShares2,
        uint256 resolverShares3
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());
        resolverShares3 = bound(resolverShares3, 1, slasher.SHARES_BASE());

        vm.assume(resolverShares3 <= resolverShares2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);

        _setResolverShares(network, alice, resolverShares1);

        assertEq(
            slasher.resolverSharesAt(network, alice, uint48(blockTimestamp + 2 * vault.epochDuration())),
            resolverShares1
        );
        assertEq(slasher.resolverShares(network, alice), resolverShares1);

        _setResolverShares(network, bob, resolverShares2);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        blockTimestamp = blockTimestamp + vault.epochDuration();
        vm.warp(blockTimestamp);

        assertEq(
            slasher.resolverSharesAt(network, alice, uint48(blockTimestamp + vault.epochDuration())), resolverShares1
        );
        assertEq(slasher.resolverShares(network, alice), resolverShares1);
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        _setResolverShares(network, bob, resolverShares3);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())), resolverShares3
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())), resolverShares2
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        blockTimestamp = blockTimestamp + vault.epochDuration();
        vm.warp(blockTimestamp);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())), resolverShares3
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())), resolverShares3
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        _setResolverShares(network, bob, resolverShares3 - 1);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())), resolverShares2
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        blockTimestamp = blockTimestamp + vault.epochDuration();
        vm.warp(blockTimestamp);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares2
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        blockTimestamp = blockTimestamp + vault.epochDuration();
        vm.warp(blockTimestamp);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares3 - 1
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares2);

        blockTimestamp = blockTimestamp + vault.epochDuration();
        vm.warp(blockTimestamp);

        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 3 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + 2 * vault.epochDuration())),
            resolverShares3 - 1
        );
        assertEq(
            slasher.resolverSharesAt(network, bob, uint48(blockTimestamp + vault.epochDuration())), resolverShares3 - 1
        );
        assertEq(slasher.resolverShares(network, bob), resolverShares3 - 1);
    }

    function test_setResolverSharesBothRevertNotOperator(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverShares1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());

        address network = alice;
        _registerNetwork(network, alice);

        vm.expectRevert(IVetoSlasher.NotNetwork.selector);
        _setResolverShares(bob, alice, resolverShares1);
    }

    function test_setResolverSharesBothRevertInvalidShares(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 resolverShares1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, slasher.SHARES_BASE() + 1, type(uint256).max);

        address network = alice;
        _registerNetwork(network, alice);

        vm.expectRevert(IVetoSlasher.InvalidShares.selector);
        _setResolverShares(network, alice, resolverShares1);
    }

    function test_ExecuteSlash(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        (
            address network_,
            address operator_,
            uint256 amount_,
            uint48 vetoDeadline_,
            uint48 executeDeadline_,
            uint256 vetoedShares_,
            bool completed_
        ) = slasher.slashRequests(0);

        assertEq(network_, network);
        assertEq(operator_, alice);
        assertEq(amount_, slashAmount1);
        assertEq(vetoDeadline_, uint48(blockTimestamp + slasher.vetoDuration()));
        assertEq(executeDeadline_, uint48(blockTimestamp + slasher.vetoDuration() + slasher.executeDuration()));
        assertEq(vetoedShares_, 0);
        assertEq(completed_, false);

        blockTimestamp = blockTimestamp + vetoDuration;
        vm.warp(blockTimestamp);

        assertEq(_executeSlash(alice, 0), slashAmount1);

        assertEq(vault.totalSupply(), depositAmount - slashAmount1);

        (network_, operator_, amount_, vetoDeadline_, executeDeadline_, vetoedShares_, completed_) =
            slasher.slashRequests(0);

        assertEq(network_, network);
        assertEq(operator_, alice);
        assertEq(amount_, slashAmount1);
        assertEq(vetoDeadline_, uint48(blockTimestamp));
        assertEq(executeDeadline_, uint48(blockTimestamp + slasher.executeDuration()));
        assertEq(vetoedShares_, 0);
        assertEq(completed_, true);
    }

    function test_ExecuteSlashRevertSlashRequestNotExist(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        blockTimestamp = blockTimestamp + vetoDuration;
        vm.warp(blockTimestamp);

        vm.expectRevert(IVetoSlasher.SlashRequestNotExist.selector);
        _executeSlash(alice, 1);
    }

    function test_ExecuteSlashRevertVetoPeriodNotEnded(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        vm.expectRevert(IVetoSlasher.VetoPeriodNotEnded.selector);
        _executeSlash(alice, 0);
    }

    function test_ExecuteSlashRevertSlashPeriodEnded(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        blockTimestamp = blockTimestamp + vetoDuration + executeDuration;
        vm.warp(blockTimestamp);

        vm.expectRevert(IVetoSlasher.SlashPeriodEnded.selector);
        _executeSlash(alice, 0);
    }

    function test_ExecuteSlashRevertSlashRequestCompleted(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 0, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        blockTimestamp = blockTimestamp + vetoDuration;
        vm.warp(blockTimestamp);

        _executeSlash(alice, 0);

        vm.expectRevert(IVetoSlasher.SlashRequestCompleted.selector);
        _executeSlash(alice, 0);
    }

    function test_VetoSlash(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, resolverShares1);
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        _vetoSlash(alice, 0);

        assertEq(slasher.hasVetoed(alice, 0), true);

        (,,,,, uint256 vetoedShares_, bool completed_) = slasher.slashRequests(0);

        assertEq(vetoedShares_, resolverShares1);
        assertEq(completed_, vetoedShares_ == slasher.SHARES_BASE());

        if (vetoedShares_ != slasher.SHARES_BASE()) {
            _vetoSlash(bob, 0);

            assertEq(slasher.hasVetoed(bob, 0), true);

            (,,,,, vetoedShares_, completed_) = slasher.slashRequests(0);

            assertEq(vetoedShares_, Math.min(resolverShares1 + resolverShares2, slasher.SHARES_BASE()));
            assertEq(completed_, vetoedShares_ == slasher.SHARES_BASE());
        }

        if (vetoedShares_ != slasher.SHARES_BASE()) {
            blockTimestamp = blockTimestamp + vetoDuration;
            vm.warp(blockTimestamp);

            assertEq(
                _executeSlash(alice, 0),
                (
                    slashAmount1
                        - slashAmount1.mulDiv(resolverShares1 + resolverShares2, slasher.SHARES_BASE(), Math.Rounding.Ceil)
                )
            );

            assertEq(
                vault.totalSupply(),
                depositAmount
                    - (
                        slashAmount1
                            - slashAmount1.mulDiv(resolverShares1 + resolverShares2, slasher.SHARES_BASE(), Math.Rounding.Ceil)
                    )
            );
        }
    }

    function test_VetoSlashRevertSlashRequestNotExist(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, resolverShares1);
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        vm.expectRevert(IVetoSlasher.SlashRequestNotExist.selector);
        _vetoSlash(alice, 1);
    }

    function test_VetoSlashRevertVetoPeriodEnded(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, resolverShares1);
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        blockTimestamp = blockTimestamp + vetoDuration;
        vm.warp(blockTimestamp);

        vm.expectRevert(IVetoSlasher.VetoPeriodEnded.selector);
        _vetoSlash(alice, 0);
    }

    function test_VetoSlashRevertNotResolver(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, resolverShares1);
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        vm.expectRevert(IVetoSlasher.NotResolver.selector);
        _vetoSlash(address(1), 0);
    }

    function test_VetoSlashRevertSlashRequestCompleted(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE());
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, slasher.SHARES_BASE());
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        _vetoSlash(alice, 0);

        vm.expectRevert(IVetoSlasher.SlashRequestCompleted.selector);
        _vetoSlash(bob, 0);
    }

    function test_VetoSlashRevertAlreadyVetoed(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration,
        uint256 depositAmount,
        uint256 networkLimit,
        uint256 operatorNetworkLimit1,
        uint256 slashAmount1,
        uint256 resolverShares1,
        uint256 resolverShares2
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        vetoDuration = uint48(bound(vetoDuration, 1, type(uint48).max / 2));
        executeDuration = uint48(bound(executeDuration, 1, type(uint48).max / 2));
        vm.assume(vetoDuration + executeDuration <= epochDuration);
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        networkLimit = bound(networkLimit, 1, type(uint256).max);
        operatorNetworkLimit1 = bound(operatorNetworkLimit1, 1, type(uint256).max / 2);
        slashAmount1 = bound(slashAmount1, 1, type(uint256).max);

        (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(epochDuration, vetoDuration, executeDuration);

        resolverShares1 = bound(resolverShares1, 1, slasher.SHARES_BASE() - 1);
        resolverShares2 = bound(resolverShares2, 1, slasher.SHARES_BASE());

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;

        address network = alice;
        _registerNetwork(network, alice);
        _setMaxNetworkLimit(network, type(uint256).max);

        _registerOperator(alice);

        _optInOperatorVault(alice);

        _optInOperatorNetwork(alice, address(network));

        _deposit(alice, depositAmount);

        _setNetworkLimit(alice, network, networkLimit);

        _setOperatorNetworkLimit(alice, network, alice, operatorNetworkLimit1);

        _optInNetworkVault(network);

        _setResolverShares(network, alice, resolverShares1);
        _setResolverShares(network, bob, resolverShares2);

        slashAmount1 = Math.min(slashAmount1, Math.min(depositAmount, Math.min(networkLimit, operatorNetworkLimit1)));

        _requestSlash(alice, network, alice, slashAmount1);

        _vetoSlash(alice, 0);

        vm.expectRevert(IVetoSlasher.AlreadyVetoed.selector);
        _vetoSlash(alice, 0);
    }

    function _getVaultAndDelegator(uint48 epochDuration) internal returns (Vault, FullRestakeDelegator) {
        (address vault_, address delegator_,) = vaultConfigurator.create(
            IVaultConfigurator.InitParams({
                version: vaultFactory.lastVersion(),
                owner: alice,
                vaultParams: IVault.InitParams({
                    collateral: address(collateral),
                    delegator: address(0),
                    slasher: address(0),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    slasherSetEpochsDelay: 3,
                    depositWhitelist: false,
                    defaultAdminRoleHolder: alice,
                    slasherSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice
                }),
                delegatorIndex: 0,
                delegatorParams: abi.encode(
                    INetworkRestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({defaultAdminRoleHolder: alice}),
                        networkLimitSetRoleHolder: alice,
                        operatorNetworkSharesSetRoleHolder: alice
                    })
                ),
                withSlasher: false,
                slasherIndex: 0,
                slasherParams: ""
            })
        );

        return (Vault(vault_), FullRestakeDelegator(delegator_));
    }

    function _getVaultAndDelegatorAndSlasher(
        uint48 epochDuration,
        uint48 vetoDuration,
        uint48 executeDuration
    ) internal returns (Vault, FullRestakeDelegator, VetoSlasher) {
        (address vault_, address delegator_, address slasher_) = vaultConfigurator.create(
            IVaultConfigurator.InitParams({
                version: vaultFactory.lastVersion(),
                owner: alice,
                vaultParams: IVault.InitParams({
                    collateral: address(collateral),
                    delegator: address(0),
                    slasher: address(0),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    slasherSetEpochsDelay: 3,
                    depositWhitelist: false,
                    defaultAdminRoleHolder: alice,
                    slasherSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice
                }),
                delegatorIndex: 1,
                delegatorParams: abi.encode(
                    IFullRestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({defaultAdminRoleHolder: alice}),
                        networkLimitSetRoleHolder: alice,
                        operatorNetworkLimitSetRoleHolder: alice
                    })
                ),
                withSlasher: true,
                slasherIndex: 1,
                slasherParams: abi.encode(
                    IVetoSlasher.InitParams({
                        vetoDuration: vetoDuration,
                        executeDuration: executeDuration,
                        resolverSetEpochsDelay: 3
                    })
                )
            })
        );

        return (Vault(vault_), FullRestakeDelegator(delegator_), VetoSlasher(slasher_));
    }

    function _getSlasher(address vault_, uint48 vetoDuration, uint48 executeDuration) internal returns (VetoSlasher) {
        return VetoSlasher(
            slasherFactory.create(
                1,
                true,
                abi.encode(
                    vault_,
                    abi.encode(
                        IVetoSlasher.InitParams({
                            vetoDuration: vetoDuration,
                            executeDuration: executeDuration,
                            resolverSetEpochsDelay: 3
                        })
                    )
                )
            )
        );
    }

    function _registerOperator(address user) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator();
        vm.stopPrank();
    }

    function _registerNetwork(address user, address middleware) internal {
        vm.startPrank(user);
        networkRegistry.registerNetwork();
        networkMiddlewareService.setMiddleware(middleware);
        vm.stopPrank();
    }

    function _grantDepositorWhitelistRole(address user, address account) internal {
        vm.startPrank(user);
        Vault(address(vault)).grantRole(vault.DEPOSITOR_WHITELIST_ROLE(), account);
        vm.stopPrank();
    }

    function _grantDepositWhitelistSetRole(address user, address account) internal {
        vm.startPrank(user);
        Vault(address(vault)).grantRole(vault.DEPOSIT_WHITELIST_SET_ROLE(), account);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        collateral.transfer(user, amount);
        vm.startPrank(user);
        collateral.approve(address(vault), amount);
        shares = vault.deposit(user, amount);
        vm.stopPrank();
    }

    function _withdraw(address user, uint256 amount) internal returns (uint256 burnedShares, uint256 mintedShares) {
        vm.startPrank(user);
        (burnedShares, mintedShares) = vault.withdraw(user, amount);
        vm.stopPrank();
    }

    function _claim(address user, uint256 epoch) internal returns (uint256 amount) {
        vm.startPrank(user);
        amount = vault.claim(user, epoch);
        vm.stopPrank();
    }

    function _optInNetworkVault(address user) internal {
        vm.startPrank(user);
        networkVaultOptInService.optIn(address(vault));
        vm.stopPrank();
    }

    function _optOutNetworkVault(address user) internal {
        vm.startPrank(user);
        networkVaultOptInService.optOut(address(vault));
        vm.stopPrank();
    }

    function _optInOperatorVault(address user) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optIn(address(vault));
        vm.stopPrank();
    }

    function _optOutOperatorVault(address user) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optOut(address(vault));
        vm.stopPrank();
    }

    function _optInOperatorNetwork(address user, address network) internal {
        vm.startPrank(user);
        operatorNetworkOptInService.optIn(network);
        vm.stopPrank();
    }

    function _optOutOperatorNetwork(address user, address network) internal {
        vm.startPrank(user);
        operatorNetworkOptInService.optOut(network);
        vm.stopPrank();
    }

    function _setDepositWhitelist(address user, bool depositWhitelist) internal {
        vm.startPrank(user);
        vault.setDepositWhitelist(depositWhitelist);
        vm.stopPrank();
    }

    function _setDepositorWhitelistStatus(address user, address depositor, bool status) internal {
        vm.startPrank(user);
        vault.setDepositorWhitelistStatus(depositor, status);
        vm.stopPrank();
    }

    function _setSlasher(address user, address slasher_) internal {
        vm.startPrank(user);
        vault.setSlasher(slasher_);
        vm.stopPrank();
    }

    function _requestSlash(
        address user,
        address network,
        address operator,
        uint256 amount
    ) internal returns (uint256 slashIndex) {
        vm.startPrank(user);
        slashIndex = slasher.requestSlash(network, operator, amount);
        vm.stopPrank();
    }

    function _executeSlash(address user, uint256 slashIndex) internal returns (uint256 slashAmount) {
        vm.startPrank(user);
        slashAmount = slasher.executeSlash(slashIndex);
        vm.stopPrank();
    }

    function _vetoSlash(address user, uint256 slashIndex) internal {
        vm.startPrank(user);
        slasher.vetoSlash(slashIndex);
        vm.stopPrank();
    }

    function _setResolverShares(address user, address resolver, uint256 shares) internal {
        vm.startPrank(user);
        slasher.setResolverShares(resolver, shares);
        vm.stopPrank();
    }

    function _setNetworkLimit(address user, address network, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setNetworkLimit(network, amount);
        vm.stopPrank();
    }

    function _setOperatorNetworkLimit(address user, address network, address operator, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setOperatorNetworkLimit(network, operator, amount);
        vm.stopPrank();
    }

    function _setMaxNetworkLimit(address user, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setMaxNetworkLimit(amount);
        vm.stopPrank();
    }
}