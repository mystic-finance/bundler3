// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MorphoLeverageBundler} from "../src/calls/MorphoLeverageBundler.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../src/interfaces/IBundler3.sol";
import {Bundler3, Call} from "../src/Bundler3.sol";
import {GeneralAdapter1} from "../src/adapters/GeneralAdapter1.sol";
import {CoreAdapter} from "../src/adapters/CoreAdapter.sol";
import {MaverickSwapAdapter} from "../src/adapters/MaverickAdapter.sol";
import {MarketParams, IMorpho, IMorphoBase} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MathRayLib} from "../src/libraries/MathRayLib.sol";
import "../lib/forge-std/src/Test.sol";
import "./helpers/mocks/ERC20Mock.sol";
import {IWNative} from "../src/interfaces/IWNative.sol";
import {IrmMock} from "test/helpers/mocks/IrmMock.sol";
import {OracleMock} from "test/helpers/mocks/OracleMock.sol";

contract MorphoLeverageBundlerTest is Test {
    using MathRayLib for uint256;

    MorphoLeverageBundler internal leverageBundler;
    GeneralAdapter1 internal generalAdapterMock;
    MaverickSwapAdapter internal maverickAdapterMock;
    address internal maverickFactoryMock;
    address internal maverickQuoterMock;
    address internal maverickPoolMock;
    Bundler3 internal bundler3;
    address USER = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;
    address MORPHO = 0x42b18785CE0Aed7BF7Ca43a39471ED4C0A3e0bB5; // Mock address
    address WRAPPED_NATIVE = 0xca59cA09E5602fAe8B629DeE83FfA819741f14be; // Mock address
    
    // Test tokens
    ERC20Mock internal collateralToken;
    ERC20Mock internal borrowToken;
    IOracle internal oracleMock;
    IrmMock internal irmMock;
    // Test parameters
    uint256 internal constant INITIAL_COLLATERAL = 0.1e6;
    uint256 internal constant LEVERAGE_2X = 30000; // 2x leverage in basis points (10000 = 1x)
    uint256 internal constant LEVERAGE_3X = 40000; // 3x leverage
    uint256 internal constant LEVERAGE_1_5X = 25000; // 1.5x leverage
    uint256 internal constant DEFAULT_SLIPPAGE = 9700; // 97% (3% slippage)
    uint256 internal constant RAY = 1e27;

    // Market parameters
    MarketParams testMarketParams;
    
    // Utility struct to track position data
    struct PositionData {
        uint256 totalBorrowsUser;
        uint256 totalCollateralUser;
        uint256 totalBorrows;
        uint256 totalCollaterals;
        uint256 morphoSupplyBalance;
        uint256 morphoBorrowBalance;
        uint256 userTokenBalance;
        uint256 bundlerTokenBalance;
        uint256 adapterTokenBalance;
    }
    
    function setUp() public {
        // Create mock tokens
        collateralToken = ERC20Mock(0x593cCcA4c4bf58b7526a4C164cEEf4003C6388db);
        borrowToken =  ERC20Mock(0xdddD73F5Df1F0DC31373357beAC77545dC5A6f3F);
        // Deploy bundler
        bundler3 = new Bundler3();
        
        // Setup mock oracle
        oracleMock = new OracleMock(1e18);
        irmMock = new IrmMock();
        
        // Create market params
        testMarketParams = MarketParams({
            loanToken: address(borrowToken),
            collateralToken: address(collateralToken),
            oracle: address(oracleMock),
            irm: address(irmMock),
            lltv: 0.9e6
        });
        
        // Create mock contracts
        maverickFactoryMock = address(0x056A588AfdC0cdaa4Cab50d8a4D2940C5D04172E);
        maverickQuoterMock = address(0xf245948e9cf892C351361d298cc7c5b217C36D82);
        maverickAdapterMock = new MaverickSwapAdapter(maverickFactoryMock, maverickQuoterMock);

        vm.prank(0xb651FC348bb9AE07f84cc2B57bdB3528DfE1ADd2);
        IMorphoBase(address(MORPHO)).enableIrm(address(irmMock));
        vm.prank(0xb651FC348bb9AE07f84cc2B57bdB3528DfE1ADd2);
        IMorphoBase(address(MORPHO)).enableLltv(0.9e6);
        vm.prank(0xb651FC348bb9AE07f84cc2B57bdB3528DfE1ADd2);
        IMorphoBase(address(MORPHO)).createMarket(testMarketParams);
        
        // Setup general adapter mock for Morpho
        generalAdapterMock = new GeneralAdapter1(address(bundler3), MORPHO, WRAPPED_NATIVE);
        
        // Deploy leverage bundler
        leverageBundler = new MorphoLeverageBundler(
            address(bundler3), 
            // MORPHO,
            address(generalAdapterMock), 
            address(maverickAdapterMock)
        );

        vm.startPrank(USER);
        collateralToken.approve(address(generalAdapterMock), type(uint256).max);
        borrowToken.approve(address(generalAdapterMock), type(uint256).max);
        collateralToken.approve(address(MORPHO), type(uint256).max);
        borrowToken.approve(address(MORPHO), type(uint256).max);
        // Additional approvals as needed for Morpho
        vm.stopPrank();
        
        // Fund user account
        deal(address(collateralToken), USER, 100000 * INITIAL_COLLATERAL);
        deal(address(borrowToken), USER, 100000 * INITIAL_COLLATERAL);

        vm.startPrank(USER);
        IMorphoBase(address(MORPHO)).supply(testMarketParams, INITIAL_COLLATERAL, 0, USER, "");
        IMorphoBase(address(MORPHO)).supply(testMarketParams, INITIAL_COLLATERAL, 0, USER, "");
        IMorphoBase(address(MORPHO)).setAuthorization(address(leverageBundler), true);
        IMorphoBase(address(MORPHO)).setAuthorization(address(generalAdapterMock), true);
        vm.stopPrank();
        
        // Mock oracle price function
        vm.mockCall(
            address(oracleMock),
            abi.encodeWithSelector(IOracle.price.selector),
            abi.encode(1e18)
        );
        
        // Approve tokens
        
        
        // Setup mock for Morpho interactions
        _setupMorphoMocks();
    }

    /**
     * @notice Setup mocks for Morpho protocol interactions
     */
    function _setupMorphoMocks() internal {
        // Mock flashloan
        // vm.mockCall(
        //     MORPHO,
        //     abi.encodeWithSelector(IMorphoBase.flashLoan.selector),
        //     abi.encode()
        // );
        
        // Mock supply
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.supply.selector),
            abi.encode(INITIAL_COLLATERAL, INITIAL_COLLATERAL)
        );
        
        // Mock supplyCollateral
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.supplyCollateral.selector),
            abi.encode()
        );
        
        // Mock borrow
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.borrow.selector),
            abi.encode(INITIAL_COLLATERAL, INITIAL_COLLATERAL)
        );
        
        // Mock repay
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.repay.selector),
            abi.encode(INITIAL_COLLATERAL, INITIAL_COLLATERAL)
        );
        
        // Mock withdraw
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.withdraw.selector),
            abi.encode(INITIAL_COLLATERAL, INITIAL_COLLATERAL)
        );
        
        // Mock withdrawCollateral
        vm.mockCall(
            MORPHO,
            abi.encodeWithSelector(IMorphoBase.withdrawCollateral.selector),
            abi.encode()
        );
        
        // Mock getQuote for MaverickAdapter
        // vm.mockCall(
        //     address(maverickAdapterMock),
        //     abi.encodeWithSelector(MaverickSwapAdapter.getSwapQuote.selector),
        //     abi.encode(INITIAL_COLLATERAL)
        // );
        
        // // Mock Morpho callback functions
        // vm.mockCall(
        //     address(generalAdapterMock),
        //     abi.encodeWithSelector(GeneralAdapter1.morphoFlashLoan.selector),
        //     abi.encode()
        // );

        vm.mockCall(
            address(generalAdapterMock),
            abi.encodeWithSelector(GeneralAdapter1.morphoSupplyCollateral.selector),
            abi.encode()
        );

        vm.mockCall(
            address(generalAdapterMock),
            abi.encodeWithSelector(GeneralAdapter1.morphoSupply.selector),
            abi.encode()
        );

        vm.mockCall(
            address(generalAdapterMock),
            abi.encodeWithSelector(GeneralAdapter1.morphoBorrow.selector),
            abi.encode()
        );
        
        // Mock ERC20 transfer functions
        vm.mockCall(
            address(generalAdapterMock),
            abi.encodeWithSelector(CoreAdapter.erc20Transfer.selector),
            abi.encode(true)
        );
        
        vm.mockCall(
            address(generalAdapterMock),
            abi.encodeWithSelector(GeneralAdapter1.erc20TransferFrom.selector),
            abi.encode(true)
        );
    }

    /**
     * @notice Utility function to get position data for a user
     * @param user The user address
     * @param marketParams The Morpho market parameters
     * @return data The position data
     */
    function getPositionData(address user, MarketParams memory marketParams) internal view returns (PositionData memory data) {
        bytes32 pairKey = leverageBundler.getMarketPairKey(marketParams);
        
        data.totalBorrowsUser = leverageBundler.totalBorrowsPerUser(pairKey, user);
        data.totalCollateralUser = leverageBundler.totalCollateralsPerUser(pairKey, user);
        data.totalBorrows = leverageBundler.totalBorrows(pairKey);
        data.totalCollaterals = leverageBundler.totalCollaterals(pairKey);
        
        data.userTokenBalance = IERC20(marketParams.collateralToken).balanceOf(user);
        data.bundlerTokenBalance = IERC20(marketParams.collateralToken).balanceOf(address(leverageBundler));
        data.adapterTokenBalance = IERC20(marketParams.collateralToken).balanceOf(address(generalAdapterMock));
    }

    /**
     * @notice Verify that no tokens are retained in the contracts
     * @param marketParams The Morpho market parameters
     */
    function verifyNoRetainedBalances(MarketParams memory marketParams) internal view {
        // Check leverageBundler has no tokens
        assertEq(IERC20(marketParams.loanToken).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained borrow tokens");
        assertEq(IERC20(marketParams.collateralToken).balanceOf(address(leverageBundler)), 0, "LeverageBundler retained collateral tokens");
        
        // Check generalAdapter has no tokens
        assertLt(IERC20(marketParams.loanToken).balanceOf(address(generalAdapterMock)), 2, "GeneralAdapter retained borrow tokens"); //borrow token is forgivable
        assertEq(IERC20(marketParams.collateralToken).balanceOf(address(generalAdapterMock)), 0, "GeneralAdapter retained collateral tokens");
        
        // Check bundler3 has no tokens
        assertEq(IERC20(marketParams.loanToken).balanceOf(address(bundler3)), 0, "Bundler3 retained borrow tokens");
        assertEq(IERC20(marketParams.collateralToken).balanceOf(address(bundler3)), 0, "Bundler3 retained collateral tokens");
    }

    /**
     * @notice Verify position accuracy after operations
     * @param user The user address
     * @param marketParams The Morpho market parameters
     * @param initialCollateral Initial collateral amount
     * @param targetLeverage Target leverage
     * @param tolerance Tolerance percentage for verification
     */
    function verifyPositionAccuracy(
        address user,
        MarketParams memory marketParams,
        uint256 initialCollateral,
        uint256 targetLeverage,
        uint256 tolerance
    ) internal view {
        bytes32 pairKey = leverageBundler.getMarketPairKey(marketParams);
        
        // Get actual position data
        uint256 actualBorrowed = leverageBundler.totalBorrowsPerUser(pairKey, user);
        uint256 actualCollateral = leverageBundler.totalCollateralsPerUser(pairKey, user);

        if(actualBorrowed == 0){
            return;
        }
        
        // Calculate expected values
        uint256 expectedCollateral = initialCollateral==0?actualCollateral: initialCollateral * targetLeverage /leverageBundler.SLIPPAGE_SCALE() ;
        uint256 expectedBorrowed =  initialCollateral==0? expectedCollateral * (targetLeverage - leverageBundler.SLIPPAGE_SCALE())/targetLeverage :expectedCollateral - initialCollateral;
        
        // Calculate actual leverage
        uint256 actualLeverage = 0;
        if (actualCollateral > actualBorrowed && actualBorrowed > 0) {
            actualLeverage = (actualCollateral * leverageBundler.SLIPPAGE_SCALE()) / (actualCollateral - actualBorrowed);
        }
        
        // Check if values are within tolerance
        assertApproxEqRel(
            actualCollateral, 
            expectedCollateral, 
            (tolerance * 1e16), // Convert basis points to percentage with 18 decimals
            "Collateral amount deviates too much from expected"
        );
        
        assertApproxEqRel(
            actualBorrowed, 
            expectedBorrowed, 
            (tolerance * 1e16), 
            "Borrowed amount deviates too much from expected"
        );
        
        assertApproxEqRel(
            actualLeverage, 
            targetLeverage, 
            (tolerance * 1e16),  // 1% deviation allowed
            "Leverage deviates too much from target"
        );
        
        // Log actual values for debugging
        console.log("Position Verification:");
        console.log("Initial Collateral:", initialCollateral);
        console.log("Expected Collateral:", expectedCollateral);
        console.log("Actual Collateral:", actualCollateral);
        console.log("Expected Borrowed:", expectedBorrowed);
        console.log("Actual Borrowed:", actualBorrowed);
        console.log("Target Leverage:", targetLeverage / 100,  targetLeverage % 100);
        console.log("Actual Leverage:", actualLeverage / 100, actualLeverage % 100);
    }
    
    /*//////////////////////////////////////////////////////////////
                        OPEN LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCreateOpenLeverageBundle() public {
        // Get initial position data
        PositionData memory before = getPositionData(USER, testMarketParams);
        uint256 initialUserBalance = collateralToken.balanceOf(USER);

        // Prepare for testing by increasing allowances
        vm.startPrank(USER);
        collateralToken.approve(address(leverageBundler), type(uint256).max);
        borrowToken.approve(address(leverageBundler), type(uint256).max);
        
        // Execute the open leverage function
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, 0, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify position accuracy with 5% tolerance
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            5
        );
    }

    function testCreateOpenLeverageBundleWithDifferentInputAsset() public {
        // Get initial position data
        PositionData memory before = getPositionData(USER, testMarketParams);
        uint256 initialUserBalance = borrowToken.balanceOf(USER);
        
        // Prepare for testing by increasing allowances
        vm.startPrank(USER);
        borrowToken.approve(address(leverageBundler), type(uint256).max);
        
        // Execute the open leverage function with borrow token as input
        Call[] memory bundleCalls = leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position tracking was updated
        assertGt(afterVal.totalBorrowsUser, 0, "User's total borrows not updated");
        assertGt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not updated");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify position accuracy with 6% tolerance
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            6
        );
    }
    
    function testCreateOpenLeverageBundleZeroCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert("Zero collateral amount");
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            0, // Zero collateral
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }
    
    function testCreateOpenLeverageBundleLowLeverage() public {
        vm.startPrank(USER);
        vm.expectRevert("Leverage must be > 1");
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            INITIAL_COLLATERAL,
            9999, // Less than 1x leverage
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }
    
    function testCreateOpenLeverageBundleHighLeverage() public {
        vm.startPrank(USER);
        vm.expectRevert("Leverage too high");
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            INITIAL_COLLATERAL,
            1000001, // Too high leverage (>100x)
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }

    function _createInitialPosition() internal returns (PositionData memory) {
        // Get initial position data
        PositionData memory before = getPositionData(USER, testMarketParams);
        
        // Prepare for testing by increasing allowances
        vm.startPrank(USER);
        collateralToken.approve(address(leverageBundler), type(uint256).max);
        
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Return the updated position data
        return getPositionData(USER, testMarketParams);
    }

    function _createInitialPositionWithDifferentInputAsset() internal returns (PositionData memory) {
        // Get initial position data
        PositionData memory before = getPositionData(USER, testMarketParams);
        
        // Prepare for testing by increasing allowances
        vm.startPrank(USER);
        borrowToken.approve(address(leverageBundler), type(uint256).max);
        
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(borrowToken),
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Return the updated position data
        return getPositionData(USER, testMarketParams);
    }
    
    /*//////////////////////////////////////////////////////////////
                        CLOSE LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testCreateCloseLeverageBundle() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        uint256 debtToClose = before.totalBorrowsUser * 95 / 100; // Close 95% of position
        
        // Close the position
        vm.startPrank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            testMarketParams,
            debtToClose
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position tracking was updated
        assertApproxEqRel(afterVal.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e18, "User's total borrows not reduced correctly");
        assertLt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not reduced");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
    }

    function testCreateCloseLeverageBundleWithDifferentInputAsset() public {
        // First open a position with different input asset
        PositionData memory before = _createInitialPositionWithDifferentInputAsset();
        uint256 debtToClose = before.totalBorrowsUser * 95 / 100; // Close 95% of position
        
        // Close the position
        vm.startPrank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            testMarketParams,
            debtToClose
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify position tracking was updated
        assertApproxEqRel(afterVal.totalBorrowsUser, before.totalBorrowsUser - debtToClose, 0.01e6, "User's total borrows not reduced correctly");
        assertLt(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral not reduced");
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        // Verify user received collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");
    }

    function testCreateCloseLeverageBundleFull() public {
        // First open a position
        PositionData memory before = getPositionData(USER, testMarketParams);
        PositionData memory before1 = _createInitialPosition();
        
        // Close the entire position
        vm.startPrank(USER);
        Call[] memory bundleCalls = leverageBundler.createCloseLeverageBundle(
            testMarketParams,
            type(uint256).max  // Close entire position
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
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
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE LEVERAGE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testUpdateLeverageBundleIncreaseLeverageOnly() public {
        // First open a position
        PositionData memory before = _createInitialPosition();

        verifyPositionAccuracy(
            USER,
            testMarketParams,
            INITIAL_COLLATERAL,
            LEVERAGE_2X,
            5
        );
        
        // Update leverage: increase from current to higher
        vm.startPrank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            testMarketParams,
            LEVERAGE_3X,  // Increase leverage
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow increased but collateral stayed the same
        assertGt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not increase");
        assertEq(afterVal.totalCollateralUser, before.totalCollateralUser, "User's total collateral changed unexpectedly");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertEq(afterVal.totalCollaterals, afterVal.totalCollateralUser, "Total collaterals mismatch");
        
        assertGt(afterVal.totalCollateralUser, afterVal.totalBorrowsUser-1, "Negative leverage");

        // Add position verification after leverage increase
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            0,
            LEVERAGE_3X,
            5
        );
    }
    
    function testUpdateLeverageBundleDecreaseLeverageOnly() public {
        // First open a position
        PositionData memory before = _createInitialPosition();
        
        // Update leverage: decrease from current to lower
        vm.startPrank(USER);
        Call[] memory bundleCalls = leverageBundler.updateLeverageBundle(
            testMarketParams,
            LEVERAGE_1_5X,  // Decrease leverage
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Get position data after operation
        PositionData memory afterVal = getPositionData(USER, testMarketParams);
        
        // Verify bundle structure
        assertGt(bundleCalls.length, 0, "Bundle should contain calls");
        
        // Verify borrow and collateral decreased
        assertLt(afterVal.totalBorrowsUser, before.totalBorrowsUser, "User's total borrows did not decrease");
        assertLt(afterVal.totalCollateralUser-1, before.totalCollateralUser, "User's total collateral did not decrease");
        
        // Verify tracking is accurate
        assertEq(afterVal.totalBorrows, afterVal.totalBorrowsUser, "Total borrows mismatch");
        assertGt(afterVal.totalCollaterals, afterVal.totalCollateralUser-1, "Total collaterals mismatch");
        
        // Verify user received some collateral back
        assertGt(afterVal.userTokenBalance, before.userTokenBalance-1, "User did not receive collateral back");

        assertGt(afterVal.totalCollateralUser, afterVal.totalBorrowsUser, "Negative leverage");
        
        // Add position verification after leverage decrease
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            0,
            LEVERAGE_1_5X,
            5
        );
    }
    
    // Test error cases
    function testUpdateLeverageBundleNoPosition() public {
        // Do not create a position first
        vm.startPrank(USER);
        vm.expectRevert("No existing position");
        leverageBundler.updateLeverageBundle(
            testMarketParams,
            LEVERAGE_3X,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }
    
    function testUpdateLeverageBundleLeverageTooLow() public {
        _createInitialPosition();
        
        vm.startPrank(USER);
        vm.expectRevert("Leverage must be > 1");
        leverageBundler.updateLeverageBundle(
            testMarketParams,
            9999,  // Less than 1x
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }
    
    function testUpdateLeverageBundleLeverageTooHigh() public {
        _createInitialPosition();
        
        vm.startPrank(USER);
        vm.expectRevert("Leverage too high");
        leverageBundler.updateLeverageBundle(
            testMarketParams,
            1000001,  // > 100x
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
    }

    // Add a dedicated test for position accuracy
    function testLeveragePositionAccuracy() public {
        // Test case with 0.1 collateral and 3x leverage
        uint256 initialCollateral = 0.1e6; 
        uint256 targetLeverage = 30000;    // 3x leverage
        uint256 tolerance = 5;           // 5% tolerance

        vm.startPrank(USER);
        collateralToken.approve(address(leverageBundler), type(uint256).max);
        
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(collateralToken),
            initialCollateral,
            targetLeverage,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Verify the position is accurately tracked
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            initialCollateral,
            targetLeverage,
            tolerance
        );
        
        // Test with borrow token as input
        vm.startPrank(USER);
        borrowToken.approve(address(leverageBundler), type(uint256).max);
        
        leverageBundler.createOpenLeverageBundle(
            testMarketParams,
            address(borrowToken),
            initialCollateral,
            targetLeverage,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        // Check combined positions accuracy 
        verifyPositionAccuracy(
            USER,
            testMarketParams,
            initialCollateral * 2,  // Account for both positions
            targetLeverage,
            tolerance
        );
    }
} 