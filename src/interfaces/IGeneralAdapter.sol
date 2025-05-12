// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IWNative} from "../interfaces/IWNative.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IGeneralAdapter1
 * @notice Interface for the GeneralAdapter1 contract which provides utility functions for interacting with various protocols
 */
interface IGeneralAdapter1 {
    /* VIEW FUNCTIONS */
    
    /// @notice The address of the Morpho contract
    function MORPHO() external view returns (IMorpho);
    
    /// @notice The address of the wrapped native token
    function WRAPPED_NATIVE() external view returns (IWNative);
    
    /// @notice Returns the address of the initiator of the current transaction
    function initiator() external view returns (address);

    /* ERC4626 ACTIONS */

    /// @notice Mints shares of an ERC4626 vault
    function erc4626Mint(address vault, uint256 shares, uint256 maxSharePriceE27, address receiver) external;

    /// @notice Deposits underlying token in an ERC4626 vault
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver) external;

    /// @notice Withdraws underlying token from an ERC4626 vault
    function erc4626Withdraw(address vault, uint256 assets, uint256 minSharePriceE27, address receiver, address owner) external;

    /// @notice Redeems shares of an ERC4626 vault
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner) external;

    /* MORPHO CALLBACKS */

    /// @notice Receives supply callback from the Morpho contract
    function onMorphoSupply(uint256 amount, bytes calldata data) external;

    /// @notice Receives supply collateral callback from the Morpho contract
    function onMorphoSupplyCollateral(uint256 amount, bytes calldata data) external;

    /// @notice Receives repay callback from the Morpho contract
    function onMorphoRepay(uint256 amount, bytes calldata data) external;

    /// @notice Receives flashloan callback from the Morpho contract
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external;

    /* MORPHO ACTIONS */

    /// @notice Supplies loan asset on Morpho
    function morphoSupply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @notice Supplies collateral on Morpho
    function morphoSupplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @notice Borrows assets on Morpho
    function morphoBorrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address onBehalf,
        address receiver
    ) external;

    /// @notice Repays assets on Morpho
    function morphoRepay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @notice Withdraws assets on Morpho
    function morphoWithdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address onBehalf,
        address receiver
    ) external;

    /// @notice Withdraws collateral from Morpho
    function morphoWithdrawCollateral(
        MarketParams calldata marketParams, 
        uint256 assets, 
        address onBehalf,
        address receiver
    ) external;

    /// @notice Triggers a flash loan on Morpho
    function morphoFlashLoan(
        address token, 
        uint256 assets, 
        bytes calldata data
    ) external;

    /* PERMIT2 ACTIONS */

    /// @notice Transfers with Permit2
    function permit2TransferFrom(
        address token, 
        address receiver, 
        uint256 amount
    ) external;

    /* TRANSFER ACTIONS */

    /// @notice Transfers ERC20 tokens from the initiator
    function erc20TransferFrom(
        address token, 
        address from, 
        address receiver, 
        uint256 amount
    ) external;
    
    /// @notice Transfers ERC20 tokens to a specified recipient
    function erc20Transfer(
        address token, 
        address to, 
        uint256 amount
    ) external;

    /* WRAPPED NATIVE TOKEN ACTIONS */

    /// @notice Wraps native tokens to wNative
    function wrapNative(
        uint256 amount, 
        address receiver
    ) external;

    /// @notice Unwraps wNative tokens to the native token
    function unwrapNative(
        uint256 amount, 
        address receiver
    ) external;
}