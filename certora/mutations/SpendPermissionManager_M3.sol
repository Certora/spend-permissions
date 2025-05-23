// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MagicSpend} from "magicspend/MagicSpend.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {IERC165} from "openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC165Checker} from "openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {CoinbaseSmartWallet} from "smart-wallet/CoinbaseSmartWallet.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {PublicERC6492Validator} from "./PublicERC6492Validator.sol";

/// @title SpendPermissionManager
///
/// @notice Allow spending native and ERC-20 tokens from a `CoinbaseSmartWallet` with a spend permission.
///
/// @dev Allowance and spend values capped at uint160 (~1e48).
/// @dev Supports ERC-6492 signatures (https://eips.ethereum.org/EIPS/eip-6492).
///
/// @author Coinbase (https://github.com/coinbase/spend-permissions)
contract SpendPermissionManager is EIP712 {
    using SafeERC20 for IERC20;

    /// @notice A spend permission for an external entity to be able to spend an account's tokens.
    struct SpendPermission {
        /// @dev Smart account this spend permission is valid for.
        address account;
        /// @dev Entity that can spend `account`'s tokens.
        address spender;
        /// @dev Token address (ERC-7528 native token or ERC-20 contract).
        address token;
        /// @dev Maximum allowed value to spend within each `period`.
        uint160 allowance;
        /// @dev Time duration for resetting used `allowance` on a recurring basis (seconds).
        uint48 period;
        /// @dev Timestamp this spend permission is valid starting at (inclusive, unix seconds).
        uint48 start;
        /// @dev Timestamp this spend permission is valid until (exclusive, unix seconds).
        uint48 end;
        /// @dev Arbitrary data to differentiate unique spend permissions with otherwise identical fields.
        uint256 salt;
        /// @dev Arbitrary data to attach to a spend permission which may be consumed by the `spender`.
        bytes extraData;
    }

    /// @notice A batch of spend permissions for an external entity to be able to spend an account's tokens.
    ///
    /// @dev A batch of permissions all share the same `account`, `period`, `start`, and `end` fields.
    /// @dev A batch can be approved with a single signature.
    struct SpendPermissionBatch {
        /// @dev Smart account this spend permission is valid for.
        address account;
        /// @dev Time duration for resetting used `allowance` on a recurring basis (seconds).
        uint48 period;
        /// @dev Timestamp this spend permission is valid starting at (inclusive, unix seconds).
        uint48 start;
        /// @dev Timestamp this spend permission is valid until (exclusive, unix seconds).
        uint48 end;
        /// @dev Array of `PermissionDetails` structs defining fields that apply per-permission.
        PermissionDetails[] permissions;
    }

    /// @notice Fields that apply per-permission within a spend permission batch.
    struct PermissionDetails {
        /// @dev Entity that can spend `account`'s tokens.
        address spender;
        /// @dev Token address (ERC-7528 native token or ERC-20 contract).
        address token;
        /// @dev Maximum allowed value to spend within each `period`.
        uint160 allowance;
        /// @dev Arbitrary data to differentiate unique spend permissions with otherwise identical fields.
        uint256 salt;
        /// @dev Arbitrary data to attach to a spend permission which may be consumed by the `spender`.
        bytes extraData;
    }

    /// @notice Period parameters and spend usage.
    struct PeriodSpend {
        /// @dev Timstamp this period starts at (inclusive, unix seconds).
        uint48 start;
        /// @dev Timestamp this period ends before (exclusive, unix seconds).
        uint48 end;
        /// @dev Accumulated spend amount for the period.
        uint160 spend;
    }

    /// @notice EIP-712 hash of SpendPermission type.
    bytes32 public constant SPEND_PERMISSION_TYPEHASH = keccak256(
        "SpendPermission(address account,address spender,address token,uint160 allowance,uint48 period,uint48 start,uint48 end,uint256 salt,bytes extraData)"
    );

    /// @notice EIP-712 hash of SpendPermissionBatch type.
    bytes32 public constant SPEND_PERMISSION_BATCH_TYPEHASH = keccak256(
        "SpendPermissionBatch(address account,uint48 period,uint48 start,uint48 end,PermissionDetails[] permissions)PermissionDetails(address spender,address token,uint160 allowance,uint256 salt,bytes extraData)"
    );

    /// @notice EIP-712 hash of PermissionDetails type.
    bytes32 public constant PERMISSION_DETAILS_TYPEHASH =
        keccak256("PermissionDetails(address spender,address token,uint160 allowance,uint256 salt,bytes extraData)");

    /// @notice ERC-7528 native token address convention (https://eips.ethereum.org/EIPS/eip-7528).
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Separated contract for validating signatures and executing ERC-6492 side effects.
    PublicERC6492Validator public immutable PUBLIC_ERC6492_VALIDATOR;

    /// @notice MagicSpend singleton (https://github.com/coinbase/magicspend).
    address public immutable MAGIC_SPEND;

    /// @notice Spend permission is approved.
    mapping(bytes32 hash => bool approved) internal _isApproved;

    /// @notice Spend permission is revoked.
    mapping(bytes32 hash => bool revoked) internal _isRevoked;

    /// @notice Last updated period for a spend permission.
    mapping(bytes32 hash => PeriodSpend) internal _lastUpdatedPeriod;

    /// @notice A flag to indicate if the contract can receive native token transfers, and the expected amount.
    ///
    /// @dev Contract can only receive exactly the expected amount during the execution of `spend` for native tokens.
    uint256 transient private _expectedReceiveAmount;

    /// @notice Spend permission was approved.
    ///
    /// @param hash Unique hash representing the spend permission.
    /// @param spendPermission Details of the spend permission.
    event SpendPermissionApproved(bytes32 indexed hash, SpendPermission spendPermission);

    /// @notice Spend permission was revoked.
    ///
    /// @param hash Unique hash representing the spend permission.
    /// @param spendPermission Details of the spend permission.
    event SpendPermissionRevoked(bytes32 indexed hash, SpendPermission spendPermission);

    /// @notice Spend permission was used.
    ///
    /// @param hash Unique hash representing the spend permission.
    /// @param account Account that had its tokens spent via the spend permission.
    /// @param spender Entity that spent `account`'s tokens.
    /// @param token Address of token spent via the spend permission.
    /// @param periodSpend Start and end of the current period with the new incremental spend (struct).
    event SpendPermissionUsed(
        bytes32 indexed hash, address indexed account, address indexed spender, address token, PeriodSpend periodSpend
    );

    /// @notice Invalid sender for the external call.
    ///
    /// @param sender Expected sender to be valid.
    error InvalidSender(address sender, address expected);

    /// @notice Token is an ERC-721, which is not supported to prevent NFT transfers
    ///
    /// @param token Address of the ERC-721 token contract.
    error ERC721TokenNotSupported(address token);

    /// @notice Invalid signature.
    error InvalidSignature();

    /// @notice Last updated period is different from the expected last updated period.
    error InvalidLastUpdatedPeriod(PeriodSpend actualLastUpdatedPeriod, PeriodSpend expectedLastUpdatedPeriod);

    /// @notice Mismatched accounts for atomically approving and revoking a pair of spend permissions.
    ///
    /// @param firstAccount Account of the first spend permission.
    /// @param secondAccount Account of the second spend permission.
    error MismatchedAccounts(address firstAccount, address secondAccount);

    /// @notice Spend permission batch is empty.
    error EmptySpendPermissionBatch();

    /// @notice Spend permission has zero token address.
    error ZeroToken();

    /// @notice Spend permission has zero spender address.
    error ZeroSpender();

    /// @notice Spend permission has zero allowance.
    error ZeroAllowance();

    /// @notice Spend permission has zero period.
    error ZeroPeriod();

    /// @notice Spend permission start time is not strictly less than end time.
    ///
    /// @param start Timestamp for start of the permission (unix seconds).
    /// @param end Timestamp for end of the permission (unix seconds).
    error InvalidStartEnd(uint48 start, uint48 end);

    /// @notice Attempting to spend zero value.
    error ZeroValue();

    /// @notice Unauthorized spend permission.
    error UnauthorizedSpendPermission();

    /// @notice Spend permission has not started yet.
    ///
    /// @param currentTimestamp Current timestamp (unix seconds).
    /// @param start Timestamp this spend permission is valid starting at (inclusive, unix seconds).
    error BeforeSpendPermissionStart(uint48 currentTimestamp, uint48 start);

    /// @notice Spend permission has already ended.
    ///
    /// @param currentTimestamp Current timestamp (unix seconds).
    /// @param end Timestamp this spend permission is valid until (exclusive, unix seconds).
    error AfterSpendPermissionEnd(uint48 currentTimestamp, uint48 end);

    /// @notice Spend value exceeds max size of uint160.
    ///
    /// @param value Spend value that triggered overflow.
    error SpendValueOverflow(uint256 value);

    /// @notice Spend value exceeds spend permission allowance.
    ///
    /// @param value Spend value that exceeded allowance.
    /// @param allowance Allowance value that was exceeded.
    error ExceededSpendPermission(uint256 value, uint256 allowance);

    /// @notice `SpendPermission.token` and `WithdrawRequest.asset` are not equal.
    ///
    /// @param spendToken Token belonging to the spend permission.
    /// @param withdrawAsset Asset belonging to the withdraw request.
    error SpendTokenWithdrawAssetMismatch(address spendToken, address withdrawAsset);

    /// @notice Attempted spend value is less than the `WithdrawRequest.amount`.
    ///
    /// @param spendValue Value attempting to spend, must not be less than withdraw amount.
    /// @param withdrawAmount Amount of asset attempting to withdraw from MagicSpend.
    error SpendValueWithdrawAmountMismatch(uint256 spendValue, uint256 withdrawAmount);

    /// @notice `WithdrawRequest.nonce` is not postfixed with the lower 128 bits of the spend permission hash.
    ///
    /// @param noncePostfix The lower 128 bits of the withdraw request nonce.
    /// @param permissionHashPostfix The lower 128 bits of the spend permission hash.
    error InvalidWithdrawRequestNonce(uint128 noncePostfix, uint128 permissionHashPostfix);

    /// @notice Contract received an unexpected amount of native token.
    error UnexpectedReceiveAmount(uint256 received, uint256 expected);

    /// @notice Require a specific sender for an external call.
    /// @param sender Expected sender for call to be valid.
    modifier requireSender(address sender) {
        if (msg.sender != sender) revert InvalidSender(msg.sender, sender);
        _;
    }

    /// @notice Deploy SpendPermissionManager and set immutable dependency contracts.
    ///
    /// @param publicERC6492Validator PublicERC6492Validator contract.
    /// @param magicSpend Address of the MagicSpend contract.
    constructor(PublicERC6492Validator publicERC6492Validator, address magicSpend) {
        PUBLIC_ERC6492_VALIDATOR = publicERC6492Validator;
        MAGIC_SPEND = magicSpend;
    }

    /// @notice Allow the contract to receive native token transfers.
    ///
    /// @dev Can only be called during execution of `spend` for native tokens.
    /// @dev Reverts if the received amount is not equal to the expected amount.
    /// @dev Note that a user could succeed in sending multiples of the expected amount during the execution of
    ///      `execute`, but this would require intentional desire from the user to lose funds.
    receive() external payable {
        if (msg.value != _expectedReceiveAmount) revert UnexpectedReceiveAmount(msg.value, _expectedReceiveAmount);
    }

    /// @notice Approve a spend permission via a direct call from the account.
    ///
    /// @dev Can only be called by the account of a spend permission.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return approved True if spend permission is approved and not revoked.
    function approve(SpendPermission calldata spendPermission)
        external
        requireSender(spendPermission.account)
        returns (bool)
    {
        return _approve(spendPermission);
    }

    /// @notice Approve a spend permission via a signature from the account.
    ///
    /// @dev Compatible with ERC-6492 signatures including side effects.
    ///
    /// @param spendPermission Details of the spend permission.
    /// @param signature Signed approval from the user.
    ///
    /// @return approved True if spend permission is approved and not revoked.
    function approveWithSignature(SpendPermission calldata spendPermission, bytes calldata signature)
        external
        returns (bool)
    {
        // validate signature over spend permission data, deploying or preparing account if necessary
        if (
            !PUBLIC_ERC6492_VALIDATOR.isValidSignatureNowAllowSideEffects(
                spendPermission.account, getHash(spendPermission), signature
            )
        ) {
            revert InvalidSignature();
        }
        return _approve(spendPermission);
    }

    /// @notice Approve a spend permission batch via a signature from the account.
    ///
    /// @dev Compatible with ERC-6492 signatures including side effects.
    /// @dev Does not enforce uniqueness of permissions within a batch, allowing duplicate idempotent approvals.
    ///
    /// @param spendPermissionBatch Details of the spend permission batch.
    /// @param signature Signed approval from the user.
    ///
    /// @return allApproved True if all spend permissions in the batch are approved and not revoked.
    function approveBatchWithSignature(SpendPermissionBatch memory spendPermissionBatch, bytes calldata signature)
        external
        returns (bool)
    {
        // validate signature over spend permission batch data
        if (
            !PUBLIC_ERC6492_VALIDATOR.isValidSignatureNowAllowSideEffects(
                spendPermissionBatch.account, getBatchHash(spendPermissionBatch), signature
            )
        ) {
            revert InvalidSignature();
        }

        // loop through each spend permission in the batch and approve it
        bool allApproved = true;
        uint256 batchLen = spendPermissionBatch.permissions.length;
        for (uint256 i; i < batchLen; i++) {
            // approve each spend permission in the batch, surfacing if any return false (are already revoked)
            if (
                !_approve(
                    SpendPermission({
                        account: spendPermissionBatch.account,
                        spender: spendPermissionBatch.permissions[i].spender,
                        token: spendPermissionBatch.permissions[i].token,
                        allowance: spendPermissionBatch.permissions[i].allowance,
                        period: spendPermissionBatch.period,
                        start: spendPermissionBatch.start,
                        end: spendPermissionBatch.end,
                        salt: spendPermissionBatch.permissions[i].salt,
                        extraData: spendPermissionBatch.permissions[i].extraData
                    })
                )
            ) {
                allApproved = false;
            }
        }
        return allApproved;
    }

    /// @notice Approve a spend permission while revoking another if its last updated period matches an expected value.
    ///
    /// @dev Comparing the revoked spend permission's last updated period mitigates frontrunning with further spend.
    /// @dev The accounts of the spend permissions must match, but all other fields can differ.
    /// @dev Reverts if not called by the account of the spend permissions.
    ///
    /// @param permissionToApprove Details of the spend permission to approve.
    /// @param permissionToRevoke Details of the spend permission to revoke.
    /// @param expectedLastUpdatedPeriod Expected last updated period for the spend permission being revoked.
    ///
    /// @return approved True if new spend permission is approved and not revoked.
    function approveWithRevoke(
        SpendPermission calldata permissionToApprove,
        SpendPermission calldata permissionToRevoke,
        PeriodSpend calldata expectedLastUpdatedPeriod
    ) external requireSender(permissionToApprove.account) returns (bool) {
        // require both spend permissions apply to the same account
        if (permissionToApprove.account != permissionToRevoke.account) {
            revert MismatchedAccounts(permissionToApprove.account, permissionToRevoke.account);
        }

        // validate that no spending has occurred since the expected last updated period
        PeriodSpend memory lastUpdatedPeriod = getLastUpdatedPeriod(permissionToRevoke);
        if (
            lastUpdatedPeriod.spend != expectedLastUpdatedPeriod.spend
                || lastUpdatedPeriod.start != expectedLastUpdatedPeriod.start
                || lastUpdatedPeriod.end != expectedLastUpdatedPeriod.end
        ) {
            revert InvalidLastUpdatedPeriod(lastUpdatedPeriod, expectedLastUpdatedPeriod);
        }

        // revoke old and approve new spend permissions
        _revoke(permissionToRevoke);
        return _approve(permissionToApprove);
    }

    /// @notice Revoke a spend permission to disable its use indefinitely.
    ///
    /// @dev Reverts if not called by the account of the spend permission.
    ///
    /// @param spendPermission Details of the spend permission.
    function revoke(SpendPermission calldata spendPermission) external requireSender(spendPermission.account) {
        _revoke(spendPermission);
    }

    /// @notice Revoke a spend permission to disable its use indefinitely.
    ///
    /// @dev Reverts if not called by the spender of the spend permission.
    ///
    /// @param spendPermission Details of the spend permission.
    function revokeAsSpender(SpendPermission calldata spendPermission)
        external
        requireSender(spendPermission.spender)
    {
        _revoke(spendPermission);
    }

    /// @notice Spend tokens using a spend permission, transferring them from `account` to `spender`.
    ///
    /// @dev Reverts if not called by the spender of the spend permission.
    /// @dev Reverts if using spend permission or completing token transfer fail.
    ///
    /// @param spendPermission Details of the spend permission.
    /// @param value Amount of token attempting to spend.
    function spend(SpendPermission memory spendPermission, uint160 value)
        external
        requireSender(spendPermission.spender)
    {
        _useSpendPermission(spendPermission, value);
        _transferFrom(spendPermission.token, spendPermission.account, spendPermission.spender, value);
    }

    /// @notice Spend tokens using a spend permission and atomically call MagicSpend to fund the account.
    ///
    /// @dev Reverts if not called by the spender of the spend permission.
    /// @dev Reverts if using spend permission, withdrawing from MagicSpend, or completing token transfer fail.
    /// @dev Requires withdraw signature from MagicSpend owner.
    ///
    /// @param spendPermission Details of the spend permission.
    /// @param value Amount of token attempting to spend.
    /// @param withdrawRequest Request to withdraw tokens from MagicSpend into the account.
    function spendWithWithdraw(
        SpendPermission memory spendPermission,
        uint160 value,
        MagicSpend.WithdrawRequest memory withdrawRequest
    ) external requireSender(spendPermission.spender) {
        // check spend token and withdraw asset are the same
        if (
            !(spendPermission.token == NATIVE_TOKEN && withdrawRequest.asset == address(0))
                && spendPermission.token != withdrawRequest.asset
        ) {
            revert SpendTokenWithdrawAssetMismatch(spendPermission.token, withdrawRequest.asset);
        }

        // check spend value is not less than withdraw request amount
        if (withdrawRequest.amount > value) {
            revert SpendValueWithdrawAmountMismatch(value, withdrawRequest.amount);
        }

        // check withdraw request nonce postfix matches spend permission hash postfix.
        bytes32 permissionHash = getHash(spendPermission);
        if (uint128(withdrawRequest.nonce) != uint128(uint256(permissionHash))) {
            revert InvalidWithdrawRequestNonce(uint128(withdrawRequest.nonce), uint128(uint256(permissionHash)));
        }

        _useSpendPermission(spendPermission, value);
        // mutation - forget to call _execute
        /*
        _execute({
            account: spendPermission.account,
            target: MAGIC_SPEND,
            value: 0,
            data: abi.encodeWithSelector(MagicSpend.withdraw.selector, withdrawRequest)
        });
        */
        _transferFrom(spendPermission.token, spendPermission.account, spendPermission.spender, value);
    }

    /// @notice Get if a spend permission is approved.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return approved True if spend permission is approved.
    function isApproved(SpendPermission memory spendPermission) public view returns (bool) {
        return _isApproved[getHash(spendPermission)];
    }

    /// @notice Get if a spend permission is revoked.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return revoked True if spend permission is revoked.
    function isRevoked(SpendPermission memory spendPermission) public view returns (bool) {
        return _isRevoked[getHash(spendPermission)];
    }

    /// @notice Get if spend permission is approved and not revoked.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return valid True if spend permission is approved and not revoked.
    function isValid(SpendPermission memory spendPermission) public view returns (bool) {
        bytes32 hash = getHash(spendPermission);
        return !_isRevoked[hash] && _isApproved[hash];
    }

    /// @notice Get last updated period for a spend permission.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return lastUpdatedPeriod Last updated period for the spend permission.
    function getLastUpdatedPeriod(SpendPermission memory spendPermission) public view returns (PeriodSpend memory) {
        return _lastUpdatedPeriod[getHash(spendPermission)];
    }

    /// @notice Get start, end, and spend of the current period.
    ///
    /// @dev Reverts if spend permission has not started or has already ended.
    /// @dev Period boundaries are at fixed intervals of [start + n * period, min(end, start + (n + 1) * period) - 1]
    ///
    /// @param spendPermission Details of the spend permission
    ///
    /// @return currentPeriod Currently active period with cumulative spend (struct)
    function getCurrentPeriod(SpendPermission memory spendPermission) public view returns (PeriodSpend memory) {
        // check current timestamp is within spend permission time range
        uint48 currentTimestamp = uint48(block.timestamp);
        if (currentTimestamp < spendPermission.start) {
            revert BeforeSpendPermissionStart(currentTimestamp, spendPermission.start);
        } else if (currentTimestamp >= spendPermission.end) {
            revert AfterSpendPermissionEnd(currentTimestamp, spendPermission.end);
        }

        PeriodSpend memory lastUpdatedPeriod = _lastUpdatedPeriod[getHash(spendPermission)];

        // last period exists if spend is non-zero
        bool lastPeriodExists = lastUpdatedPeriod.spend != 0;

        // last period still active if current timestamp within [start, end - 1] range.
        bool lastPeriodStillActive = currentTimestamp < lastUpdatedPeriod.end;

        // return last period if exists and still active, otherwise compute new period with no spend
        if (lastPeriodExists && lastPeriodStillActive) {
            return lastUpdatedPeriod;
        } else {
            // last active period does not exist or is outdated, determine current period

            // current period progress is remainder of time since first recurring period mod reset period
            uint48 currentPeriodProgress = (currentTimestamp - spendPermission.start) % spendPermission.period;

            // current period start is progress duration before current time
            uint48 start = currentTimestamp - currentPeriodProgress;

            // current period end will overflow if period is sufficiently large
            bool endOverflow = uint256(start) + uint256(spendPermission.period) > spendPermission.end;

            // end is one period after start or spend permission's end if overflow
            uint48 end = endOverflow ? spendPermission.end : start + spendPermission.period;

            return PeriodSpend({start: start, end: end, spend: 0});
        }
    }

    /// @notice Hash a SpendPermission struct for signing in accordance with EIP-712
    ///         (https://eips.ethereum.org/EIPS/eip-712).
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return hash Hash of the spend permission.
    function getHash(SpendPermission memory spendPermission) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    SPEND_PERMISSION_TYPEHASH,
                    spendPermission.account,
                    spendPermission.spender,
                    spendPermission.token,
                    spendPermission.allowance,
                    spendPermission.period,
                    spendPermission.start,
                    spendPermission.end,
                    spendPermission.salt,
                    keccak256(spendPermission.extraData)
                )
            )
        );
    }

    /// @notice Hash a SpendPermissionBatch struct for signing in accordance with EIP-712
    ///         (https://eips.ethereum.org/EIPS/eip-712).
    ///
    /// @dev Reverts if the batch is empty.
    ///
    /// @param spendPermissionBatch Details of the spend permission batch.
    ///
    /// @return hash Hash of the spend permission batch.
    function getBatchHash(SpendPermissionBatch memory spendPermissionBatch) public view returns (bytes32) {
        // check batch is non-empty
        uint256 permissionDetailsLen = spendPermissionBatch.permissions.length;
        if (permissionDetailsLen == 0) revert EmptySpendPermissionBatch();

        // loop over permission details to aggregate inner struct hashes
        bytes32[] memory permissionDetailsHashes = new bytes32[](permissionDetailsLen);
        for (uint256 i; i < permissionDetailsLen; i++) {
            permissionDetailsHashes[i] = keccak256(
                abi.encode(
                    PERMISSION_DETAILS_TYPEHASH,
                    spendPermissionBatch.permissions[i].spender,
                    spendPermissionBatch.permissions[i].token,
                    spendPermissionBatch.permissions[i].allowance,
                    spendPermissionBatch.permissions[i].salt,
                    keccak256(spendPermissionBatch.permissions[i].extraData)
                )
            );
        }

        return _hashTypedData(
            keccak256(
                abi.encode(
                    SPEND_PERMISSION_BATCH_TYPEHASH,
                    spendPermissionBatch.account,
                    spendPermissionBatch.period,
                    spendPermissionBatch.start,
                    spendPermissionBatch.end,
                    keccak256(abi.encodePacked(permissionDetailsHashes))
                )
            )
        );
    }

    /// @notice Approve a spend permission.
    ///
    /// @dev Early returns false if permission is revoked, stopping unusable approval.
    /// @dev Only emits approval event once on first approval.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return approved True if spend permission is approved and not revoked.
    function _approve(SpendPermission memory spendPermission) internal returns (bool) {
        // check token is non-zero
        if (spendPermission.token == address(0)) revert ZeroToken();

        // check token is not an ERC-721
        if (spendPermission.token != NATIVE_TOKEN) {
            if (ERC165Checker.supportsInterface(spendPermission.token, type(IERC721).interfaceId)) {
                revert ERC721TokenNotSupported(spendPermission.token);
            }
        }

        // check spender is non-zero
        if (spendPermission.spender == address(0)) revert ZeroSpender();

        // check period non-zero
        if (spendPermission.period == 0) revert ZeroPeriod();

        // check allowance non-zero
        if (spendPermission.allowance == 0) revert ZeroAllowance();

        // check start is strictly before end
        if (spendPermission.start >= spendPermission.end) {
            revert InvalidStartEnd(spendPermission.start, spendPermission.end);
        }

        bytes32 hash = getHash(spendPermission);

        // return false early if spend permission is already revoked
        if (_isRevoked[hash]) return false;

        // return early if spend permission is already approved
        if (_isApproved[hash]) return true;

        _isApproved[hash] = true;
        emit SpendPermissionApproved(hash, spendPermission);
        return true;
    }

    /// @notice Revoke a spend permission.
    ///
    /// @dev Only emits revoked event once on first revocation.
    ///
    /// @param spendPermission Details of the spend permission.
    ///
    /// @return revoked True if spend permission is revoked.
    function _revoke(SpendPermission memory spendPermission) internal returns (bool) {
        bytes32 hash = getHash(spendPermission);

        // return early if spend permission is already revoked
        if (_isRevoked[hash]) return true;

        _isRevoked[hash] = true;
        emit SpendPermissionRevoked(hash, spendPermission);
        return true;
    }

    /// @notice Use a spend permission.
    ///
    /// @param spendPermission Details of the spend permission.
    /// @param value Amount of token attempting to spend (wei).
    function _useSpendPermission(SpendPermission memory spendPermission, uint256 value) internal {
        // check value is non-zero
        if (value == 0) revert ZeroValue();

        // check spend permission is approved and not revoked
        if (!isValid(spendPermission)) revert UnauthorizedSpendPermission();

        PeriodSpend memory currentPeriod = getCurrentPeriod(spendPermission);
        uint256 totalSpend = value + uint256(currentPeriod.spend);

        // check total spend value does not overflow max value
        if (totalSpend > type(uint160).max) revert SpendValueOverflow(totalSpend);

        // check total spend value does not exceed spend permission
        if (totalSpend > spendPermission.allowance) {
            revert ExceededSpendPermission(totalSpend, spendPermission.allowance);
        }

        bytes32 hash = getHash(spendPermission);

        // update total spend for current period and emit event for incremental spend
        currentPeriod.spend = uint160(totalSpend);
        _lastUpdatedPeriod[hash] = currentPeriod;
        emit SpendPermissionUsed(
            hash,
            spendPermission.account,
            spendPermission.spender,
            spendPermission.token,
            PeriodSpend(currentPeriod.start, currentPeriod.end, uint160(value))
        );
    }

    /// @notice Transfer assets from an account to a recipient.
    ///
    /// @dev Reverts if token transfer fail.
    ///
    /// @param token Address of token (ERC-7528 native token or ERC-20 contract).
    /// @param account Address to transfer from.
    /// @param recipient Address to transfer to.
    /// @param value Amount to transfer.
    function _transferFrom(address token, address account, address recipient, uint256 value) internal {
        if (token == NATIVE_TOKEN) {
            // set flag to allow contract to receive expected amount of native token
            _expectedReceiveAmount = value;

            // call account to send native token to this contract
            _execute({account: account, target: address(this), value: value, data: hex""});
            _expectedReceiveAmount = 0;

            // forward native token to recipient, which will revert if funds are not actually available
            SafeTransferLib.safeTransferETH(payable(recipient), value);
        } else {
            // set allowance for this contract to spend exact value on behalf of account
            _execute({
                account: account,
                target: token,
                value: 0,
                data: abi.encodeWithSelector(IERC20.approve.selector, address(this), value)
            });

            // use allowance to transfer from account to recipient, which will revert if transfer fails
            IERC20(token).safeTransferFrom(account, recipient, value);
        }
    }

    /// @notice Execute a single call on an account.
    ///
    /// @dev Assumes this contract has authority to execute calls on the account.
    /// @dev Function made virtual to encourage overrides for other account implementations.
    ///
    /// @param account Address of the account.
    /// @param target Address of the target.
    /// @param value Amount of native token to send.
    /// @param data Arbitrary data to send.
    function _execute(address account, address target, uint256 value, bytes memory data) internal virtual {
        CoinbaseSmartWallet(payable(account)).execute({target: target, value: value, data: data});
    }

    /// @notice Get EIP-712 domain name and version.
    ///
    /// @return name Name string for the EIP-712 domain.
    /// @return version Version string for the EIP-712 domain.
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Spend Permission Manager";
        version = "1";
    }
}
