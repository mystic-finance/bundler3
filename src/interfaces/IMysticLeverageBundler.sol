// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IBundler3, Call} from "../interfaces/IBundler3.sol";
import {IMysticAdapter} from "../interfaces/IMysticAdapter.sol";
import {MaverickSwapAdapter} from "../adapters/MaverickAdapter.sol";

/**
 * @title IMysticLeverageBundler
 * @notice Interface for creating bundles of calls for leveraged positions on Mystic
 */
interface IMysticLeverageBundler {
    // Events
    event BundleCreated(address indexed user, bytes32 indexed operationType, uint256 bundleSize);
    event LeverageOpened(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 leverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageClosed(address indexed user, address collateralToken, address borrowToken, uint256 collateralReturned, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageUpdated(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 oldLeverageMultiplier, uint256 newLeverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);

    // Constants
    function SLIPPAGE_SCALE() external pure returns (uint256);
    function DEFAULT_SLIPPAGE() external pure returns (uint256);
    function VARIABLE_RATE_MODE() external pure returns (uint256);

    // State variables
    function bundler() external view returns (IBundler3);
    function mysticAdapter() external view returns (IMysticAdapter);
    function maverickAdapter() external view returns (MaverickSwapAdapter);
    function totalBorrows(bytes32 pairKey) external view returns (uint256);
    function totalCollaterals(bytes32 pairKey) external view returns (uint256);
    function totalBorrowsPerUser(bytes32 pairKey, address user) external view returns (uint256);
    function totalCollateralsPerUser(bytes32 pairKey, address user) external view returns (uint256);

    // Core functions
    function getPairKey(address borrowToken, address collateralToken) external view returns (bytes32);
    
    function createOpenLeverageBundle(
        address asset, 
        address collateralAsset, 
        address inputAsset, 
        uint256 initialCollateralAmount, 
        uint256 targetLeverage, 
        uint256 slippageTolerance
    ) external returns (Call[] memory bundle);
    
    function createCloseLeverageBundle(
        address asset, 
        address collateralAsset, 
        uint256 debtToClose
    ) external returns (Call[] memory bundle);
    
    function updateLeverageBundle(
        address asset, 
        address collateralAsset, 
        uint256 newTargetLeverage, 
        uint256 slippageTolerance
    ) external returns (Call[] memory bundle);

    // Admin functions
    function updateMysticAdapter(address _newMysticAdapter) external;
    function updateMaverickAdapter(address _newMaverickAdapter) external;
}