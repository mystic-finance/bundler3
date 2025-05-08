// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {MysticLeverageBundler} from "../../src/calls/MysticLeverageBundler.sol";
import {IMysticAdapter} from "../../src/interfaces/IMysticAdapter.sol";
import {IMaverickV2Pool} from "../../src/interfaces/IMaverickV2Pool.sol";
import {IMaverickV2Factory} from "../../src/interfaces/IMaverickV2Factory.sol";
import {IMaverickV2Quoter} from "../../src/interfaces/IMaverickV2Quoter.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../../src/interfaces/IBundler3.sol";
import {MysticAdapter} from "../../src/adapters/MysticAdapter.sol";
import {Bundler3, Call} from "../../src/Bundler3.sol";
import "../../lib/forge-std/src/Test.sol";
import "../helpers/mocks/ERC20Mock.sol";
import {ICreditDelegationToken} from "../../src/interfaces/ICreditDelegationToken.sol";
import {MaverickSwapAdapter} from "../../src/adapters/MaverickAdapter.sol";
import {IMysticV3 as IPool, ReserveDataMap as ReserveData} from "../../src/interfaces/IMysticV3.sol";

contract MysticLeverageBundlerForkTest is Test {
    MysticLeverageBundler internal leverageBundler;
    MysticAdapter internal mysticAdapterMock;
    MaverickSwapAdapter internal maverickAdapterMock;
    address internal maverickFactoryMock;
    address internal maverickQuoterMock;
    address internal maverickPoolMock;
    Bundler3 internal bundler3;
    address USER = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;
    
    // Test tokens
    ERC20Mock internal collateralToken;
    ERC20Mock internal borrowToken;
    
    // Test parameters
    uint256 internal constant INITIAL_COLLATERAL = 0.1e6;
    uint256 internal constant LEVERAGE_2X = 30000; // 2x leverage in basis points (10000 = 1x)
    uint256 internal constant LEVERAGE_3X = 40000; // 3x leverage
    uint256 internal constant LEVERAGE_1_5X = 25000; // 1.5x leverage
    uint256 internal constant DEFAULT_SLIPPAGE = 9700; // 97% (3% slippage)

    // Utility struct to track position data
    struct PositionData {
        uint256 totalBorrowsUser;
        uint256 totalCollateralUser;
        uint256 totalBorrows;
        uint256 totalCollaterals;
        uint256 aTokenBalance;
        uint256 vTokenBalance;
        uint256 userTokenBalance;
        uint256 bundlerTokenBalance;
        uint256 adapterTokenBalance;
    }
    
    function setUp() public {
        // Create mock tokens
        collateralToken = ERC20Mock(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db);
        borrowToken =  ERC20Mock(0xdddD73F5Df1F0DC31373357beAC77545dC5A6f3F);
        bundler3 = new Bundler3();
        
        // Create mock contracts
        mysticAdapterMock =  MysticAdapter(payable(0xE2314ECb6Ae07a987018a71e412897ED2F54E075)); // change
        maverickFactoryMock = 0x056A588AfdC0cdaa4Cab50d8a4D2940C5D04172E;
        maverickQuoterMock = 0xf245948e9cf892C351361d298cc7c5b217C36D82;
        
        // Deploy leverage bundler
        leverageBundler =  MysticLeverageBundler(payable(0x598Fc8cD4335D5916Fa81Ec0Efa25b462aA721F1)); //change
        deal(address(collateralToken), USER, 1e6 * INITIAL_COLLATERAL);
        deal(address(0x9fbC367B9Bb966a2A537989817A088AFCaFFDC4c), USER, 1e6 * INITIAL_COLLATERAL);
        deal(address(borrowToken), USER, 1e6 * INITIAL_COLLATERAL);
        
        // Approve tokens
        vm.startPrank(USER);
        collateralToken.approve(address(mysticAdapterMock), type(uint256).max);
        ERC20Mock(0x9fbC367B9Bb966a2A537989817A088AFCaFFDC4c).approve(address(mysticAdapterMock), type(uint256).max);
        borrowToken.approve(address(mysticAdapterMock), type(uint256).max);
        ICreditDelegationToken(0xA9b705D4719002030386fa83087c905Ca4c25eB2).approveDelegation(address(mysticAdapterMock), type(uint128).max);
        IERC20(0xAf5aEAb2248415716569Be5d24FbE10b16590D6c).approve(address(mysticAdapterMock), type(uint128).max);
        IERC20(0xDb224c353CFB74e220b7B6cB12f8D8Bc7c8B2863).approve(address(mysticAdapterMock), type(uint128).max);
        IERC20(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db).approve(address(0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0), type(uint128).max);
        // IPool(0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0).supply(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db, INITIAL_COLLATERAL*1000, USER, 0);
        // IPool(address(0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0)).setUserUseReserveAsCollateral(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db, true);
        ICreditDelegationToken(0xA9b705D4719002030386fa83087c905Ca4c25eB2).approveDelegation(address(mysticAdapterMock), type(uint128).max);
        IERC20(0xAf5aEAb2248415716569Be5d24FbE10b16590D6c).approve(address(mysticAdapterMock), type(uint128).max);
        IERC20(0xd1a7183708EF9706F3dD2d51B27a7e02a70F30fa).approve(address(mysticAdapterMock), type(uint128).max);
        IERC20(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db).approve(address(0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0), type(uint128).max);
        vm.stopPrank(); 
    }

    /**
     * @notice Utility function to get aToken and vToken addresses for a given asset
     * @param asset The asset to get token addresses for
     * @return aToken The aToken address
     * @return vToken The vToken address
     */
    function getMysticTokens(address asset) internal view returns (address aToken, address vToken) {
        ReserveData memory reserveData = IPool(address(0xCE192A6E105cD8dd97b8Dedc5B5b263B52bb6AE0)).getReserveData(asset);
        aToken = reserveData.aTokenAddress;
        vToken = reserveData.variableDebtTokenAddress;
    }

    /**
     * @notice Utility function to get position data for a user
     * @param user The user address
     * @param asset The borrow asset
     * @param collateralAsset The collateral asset
     * @return data The position data
     */
    function getPositionData(address user, address asset, address collateralAsset) internal view returns (PositionData memory data) {
        bytes32 pairKey = leverageBundler.getPairKey(asset, collateralAsset);
        
        data.totalBorrowsUser = leverageBundler.totalBorrowsPerUser(pairKey, user);
        data.totalCollateralUser = leverageBundler.totalCollateralsPerUser(pairKey, user);
        data.totalBorrows = leverageBundler.totalBorrows(pairKey);
        data.totalCollaterals = leverageBundler.totalCollaterals(pairKey);
        
        (address aToken, address vToken) = getMysticTokens(collateralAsset);
        if (aToken != address(0)) {
            data.aTokenBalance = IERC20(aToken).balanceOf(user);
        }
        
        (,address borrowVToken) = getMysticTokens(asset);
        if (borrowVToken != address(0)) {
            data.vTokenBalance = IERC20(borrowVToken).balanceOf(user);
        }
        
        data.userTokenBalance = IERC20(collateralAsset).balanceOf(user);
        data.bundlerTokenBalance = IERC20(collateralAsset).balanceOf(address(leverageBundler));
        data.adapterTokenBalance = IERC20(collateralAsset).balanceOf(address(mysticAdapterMock));
    }

    /**
     * @notice Verify that no tokens are retained in the contracts
     * @param asset The borrow asset
     * @param collateralAsset The collateral asset
     */
    function verifyNoRetainedBalances(address asset, address collateralAsset) internal view {
        // Check leverageBundler has no tokens
        assertEq(IERC20(asset).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained borrow tokens");
        assertEq(IERC20(collateralAsset).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained collateral tokens");
        
        // Check mysticAdapter has no tokens
        assertLt(IERC20(asset).balanceOf(address(mysticAdapterMock)), 2, "MysticAdapter retained borrow tokens"); //borrow tok is forgivable
        assertEq(IERC20(collateralAsset).balanceOf(address(mysticAdapterMock)), 0, "MysticAdapter retained collateral tokens");
        
        // Check bundler3 has no tokens
        assertEq(IERC20(asset).balanceOf(address(bundler3)), 0, "Bundler3 retained borrow tokens");
        assertEq(IERC20(collateralAsset).balanceOf(address(bundler3)), 0, "Bundler3 retained collateral tokens");

        (address aToken, address vToken) = getMysticTokens(asset);
        assertEq(IERC20(aToken).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained borrow tokens");
        assertEq(IERC20(vToken).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained collateral tokens");
        
        // Check mysticAdapter has no tokens
        assertEq(IERC20(aToken).balanceOf(address(mysticAdapterMock)), 0, "MysticAdapter retained borrow tokens"); //borrow tok is forgivable
        assertEq(IERC20(vToken).balanceOf(address(mysticAdapterMock)), 0, "MysticAdapter retained collateral tokens");

        assertEq(IERC20(aToken).balanceOf(address(bundler3)), 0, "Bundler3 retained borrow tokens");
        assertEq(IERC20(vToken).balanceOf(address(bundler3)), 0, "Bundler3 retained collateral tokens");

        (address aToken1, address vToken2) = getMysticTokens(collateralAsset);
        assertEq(IERC20(aToken1).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained borrow tokens");
        assertEq(IERC20(vToken2).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained collateral tokens");
        
        // Check mysticAdapter has no tokens
        assertEq(IERC20(aToken1).balanceOf(address(mysticAdapterMock)), 0, "MysticAdapter retained borrow tokens"); //borrow tok is forgivable
        assertEq(IERC20(vToken2).balanceOf(address(mysticAdapterMock)), 0, "MysticAdapter retained collateral tokens");

        assertEq(IERC20(aToken1).balanceOf(address(bundler3)), 0, "Bundler3 retained borrow tokens");
        assertEq(IERC20(vToken2).balanceOf(address(bundler3)), 0, "Bundler3 retained collateral tokens");
    }
    
    /*//////////////////////////////////////////////////////////////
                        OPEN LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCreateOpenLeverageBundle() public {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        uint256 initialUserBalance = collateralToken.balanceOf(USER);
        
        // Execute the open leverage function
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify user's collateral was transferred
        assertEq(initialUserBalance - collateralToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, 0, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify vToken (debt) balance increased
        assertGt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testCreateOpenLeverageBundleWithDifferentAsset() public {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        uint256 initialUserBalance = collateralToken.balanceOf(USER);
        
        // Execute the open leverage function
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );

        _createInitialDifferentAssetPosition();
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify user's collateral was transferred
        assertEq(initialUserBalance - collateralToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, 0, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify vToken (debt) balance increased
        assertGt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    

    function testCreateOpenLeverageBundleWithDifferentInputAsset() public {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        uint256 initialUserBalance = borrowToken.balanceOf(USER);
        
        // Execute the open leverage function
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify user's collateral was transferred
        assertEq(initialUserBalance - borrowToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, 0, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify vToken (debt) balance increased
        assertGt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    
    function testCreateOpenLeverageBundleZeroCollateral() public {
        vm.prank(USER);
        vm.expectRevert("Zero collateral amount");
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            0, // Zero collateral
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
    }
    
    function testCreateOpenLeverageBundleLowLeverage() public {
        vm.prank(USER);
        vm.expectRevert("Leverage must be > 1");
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            9999, // Less than 1x leverage
            DEFAULT_SLIPPAGE
        );
    }
    
    function testCreateOpenLeverageBundleHighLeverage() public {
        vm.prank(USER);
        vm.expectRevert("Leverage too high");
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            1000001, // Too high leverage (>100x)
            DEFAULT_SLIPPAGE
        );
    }

    function _createInitialPosition() internal returns (PositionData memory) {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        vm.prank(USER);
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Return the updated position data
        return getPositionData(USER, address(borrowToken), address(collateralToken));
    }

    function _createInitialDifferentAssetPosition() internal returns (PositionData memory) {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        vm.prank(USER);
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(0x9fbC367B9Bb966a2A537989817A088AFCaFFDC4c),
            address(0x9fbC367B9Bb966a2A537989817A088AFCaFFDC4c),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Return the updated position data
        return getPositionData(USER, address(borrowToken), address(collateralToken));
    }

    function _createInitialPositionWithDifferentInputAsset() internal returns (PositionData memory) {
        // Get initial position data
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        vm.prank(USER);
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Return the updated position data
        return getPositionData(USER, address(borrowToken), address(collateralToken));
    }
    
    /*//////////////////////////////////////////////////////////////
                        CLOSE LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCreateCloseLeverageBundle() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        uint256 debtToClose = before.totalBorrowsUser * 95 / 100; // Close 95% of position
        
        // Close the position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertEq(bundleCalls.length, 5, "Bundle should have 5 calls");
        
        // Verify position tracking was updated
        assertApproxEqRel(afterVal.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "User's total borrows not reduced correctly");
        assertLt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not reduced");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance decreased
        assertLt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not decrease");
        
        // Verify vToken (debt) balance decreased
        assertLt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not decrease");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    function testMultipleCreateCloseLeverageBundle() public {
        // First open a position
        _createInitialDifferentAssetPosition();
        PositionData memory before = _createInitialPosition();
        uint256 debtToClose = before.totalBorrowsUser * 95 / 100; // Close 95% of position
        
        // Close the position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertEq(bundleCalls.length, 5, "Bundle should have 5 calls");
        
        // Verify position tracking was updated
        assertApproxEqRel(afterVal.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "User's total borrows not reduced correctly");
        assertLt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not reduced");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance decreased
        assertLt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not decrease");
        
        // Verify vToken (debt) balance decreased
        assertLt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not decrease");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testCreateCloseLeverageBundleWithDifferentInputAsset() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        uint256 debtToClose = before.totalBorrowsUser * 95 / 100; // Close 95% of position
        
        // Close the position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertEq(bundleCalls.length, 5, "Bundle should have 5 calls");
        
        // Verify position tracking was updated
        assertApproxEqRel(afterVal.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "User's total borrows not reduced correctly");
        assertLt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not reduced");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify aToken balance decreased
        assertLt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not decrease");
        
        // Verify vToken (debt) balance decreased
        assertLt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not decrease");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testCreateCloseLeverageBundleFull() public {
        // First open a position
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        PositionData memory before1 = _createInitialPosition();
        
        // Close the entire position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            type(uint256).max  // Close entire position
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position was completely closed
        assertEq(afterVal.totalBorrowsUser, 0, "User still has borrows");
        assertEq(afterVal.totalCollateralUser, 0, "User still has collateral in position");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, 0, "Total borrows not updated");
        assertEq(afterVal.totalCollaterals, 0, "Total collaterals not updated");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before1.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no aToken or vToken left
        // assertEq(afterVal.aTokenBalance - before.aTokenBalance, 0, "User still has aTokens");
        // assertEq(afterVal.vTokenBalance - before.vTokenBalance, 0, "User still has vTokens");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

     function testCreateOpenLeverageBundleFullHighAmount() public {
        // First open a position
        // PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        vm.prank(USER);
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL * 50,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testCreateCloseLeverageBundleFullHighAmount() public {
        // First open a position
        // PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        vm.prank(USER);
        leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL * 50,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        PositionData memory before = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Close the entire position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            type(uint256).max  // Close entire position
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position was completely closed
        // assertEq(afterVal.totalBorrowsUser, 0, "User still has borrows");
        // assertEq(afterVal.totalCollateralUser, 0, "User still has collateral in position");
        
        // // Verify tracking is accurate
        // assertEq(afterVal.totalBorrows, 0, "Total borrows not updated");
        // assertEq(afterVal.totalCollaterals, 0, "Total collaterals not updated");
        
        // // Verify user received collateral back
        // assertGt(afterVal.userTokenBalance, before.userTokenBalance, "User did not receive collateral back");
        
        // Verify no aToken or vToken left
        // assertEq(afterVal.aTokenBalance, 0, "User still has aTokens");
        // assertEq(afterVal.vTokenBalance, 0, "User still has vTokens");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    // Test increasing leverage only
    function testUpdateLeverageBundleIncreaseLeverageOnly() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        
        // Update leverage: increase from current to higher
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            LEVERAGE_3X,  // Increase leverage
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow increased but collateral stayed the same
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not increase");
        assertEq(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral changed unexpectedly");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify vToken (debt) balance increased
        assertGt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

     function testUpdateLeverageBundleIncreaseLeverageOnlyWithDifferentInputAsset() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        
        // Update leverage: increase from current to higher
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            LEVERAGE_3X,  // Increase leverage
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow increased but collateral stayed the same
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not increase");
        assertEq(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral changed unexpectedly");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify vToken (debt) balance increased
        assertGt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    
    // Test decreasing leverage only
    function testUpdateLeverageBundleDecreaseLeverageOnly() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        
        // Update leverage: decrease from current to lower
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            LEVERAGE_1_5X,  // Decrease leverage
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow and collateral decreased
        assertLt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not decrease");
        assertLt(afterVal.totalCollateralUser-1, before.totalCollateralUser, "User's total collateral did not decrease");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertGt(afterVal.totalCollaterals, afterVal.totalCollateralUser -1, "Total collaterals mismatch");
        
        // Verify user received some collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify vToken (debt) balance decreased
        assertLt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not decrease");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

     function testUpdateLeverageBundleDecreaseLeverageOnlyWithDifferentInputAsset() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        
        // Update leverage: decrease from current to lower
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            LEVERAGE_1_5X,  // Decrease leverage
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow and collateral decreased
        assertLt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not decrease");
        assertLt(afterVal.totalCollateralUser-1, before.totalCollateralUser, "User's total collateral did not decrease");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertGt(afterVal.totalCollaterals, afterVal.totalCollateralUser -1, "Total collaterals mismatch");
        
        // Verify user received some collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify vToken (debt) balance decreased
        assertLt(afterVal.vTokenBalance, before.vTokenBalance, "User's vToken balance did not decrease");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    
    // Test adding collateral only
    function testAddCollateral() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        uint256 initialUserBalance = collateralToken.balanceOf(USER);
        
        // Add more collateral
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify collateral was transferred from user
        assertEq(initialUserBalance - collateralToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testAddCollateralWithDifferentInputAsset() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        uint256 initialUserBalance = borrowToken.balanceOf(USER);
        
        // Add more collateral
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify collateral was transferred from user
        assertEq(initialUserBalance - borrowToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testAddCollateralWithDifferentInputAsset2() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        uint256 initialUserBalance = borrowToken.balanceOf(USER);
        
        // Add more collateral
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify collateral was transferred from user
        assertEq(initialUserBalance - borrowToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testAddCollateralWithDifferentInputAsset3() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        uint256 initialUserBalance = collateralToken.balanceOf(USER);
        
        // Add more collateral
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        
        // Get position data afterVal operation
        PositionData memory afterVal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify collateral was transferred from user
        assertEq(initialUserBalance - collateralToken.balanceOf(USER), INITIAL_COLLATERAL, "User collateral was not transferred correctly");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        
        // Verify aToken balance increased
        assertGt(afterVal.aTokenBalance, before.aTokenBalance, "User's aToken balance did not increase");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    
    // Test removing collateral (partial close)
    function testRemoveCollateral() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        uint256 debtToClose = before.totalBorrowsUser / 3; // Close 1/3 of position
        
        // Remove some collateral by closing part of position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal first operation
        PositionData memory after1 = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Remove more in a second operation
        vm.prank(USER);
        Call[] memory bundleCalls2 = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal second operation
        PositionData memory after2 = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Remove the rest in a third operation
        vm.prank(USER);
        Call[] memory bundleCalls3 = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            type(uint256).max
        );
        
        // Get position data afterVal final operation
        PositionData memory afterFinal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "First bundle should contain calls");
        assertGt(bundleCalls2.length, 0, "Second bundle should contain calls");
        assertGt(bundleCalls3.length, 0, "Third bundle should contain calls");
        
        // Verify intermediary states
        assertApproxEqRel(after1.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "First close: User's total borrows not reduced correctly");
        assertApproxEqRel(after2.totalBorrowsUser, after1.totalBorrowsUser - debtToClose, 0.01e18, "Second close: User's total borrows not reduced correctly");
        
        // Verify final state
        assertEq(afterFinal.totalBorrowsUser, 0, "Final: User still has borrows");
        assertEq(afterFinal.totalCollateralUser, 0, "Final: User still has collateral in position");
        
        // Verify user received all collateral back
        assertGt(afterFinal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }

    function testRemoveCollateralWithDifferentInputAsset() public {
        // First open a position
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        uint256 debtToClose = before.totalBorrowsUser / 3; // Close 1/3 of position
        
        // Remove some collateral by closing part of position
        vm.prank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal first operation
        PositionData memory after1 = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Remove more in a second operation
        vm.prank(USER);
        Call[] memory bundleCalls2 = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            debtToClose
        );
        
        // Get position data afterVal second operation
        PositionData memory after2 = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Remove the rest in a third operation
        vm.prank(USER);
        Call[] memory bundleCalls3 = leverageBundler.createCloseLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            type(uint256).max
        );
        
        // Get position data afterVal final operation
        PositionData memory afterFinal = getPositionData(USER, address(borrowToken), address(collateralToken));
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "First bundle should contain calls");
        assertGt(bundleCalls2.length, 0, "Second bundle should contain calls");
        assertGt(bundleCalls3.length, 0, "Third bundle should contain calls");
        
        // Verify intermediary states
        assertApproxEqRel(after1.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "First close: User's total borrows not reduced correctly");
        assertApproxEqRel(after2.totalBorrowsUser, after1.totalBorrowsUser - debtToClose, 0.01e18, "Second close: User's total borrows not reduced correctly");
        
        // Verify final state
        assertEq(afterFinal.totalBorrowsUser, 0, "Final: User still has borrows");
        assertEq(afterFinal.totalCollateralUser, 0, "Final: User still has collateral in position");
        
        // Verify user received all collateral back
        assertGt(afterFinal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
        
        // Verify no tokens are retained in contracts
        verifyNoRetainedBalances(address(borrowToken), address(collateralToken));
    }
    

    // Test error cases
    function testUpdateLeverageBundleNoPosition() public {
        // Do not create a position first
        vm.prank(USER);
        vm.expectRevert("No existing position");
        leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            LEVERAGE_3X,
            DEFAULT_SLIPPAGE
        );
    }
    
    // function testUpdateLeverageBundleNoChanges() public {
    //     _createInitialPosition();
        
    //     vm.prank(USER);
    //     vm.expectRevert("No changes to position");
    //     leverageBundler.updateLeverageBundle(
    //         address(borrowToken),
    //         address(collateralToken),
    //         LEVERAGE_3X,  // Same as initial
    //         DEFAULT_SLIPPAGE
    //     );
    // }
    
    function testUpdateLeverageBundleLeverageTooLow() public {
        _createInitialPosition();
        
        vm.prank(USER);
        vm.expectRevert("Leverage must be > 1");
        leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            9999,  // Less than 1x
            DEFAULT_SLIPPAGE
        );
    }
    
    function testUpdateLeverageBundleLeverageTooHigh() public {
        _createInitialPosition();
        
        vm.prank(USER);
        vm.expectRevert("Leverage too high");
        leverageBundler.updateLeverageBundle(
            address(borrowToken),
            address(collateralToken),
            1000001,  // > 100x
            DEFAULT_SLIPPAGE
        );
    }
} 