import {IDefaultLimiter} from "src/interfaces/defaultLimiter/IDefaultLimiter.sol";
import {ILimiter} from "src/interfaces/ILimiter.sol";
import {IRegistry} from "src/interfaces/base/IRegistry.sol";
import {IVault} from "src/interfaces/vault/v1/IVault.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract DefaultLimiter is Initializable, IDefaultLimiter, AccessControlUpgradeable {
    /**
     * @inheritdoc IDefaultLimiter
     */
    address public immutable NETWORK_REGISTRY;

    /**
     * @inheritdoc IDefaultLimiter
     */
    address public immutable VAULT_FACTORY;

    /**
     * @inheritdoc IDefaultLimiter
     */
    bytes32 public constant NETWORK_RESOLVER_LIMIT_SET_ROLE = keccak256("NETWORK_RESOLVER_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IDefaultLimiter
     */
    bytes32 public constant OPERATOR_NETWORK_LIMIT_SET_ROLE = keccak256("OPERATOR_NETWORK_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IDefaultLimiter
     */
    mapping(address vault => mapping(address network => mapping(address resolver => uint256 amount))) public
        maxNetworkResolverLimit;

    /**
     * @inheritdoc IDefaultLimiter
     */
    mapping(address vault => mapping(address network => mapping(address resolver => DelayedLimit))) public
        nextNetworkResolverLimit;

    /**
     * @inheritdoc IDefaultLimiter
     */
    mapping(address vault => mapping(address operator => mapping(address network => DelayedLimit))) public
        nextOperatorNetworkLimit;

    mapping(address vault => mapping(address network => mapping(address resolver => Limit limit))) internal
        _networkResolverLimit;

    mapping(address vault => mapping(address operator => mapping(address network => Limit limit))) internal
        _operatorNetworkLimit;

    modifier onlyStakingController(address vault) {
        if (IVault(vault).stakingController() != msg.sender) {
            revert NotStakingController();
        }
        _;
    }

    constructor(address networkRegistry, address vaultFactory) {
        NETWORK_REGISTRY = networkRegistry;
        VAULT_FACTORY = vaultFactory;
    }

    /**
     * @inheritdoc ILimiter
     */
    function networkResolverLimitIn(
        address vault,
        address network,
        address resolver,
        uint48 duration
    ) public view returns (uint256) {
        return _getLimitAt(
            _networkResolverLimit[vault][network][resolver],
            nextNetworkResolverLimit[vault][network][resolver],
            Time.timestamp() + duration
        );
    }

    /**
     * @inheritdoc ILimiter
     */
    function networkResolverLimit(address vault, address network, address resolver) public view returns (uint256) {
        return networkResolverLimitIn(vault, network, resolver, 0);
    }

    /**
     * @inheritdoc ILimiter
     */
    function operatorNetworkLimitIn(
        address vault,
        address operator,
        address network,
        uint48 duration
    ) public view returns (uint256) {
        return _getLimitAt(
            _operatorNetworkLimit[vault][operator][network],
            nextOperatorNetworkLimit[vault][operator][network],
            Time.timestamp() + duration
        );
    }

    /**
     * @inheritdoc ILimiter
     */
    function operatorNetworkLimit(address vault, address operator, address network) public view returns (uint256) {
        return operatorNetworkLimitIn(vault, operator, network, 0);
    }

    function initialize(address networkResolverLimiter, address operatorNetworkLimiter) external initializer {
        _grantRole(NETWORK_RESOLVER_LIMIT_SET_ROLE, networkResolverLimiter);
        _grantRole(OPERATOR_NETWORK_LIMIT_SET_ROLE, operatorNetworkLimiter);
    }

    /**
     * @inheritdoc IDefaultLimiter
     */
    function setMaxNetworkResolverLimit(address vault, address resolver, uint256 amount) external {
        if (maxNetworkResolverLimit[vault][msg.sender][resolver] == amount) {
            revert AlreadySet();
        }

        if (!IRegistry(NETWORK_REGISTRY).isEntity(msg.sender)) {
            revert NotNetwork();
        }

        maxNetworkResolverLimit[vault][msg.sender][resolver] = amount;

        Limit storage limit = _networkResolverLimit[vault][msg.sender][resolver];
        DelayedLimit storage nextLimit = nextNetworkResolverLimit[vault][msg.sender][resolver];

        _updateLimit(limit, nextLimit);

        if (limit.amount > amount) {
            limit.amount = amount;
        }
        if (nextLimit.amount > amount) {
            nextLimit.amount = amount;
        }

        emit SetMaxNetworkResolverLimit(vault, msg.sender, resolver, amount);
    }

    /**
     * @inheritdoc IDefaultLimiter
     */
    function setNetworkResolverLimit(
        address vault,
        address network,
        address resolver,
        uint256 amount
    ) external onlyRole(NETWORK_RESOLVER_LIMIT_SET_ROLE) {
        if (amount > maxNetworkResolverLimit[vault][network][resolver]) {
            revert ExceedsMaxNetworkResolverLimit();
        }

        Limit storage limit = _networkResolverLimit[vault][network][resolver];
        DelayedLimit storage nextLimit = nextNetworkResolverLimit[vault][network][resolver];

        _setLimit(limit, nextLimit, vault, amount);

        emit SetNetworkResolverLimit(vault, network, resolver, amount);
    }

    /**
     * @inheritdoc IDefaultLimiter
     */
    function setOperatorNetworkLimit(
        address vault,
        address operator,
        address network,
        uint256 amount
    ) external onlyRole(OPERATOR_NETWORK_LIMIT_SET_ROLE) {
        Limit storage limit = _operatorNetworkLimit[vault][operator][network];
        DelayedLimit storage nextLimit = nextOperatorNetworkLimit[vault][operator][network];

        _setLimit(limit, nextLimit, vault, amount);

        emit SetOperatorNetworkLimit(vault, operator, network, amount);
    }

    /**
     * @inheritdoc ILimiter
     */
    function onSlash(
        address vault,
        address network,
        address resolver,
        address operator,
        uint256 slashedAmount
    ) external onlyStakingController(vault) {
        uint256 networkResolverLimit_ = networkResolverLimit(vault, network, resolver);
        uint256 operatorNetworkLimit_ = operatorNetworkLimit(vault, operator, network);

        _updateLimit(
            _networkResolverLimit[vault][network][resolver], nextNetworkResolverLimit[vault][network][resolver]
        );
        _updateLimit(
            _operatorNetworkLimit[vault][operator][network], nextOperatorNetworkLimit[vault][operator][network]
        );

        if (networkResolverLimit_ != type(uint256).max) {
            _networkResolverLimit[vault][network][resolver].amount = networkResolverLimit_ - slashedAmount;
        }
        if (operatorNetworkLimit_ != type(uint256).max) {
            _operatorNetworkLimit[vault][operator][network].amount = operatorNetworkLimit_ - slashedAmount;
        }
    }

    function _getLimitAt(
        Limit storage limit,
        DelayedLimit storage nextLimit,
        uint48 timestamp
    ) private view returns (uint256) {
        if (nextLimit.timestamp == 0 || timestamp < nextLimit.timestamp) {
            return limit.amount;
        }
        return nextLimit.amount;
    }

    function _setLimit(Limit storage limit, DelayedLimit storage nextLimit, address vault, uint256 amount) private {
        _updateLimit(limit, nextLimit);

        if (amount < limit.amount) {
            nextLimit.amount = amount;
            nextLimit.timestamp = IVault(vault).currentEpochStart() + 2 * IVault(vault).epochDuration();
        } else {
            limit.amount = amount;
            nextLimit.amount = 0;
            nextLimit.timestamp = 0;
        }
    }

    function _updateLimit(Limit storage limit, DelayedLimit storage nextLimit) internal {
        if (nextLimit.timestamp != 0 && nextLimit.timestamp <= Time.timestamp()) {
            limit.amount = nextLimit.amount;
            nextLimit.timestamp = 0;
            nextLimit.amount = 0;
        }
    }
}