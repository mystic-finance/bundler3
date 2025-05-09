// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC4626} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IWNative} from "./IWNative.sol";
import {IMysticV3 as IPool} from "./IMysticV3.sol";
import {IFlashLoanReceiver} from "./IFlashLoanReceiver.sol";

/**
 * @title IMysticAdapter
 * @notice Interface for the Mystic adapter contract
 * @dev Defines the functions available in the Mystic adapter
 */
interface IMysticAdapter is IFlashLoanReceiver {
    /* CONSTANTS */
    
    /// @dev Interest rate mode: 1 for stable, 2 for variable
    function INTEREST_RATE_MODE_STABLE() external view returns (uint256);
    function INTEREST_RATE_MODE_VARIABLE() external view returns (uint256);
    
    /// @dev Referral code (0 for no referral)
    function REFERRAL_CODE() external view returns (uint16);

    /* IMMUTABLES */

    /// @notice The address of the Mystic V3 Pool contract.
    function AAVE_POOL() external view returns (IPool);

    /// @dev The address of the wrapped native token.
    function WRAPPED_NATIVE() external view returns (IWNative);

    /* ERC4626 ACTIONS */

    /// @notice Mints shares of an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to mint.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Mint(address vault, uint256 shares, uint256 maxSharePriceE27, address receiver) external;

    /// @notice Deposits underlying token in an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to deposit. Pass `type(uint).max` to deposit the adapter's balance.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver) external;

    /// @notice Withdraws underlying token from an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to withdraw.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the assets are withdrawn. Can only be the adapter or the initiator.
    function erc4626Withdraw(address vault, uint256 assets, uint256 minSharePriceE27, address receiver, address owner) external;

    /// @notice Redeems shares of an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to redeem. Pass `type(uint).max` to redeem the owner's shares.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the shares are redeemed. Can only be the adapter or the initiator.
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner) external;

    /* AAVE ACTIONS */

    /// @notice Supplies assets to the Mystic protocol.
    /// @dev Assets must have been previously sent to the adapter.
    /// @param asset The address of the asset to supply.
    /// @param amount The amount of the asset to supply. Pass `type(uint).max` to supply the adapter's balance.
    /// @param onBehalf The address that will own the increased supply position.
    /// @param useAsCollateral Whether to set this asset as collateral.
    function mysticSupply(address asset, uint256 amount, address onBehalf, bool useAsCollateral) external;

    /// @notice Withdraws assets from the Mystic protocol.
    /// @dev Initiator must have previously authorized the adapter to act on their behalf on Mystic.
    /// @param asset The address of the asset to withdraw.
    /// @param amount The amount of the asset to withdraw. Pass `type(uint).max` to withdraw the entire balance.
    /// @param receiver The address that will receive the withdrawn assets.
    function mysticWithdraw(address asset, uint256 amount, address onBehalf, address receiver) external;

    /// @notice Borrows assets from the Mystic protocol.
    /// @dev Initiator must have sufficient collateral in the Mystic protocol.
    /// @param asset The address of the asset to borrow.
    /// @param amount The amount of the asset to borrow.
    /// @param interestRateMode The interest rate mode (1 for stable, 2 for variable).
    /// @param receiver The address that will receive the borrowed assets.
    function mysticBorrow(address asset, uint256 amount, uint256 interestRateMode, address from, address receiver) external;

    /// @notice Repays a debt on the Mystic protocol.
    /// @dev Assets must have been previously sent to the adapter.
    /// @param asset The address of the asset to repay.
    /// @param amount The amount of the asset to repay. Pass `type(uint).max` to repay the adapter's asset balance.
    /// @param interestRateMode The interest rate mode (1 for stable, 2 for variable).
    /// @param onBehalf The address of the owner of the debt position.
    function mysticRepay(address asset, uint256 amount, uint256 interestRateMode, address onBehalf) external;

    /// @notice Set an asset to be used as collateral or not.
    /// @dev Initiator must have previously authorized the adapter to act on their behalf on Mystic.
    /// @param asset The address of the asset.
    /// @param useAsCollateral Whether to use the asset as collateral.
    function mysticSetUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    /// @notice Triggers a flash loan on Mystic.
    /// @param assets The addresses of the assets to flash loan.
    /// @param amounts The amounts of the assets to flash loan.
    /// @param interestRateModes The interest rate modes to use if debt is opened.
    /// @param data Arbitrary data to pass to the flash loan callback.
    function mysticFlashLoan(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        bytes calldata data
    ) external;

    /* PERMIT2 ACTIONS */

    /// @notice Transfers with Permit2.
    /// @param token The address of the ERC20 token to transfer.
    /// @param receiver The address that will receive the tokens.
    /// @param amount The amount of token to transfer. Pass `type(uint).max` to transfer the initiator's balance.
    function permit2TransferFrom(address token, address receiver, uint256 amount) external;

    /* TRANSFER ACTIONS */

    /// @notice Transfers ERC20 tokens from the initiator.
    /// @notice Initiator must have given sufficient allowance to the Adapter to spend their tokens
    function erc20TransferFrom(address token, address from, address receiver, uint256 amount) external;

    function erc20Transfer(address token, address receiver, uint256 amount) external;
    

    /* WRAPPED NATIVE TOKEN ACTIONS */

    /// @notice Wraps native tokens to wNative.
    /// @dev Native tokens must have been previously sent to the adapter.
    /// @param amount The amount of native token to wrap. Pass `type(uint).max` to wrap the adapter's balance.
    /// @param receiver The account receiving the wrapped native tokens.
    function wrapNative(uint256 amount, address receiver) external;

    /// @notice Unwraps wNative tokens to the native token.
    /// @dev Wrapped native tokens must have been previously sent to the adapter.
    /// @param amount The amount of wrapped native token to unwrap. Pass `type(uint).max` to unwrap the adapter's balance.
    /// @param receiver The account receiving the native tokens.
    function unwrapNative(uint256 amount, address receiver) external;

    function flashLoanFee(uint256 amount) external view returns (uint256);

    function getAvailableLiquidity(address asset) external view returns (uint256);

    function getWithdrawableLiquidity(address user, address asset) external view returns(uint256);

    function getBorrowableLiquidity(address user, address asset) external view returns (uint256);

    function getMainUserAccountData(address user) external view returns (uint256, uint256, uint256, uint256, uint256);

    function getAssetLtv(address asset) external view returns (uint256);

    function getAssetPrice(address asset) external view returns (uint256);
} 