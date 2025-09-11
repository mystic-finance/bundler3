// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IBundler3, Call} from "./IBundler3.sol";
import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MaverickSwapAdapter} from "../adapters/MaverickAdapter.sol";

/**
 * @title IMorphoLeverageBundler
 * @notice Interface for creating bundles of calls for leveraged positions on Morpho
 */
interface IMorphoLeverageBundler {
    // Events
    event BundleCreated(address indexed user, bytes32 indexed operationType, uint256 bundleSize);
    event LeverageOpened(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 leverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageClosed(address indexed user, address collateralToken, address borrowToken, uint256 collateralReturned, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageUpdated(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 oldLeverageMultiplier, uint256 newLeverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);

    // Constants
    function SLIPPAGE_SCALE() external pure returns (uint256);
    function DEFAULT_SLIPPAGE() external pure returns (uint256);
    function RAY() external pure returns (uint256);

    // State variables
    function bundler() external view returns (IBundler3);
    function morpho() external view returns (IMorpho);
    function maverickAdapter() external view returns (MaverickSwapAdapter);
    function totalBorrows(bytes32 pairKey) external view returns (uint256);
    function totalCollaterals(bytes32 pairKey) external view returns (uint256);
    function totalBorrowsPerUser(bytes32 pairKey, address user) external view returns (uint256);
    function totalCollateralsPerUser(bytes32 pairKey, address user) external view returns (uint256);

    // Core functions
    function getMarketPairKey(MarketParams calldata marketParams) external view returns (bytes32);
    
    function createOpenLeverageBundle(
        MarketParams calldata marketParams,
        address inputAsset,
        uint256 initialCollateralAmount,
        uint256 targetLeverage,
        uint256 slippageTolerance
    ) external returns (Call[] memory bundle);
    
    function createCloseLeverageBundle(
        MarketParams calldata marketParams,
        uint256 debtToClose
    ) external returns (Call[] memory bundle);
    
    function updateLeverageBundle(
        MarketParams calldata marketParams,
        uint256 newTargetLeverage,
        uint256 slippageTolerance
    ) external returns (Call[] memory bundle);

    // Admin functions
    function updateMaverickAdapter(address _newMaverickAdapter) external;
} 