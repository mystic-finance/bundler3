// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../interfaces/IBundler3.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {MaverickSwapAdapter} from "../adapters/MaverickAdapter.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathRayLib} from "../libraries/MathRayLib.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {IGeneralAdapter1} from "../interfaces/IGeneralAdapter.sol";

/**
 * @title MorphoLeverageBundler
 * @notice Creates bundles of calls for leveraged positions on Morpho using flashloans and Maverick swap
 * @dev Uses bundler to create sequences of calls for execution in a single transaction
 */
contract MorphoLeverageBundler is Ownable {
    using SafeERC20 for IERC20;
    using MathRayLib for uint256;

    // Bundler contract
    IBundler3 public immutable bundler;
    IGeneralAdapter1 public generalAdapter;
    MaverickSwapAdapter public maverickAdapter;
    
    // Constants
    uint256 public constant SLIPPAGE_SCALE = 10000; // 10000 = 100%
    uint256 public constant DEFAULT_SLIPPAGE = 9700; // 97%, or 3% slippage allowance
    uint256 public constant RAY = 1e27;

    // Position tracking
    mapping(bytes32 => uint256) public totalBorrows;
    mapping(bytes32 => uint256) public totalCollaterals;
    mapping(bytes32 => mapping(address => uint256)) public totalBorrowsPerUser;
    mapping(bytes32 => mapping(address => uint256)) public totalCollateralsPerUser;
    
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
        maverickAdapter = MaverickSwapAdapter(_maverickAdapter);
    }
    
    function getMarketPairKey(MarketParams calldata marketParams) public view returns (bytes32) {
        address borrowToken = marketParams.loanToken;
        address collateralToken = marketParams.collateralToken;
        uint256 borrowPrice = IOracle(marketParams.oracle).price();
        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 ratio = (collateralPrice * SLIPPAGE_SCALE) / borrowPrice;
        require(ratio <= SLIPPAGE_SCALE + 500 && ratio >= SLIPPAGE_SCALE - 500, "Price deviation too high for safe leverage"); // 5% deviation allowed
        return keccak256(abi.encodePacked(borrowToken, collateralToken, ratio));
    }

    function updatePositionTracking(bytes32 pairKey, uint256 borrowAmount, uint256 collateralAmount, address user, bool isOpen) internal {
        if (isOpen) {
            totalBorrows[pairKey] += borrowAmount;
            totalCollaterals[pairKey] += collateralAmount; 
            totalBorrowsPerUser[pairKey][user] += borrowAmount;
            totalCollateralsPerUser[pairKey][user] += collateralAmount;
            require(totalBorrowsPerUser[pairKey][user] < totalCollateralsPerUser[pairKey][user], "Leverage too high");
        } else {
            totalBorrows[pairKey] -= borrowAmount;
            totalCollaterals[pairKey] -= collateralAmount;
            totalBorrowsPerUser[pairKey][user] -= borrowAmount;
            totalCollateralsPerUser[pairKey][user] -= collateralAmount;
            require(totalBorrowsPerUser[pairKey][user] <= totalCollateralsPerUser[pairKey][user], "Leverage too high");
        }
    }

    function createOpenLeverageBundle(MarketParams calldata marketParams, address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance) external returns (Call[] memory bundle) {
        require(initialCollateralAmount > 0, "Zero collateral amount");
        require(targetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
        require(targetLeverage <= 1000000, "Leverage too high");
        address collateralAsset = marketParams.collateralToken;
        address borrowAsset = marketParams.loanToken;  
        IERC20(collateralAsset).approve(address(generalAdapter), type(uint256).max);
        IERC20(borrowAsset).approve(address(generalAdapter), type(uint256).max);      
        return _createOpenLeverageBundleWithFlashloan(marketParams, inputAsset, initialCollateralAmount, targetLeverage, slippageTolerance);
    }

    function _createOpenLeverageBundleWithFlashloan(MarketParams calldata marketParams,address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance) internal returns (Call[] memory bundle) {
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
        
        if (inputAsset == collateralAsset) {
            // When input is collateral: Calculate total collateral after leverage
            totalCollateralAmount = collateralValue + getQuote(borrowAsset, collateralAsset, borrowAmount);
        } else {
            // When input is borrowing asset: calculate total borrowing first
            totalCollateralAmount = getQuote(borrowAsset, collateralAsset, positionSize);
        }

        // Create callback bundle
        flashloanCallbackBundle[0] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
        flashloanCallbackBundle[1] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, slippage, false);
        flashloanCallbackBundle[2] = _createERC20TransferFromCall(collateralAsset, address(this), address(generalAdapter), type(uint256).max);
        flashloanCallbackBundle[3] = _createMorphoSupplyCollateralCall(marketParams, type(uint256).max, msg.sender);
        flashloanCallbackBundle[4] = _createMorphoBorrowCall(marketParams, borrowAmount, 0, RAY, msg.sender, address(generalAdapter));

        // Create main bundle
        mainBundle[0] = inputAsset == collateralAsset ? _createERC20TransferFromCall(collateralAsset, msg.sender, address(this), initialCollateralAmount) : _createERC20TransferFromCall(borrowAsset, msg.sender, address(maverickAdapter), initialCollateralAmount);
        mainBundle[1] = _createMorphoFlashloanCall(borrowAsset, borrowAmount, abi.encode(flashloanCallbackBundle));
        bundler.multicall(mainBundle);
        updatePositionTracking(pairKey, borrowAmount, totalCollateralAmount, msg.sender, true);
        emit BundleCreated(msg.sender, keccak256("OPEN_LEVERAGE"), mainBundle.length);
        emit LeverageOpened(msg.sender, collateralAsset, borrowAsset, initialCollateralAmount, targetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }

    function createCloseLeverageBundle(MarketParams calldata marketParams, uint256 debtToClose) external returns (Call[] memory bundle) {
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
        
        uint256 debtToCover = debtToClose;
        uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * debtToCover) / totalBorrowsPerUser[pairKey][msg.sender];
        collateralForRepayment = collateralForRepayment > totalCollateralsPerUser[pairKey][msg.sender] ? totalCollateralsPerUser[pairKey][msg.sender] : collateralForRepayment; // Safety check
        
        // Callback bundle creation
        flashloanCallbackBundle[0] = _createMorphoRepayCall(marketParams, debtToCover, 0, RAY, msg.sender);
        flashloanCallbackBundle[1] = _createMorphoWithdrawCollateralCall(marketParams, collateralForRepayment, msg.sender, address(maverickAdapter));
        flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, borrowAsset, collateralForRepayment, debtToCover, 0, false);
        flashloanCallbackBundle[3] = _createERC20TransferCall(borrowAsset, address(generalAdapter), type(uint256).max);
        
        // Main bundle creation
        mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, debtToCover, abi.encode(flashloanCallbackBundle));
        mainBundle[1] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
        mainBundle[2] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, 0, false);
        mainBundle[3] = _createERC20TransferCall(collateralAsset, address(this), type(uint256).max);
        mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
        bundler.multicall(mainBundle);
        updatePositionTracking(pairKey, debtToCover, collateralForRepayment, msg.sender, false);

        emit BundleCreated(msg.sender, keccak256("CLOSE_LEVERAGE"), mainBundle.length);
        emit LeverageClosed(msg.sender, collateralAsset, borrowAsset, collateralForRepayment, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }
    
    function updateLeverageBundle(MarketParams calldata marketParams, uint256 newTargetLeverage, uint256 slippageTolerance) external returns (Call[] memory bundle) {
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
        uint256 currentLeverage = (currentCollateral * SLIPPAGE_SCALE) / (currentCollateral - currentBorrow);
        uint256 newBorrow = currentBorrow * (newTargetLeverage - SLIPPAGE_SCALE) * currentLeverage / (newTargetLeverage * (currentLeverage - SLIPPAGE_SCALE));
        int256 borrowDelta = int256(newBorrow) - int256(currentBorrow);
        
        if (borrowDelta > 0) {
            uint256 additionalBorrowAmount = uint256(borrowDelta);
            mainBundle = new Call[](1);
            flashloanCallbackBundle = new Call[](5);
            flashloanCallbackBundle[0] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
            flashloanCallbackBundle[1] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, slippage, false);
            flashloanCallbackBundle[2] = _createERC20TransferCall(collateralAsset, address(generalAdapter), type(uint256).max);
            flashloanCallbackBundle[3] = _createMorphoSupplyCollateralCall(marketParams, type(uint256).max, msg.sender);
            flashloanCallbackBundle[4] = _createMorphoBorrowCall(marketParams, additionalBorrowAmount, 0, RAY, msg.sender, address(generalAdapter));
            mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, additionalBorrowAmount, abi.encode(flashloanCallbackBundle));
            updatePositionTracking(pairKey, additionalBorrowAmount, 0, msg.sender, true);
        } else if (borrowDelta < 0) {
            uint256 repayAmount = uint256(-borrowDelta);
            uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * repayAmount) / totalBorrowsPerUser[pairKey][msg.sender];
            mainBundle = new Call[](5);
            flashloanCallbackBundle = new Call[](4);
            flashloanCallbackBundle[0] = _createMorphoRepayCall(marketParams, repayAmount, 0, RAY, msg.sender);
            flashloanCallbackBundle[1] = _createMorphoWithdrawCollateralCall(marketParams, collateralForRepayment, msg.sender, address(maverickAdapter));
            flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, borrowAsset, collateralForRepayment, repayAmount, 0, false);
            flashloanCallbackBundle[3] = _createERC20TransferCall(borrowAsset, address(generalAdapter), type(uint256).max);
            
            mainBundle[0] = _createMorphoFlashloanCall(borrowAsset, repayAmount, abi.encode(flashloanCallbackBundle));
            mainBundle[1] = _createERC20TransferCall(borrowAsset, address(maverickAdapter), type(uint256).max);
            mainBundle[2] = _createMaverickSwapCall(borrowAsset, collateralAsset, type(uint256).max, 0, 0, false);
            mainBundle[3] = _createERC20TransferCall(collateralAsset, address(this), type(uint256).max);
            mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
            updatePositionTracking(pairKey, repayAmount, 0, msg.sender, false);
        } else {
            revert("No changes to position");
        }
        
        bundler.multicall(mainBundle);
        emit BundleCreated(msg.sender, keccak256("UPDATE_LEVERAGE"), mainBundle.length);
        emit LeverageUpdated(msg.sender, collateralAsset, borrowAsset, currentCollateral, currentLeverage, newTargetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
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
        return _call(address(generalAdapter), abi.encodeCall(IGeneralAdapter1.erc20TransferFrom, (token, from, to, amount)), 0, false, bytes32(0));
    }

    function getQuote(address tokenIn,address tokenOut, uint256 amountIn) internal returns (uint256) {
        require(tokenIn != address(0) && tokenOut != address(0), 'Invalid token address');
        return maverickAdapter.getSwapQuote(tokenIn, tokenOut, amountIn, false, 1e8);
    }
    
    function _createMaverickSwapCall(address tokenIn,address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 slippage, bool exactOutput) internal view returns (Call memory) {
        return _call(address(maverickAdapter), abi.encodeCall(MaverickSwapAdapter.swapExactTokensForTokens, (tokenIn, tokenOut, amountIn, amountOutMin, slippage, address(this), 1e8)), 0, false, bytes32(0));
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
        maverickAdapter = MaverickSwapAdapter(_newMaverickAdapter);
    }
}