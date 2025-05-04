// // SPDX-License-Identifier: GPL-2.0-or-later
// pragma solidity 0.8.28;

// import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {IBundler3, Call} from "../interfaces/IBundler3.sol";
// import {IMaverickV2Pool} from "../interfaces/IMaverickV2Pool.sol";
// import {IMaverickV2Factory} from "../interfaces/IMaverickV2Factory.sol";
// import {IMaverickV2Quoter} from "../interfaces/IMaverickV2Quoter.sol";
// import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

// /**
//  * @title MorphoLeverageBundler
//  * @notice Creates bundles of calls for leveraged positions on Morpho using flashloans and Maverick swap
//  * @dev Uses bundler to create sequences of calls for execution in a single transaction
//  */
// contract MorphoLeverageBundler is Ownable {
//     // Bundler contract
//     IBundler3 public immutable bundler;
    
//     // Morpho protocol
//     IMorpho public immutable morpho;
    
//     // Maverick components
//     IMaverickV2Factory public immutable factory;
//     IMaverickV2Quoter public immutable quoter;
    
//     // Constants
//     uint256 public constant SLIPPAGE_SCALE = 10000; // 10000 = 100%
//     uint256 public constant DEFAULT_SLIPPAGE = 9700; // 97%, or 3% slippage allowance
    
//     // Events
//     event BundleCreated(address indexed user, bytes32 indexed operationType, uint256 bundleSize);
    
//     /**
//      * @param _bundler Bundler contract address
//      * @param _morpho Morpho protocol address
//      * @param _factory Maverick factory address
//      * @param _quoter Maverick quoter address
//      */
//     constructor(
//         address _bundler,
//         address _morpho,
//         address _factory,
//         address _quoter
//     ) Ownable(msg.sender) {
//         bundler = IBundler3(_bundler);
//         morpho = IMorpho(_morpho);
//         factory = IMaverickV2Factory(_factory);
//         quoter = IMaverickV2Quoter(_quoter);
//     }
    
//     /**
//      * @notice Creates a bundle to open a leveraged position using a flashloan
//      * @param marketParams The market parameters for Morpho
//      * @param initialCollateralAmount Amount of initial collateral
//      * @param targetLeverage Target leverage ratio (in 1e4 format, e.g. 20000 = 2x)
//      * @param slippageTolerance Minimum acceptable slippage (9700 = 3% slippage)
//      * @return bundle Array of calls to execute
//      */
//     function createOpenLeverageBundle(
//         MarketParams calldata marketParams,
//         uint256 initialCollateralAmount,
//         uint256 targetLeverage,
//         uint256 slippageTolerance
//     ) external view returns (Call[] memory bundle) {
//         require(initialCollateralAmount > 0, "Zero collateral amount");
//         require(targetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
//         require(targetLeverage <= 50000, "Leverage too high"); // Max 5x
        
//         // Set default slippage if not specified
//         uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        
//         // Calculate borrow amount based on target leverage
//         uint256 positionSize = initialCollateralAmount * targetLeverage / SLIPPAGE_SCALE;
//         uint256 borrowAmount = positionSize - initialCollateralAmount;
        
//         // Create a bundle of calls
//         Call[] memory mainBundle = new Call[](3);
//         Call[] memory flashloanCallbackBundle = new Call[](4);
        
//         // 1. First transfer collateral from user
//         mainBundle[0] = _createERC20TransferFromCall(
//             marketParams.collateralToken,
//             msg.sender, 
//             address(this), 
//             initialCollateralAmount
//         );
        
//         // 2. Supply initial collateral to Morpho
//         mainBundle[1] = _createMorphoSupplyCollateralCall(
//             marketParams,
//             initialCollateralAmount,
//             msg.sender,
//             ""
//         );
        
//         // --- Flashloan callback operations ---
        
//         // 3a. In callback: Swap borrowed tokens for more collateral
//         flashloanCallbackBundle[0] = _createMaverickSwapCall(
//             marketParams.loanToken,
//             marketParams.collateralToken,
//             borrowAmount,
//             borrowAmount * slippage / SLIPPAGE_SCALE // Min output with slippage
//         );
        
//         // 3b. In callback: Supply swapped collateral to user's position
//         flashloanCallbackBundle[1] = _createMorphoSupplyCollateralCall(
//             marketParams,
//             type(uint256).max, // All available collateral after swap
//             msg.sender,
//             ""
//         );
        
//         // 3c. In callback: Borrow to repay flashloan
//         flashloanCallbackBundle[2] = _createMorphoBorrowCall(
//             marketParams,
//             borrowAmount,
//             0, // No shares specified
//             msg.sender,
//             address(this)
//         );
        
//         // 3d. In callback: Approve loan token for flashloan repayment
//         flashloanCallbackBundle[3] = _createERC20ApproveCall(
//             marketParams.loanToken,
//             address(morpho),
//             borrowAmount
//         );
        
//         // 3. Execute flashloan with callback bundle
//         mainBundle[2] = _createMorphoFlashloanCall(
//             marketParams.loanToken,
//             borrowAmount,
//             abi.encode(flashloanCallbackBundle)
//         );
        
//         emit BundleCreated(msg.sender, keccak256("OPEN_LEVERAGE"), mainBundle.length);
        
//         return mainBundle;
//     }
    
//     /**
//      * @notice Creates a bundle to close a leveraged position using a flashloan
//      * @param marketParams The market parameters for Morpho
//      * @param slippageTolerance Minimum acceptable slippage (9700 = 3% slippage)
//      * @return bundle Array of calls to execute
//      */
//     function createCloseLeverageBundle(
//         MarketParams calldata marketParams,
//         uint256 slippageTolerance
//     ) external view returns (Call[] memory bundle) {
//         // Set default slippage if not specified
//         uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        
//         // Create main bundle and callback bundle
//         Call[] memory mainBundle = new Call[](1);
//         Call[] memory flashloanCallbackBundle = new Call[](5);
        
//         // Get total debt to repay via flashloan
//         uint256 borrowShares = morpho.position(marketParams.id(), msg.sender).borrowShares;
//         require(borrowShares > 0, "No debt to repay");
//         uint256 totalDebt = morpho.borrowShareToAssetAmount(marketParams.id(), borrowShares);
        
//         // --- Flashloan callback operations ---
        
//         // a. In callback: Withdraw collateral to sell
//         // We need to calculate precisely how much collateral to withdraw based on the debt
//         uint256 collateralToWithdraw = morpho.position(marketParams.id(), msg.sender).collateral;
        
//         // Use the max necessary collateral based on price + slippage
//         flashloanCallbackBundle[0] = _createMorphoWithdrawCollateralCall(
//             marketParams,
//             collateralToWithdraw,
//             msg.sender,
//             address(this)
//         );
        
//         // b. In callback: Swap collateral for loan token to repay flashloan
//         flashloanCallbackBundle[1] = _createMaverickSwapCall(
//             marketParams.collateralToken,
//             marketParams.loanToken,
//             type(uint256).max, // All withdrawn collateral
//             totalDebt * slippage / SLIPPAGE_SCALE // Min output with slippage
//         );
        
//         // c. In callback: Repay borrowed position
//         flashloanCallbackBundle[2] = _createMorphoRepayCall(
//             marketParams,
//             0, // Amount is calculated from shares
//             borrowShares,
//             msg.sender,
//             ""
//         );
        
//         // d. In callback: Withdraw remaining collateral to user
//         flashloanCallbackBundle[3] = _createMorphoWithdrawCollateralCall(
//             marketParams,
//             type(uint256).max, // All remaining collateral
//             msg.sender,
//             msg.sender
//         );
        
//         // e. In callback: Approve loan token for flashloan repayment
//         flashloanCallbackBundle[4] = _createERC20ApproveCall(
//             marketParams.loanToken,
//             address(morpho),
//             totalDebt
//         );
        
//         // Execute flashloan with callback bundle
//         mainBundle[0] = _createMorphoFlashloanCall(
//             marketParams.loanToken,
//             totalDebt,
//             abi.encode(flashloanCallbackBundle)
//         );
        
//         emit BundleCreated(msg.sender, keccak256("CLOSE_LEVERAGE"), mainBundle.length);
        
//         return mainBundle;
//     }
    
//     /**
//      * @notice Creates a bundle to increase leverage on an existing position
//      * @param marketParams The market parameters for Morpho
//      * @param additionalBorrowAmount Additional amount to borrow
//      * @param slippageTolerance Minimum acceptable slippage (9700 = 3% slippage)
//      * @return bundle Array of calls to execute
//      */
//     function createIncreaseLeverageBundle(
//         MarketParams calldata marketParams,
//         uint256 additionalBorrowAmount,
//         uint256 slippageTolerance
//     ) external view returns (Call[] memory bundle) {
//         require(additionalBorrowAmount > 0, "Zero borrow amount");
        
//         // Set default slippage if not specified
//         uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        
//         // Create main bundle and callback bundle
//         Call[] memory mainBundle = new Call[](1);
//         Call[] memory flashloanCallbackBundle = new Call[](4);
        
//         // --- Flashloan callback operations ---
        
//         // a. In callback: Swap borrowed tokens for more collateral
//         flashloanCallbackBundle[0] = _createMaverickSwapCall(
//             marketParams.loanToken,
//             marketParams.collateralToken,
//             additionalBorrowAmount,
//             additionalBorrowAmount * slippage / SLIPPAGE_SCALE // Min output with slippage
//         );
        
//         // b. In callback: Supply swapped collateral to user's position
//         flashloanCallbackBundle[1] = _createMorphoSupplyCollateralCall(
//             marketParams,
//             type(uint256).max, // All available collateral after swap
//             msg.sender,
//             ""
//         );
        
//         // c. In callback: Borrow to repay flashloan
//         flashloanCallbackBundle[2] = _createMorphoBorrowCall(
//             marketParams,
//             additionalBorrowAmount,
//             0, // No shares specified
//             msg.sender,
//             address(this)
//         );
        
//         // d. In callback: Approve loan token for flashloan repayment
//         flashloanCallbackBundle[3] = _createERC20ApproveCall(
//             marketParams.loanToken,
//             address(morpho),
//             additionalBorrowAmount
//         );
        
//         // Execute flashloan with callback bundle
//         mainBundle[0] = _createMorphoFlashloanCall(
//             marketParams.loanToken,
//             additionalBorrowAmount,
//             abi.encode(flashloanCallbackBundle)
//         );
        
//         emit BundleCreated(msg.sender, keccak256("INCREASE_LEVERAGE"), mainBundle.length);
        
//         return mainBundle;
//     }
    
//     /**
//      * @notice Creates a bundle to decrease leverage on an existing position
//      * @param marketParams The market parameters for Morpho
//      * @param repayAmount Amount to repay
//      * @param slippageTolerance Minimum acceptable slippage (9700 = 3% slippage)
//      * @return bundle Array of calls to execute
//      */
//     function createDecreaseLeverageBundle(
//         MarketParams calldata marketParams,
//         uint256 repayAmount,
//         uint256 slippageTolerance
//     ) external view returns (Call[] memory bundle) {
//         require(repayAmount > 0, "Zero repay amount");
        
//         // Set default slippage if not specified
//         uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        
//         // Create main bundle and callback bundle
//         Call[] memory mainBundle = new Call[](1);
//         Call[] memory flashloanCallbackBundle = new Call[](5);
        
//         // Get total debt
//         uint256 totalDebt = morpho.borrowShareToAssetAmount(
//             marketParams.id(), 
//             morpho.position(marketParams.id(), msg.sender).borrowShares
//         );
//         require(repayAmount <= totalDebt, "Amount exceeds debt");
        
//         // --- Flashloan callback operations ---
        
//         // Calculate collateral to withdraw based on repay amount
//         uint256 collateralToWithdraw = morpho.position(marketParams.id(), msg.sender).collateral * repayAmount / totalDebt;
//         collateralToWithdraw = collateralToWithdraw * SLIPPAGE_SCALE / slippage; // Add slippage buffer
        
//         // a. In callback: Withdraw collateral to sell
//         flashloanCallbackBundle[0] = _createMorphoWithdrawCollateralCall(
//             marketParams,
//             collateralToWithdraw,
//             msg.sender,
//             address(this)
//         );
        
//         // b. In callback: Swap collateral for loan token to repay flashloan
//         flashloanCallbackBundle[1] = _createMaverickSwapCall(
//             marketParams.collateralToken,
//             marketParams.loanToken,
//             type(uint256).max, // All withdrawn collateral
//             repayAmount * slippage / SLIPPAGE_SCALE // Min output with slippage
//         );
        
//         // c. In callback: Repay portion of borrowed position
//         flashloanCallbackBundle[2] = _createMorphoRepayCall(
//             marketParams,
//             repayAmount,
//             0, // No shares specified
//             msg.sender,
//             ""
//         );
        
//         // d. In callback: Return any excess tokens to user
//         flashloanCallbackBundle[3] = _createERC20TransferCall(
//             marketParams.loanToken,
//             msg.sender,
//             type(uint256).max // All remaining loan tokens
//         );
        
//         // e. In callback: Approve loan token for flashloan repayment
//         flashloanCallbackBundle[4] = _createERC20ApproveCall(
//             marketParams.loanToken,
//             address(morpho),
//             repayAmount
//         );
        
//         // Execute flashloan with callback bundle
//         mainBundle[0] = _createMorphoFlashloanCall(
//             marketParams.loanToken,
//             repayAmount,
//             abi.encode(flashloanCallbackBundle)
//         );
        
//         emit BundleCreated(msg.sender, keccak256("DECREASE_LEVERAGE"), mainBundle.length);
        
//         return mainBundle;
//     }
    
//     /* CALL GENERATORS */
    
//     function _createMorphoFlashloanCall(
//         address token,
//         uint256 amount,
//         bytes memory data
//     ) internal view returns (Call memory) {
//         return Call(
//             address(morpho),
//             abi.encodeCall(IMorpho.flashLoan, (token, amount, data)),
//             0,
//             false,
//             data.length == 0 ? bytes32(0) : keccak256(data)
//         );
//     }
    
//     function _createMorphoSupplyCollateralCall(
//         MarketParams memory marketParams,
//         uint256 assets,
//         address onBehalf,
//         bytes memory data
//     ) internal view returns (Call memory) {
//         return Call(
//             address(morpho),
//             abi.encodeCall(IMorpho.supplyCollateral, (marketParams, assets, onBehalf, data)),
//             0,
//             false,
//             data.length == 0 ? bytes32(0) : keccak256(data)
//         );
//     }
    
//     function _createMorphoBorrowCall(
//         MarketParams memory marketParams,
//         uint256 assets,
//         uint256 shares,
//         address onBehalf,
//         address receiver
//     ) internal view returns (Call memory) {
//         return Call(
//             address(morpho),
//             abi.encodeCall(IMorpho.borrow, (marketParams, assets, shares, onBehalf, receiver)),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
    
//     function _createMorphoRepayCall(
//         MarketParams memory marketParams,
//         uint256 assets,
//         uint256 shares,
//         address onBehalf,
//         bytes memory data
//     ) internal view returns (Call memory) {
//         return Call(
//             address(morpho),
//             abi.encodeCall(IMorpho.repay, (marketParams, assets, shares, onBehalf, data)),
//             0,
//             false,
//             data.length == 0 ? bytes32(0) : keccak256(data)
//         );
//     }
    
//     function _createMorphoWithdrawCollateralCall(
//         MarketParams memory marketParams,
//         uint256 assets,
//         address onBehalf,
//         address receiver
//     ) internal view returns (Call memory) {
//         return Call(
//             address(morpho),
//             abi.encodeCall(IMorpho.withdrawCollateral, (marketParams, assets, onBehalf, receiver)),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
    
//     function _createERC20ApproveCall(
//         address token,
//         address spender,
//         uint256 amount
//     ) internal pure returns (Call memory) {
//         return Call(
//             token,
//             abi.encodeCall(IERC20.approve, (spender, amount)),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
    
//     function _createERC20TransferCall(
//         address token,
//         address to,
//         uint256 amount
//     ) internal pure returns (Call memory) {
//         return Call(
//             token,
//             abi.encodeCall(IERC20.transfer, (to, amount)),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
    
//     function _createERC20TransferFromCall(
//         address token,
//         address from,
//         address to,
//         uint256 amount
//     ) internal pure returns (Call memory) {
//         return Call(
//             token,
//             abi.encodeCall(IERC20.transferFrom, (from, to, amount)),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
    
//     function _createMaverickSwapCall(
//         address tokenIn,
//         address tokenOut,
//         uint256 amountIn,
//         uint256 amountOutMin
//     ) internal view returns (Call memory) {
//         // Use a pool lookup to find the best pool
//         IMaverickV2Pool[] memory pools = factory.lookup(IERC20(tokenIn), IERC20(tokenOut), 0, 10);
//         require(pools.length > 0, "No pool available");
        
//         // Select first pool for simplicity
//         // In production, you might want to select the pool with the most liquidity
//         IMaverickV2Pool pool = pools[0];
        
//         // Determine swap direction
//         bool tokenAIn = pool.tokenA() == IERC20(tokenIn);
//         int32 tickLimit = tokenAIn ? pool.getState().activeTick + 50 : pool.getState().activeTick - 50;
        
//         // Create swap parameters
//         IMaverickV2Pool.SwapParams memory swapParams = IMaverickV2Pool.SwapParams({
//             amount: amountIn,
//             tokenAIn: tokenAIn,
//             exactOutput: false,
//             tickLimit: tickLimit
//         });
        
//         return Call(
//             address(pool),
//             abi.encodeCall(IMaverickV2Pool.swap, (address(this), swapParams, "")),
//             0,
//             false,
//             bytes32(0)
//         );
//     }
// } 