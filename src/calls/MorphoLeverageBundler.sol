// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../interfaces/IBundler3.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {MaverickSwapAdapter} from "../adapters/MaverickAdapter.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams, IMorpho, Position, Id, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathRayLib} from "../libraries/MathRayLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {IGeneralAdapter1} from "../interfaces/IGeneralAdapter.sol";
import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title MorphoLeverageBundler
 * @notice Creates bundles of calls for leveraged positions on Morpho using flashloans and Maverick swap
 * @dev Uses bundler to create sequences of calls for execution in a single transaction
 */
contract MorphoLeverageBundler is Ownable {
    using SafeERC20 for IERC20;
    using MathRayLib for uint256;
    using MarketParamsLib for MarketParams;

    // Bundler contract
    IBundler3 public immutable bundler;
    IGeneralAdapter1 public generalAdapter;
    MaverickSwapAdapter public maverickAdapter;
    
    // Constants
    uint256 public constant SLIPPAGE_SCALE = 10000; // 10000 = 100%
    uint256 public constant DEFAULT_SLIPPAGE = 9500; // 95%, or 5% slippage allowance
    uint256 public constant RAY = 1e27;
    uint256 public constant SHARE_PRICE_SLIPPAGE = 300; // 3% slippage for share price

    // Position tracking
    mapping(bytes32 => uint256) public totalBorrows;
    mapping(bytes32 => uint256) public totalCollaterals;
    mapping(bytes32 => mapping(address => uint256)) public totalBorrowsPerUser;
    mapping(bytes32 => mapping(address => uint256)) public totalCollateralsPerUser;
    mapping(bytes32 => mapping(address => uint256)) public leveragePerUser;
    
    // Events
    event BundleCreated(address indexed user, bytes32 indexed operationType, uint256 bundleSize);
    event LeverageOpened(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 leverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageClosed(address indexed user, address collateralToken, address borrowToken, uint256 collateralReturned, uint256 totalCollateral, uint256 totalBorrowed);
    event LeverageUpdated(address indexed user, address collateralToken, address borrowToken, uint256 initialCollateral, uint256 oldLeverageMultiplier, uint256 newLeverageMultiplier, uint256 totalCollateral, uint256 totalBorrowed);

    constructor(
      address _bundler,
      address _generalAdapter,
      address _maverickAdapter
    ) Ownable(msg.sender) {
        bundler = IBundler3(_bundler);
        generalAdapter = IGeneralAdapter1(payable(_generalAdapter));
        maverickAdapter = MaverickSwapAdapter(payable(_maverickAdapter));
    }

    modifier modifyBalances(bytes32 pairKey, MarketParams calldata marketParams, bool isOpen){
        Position memory positionBefore = generalAdapter.MORPHO().position(marketParams.id(), msg.sender);
        _;
        Position memory positionAfter = generalAdapter.MORPHO().position(marketParams.id(), msg.sender);

        uint256 assetDecimals = IERC20Metadata(marketParams.loanToken).decimals();
        uint256 collateralDecimals = IERC20Metadata(marketParams.collateralToken).decimals();

        if(isOpen){
            updatePositionTracking(pairKey, (positionAfter.borrowShares - positionBefore.borrowShares)/1e6, positionAfter.collateral - positionBefore.collateral, msg.sender, isOpen, assetDecimals, collateralDecimals);
        } else {
            updatePositionTracking(pairKey, (positionBefore.borrowShares - positionAfter.borrowShares)/1e6, positionBefore.collateral - positionAfter.collateral, msg.sender, isOpen, assetDecimals, collateralDecimals);
        }
    }
    
    function getMarketPairKey(MarketParams calldata marketParams) public view returns (bytes32) {
        address borrowToken = marketParams.loanToken;
        address collateralToken = marketParams.collateralToken;
        // Get the price ratio directly from the oracle
        // The price() function returns the price of 1 collateral token in terms of loan token, scaled by 1e36
        uint256 priceRatio = IOracle(marketParams.oracle).price();
        // The expected ratio is 1e36 (if tokens have equal value)
        // Allow for 5% deviation (500 basis points)
        uint256 baseRatio = 1e36;
        require(
            priceRatio <= baseRatio + (baseRatio * 500 / SLIPPAGE_SCALE) && 
            priceRatio >= baseRatio - (baseRatio * 500 / SLIPPAGE_SCALE), 
            "Price deviation too high for safe leverage"
        ); // 5% deviation allowed
        return keccak256(abi.encodePacked(borrowToken, collateralToken));
    }

    function updatePositionTracking(bytes32 pairKey, uint256 borrowAmount, uint256 collateralAmount, address user, bool isOpen, uint256 assetDecimals, uint256 collateralDecimals) internal {
        uint256 borrowDecimals = assetDecimals < 18 ? 18 - assetDecimals : 0;
        uint256 collateralDecimals = collateralDecimals < 18 ? 18 - collateralDecimals : 0;
    
        if (isOpen) {
            totalBorrows[pairKey] += borrowAmount;
            totalCollaterals[pairKey] += collateralAmount; 
            totalBorrowsPerUser[pairKey][user] += borrowAmount;
            totalCollateralsPerUser[pairKey][user] += collateralAmount;
        } else {
            totalBorrows[pairKey] -= borrowAmount;
            totalCollaterals[pairKey] -= collateralAmount;
            totalBorrowsPerUser[pairKey][user] -= borrowAmount;
            totalCollateralsPerUser[pairKey][user] -= collateralAmount;
        }
        uint256 borrowValue = totalBorrowsPerUser[pairKey][user] * (10 ** borrowDecimals); // normalize to 18 decimals
        uint256 collateralValue = totalCollateralsPerUser[pairKey][user] * (10 ** collateralDecimals);
        require(borrowValue < collateralValue || totalBorrowsPerUser[pairKey][user] == 0,  "Leverage too high");
    }

    function createOpenLeverageBundle(MarketParams calldata marketParams, address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance, bytes calldata data) modifyBalances(getMarketPairKey(marketParams), marketParams, true) external returns (Call[] memory bundle) {
        require(initialCollateralAmount > 0, "Zero collateral amount");
        require(targetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
        require(targetLeverage <= 1000000, "Leverage too high");
        address collateralAsset = marketParams.collateralToken;
        address borrowAsset = marketParams.loanToken;  
        IERC20(collateralAsset).approve(address(generalAdapter), type(uint256).max);
        IERC20(borrowAsset).approve(address(generalAdapter), type(uint256).max);      
        return _createOpenLeverageBundleWithFlashloan(marketParams, inputAsset, initialCollateralAmount, targetLeverage, slippageTolerance, data);
    }

    function _createOpenLeverageBundleWithFlashloan(MarketParams calldata marketParams,address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance, bytes calldata data) internal returns (Call[] memory bundle) {
        address collateralAsset = marketParams.collateralToken;
        address borrowAsset = marketParams.loanToken;
        Call[] memory mainBundle = new Call[](2);
        Call[] memory flashloanCallbackBundle = new Call[](5);
        uint256 totalCollateralAmount = 0;
        
        require(inputAsset == collateralAsset || inputAsset == borrowAsset, "Input asset must be collateral or loan asset");
        uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        uint256 collateralValue = initialCollateralAmount;
        uint256 positionSize = collateralValue * targetLeverage / SLIPPAGE_SCALE;
        uint256 borrowAmount = positionSize - collateralValue;
        bytes32 pairKey = getMarketPairKey(marketParams);
        uint256 minSharePrice = getMinBorrowSharePrice(marketParams);
        
        // if (inputAsset == collateralAsset) {
        //     // When input is collateral: Calculate total collateral after leverage
        //     totalCollateralAmount = collateralValue + getQuote(borrowAsset, collateralAsset, borrowAmount);
        // } else {
        //     // When input is borrowing asset: calculate total borrowing first
        //     totalCollateralAmount = getQuote(borrowAsset, collateralAsset, positionSize);
        // }
        if (data.length > 0) {
            // mint message data is generated offchain due to kyc but sender in message must be maverick adapter
            // validation will be done to ensure all params are correct
            flashloanCallbackBundle[1] = _createMaverickMintCall(data, borrowAsset, collateralAsset, address(this), borrowAmount, slippage);
        }else{
            flashloanCallbackBundle[1] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, slippage, false);
        }

        // Create callback bundle
        flashloanCallbackBundle[0] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
        flashloanCallbackBundle[2] = _createERC20TransferFromCall(collateralAsset, address(this), address(generalAdapter), type(uint256).max);
        flashloanCallbackBundle[3] = _createMorphoSupplyCollateralCall(marketParams, type(uint256).max, msg.sender);
        flashloanCallbackBundle[4] = _createMorphoBorrowCall(marketParams, borrowAmount, 0, minSharePrice, msg.sender, address(generalAdapter));

        // Create main bundle
        inputAsset == collateralAsset ? _createERC20TransferFromPureCall(collateralAsset, msg.sender, address(this), initialCollateralAmount) : _createERC20TransferFromPureCall(borrowAsset, msg.sender, address(maverickAdapter), initialCollateralAmount);
        mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, borrowAmount, abi.encode(flashloanCallbackBundle));
        bundler.multicall(mainBundle);
        leveragePerUser[pairKey][msg.sender] = targetLeverage;
        emit BundleCreated(msg.sender, keccak256("OPEN_LEVERAGE"), mainBundle.length);
        emit LeverageOpened(msg.sender, collateralAsset, borrowAsset, initialCollateralAmount, targetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }

    function createCloseLeverageBundle(MarketParams calldata marketParams, uint256 debtToClose) external modifyBalances(getMarketPairKey(marketParams), marketParams, false) returns (Call[] memory bundle) {
        bytes32 pairKey = getMarketPairKey(marketParams);
        if(debtToClose == type(uint256).max || totalBorrowsPerUser[pairKey][msg.sender] <= debtToClose) {
            debtToClose = totalBorrowsPerUser[pairKey][msg.sender];
        }
        require(debtToClose > 0, "No debt found");
        return _createCloseLeverageBundleWithFlashloan(marketParams, debtToClose);
    }
    
    function _createCloseLeverageBundleWithFlashloan(MarketParams calldata marketParams,uint256 debtToClose) internal returns (Call[] memory bundle) {
        address collateralAsset = marketParams.collateralToken;
        address borrowAsset = marketParams.loanToken;
        bytes32 pairKey = getMarketPairKey(marketParams);
        Call[] memory mainBundle = new Call[](5);
        Call[] memory flashloanCallbackBundle = new Call[](4);
        uint256 maxSharePrice = getMaxRepaySharePrice(marketParams);
        
        uint256 debtToCover = debtToClose;
        uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * debtToCover) / totalBorrowsPerUser[pairKey][msg.sender];
        collateralForRepayment = collateralForRepayment > totalCollateralsPerUser[pairKey][msg.sender] ? totalCollateralsPerUser[pairKey][msg.sender] : collateralForRepayment; // Safety check
        
        // Callback bundle creation
        flashloanCallbackBundle[0] = _createMorphoRepayCall(marketParams, debtToCover, 0, maxSharePrice, msg.sender);
        flashloanCallbackBundle[1] = _createMorphoWithdrawCollateralCall(marketParams, collateralForRepayment, msg.sender, address(maverickAdapter));
        flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, borrowAsset, collateralForRepayment, debtToCover, 0, false);
        flashloanCallbackBundle[3] = _createERC20TransferFromCall(borrowAsset, address(this), address(generalAdapter), type(uint256).max);
        
        // Main bundle creation
        mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, debtToCover, abi.encode(flashloanCallbackBundle));
        mainBundle[1] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
        mainBundle[2] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, 0, false);
        mainBundle[3] = _createERC20TransferCall(collateralAsset, address(this), type(uint256).max);
        mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
        bundler.multicall(mainBundle);

        emit BundleCreated(msg.sender, keccak256("CLOSE_LEVERAGE"), mainBundle.length);
        emit LeverageClosed(msg.sender, collateralAsset, borrowAsset, collateralForRepayment, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }
    
    function updateLeverageBundle(MarketParams calldata marketParams, uint256 newTargetLeverage, uint256 slippageTolerance, bytes calldata data) external returns (Call[] memory bundle) {
        // Create appropriate bundles based on the operation type
        Call[] memory mainBundle;
        Call[] memory flashloanCallbackBundle;
        require(newTargetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
        require(newTargetLeverage <= 1000000, "Leverage too high"); // Max 100
        address collateralAsset = marketParams.collateralToken;
        address borrowAsset = marketParams.loanToken;
        bytes32 pairKey = getMarketPairKey(marketParams);
        uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        uint256 currentCollateral = totalCollateralsPerUser[pairKey][msg.sender];
        uint256 currentBorrow = totalBorrowsPerUser[pairKey][msg.sender];

        require(currentCollateral > 0 && currentBorrow > 0, "No existing position");
        uint256 currentLeverage = leveragePerUser[pairKey][msg.sender];// (currentCollateral * SLIPPAGE_SCALE) / (currentCollateral - currentBorrow);
        uint256 newBorrow = currentBorrow * (newTargetLeverage - SLIPPAGE_SCALE) * currentLeverage / (newTargetLeverage * (currentLeverage - SLIPPAGE_SCALE));
        int256 borrowDelta = int256(newBorrow) - int256(currentBorrow);
        Position memory positionBefore = generalAdapter.MORPHO().position(marketParams.id(), msg.sender);
        
        if (borrowDelta > 0) {
            uint256 additionalBorrowAmount = uint256(borrowDelta);
            mainBundle = new Call[](1);
            flashloanCallbackBundle = new Call[](5);
            uint256 minSharePrice = getMinBorrowSharePrice(marketParams);

            if (data.length > 0) {
                // mint message data is generated offchain due to kyc but sender in message must be maverick adapter
                // validation will be done to ensure all params are correct
                flashloanCallbackBundle[1] = _createMaverickMintCall(data, borrowAsset, collateralAsset, address(this), additionalBorrowAmount, slippage);
            }else{
                flashloanCallbackBundle[1] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, slippage, false);
            }
            flashloanCallbackBundle[0] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
            flashloanCallbackBundle[2] = _createERC20TransferFromCall(collateralAsset, address(this), address(generalAdapter), type(uint256).max);
            flashloanCallbackBundle[3] = _createMorphoSupplyCollateralCall(marketParams, type(uint256).max, msg.sender);
            flashloanCallbackBundle[4] = _createMorphoBorrowCall(marketParams, additionalBorrowAmount, 0, minSharePrice, msg.sender, address(generalAdapter));
            mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, additionalBorrowAmount, abi.encode(flashloanCallbackBundle));
        } else if (borrowDelta < 0) {
            uint256 repayAmount = uint256(-borrowDelta);
            uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * repayAmount) / totalBorrowsPerUser[pairKey][msg.sender];
            mainBundle = new Call[](5);
            flashloanCallbackBundle = new Call[](4);
            uint256 maxSharePrice = getMaxRepaySharePrice(marketParams);
            flashloanCallbackBundle[0] = _createMorphoRepayCall(marketParams, repayAmount, 0, maxSharePrice, msg.sender);
            flashloanCallbackBundle[1] = _createMorphoWithdrawCollateralCall(marketParams, collateralForRepayment, msg.sender, address(maverickAdapter));
            flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, borrowAsset, collateralForRepayment, repayAmount, 0, false);
            flashloanCallbackBundle[3] = _createERC20TransferFromCall(borrowAsset, address(this), address(generalAdapter), type(uint256).max);
            
            mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, repayAmount, abi.encode(flashloanCallbackBundle));
            mainBundle[1] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
            mainBundle[2] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, 0, false);
            mainBundle[3] = _createERC20TransferCall(collateralAsset, address(this), type(uint256).max);
            mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
        } else {
            revert("No changes to position");
        }
        
        bundler.multicall(mainBundle);

        Position memory positionAfter = generalAdapter.MORPHO().position(marketParams.id(), msg.sender);
        uint256 assetDecimals = IERC20Metadata(marketParams.loanToken).decimals();
        uint256 collateralDecimals = IERC20Metadata(marketParams.collateralToken).decimals();

        if(borrowDelta > 0){
            updatePositionTracking(pairKey, (positionAfter.borrowShares - positionBefore.borrowShares)/1e6, positionAfter.collateral - positionBefore.collateral, msg.sender, true, assetDecimals, collateralDecimals);
        } else {
            updatePositionTracking(pairKey, (positionBefore.borrowShares - positionAfter.borrowShares)/1e6, positionBefore.collateral - positionAfter.collateral, msg.sender, false, assetDecimals, collateralDecimals);
        }
        leveragePerUser[pairKey][msg.sender] = newTargetLeverage;

        emit BundleCreated(msg.sender, keccak256("UPDATE_LEVERAGE"), mainBundle.length);
        emit LeverageUpdated(msg.sender, collateralAsset, borrowAsset, currentCollateral, currentLeverage, newTargetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }

    function getMinBorrowSharePrice(MarketParams calldata marketParams) public view returns (uint256) {
        // Get the current market state
        IMorpho morpho = generalAdapter.MORPHO();
        Id marketId = marketParams.id();
        Market memory market = morpho.market(marketId);
        
        // If market is empty or has no borrows, return RAY (1.0)
        if (market.totalBorrowShares == 0 || market.totalBorrowAssets == 0) {
            return RAY;
        }
        
        // Calculate the current share price: assets/shares
        // For borrowing, we want the minimum price, so we apply slippage downward
        uint256 currentSharePrice = (uint256(market.totalBorrowAssets) * RAY) / uint256(market.totalBorrowShares);
        return (currentSharePrice * (SLIPPAGE_SCALE - SHARE_PRICE_SLIPPAGE)) / SLIPPAGE_SCALE;
    }
    
    function getMaxRepaySharePrice(MarketParams calldata marketParams) public view returns (uint256) {
        // Get the current market state
        IMorpho morpho = generalAdapter.MORPHO();
        Id marketId = marketParams.id();
        Market memory market = morpho.market(marketId);
        
        // If market is empty or has no borrows, return RAY (1.0)
        if (market.totalBorrowShares == 0 || market.totalBorrowAssets == 0) {
            return RAY;
        }
        
        // Calculate the current share price: assets/shares
        // For repaying, we want the maximum price, so we apply slippage upward
        uint256 currentSharePrice = (uint256(market.totalBorrowAssets) * RAY) / uint256(market.totalBorrowShares);
        return (currentSharePrice * (SLIPPAGE_SCALE + SHARE_PRICE_SLIPPAGE)) / SLIPPAGE_SCALE;
    }
    
    function _createMorphoFlashloanCall(address token, uint256 amount,bytes memory data) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoFlashLoan, (token, amount, data)), 0, false, data.length == 0 ? bytes32(0) : keccak256(data));
    }
    
    function _createMorphoSupplyCall(MarketParams calldata marketParams, uint256 assets, uint256 shares, uint256 maxSharePriceE27, address onBehalf, bytes calldata data) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoSupply, (marketParams, assets, shares, maxSharePriceE27, onBehalf, data)), 0, false, bytes32(0));
    }
    
    function _createMorphoSupplyCollateralCall(MarketParams calldata marketParams, uint256 assets, address onBehalf) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoSupplyCollateral, (marketParams, assets, onBehalf, "")), 0, false, bytes32(0));
    }
    
    function _createMorphoWithdrawCollateralCall(MarketParams calldata marketParams, uint256 assets, address onBehalf,address receiver) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoWithdrawCollateral, (marketParams, assets, onBehalf, receiver)), 0, false, bytes32(0));
    }
    
    function _createMorphoBorrowCall(MarketParams calldata marketParams, uint256 assets, uint256 shares, uint256 minSharePriceE27, address onBehalf, address receiver) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoBorrow, (marketParams, assets, shares, minSharePriceE27, onBehalf, receiver)), 0, false, bytes32(0));
    }
    
    function _createMorphoRepayCall(MarketParams calldata marketParams, uint256 assets, uint256 shares, uint256 maxSharePriceE27, address onBehalf) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoRepay, (marketParams, assets, shares, maxSharePriceE27, onBehalf, "")), 0, false, bytes32(0));
    }
    
    function _createMorphoWithdrawCall(MarketParams calldata marketParams, uint256 assets, uint256 shares, uint256 minSharePriceE27, address onBehalf, address receiver) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.morphoWithdraw, (marketParams, assets, shares, minSharePriceE27, onBehalf, receiver)), 0, false, bytes32(0));
    }
    
    function _createERC20ApproveCall(address token, address spender, uint256 amount) internal view returns (Call memory) {
        return _call(token, abi.encodeCall(IERC20.approve, (spender, amount)), 0, false, bytes32(0));
    }
    
    function _createERC20TransferCall(address token,address to,uint256 amount) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.erc20Transfer, (token, to, amount)), 0, false, bytes32(0));
    }
    
    function _createERC20TransferFromCall(address token, address from, address to, uint256 amount) internal view returns (Call memory) {
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.erc20TransferFromWithSender, (token, from, to, amount)), 0, false, bytes32(0));
    }

    function _createERC20TransferFromPureCall(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal returns (Call memory) {
        require(IERC20(token).transferFrom(from, to, amount), "TransferFrom failed");
    }

    function getQuote(address tokenIn,address tokenOut, uint256 amountIn) internal returns (uint256) {
        require(tokenIn != address(0) && tokenOut != address(0), 'Invalid token address');
        return maverickAdapter.getSwapQuote(tokenIn, tokenOut, amountIn, false, 1e8);
    }
    
    function _createMaverickSwapCall(address tokenIn,address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 slippage, bool exactOutput) internal view returns (Call memory) {
        if(slippage == 0){
            slippage = DEFAULT_SLIPPAGE;
        }
        return _call(address(maverickAdapter), abi.encodeCall(MaverickSwapAdapter.swapExactTokensForTokens, (tokenIn, tokenOut, amountIn, amountOutMin, slippage, address(this), 1e8)), 0, false, bytes32(0));
    }

    function _createMaverickMintCall(bytes calldata data, address asset, address collateralAsset, address recipient, uint256 amount, uint256 slippage) internal view returns (Call memory) {
        if(slippage == 0){
            slippage = DEFAULT_SLIPPAGE;
        }
        uint256 minMint = amount * slippage / SLIPPAGE_SCALE;

        return _call(address(maverickAdapter), abi.encodeCall(MaverickSwapAdapter.mintToken, (data, asset, collateralAsset, recipient, amount, minMint)), 0, false, bytes32(0));
    }

    function _call(address to, bytes memory data, uint256 value, bool skipRevert, bytes32 callbackHash)
        internal
        pure
        returns (Call memory)
    {
        require(to != address(0), "Adapter address is zero");
        return Call(to, data, value, skipRevert, callbackHash);
    }

    function updateGeneralAdapter(address _newGeneralAdapter) external onlyOwner {
        require(_newGeneralAdapter != address(0), "Adapter address is zero");
        generalAdapter = IGeneralAdapter1(payable(_newGeneralAdapter));
    }

    function updateMaverickAdapter(address _newMaverickAdapter) external onlyOwner {
        require(_newMaverickAdapter != address(0), "Adapter address is zero");
        maverickAdapter = MaverickSwapAdapter(payable(_newMaverickAdapter));
    }
}