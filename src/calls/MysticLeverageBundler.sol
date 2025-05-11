// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBundler3, Call} from "../interfaces/IBundler3.sol";
import {IMaverickV2Pool} from "../interfaces/IMaverickV2Pool.sol";
import {IMaverickV2Factory} from "../interfaces/IMaverickV2Factory.sol";
import {IMaverickV2Quoter} from "../interfaces/IMaverickV2Quoter.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IMysticAdapter} from "../interfaces/IMysticAdapter.sol";
import { IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {MaverickSwapAdapter} from "../adapters/MaverickAdapter.sol";


/**
 * @title MysticLeverageBundler
 * @notice Creates bundles of calls for leveraged positions on Mystic using flashloans and Maverick swap
 * @dev Uses bundler to create sequences of calls for execution in a single transaction
 */
// we expect leverage against derivatives ie nrwa/pusd, ntbill/pusd, nelixir/pusd
contract MysticLeverageBundler is Ownable {
    // Bundler contract
    IBundler3 public immutable bundler;
    IMysticAdapter public mysticAdapter;
    MaverickSwapAdapter public maverickAdapter;
    
    // Constants
    uint256 public constant SLIPPAGE_SCALE = 10000; // 10000 = 100%
    uint256 public constant DEFAULT_SLIPPAGE = 9700; // 97%, or 3% slippage allowance
    uint256 public constant VARIABLE_RATE_MODE = 2; // Mystic variable interest rate mode

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
        address _mysticAdapter,
        address _maverickAdapter
    ) Ownable(msg.sender) {
        bundler = IBundler3(_bundler);
        mysticAdapter = IMysticAdapter(_mysticAdapter);
        maverickAdapter = MaverickSwapAdapter(_maverickAdapter);
    }

    function getPairKey(address borrowToken, address collateralToken) public view returns (bytes32) {
        uint256 borrowPrice = mysticAdapter.getAssetPrice(borrowToken);
        uint256 collateralPrice = mysticAdapter.getAssetPrice(collateralToken);
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
            require(totalBorrowsPerUser[pairKey][user] < totalCollateralsPerUser[pairKey][user],  "Leverage too high");
        } else {
            totalBorrows[pairKey] -= borrowAmount;
            totalCollaterals[pairKey] -= collateralAmount;
            totalBorrowsPerUser[pairKey][user] -= borrowAmount;
            totalCollateralsPerUser[pairKey][user] -= collateralAmount;
            require(totalBorrowsPerUser[pairKey][user] <= totalCollateralsPerUser[pairKey][user],  "Leverage too high");
        }
    }

    function createOpenLeverageBundle(address asset, address collateralAsset, address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance) external returns (Call[] memory bundle) {
      require(initialCollateralAmount > 0, "Zero collateral amount");
      require(targetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
      require(targetLeverage <= 1000000, "Leverage too high");
      
      uint256 positionSize = initialCollateralAmount * targetLeverage / SLIPPAGE_SCALE;

      IERC20(collateralAsset).approve(address(mysticAdapter), type(uint256).max);
      IERC20(asset).approve(address(mysticAdapter), type(uint256).max);
      
      // Check if there's enough liquidity for flashloan
      if (mysticAdapter.getAvailableLiquidity(asset) > positionSize) {
          return _createOpenLeverageBundleWithFlashloan(asset, collateralAsset, inputAsset, initialCollateralAmount, targetLeverage, slippageTolerance);
      } else { // loop can still accomodate smaller leverages even with insufficient liqudiity in a pool, there will be a warning in the frontend though
          return _createOpenLeverageBundleWithLoops(asset, collateralAsset, inputAsset, initialCollateralAmount, targetLeverage, slippageTolerance);
      }
    }
    function _createOpenLeverageBundleWithFlashloan(address asset, address collateralAsset, address inputAsset, uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance) internal returns (Call[] memory bundle) {
        require(inputAsset == collateralAsset || inputAsset == asset, "Input asset must be the same as collateral asset or asset");
        uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        uint256 collateralValue = initialCollateralAmount; //inputAsset == collateralAsset ? initialCollateralAmount : getQuote(inputAsset, collateralAsset, initialCollateralAmount);
        uint256 positionSize = collateralValue * targetLeverage / SLIPPAGE_SCALE;
        uint256 borrowAmount = positionSize - collateralValue;  //getQuote(collateralAsset, asset, positionSize - collateralValue);
        bytes32 pairKey = getPairKey(asset, collateralAsset);
        
        Call[] memory mainBundle = new Call[](2);
        Call[] memory flashloanCallbackBundle = new Call[](5);
        uint256 totalBorrowAmount = borrowAmount + mysticAdapter.flashLoanFee(borrowAmount) + 1; // +1 for rounding buffer
        uint256 totalCollateralAmount = 0;  // this is meant to force accuracy of collateral (and reduce discrepancy due to swap output)
        if (inputAsset == collateralAsset) {
            // When input is collateral: direct calculation, Calculate total collateral after leverage (initial + converted borrowed)
            totalCollateralAmount = collateralValue + getQuote(asset, collateralAsset, borrowAmount);
        } else {
            // When input is borrowing asset: calculate total borrowing first
            totalCollateralAmount = getQuote(asset, collateralAsset, positionSize);
        }

        // Compressed callback bundle creation
        flashloanCallbackBundle[0] = _createERC20TransferCall(asset, address(maverickAdapter), type(uint256).max);
        flashloanCallbackBundle[1] = _createMaverickSwapCall(asset, collateralAsset, type(uint256).max, 0, slippage, false);
        flashloanCallbackBundle[2] = _createERC20TransferFromCall(collateralAsset, address(this), address(mysticAdapter), type(uint256).max);
        flashloanCallbackBundle[3] = _createMysticSupplyCall( collateralAsset, type(uint256).max, msg.sender);
        flashloanCallbackBundle[4] = _createMysticBorrowCall(asset, totalBorrowAmount, VARIABLE_RATE_MODE, msg.sender, address(mysticAdapter));

        // Compressed main bundle creation
        mainBundle[0] = inputAsset == collateralAsset ? _createERC20TransferFromCall(collateralAsset,msg.sender,address(this),initialCollateralAmount) : _createERC20TransferFromCall(asset,msg.sender,address(maverickAdapter),initialCollateralAmount);
        mainBundle[1] = _createMysticFlashloanCall(asset,borrowAmount,false,abi.encode(flashloanCallbackBundle));

        bundler.multicall(mainBundle);
        updatePositionTracking(pairKey, totalBorrowAmount, totalCollateralAmount, msg.sender, true);
        
        emit BundleCreated(msg.sender, keccak256("OPEN_LEVERAGE"), mainBundle.length);
        emit LeverageOpened(msg.sender, collateralAsset, asset, initialCollateralAmount, targetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        
        return mainBundle;
    }

    function _createOpenLeverageBundleWithLoops(address asset, address collateralAsset, address inputAsset,  uint256 initialCollateralAmount, uint256 targetLeverage, uint256 slippageTolerance) internal returns (Call[] memory bundle) {
        // very expensive gas wise, with a limit of 25 loops(4x leverage), and extremely ineffective, only to be used if pool cannot fulfill flashloan
        // we understand that iterations != leverage but fo the sake of limiting gas, we assume iteration == loop instead of 1-ltv**(n+1)/1-ltv, where n is iteration
        require(inputAsset == collateralAsset, "Input asset must be the same as collateral asset");
        uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
        uint256 ltv = mysticAdapter.getAssetLtv(collateralAsset);
        uint8 loop = 20;
        bytes32 pairKey = getPairKey(asset, collateralAsset);
        require(ltv > 0, "Collateral asset has no LTV");
        
        Call[] memory mainBundle = new Call[](2+ loop*4);
        mainBundle[0] = _createERC20TransferFromCall(inputAsset,msg.sender,address(mysticAdapter),initialCollateralAmount);
        mainBundle[1] = _createMysticSupplyCall( collateralAsset, type(uint256).max, msg.sender);
        uint256 newCollateral = initialCollateralAmount;
        totalCollaterals[pairKey] += newCollateral;
        totalCollateralsPerUser[pairKey][msg.sender] += newCollateral;

        for (uint8 i=0; i< loop; i++){
          uint256 idx = 2 + i * 4;
          mainBundle[idx] = _createMysticBorrowCall(asset, type(uint256).max, VARIABLE_RATE_MODE, msg.sender, address(maverickAdapter));
          mainBundle[idx+1] = _createMaverickSwapCall(asset, collateralAsset, type(uint256).max, 0, slippage, false);
          mainBundle[idx+2] = _createERC20TransferFromCall(collateralAsset, address(this), address(mysticAdapter), type(uint256).max);
          mainBundle[idx+3] = _createMysticSupplyCall( collateralAsset, type(uint256).max, msg.sender);

          newCollateral = newCollateral * ltv / SLIPPAGE_SCALE;
          uint256 newBorrow = getQuote(collateralAsset, asset, newCollateral) * ltv / SLIPPAGE_SCALE;
          updatePositionTracking(pairKey, newBorrow, newCollateral, msg.sender, true);
          
          uint leverage = (totalCollateralsPerUser[pairKey][msg.sender]) * SLIPPAGE_SCALE / (totalCollateralsPerUser[pairKey][msg.sender] - totalBorrowsPerUser[pairKey][msg.sender]);
          if (leverage >= (targetLeverage * 9000) / SLIPPAGE_SCALE) break; // break if leverage gotten is in similar range as expected 10% error margin 4 -> 3.6 is fine
        }
        require(totalBorrowsPerUser[pairKey][msg.sender] < totalCollateralsPerUser[pairKey][msg.sender], "Leverage too high");

        bundler.multicall(mainBundle);

        emit BundleCreated(msg.sender, keccak256("OPEN_LEVERAGE"), mainBundle.length);
        emit LeverageOpened(msg.sender, collateralAsset, asset, initialCollateralAmount, targetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
        return mainBundle;
    }

    function createCloseLeverageBundle(address asset, address collateralAsset, uint256 debtToClose) external returns (Call[] memory bundle) {
      bytes32 pairKey = getPairKey(asset, collateralAsset);
      if(debtToClose == type(uint256).max || totalBorrowsPerUser[pairKey][msg.sender] <= debtToClose) {
        debtToClose = totalBorrowsPerUser[pairKey][msg.sender];
      }

      require(debtToClose > 0, "no debt found");
      
      // Check if there's enough liquidity for flashloan or if we're closing a small position
      if (mysticAdapter.getAvailableLiquidity(asset) > debtToClose) {
        return _createCloseLeverageBundleWithFlashloan(asset, collateralAsset, debtToClose);
      } else {
        return _createCloseLeverageBundleWithLoops(asset, collateralAsset, debtToClose);
      }
    }
    
    function _createCloseLeverageBundleWithFlashloan(address asset, address collateralAsset, uint256 debtToClose) internal returns (Call[] memory bundle) {
        Call[] memory mainBundle = new Call[](5);
        Call[] memory flashloanCallbackBundle = new Call[](4);
        bytes32 pairKey = getPairKey(asset, collateralAsset);
        uint256 debtToCover = debtToClose;
        uint256 totalBorrowAmount = debtToCover + mysticAdapter.flashLoanFee(debtToCover) + 1; // +1 for rounding buffer, plus new fee
        uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * debtToClose) / totalBorrowsPerUser[pairKey][msg.sender];
        collateralForRepayment = collateralForRepayment > totalCollateralsPerUser[pairKey][msg.sender]? totalCollateralsPerUser[pairKey][msg.sender]: collateralForRepayment; //safeguard to avoid overflow
                
         // Compressed callback bundle creation
        flashloanCallbackBundle[0] = _createMysticRepayCall(asset, debtToCover, VARIABLE_RATE_MODE, msg.sender);
        flashloanCallbackBundle[1] = _createMysticWithdrawCall(collateralAsset, collateralForRepayment, msg.sender, address(maverickAdapter));
        flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, asset, collateralForRepayment, totalBorrowAmount , 0, false);
        flashloanCallbackBundle[3] = _createERC20TransferFromCall(asset, address(this), address(mysticAdapter), type(uint256).max);
        // Compressed main bundle creation
        mainBundle[0] = _createMysticFlashloanCall(asset,debtToCover,false, abi.encode(flashloanCallbackBundle));
        mainBundle[1] = _createERC20TransferCall(asset, address(maverickAdapter), type(uint256).max);
        mainBundle[2] = _createMaverickSwapCall(asset, collateralAsset, type(uint256).max, 0 , 0, false);
        mainBundle[3] = _createERC20TransferCall(collateralAsset, address(this), type(uint256).max);
        mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
        
        bundler.multicall(mainBundle);
        updatePositionTracking(pairKey, debtToCover, collateralForRepayment, msg.sender, false);

        emit BundleCreated(msg.sender, keccak256("CLOSE_LEVERAGE"), mainBundle.length);
        emit LeverageClosed(msg.sender, collateralAsset, asset, collateralForRepayment, totalCollaterals[pairKey], totalBorrows[pairKey]);
        
        return mainBundle;
    }

    function _createCloseLeverageBundleWithLoops(address asset, address collateralAsset, uint256 debtToClose) internal returns (Call[] memory bundle) {
      bytes32 pairKey = getPairKey(asset, collateralAsset);
      uint256 collateralToWithdraw = (totalCollateralsPerUser[pairKey][msg.sender] * debtToClose) / totalBorrowsPerUser[pairKey][msg.sender];
      uint256 leverage = (totalCollateralsPerUser[pairKey][msg.sender]) / (totalCollateralsPerUser[pairKey][msg.sender] - totalBorrowsPerUser[pairKey][msg.sender]);
      uint256 ltv = mysticAdapter.getAssetLtv(collateralAsset);
      uint8 numLoops = 20;
      uint256 remainingDebt = debtToClose;
      uint256 borrowable = mysticAdapter.getWithdrawableLiquidity(msg.sender, collateralAsset);
      Call[] memory mainBundle = new Call[](numLoops * 4+1); 
      
      // For each loop iteration
      for (uint8 i = 0; i < numLoops; i++) {
          uint256 baseIndex = i * 4;
          mainBundle[baseIndex + 0] = _createMysticWithdrawCall(collateralAsset, type(uint256).max, msg.sender, address(maverickAdapter));
          mainBundle[baseIndex + 1] = _createMaverickSwapCall(collateralAsset, asset, type(uint256).max, 0, 0, false);
          mainBundle[baseIndex + 2] = _createERC20TransferFromCall(asset, address(this), address(mysticAdapter), type(uint256).max);
          mainBundle[baseIndex + 3] = _createMysticRepayCall(asset, type(uint256).max, VARIABLE_RATE_MODE, msg.sender);
          
          remainingDebt = remainingDebt > borrowable? remainingDebt - borrowable:0;
          borrowable = borrowable * SLIPPAGE_SCALE/ ltv;
          if(remainingDebt == 0) break;
      }
      
      mainBundle[numLoops * 4] = _createMysticWithdrawCall(collateralAsset, type(uint256).max, msg.sender, msg.sender);
      uint spentCollateral = getQuote(asset, collateralAsset, debtToClose - remainingDebt);
      bundler.multicall(mainBundle);
      updatePositionTracking(pairKey, debtToClose - remainingDebt, spentCollateral, msg.sender, false);
      
      emit BundleCreated(msg.sender, keccak256("CLOSE_LEVERAGE_LOOPS"), mainBundle.length);
      emit LeverageClosed(msg.sender, collateralAsset, asset, collateralToWithdraw, totalCollaterals[pairKey], totalBorrows[pairKey]);
      
      return mainBundle;
  }
    
  
  function updateLeverageBundle(
      address asset,
      address collateralAsset,
      uint256 newTargetLeverage,
      uint256 slippageTolerance
  ) external returns (Call[] memory bundle) {
      require(newTargetLeverage > SLIPPAGE_SCALE, "Leverage must be > 1");
      require(newTargetLeverage <= 1000000, "Leverage too high"); // Max 100x
      bytes32 pairKey = getPairKey(asset, collateralAsset);
      uint256 slippage = slippageTolerance == 0 ? DEFAULT_SLIPPAGE : slippageTolerance;
      uint256 currentCollateral = totalCollateralsPerUser[pairKey][msg.sender];
      uint256 currentBorrow = totalBorrowsPerUser[pairKey][msg.sender];

      require(currentCollateral > 0 && currentBorrow > 0, "No existing position");
      uint256 currentLeverage = (currentCollateral * SLIPPAGE_SCALE) / (currentCollateral - currentBorrow);
      uint256 newBorow =  currentBorrow * (newTargetLeverage - SLIPPAGE_SCALE) * currentLeverage / (newTargetLeverage * (currentLeverage - SLIPPAGE_SCALE)); //getQuote(collateralAsset, asset, currentCollateral * (newTargetLeverage - SLIPPAGE_SCALE) / newTargetLeverage);
      int256 borrowDelta = int256(newBorow) - int256(currentBorrow);
      
      // Create appropriate bundles based on the operation type
      Call[] memory mainBundle;
      Call[] memory flashloanCallbackBundle;
 
      if (borrowDelta > 0) {
          // INCREASE LEVERAGE CASE
        uint256 additionalBorrowAmount = uint256(borrowDelta);
        uint totalBorrowAmount = additionalBorrowAmount + mysticAdapter.flashLoanFee(additionalBorrowAmount) + 1;

        mainBundle = new Call[](1);
        flashloanCallbackBundle = new Call[](5);
        flashloanCallbackBundle[0] = _createERC20TransferCall(asset, address(maverickAdapter), type(uint256).max);
        flashloanCallbackBundle[1] = _createMaverickSwapCall(asset, collateralAsset, type(uint256).max, 0, slippage, false);
        flashloanCallbackBundle[2] = _createERC20TransferFromCall(collateralAsset, address(this), address(mysticAdapter), type(uint256).max);
        flashloanCallbackBundle[3] = _createMysticSupplyCall( collateralAsset, type(uint256).max, msg.sender);
        flashloanCallbackBundle[4] = _createMysticBorrowCall(asset, totalBorrowAmount, VARIABLE_RATE_MODE, msg.sender, address(mysticAdapter));

        mainBundle[0] = _createMysticFlashloanCall(asset,additionalBorrowAmount,false,abi.encode(flashloanCallbackBundle));
        updatePositionTracking(pairKey, additionalBorrowAmount, 0, msg.sender, true);
      } else if (borrowDelta < 0) {
        uint256 repayAmount = uint256(-borrowDelta);
        uint256 collateralForRepayment = (totalCollateralsPerUser[pairKey][msg.sender] * repayAmount) / totalBorrowsPerUser[pairKey][msg.sender];
          
        mainBundle = new Call[](5);
        flashloanCallbackBundle = new Call[](4);

        flashloanCallbackBundle[0] = _createMysticRepayCall(asset, repayAmount, VARIABLE_RATE_MODE, msg.sender);
        flashloanCallbackBundle[1] = _createMysticWithdrawCall(collateralAsset, collateralForRepayment, msg.sender, address(maverickAdapter));
        flashloanCallbackBundle[2] = _createMaverickSwapCall(collateralAsset, asset, collateralForRepayment, repayAmount , 0, false);
        flashloanCallbackBundle[3] = _createERC20TransferFromCall(asset, address(this), address(mysticAdapter), type(uint256).max);
        // Compressed main bundle creation
        mainBundle[0] = _createMysticFlashloanCall(asset,repayAmount,false, abi.encode(flashloanCallbackBundle));
        mainBundle[1] = _createERC20TransferCall(asset,address(maverickAdapter), type(uint256).max);
        mainBundle[2] = _createMaverickSwapCall(asset, collateralAsset, type(uint256).max, 0 , 0, false);
        mainBundle[3] = _createERC20TransferCall(collateralAsset,address(this), type(uint256).max);
        mainBundle[4] = _createERC20TransferFromCall(collateralAsset, address(this), msg.sender, type(uint256).max);
        updatePositionTracking(pairKey, repayAmount, 0, msg.sender, false);
      } else {
          revert("No changes to position");
      }
      
      bundler.multicall(mainBundle);
      
      emit BundleCreated(msg.sender, keccak256("UPDATE_LEVERAGE"), mainBundle.length);
      emit LeverageUpdated(msg.sender, collateralAsset, asset, currentCollateral, currentLeverage, newTargetLeverage, totalCollaterals[pairKey], totalBorrows[pairKey]);
      
      return mainBundle;
  }
    
    function _createMysticFlashloanCall(
        address asset,
        uint256 amount,
        bool isDebtToken,
        bytes memory data
    ) internal view returns (Call memory) {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        assets[0] = asset;
        amounts[0] = amount;
        modes[0] = isDebtToken ? 2 : 0; // 0 = no debt, 2 = variable rate debt
        
        return _call(
            address(mysticAdapter), abi.encodeCall(IMysticAdapter.mysticFlashLoan, (assets,amounts,modes,data) ), 0, false, data.length == 0 ? bytes32(0) : keccak256(data)
        );
    }
    
    function _createMysticSupplyCall(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) internal view returns (Call memory) {
        return _call(
            address(mysticAdapter), abi.encodeCall(IMysticAdapter.mysticSupply, (asset,amount,onBehalfOf,true) ), 0, false, bytes32(0)
        );
    }
    
    function _createMysticWithdrawCall(
        address asset,
        uint256 amount,
        address onBehalfOf,
        address to
    ) internal view returns (Call memory) {
        return _call(
            address(mysticAdapter), abi.encodeCall(IMysticAdapter.mysticWithdraw, (asset,amount, onBehalfOf, to)), 0, false, bytes32(0)
        );
    }
    
    function _createMysticBorrowCall(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf,
        address receiver
    ) internal view returns (Call memory) {
        return _call(
          address(mysticAdapter), abi.encodeCall(IMysticAdapter.mysticBorrow, (asset,amount,interestRateMode,onBehalfOf, receiver)), 0, false, bytes32(0)
        );
    }
    
    function _createMysticRepayCall(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) internal view returns (Call memory) {
        return _call(
            address(mysticAdapter), abi.encodeCall(IMysticAdapter.mysticRepay, (asset,amount,interestRateMode,onBehalfOf)), 0, false, bytes32(0)
        );
    }
    
    function _createERC20ApproveCall(
        address token,
        address spender,
        uint256 amount
    ) internal view returns (Call memory) {
        return _call(
            token, abi.encodeCall(IERC20.approve, (spender, amount)), 0, false, bytes32(0)
        );
    }
    
    function _createERC20TransferCall(
        address token,
        address to,
        uint256 amount
    ) internal view returns (Call memory) {
        return _call(
            address(mysticAdapter), abi.encodeCall(IMysticAdapter.erc20Transfer, (token, to, amount)), 0, false, bytes32(0)
        );
    }

    function _createERC20TransferPureCall(
        address token,
        address to,
        uint256 amount
    ) internal view returns (Call memory) {
        return _call(
            address(token), abi.encodeCall(IERC20.transfer, (to, amount)), 0, false, bytes32(0)
        );
    }
    
    function _createERC20TransferFromCall(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal view returns (Call memory) {
        return _call(
            address(mysticAdapter),abi.encodeCall(IMysticAdapter.erc20TransferFrom, (token, from, to, amount)), 0, false, bytes32(0)
        );
    }

    function getQuote(
      address tokenIn,
      address tokenOut,
      uint256 amountIn
    ) internal returns (uint256) {
      require(tokenIn != address(0) && tokenOut != address(0), 'Invalid token address');
      return maverickAdapter.getSwapQuote(tokenIn, tokenOut, amountIn, false, 1e8);
    }
    function _createMaverickSwapCall(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 slippage,
        bool exactOutput
    ) internal view returns (Call memory) {
        return _call(
            address(maverickAdapter), abi.encodeCall( MaverickSwapAdapter.swapExactTokensForTokens, (tokenIn, tokenOut, amountIn, amountOutMin, slippage, address(this), 1e8)), 0, false, bytes32(0)
        );
    }

    function _call(address to, bytes memory data, uint256 value, bool skipRevert, bytes32 callbackHash)
        internal
        pure
        returns (Call memory)
    {
        require(to != address(0), "Adapter address is zero");
        return Call(to, data, value, skipRevert, callbackHash);
    }

    function updateMysticAdapter(address _newMysticAdapter) external onlyOwner {
        require(_newMysticAdapter != address(0), "Adapter address is zero");
        mysticAdapter = IMysticAdapter(_newMysticAdapter);
    }

    function updateMaverickAdapter(address _newMaverickAdapter) external onlyOwner {
        require(_newMaverickAdapter != address(0), "Adapter address is zero");
        maverickAdapter = MaverickSwapAdapter(_newMaverickAdapter);
    }
} 