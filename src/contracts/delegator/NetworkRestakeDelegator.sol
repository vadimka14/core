// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {BaseDelegator} from "./BaseDelegator.sol";

import {INetworkRestakeDelegator} from "src/interfaces/delegator/INetworkRestakeDelegator.sol";
import {IBaseDelegator} from "src/interfaces/delegator/IBaseDelegator.sol";
import {IVault} from "src/interfaces/vault/IVault.sol";
import {INetworkRestakeDelegatorHook} from "src/interfaces/delegator/hook/INetworkRestakeDelegatorHook.sol";

import {Checkpoints} from "src/contracts/libraries/Checkpoints.sol";

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract NetworkRestakeDelegator is BaseDelegator, INetworkRestakeDelegator {
    using Checkpoints for Checkpoints.Trace256;
    using Math for uint256;

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    bytes32 public constant NETWORK_LIMIT_SET_ROLE = keccak256("NETWORK_LIMIT_SET_ROLE");

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    bytes32 public constant OPERATOR_NETWORK_SHARES_SET_ROLE = keccak256("OPERATOR_NETWORK_SHARES_SET_ROLE");

    mapping(address network => Checkpoints.Trace256 value) private _networkLimit;

    mapping(address network => Checkpoints.Trace256 shares) private _totalOperatorNetworkShares;

    mapping(address network => mapping(address operator => Checkpoints.Trace256 shares)) private _operatorNetworkShares;

    constructor(
        address networkRegistry,
        address vaultFactory,
        address operatorVaultOptInService,
        address operatorNetworkOptInService,
        address delegatorFactory
    )
        BaseDelegator(
            networkRegistry,
            vaultFactory,
            operatorVaultOptInService,
            operatorNetworkOptInService,
            delegatorFactory
        )
    {}

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function networkLimitAt(address network, uint48 timestamp) public view returns (uint256) {
        return _networkLimit[network].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function networkLimit(address network) public view returns (uint256) {
        return _networkLimit[network].latest();
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function totalOperatorNetworkSharesAt(address network, uint48 timestamp) public view returns (uint256) {
        return _totalOperatorNetworkShares[network].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function totalOperatorNetworkShares(address network) public view returns (uint256) {
        return _totalOperatorNetworkShares[network].latest();
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function operatorNetworkSharesAt(
        address network,
        address operator,
        uint48 timestamp
    ) public view returns (uint256) {
        return _operatorNetworkShares[network][operator].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function operatorNetworkShares(address network, address operator) public view returns (uint256) {
        return _operatorNetworkShares[network][operator].latest();
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function networkSlashableStakeIn(
        address network,
        uint48 duration
    ) public view override(IBaseDelegator, BaseDelegator) returns (uint256) {
        if (totalOperatorNetworkSharesAt(network, Time.timestamp() + duration) == 0) {
            return 0;
        }
        return Math.min(IVault(vault).totalSupplyIn(duration), networkLimitAt(network, Time.timestamp() + duration));
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function networkSlashableStake(address network)
        public
        view
        override(IBaseDelegator, BaseDelegator)
        returns (uint256)
    {
        if (totalOperatorNetworkShares(network) == 0) {
            return 0;
        }
        return Math.min(IVault(vault).totalSupply(), networkLimit(network));
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function operatorNetworkSlashableStakeIn(
        address network,
        address operator,
        uint48 duration
    ) public view override(IBaseDelegator, BaseDelegator) returns (uint256) {
        uint256 totalOperatorNetworkSharesIn_ = totalOperatorNetworkSharesAt(network, Time.timestamp() + duration);
        if (totalOperatorNetworkSharesIn_ == 0) {
            return 0;
        }
        return operatorNetworkSharesAt(network, operator, Time.timestamp() + duration).mulDiv(
            networkSlashableStakeIn(network, duration), totalOperatorNetworkSharesIn_
        );
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function operatorNetworkSlashableStake(
        address network,
        address operator
    ) public view override(IBaseDelegator, BaseDelegator) returns (uint256) {
        uint256 totalOperatorNetworkShares_ = totalOperatorNetworkShares(network);
        if (totalOperatorNetworkShares_ == 0) {
            return 0;
        }
        return
            operatorNetworkShares(network, operator).mulDiv(networkSlashableStake(network), totalOperatorNetworkShares_);
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function setNetworkLimit(address network, uint256 amount) external onlyRole(NETWORK_LIMIT_SET_ROLE) {
        if (amount > maxNetworkLimit[network]) {
            revert ExceedsMaxNetworkLimit();
        }

        _setNetworkLimit(network, amount);

        emit SetNetworkLimit(network, amount);
    }

    /**
     * @inheritdoc INetworkRestakeDelegator
     */
    function setOperatorNetworkShares(
        address network,
        address operator,
        uint256 shares
    ) external onlyRole(OPERATOR_NETWORK_SHARES_SET_ROLE) {
        _setOperatorNetworkShares(network, operator, shares);

        emit SetOperatorNetworkShares(network, operator, shares);
    }

    function _setNetworkLimit(address network, uint256 amount) internal {
        _networkLimit[network].push(Time.timestamp(), amount);
    }

    function _setOperatorNetworkShares(address network, address operator, uint256 shares) internal {
        _totalOperatorNetworkShares[network].push(
            Time.timestamp(), totalOperatorNetworkShares(network) - operatorNetworkShares(network, operator) + shares
        );
        _operatorNetworkShares[network][operator].push(Time.timestamp(), shares);
    }

    function _operatorNetworkStakeAt(
        address network,
        address operator,
        uint48 timestamp
    ) internal view override returns (uint256) {
        uint256 totalOperatorNetworkSharesAt_ = totalOperatorNetworkSharesAt(network, timestamp);
        return totalOperatorNetworkSharesAt_ == 0
            ? 0
            : operatorNetworkSharesAt(network, operator, timestamp).mulDiv(
                Math.min(IVault(vault).activeSupplyAt(timestamp), networkLimitAt(network, timestamp)),
                totalOperatorNetworkSharesAt_
            );
    }

    function _operatorNetworkStake(address network, address operator) internal view override returns (uint256) {
        uint256 totalOperatorNetworkShares_ = totalOperatorNetworkShares(network);
        return totalOperatorNetworkShares_ == 0
            ? 0
            : operatorNetworkShares(network, operator).mulDiv(
                Math.min(IVault(vault).activeSupply(), networkLimit(network)), totalOperatorNetworkShares_
            );
    }

    function _setMaxNetworkLimit(uint256 amount) internal override {
        (bool exists,, uint256 latestValue) = _networkLimit[msg.sender].latestCheckpoint();
        if (exists) {
            _networkLimit[msg.sender].push(Time.timestamp(), Math.min(latestValue, amount));
        }
    }

    function _onSlash(
        address network,
        address operator,
        uint256 slashedAmount,
        uint48 captureTimestamp
    ) internal override {
        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call{gas: 200_000}(
                abi.encodeWithSelector(
                    INetworkRestakeDelegatorHook.onSlash.selector, network, operator, slashedAmount, captureTimestamp
                )
            );
            if (success && returndata.length == 64) {
                (uint256 networkLimit_, uint256 operatorNetworkShares_) = abi.decode(returndata, (uint256, uint256));
                _setNetworkLimit(network, networkLimit_);
                _setOperatorNetworkShares(network, operator, operatorNetworkShares_);
            }
        }
    }

    function _initializeInternal(
        address,
        bytes memory data
    ) internal override returns (IBaseDelegator.BaseParams memory) {
        InitParams memory params = abi.decode(data, (InitParams));

        if (
            params.baseParams.defaultAdminRoleHolder == address(0)
                && (
                    params.networkLimitSetRoleHolder == address(0)
                        || params.operatorNetworkSharesSetRoleHolder == address(0)
                )
        ) {
            revert MissingRoleHolders();
        }

        if (params.networkLimitSetRoleHolder != address(0)) {
            _grantRole(NETWORK_LIMIT_SET_ROLE, params.networkLimitSetRoleHolder);
        }
        if (params.operatorNetworkSharesSetRoleHolder != address(0)) {
            _grantRole(OPERATOR_NETWORK_SHARES_SET_ROLE, params.operatorNetworkSharesSetRoleHolder);
        }

        return params.baseParams;
    }
}
