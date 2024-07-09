// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {MigratableEntity} from "src/contracts/common/MigratableEntity.sol";
import {VaultStorage} from "./VaultStorage.sol";

import {IRegistry} from "src/interfaces/common/IRegistry.sol";
import {ICollateral} from "src/interfaces/collateral/ICollateral.sol";
import {IVault} from "src/interfaces/vault/IVault.sol";

import {Checkpoints} from "src/contracts/libraries/Checkpoints.sol";
import {ERC4626Math} from "src/contracts/libraries/ERC4626Math.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract Vault is VaultStorage, MigratableEntity, AccessControlUpgradeable, IVault {
    using Checkpoints for Checkpoints.Trace256;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /**
     * @inheritdoc IVault
     */
    function slasherIn(uint48 duration) public view returns (address) {
        if (_nextSlasher.timestamp == 0 || Time.timestamp() + duration < _nextSlasher.timestamp) {
            return _slasher.address_;
        }
        return _nextSlasher.address_;
    }

    /**
     * @inheritdoc IVault
     */
    function slasher() public view returns (address) {
        return slasherIn(0);
    }

    /**
     * @inheritdoc IVault
     */
    function totalSupplyIn(uint48 duration) public view returns (uint256) {
        uint256 epoch = currentEpoch();
        uint256 futureEpoch = epochAt(Time.timestamp() + duration);

        if (futureEpoch > epoch + 1) {
            return activeSupply();
        }

        if (futureEpoch > epoch) {
            return activeSupply() + withdrawals[futureEpoch];
        }

        return activeSupply() + withdrawals[epoch] + withdrawals[epoch + 1];
    }

    /**
     * @inheritdoc IVault
     */
    function totalSupply() public view returns (uint256) {
        uint256 epoch = currentEpoch();
        return activeSupply() + withdrawals[epoch] + withdrawals[epoch + 1];
    }

    /**
     * @inheritdoc IVault
     */
    function activeBalanceOfAt(address account, uint48 timestamp) public view returns (uint256) {
        return ERC4626Math.previewRedeem(
            activeSharesOfAt(account, timestamp), activeSupplyAt(timestamp), activeSharesAt(timestamp)
        );
    }

    /**
     * @inheritdoc IVault
     */
    function activeBalanceOf(address account) public view returns (uint256) {
        return ERC4626Math.previewRedeem(activeSharesOf(account), activeSupply(), activeShares());
    }

    /**
     * @inheritdoc IVault
     */
    function withdrawalsOf(uint256 epoch, address account) public view returns (uint256) {
        return
            ERC4626Math.previewRedeem(withdrawalSharesOf[epoch][account], withdrawals[epoch], withdrawalShares[epoch]);
    }

    constructor(
        address delegatorFactory,
        address slasherFactory,
        address vaultFactory
    ) VaultStorage(delegatorFactory, slasherFactory) MigratableEntity(vaultFactory) {}

    /**
     * @inheritdoc IVault
     */
    function deposit(address onBehalfOf, uint256 amount) external returns (uint256 shares) {
        if (onBehalfOf == address(0)) {
            revert InvalidOnBehalfOf();
        }

        if (depositWhitelist && !isDepositorWhitelisted[msg.sender]) {
            revert NotWhitelistedDepositor();
        }

        if (amount == 0) {
            revert InsufficientDeposit();
        }

        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);

        uint256 activeSupply_ = activeSupply();
        uint256 activeShares_ = activeShares();

        shares = ERC4626Math.previewDeposit(amount, activeShares_, activeSupply_);

        _activeSupplies.push(Time.timestamp(), activeSupply_ + amount);
        _activeShares.push(Time.timestamp(), activeShares_ + shares);
        _activeSharesOf[onBehalfOf].push(Time.timestamp(), activeSharesOf(onBehalfOf) + shares);

        emit Deposit(msg.sender, onBehalfOf, amount, shares);
    }

    /**
     * @inheritdoc IVault
     */
    function withdraw(address claimer, uint256 amount) external returns (uint256 burnedShares, uint256 mintedShares) {
        if (claimer == address(0)) {
            revert InvalidClaimer();
        }

        if (amount == 0) {
            revert InsufficientWithdrawal();
        }

        uint256 activeSupply_ = activeSupply();
        uint256 activeShares_ = activeShares();
        uint256 activeSharesOf_ = activeSharesOf(msg.sender);

        burnedShares = ERC4626Math.previewWithdraw(amount, activeShares_, activeSupply_);
        if (burnedShares > activeSharesOf_) {
            revert TooMuchWithdraw();
        }

        _activeSupplies.push(Time.timestamp(), activeSupply_ - amount);
        _activeShares.push(Time.timestamp(), activeShares_ - burnedShares);
        _activeSharesOf[msg.sender].push(Time.timestamp(), activeSharesOf_ - burnedShares);

        uint256 epoch = currentEpoch() + 1;
        uint256 withdrawals_ = withdrawals[epoch];
        uint256 withdrawalsShares_ = withdrawalShares[epoch];

        mintedShares = ERC4626Math.previewDeposit(amount, withdrawalsShares_, withdrawals_);

        withdrawals[epoch] = withdrawals_ + amount;
        withdrawalShares[epoch] = withdrawalsShares_ + mintedShares;
        withdrawalSharesOf[epoch][claimer] += mintedShares;

        emit Withdraw(msg.sender, claimer, amount, burnedShares, mintedShares);
    }

    /**
     * @inheritdoc IVault
     */
    function claim(address recipient, uint256 epoch) external returns (uint256 amount) {
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        if (epoch >= currentEpoch()) {
            revert InvalidEpoch();
        }

        if (isWithdrawalsClaimed[epoch][msg.sender]) {
            revert AlreadyClaimed();
        }

        amount = withdrawalsOf(epoch, msg.sender);

        if (amount == 0) {
            revert InsufficientClaim();
        }

        isWithdrawalsClaimed[epoch][msg.sender] = true;

        IERC20(collateral).safeTransfer(recipient, amount);

        emit Claim(msg.sender, recipient, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function onSlash(uint256 slashedAmount, uint48 captureTimestamp) external {
        if (msg.sender != slasher()) {
            revert NotSlasher();
        }

        uint256 currentEpoch_ = currentEpoch();
        uint256 captureEpoch = epochAt(captureTimestamp);
        if ((currentEpoch_ != 0 && captureEpoch < currentEpoch_ - 1) || captureEpoch > currentEpoch_) {
            revert InvalidCaptureEpoch();
        }

        uint256 activeSupply_ = activeSupply();
        uint256 nextWithdrawals = withdrawals[currentEpoch_ + 1];
        if (captureEpoch == currentEpoch_) {
            uint256 slashableSupply = activeSupply_ + nextWithdrawals;
            slashedAmount = Math.min(slashedAmount, slashableSupply);
            if (slashedAmount > 0) {
                uint256 activeSlashed = slashedAmount.mulDiv(activeSupply_, slashableSupply);
                uint256 nextWithdrawalsSlashed = slashedAmount - activeSlashed;

                _activeSupplies.push(Time.timestamp(), activeSupply_ - activeSlashed);
                withdrawals[captureEpoch + 1] = nextWithdrawals - nextWithdrawalsSlashed;
            }
        } else {
            uint256 withdrawals_ = withdrawals[currentEpoch_];
            uint256 slashableSupply = activeSupply_ + withdrawals_ + nextWithdrawals;
            slashedAmount = Math.min(slashedAmount, slashableSupply);
            if (slashedAmount > 0) {
                uint256 activeSlashed = slashedAmount.mulDiv(activeSupply_, slashableSupply);
                uint256 nextWithdrawalsSlashed = slashedAmount.mulDiv(nextWithdrawals, slashableSupply);
                uint256 withdrawalsSlashed = slashedAmount - activeSlashed - nextWithdrawalsSlashed;

                if (withdrawals_ < withdrawalsSlashed) {
                    nextWithdrawalsSlashed += withdrawalsSlashed - withdrawals_;
                    withdrawalsSlashed = withdrawals_;
                }

                _activeSupplies.push(Time.timestamp(), activeSupply_ - activeSlashed);
                withdrawals[currentEpoch_ + 1] = nextWithdrawals - nextWithdrawalsSlashed;
                withdrawals[currentEpoch_] = withdrawals_ - withdrawalsSlashed;
            }
        }

        if (slashedAmount > 0) {
            ICollateral(collateral).issueDebt(burner, slashedAmount);
        }

        emit OnSlash(msg.sender, slashedAmount);
    }

    /**
     * @inheritdoc IVault
     */
    function setSlasher(address slasher_) external onlyRole(SLASHER_SET_ROLE) {
        if (slasher_ != address(0) && !IRegistry(SLASHER_FACTORY).isEntity(slasher_)) {
            revert NotSlasher();
        }

        if (_nextSlasher.timestamp > 0 && _nextSlasher.timestamp <= Time.timestamp()) {
            _slasher.address_ = _nextSlasher.address_;
            _nextSlasher.timestamp = 0;
            _nextSlasher.address_ = address(0);
        }

        _nextSlasher.address_ = slasher_;
        _nextSlasher.timestamp = (currentEpochStart() + slasherSetEpochsDelay * epochDuration).toUint48();

        emit SetSlasher(slasher_);
    }

    /**
     * @inheritdoc IVault
     */
    function setDepositWhitelist(bool status) external onlyRole(DEPOSIT_WHITELIST_SET_ROLE) {
        if (depositWhitelist == status) {
            revert AlreadySet();
        }

        depositWhitelist = status;

        emit SetDepositWhitelist(status);
    }

    /**
     * @inheritdoc IVault
     */
    function setDepositorWhitelistStatus(address account, bool status) external onlyRole(DEPOSITOR_WHITELIST_ROLE) {
        if (account == address(0)) {
            revert InvalidAccount();
        }

        if (isDepositorWhitelisted[account] == status) {
            revert AlreadySet();
        }

        if (status && !depositWhitelist) {
            revert NoDepositWhitelist();
        }

        isDepositorWhitelisted[account] = status;

        emit SetDepositorWhitelistStatus(account, status);
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        (IVault.InitParams memory params) = abi.decode(data, (IVault.InitParams));

        if (params.collateral == address(0)) {
            revert InvalidCollateral();
        }

        if (params.slasherSetEpochsDelay < 3) {
            revert InvalidSlasherSetEpochsDelay();
        }

        if (params.epochDuration == 0) {
            revert InvalidEpochDuration();
        }

        if (!IRegistry(DELEGATOR_FACTORY).isEntity(params.delegator)) {
            revert NotDelegator();
        }

        if (params.slasher != address(0) && !IRegistry(SLASHER_FACTORY).isEntity(params.slasher)) {
            revert NotSlasher();
        }

        collateral = params.collateral;

        delegator = params.delegator;

        burner = params.burner;

        epochDurationInit = Time.timestamp();
        epochDuration = params.epochDuration;

        slasherSetEpochsDelay = params.slasherSetEpochsDelay;

        if (params.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        }

        if (params.slasher == address(0)) {
            if (params.slasherSetRoleHolder != address(0)) {
                _grantRole(SLASHER_SET_ROLE, params.slasherSetRoleHolder);
            }
        } else {
            _slasher.address_ = params.slasher;
        }

        if (params.depositWhitelist) {
            depositWhitelist = true;

            if (params.depositorWhitelistRoleHolder != address(0)) {
                _grantRole(DEPOSITOR_WHITELIST_ROLE, params.depositorWhitelistRoleHolder);
            }
        }
    }

    function _migrate(uint64, bytes memory) internal override {
        revert();
    }
}
