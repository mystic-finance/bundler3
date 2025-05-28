// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IWNative} from "../interfaces/IWNative.sol";
import {IERC4626} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {CoreAdapter, ErrorsLib, IERC20, SafeERC20, Address} from "./CoreAdapter.sol";
import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MathRayLib} from "../libraries/MathRayLib.sol";
import {SafeCast160} from "../../lib/permit2/src/libraries/SafeCast160.sol";
import {Permit2Lib} from "../../lib/permit2/src/libraries/Permit2Lib.sol";
import {IAaveV3 as IPool, ReserveDataMap as ReserveData, IAaveProvider, ReserveConfigurationMap} from "../interfaces/IAaveV3.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IAavePriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Chain agnostic adapter contract for Mystic V3.
contract MysticAdapter is CoreAdapter, Ownable, IFlashLoanReceiver {
    using SafeCast160 for uint256;
    using MathRayLib for uint256;
    uint256 public constant INTEREST_RATE_MODE_STABLE = 1;
    uint256 public constant INTEREST_RATE_MODE_VARIABLE = 2;
    uint16 public constant REFERRAL_CODE = 0;
    IPool public immutable MYSTIC_POOL;
    IWNative public immutable WRAPPED_NATIVE;
    constructor(address bundler3, address mysticPool, address wNative) CoreAdapter(bundler3) Ownable(msg.sender) {
        require(mysticPool != address(0), ErrorsLib.ZeroAddress());
        require(wNative != address(0), ErrorsLib.ZeroAddress());
        
        MYSTIC_POOL = IPool(mysticPool);
        WRAPPED_NATIVE = IWNative(wNative);
    }

    function flashLoanFee(uint256 amount) external view returns (uint256) {
        return MYSTIC_POOL.FLASHLOAN_PREMIUM_TOTAL() * amount / 10000;
    }

    function mysticSupply(address asset, uint256 amount, address onBehalf, bool useAsCollateral)
        external
        onlyBundler3
    {
        require(onBehalf != address(this), ErrorsLib.AdapterAddress());

        if (amount == type(uint256).max) {
            amount = IERC20(asset).balanceOf(address(this));
            require(amount != 0, ErrorsLib.ZeroAmount());
        }

        SafeERC20.forceApprove(IERC20(asset), address(MYSTIC_POOL), type(uint256).max);
        MYSTIC_POOL.supply(asset, amount, onBehalf, REFERRAL_CODE);
        SafeERC20.safeTransfer(IERC20(asset), onBehalf,  IERC20(asset).balanceOf(address(this)));
    }

    function mysticWithdraw(address asset, uint256 amount, address onBehalf, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0) || receiver == address(this), ErrorsLib.ZeroAddress());
        require(amount != 0, ErrorsLib.ZeroAmount());
        ReserveData memory reserveData = IPool(address(MYSTIC_POOL)).getReserveData(asset);
        uint256 balance = IERC20(reserveData.aTokenAddress).balanceOf(onBehalf);

        if(amount == type(uint256).max) {
            amount = getWithdrawableLiquidity(onBehalf, asset);
            require(amount != 0, ErrorsLib.ZeroAmount());
        }

        if(amount > balance) {
            amount = balance;
        }
        
        SafeERC20.safeTransferFrom(IERC20(reserveData.aTokenAddress), onBehalf, address(this), amount);
        uint256 withdrawnAmount = MYSTIC_POOL.withdraw(asset, amount, receiver);
        require(withdrawnAmount > 0, ErrorsLib.ZeroAmount());
        SafeERC20.safeTransfer(IERC20(reserveData.aTokenAddress), onBehalf,  IERC20(reserveData.aTokenAddress).balanceOf(address(this))); //refund any remaining atoken
    }

    function mysticBorrow(address asset, uint256 amount, uint256 interestRateMode, address from, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(amount != 0, ErrorsLib.ZeroAmount());
        require(
            interestRateMode == INTEREST_RATE_MODE_STABLE || interestRateMode == INTEREST_RATE_MODE_VARIABLE,
            ErrorsLib.WithdrawFailed()
        );

        address initiator = initiator();
        if(from != address(0)) initiator = from;
        
        if(amount == type(uint256).max) {
            amount = getBorrowableLiquidity(initiator, asset);
            require(amount != 0, ErrorsLib.ZeroAmount());
        }

        MYSTIC_POOL.borrow(asset, amount, interestRateMode, REFERRAL_CODE, initiator);
        
        if (receiver != address(this)) {
            SafeERC20.safeTransfer(IERC20(asset), receiver,  IERC20(asset).balanceOf(address(this)));
        }
    }

    function mysticRepay(address asset, uint256 amount, uint256 interestRateMode, address onBehalf)
        external
        onlyBundler3
    {
        require(onBehalf != address(this), ErrorsLib.AdapterAddress());
        require(
            interestRateMode == INTEREST_RATE_MODE_STABLE || interestRateMode == INTEREST_RATE_MODE_VARIABLE,
            ErrorsLib.DepositFailed()
        );

        if (amount == type(uint256).max) {
            amount = IERC20(asset).balanceOf(address(this));
            require(amount != 0, ErrorsLib.ZeroAmount());
        }

        SafeERC20.forceApprove(IERC20(asset), address(MYSTIC_POOL), type(uint256).max);
        uint256 repaidAmount = MYSTIC_POOL.repay(asset, amount, interestRateMode, onBehalf);
        require(repaidAmount > 0, ErrorsLib.ZeroAmount());
        SafeERC20.safeTransfer(IERC20(asset), onBehalf,  IERC20(asset).balanceOf(address(this)));
    }

    function mysticSetUserUseReserveAsCollateral(address asset, bool useAsCollateral)
        external
        onlyBundler3
    {
        MYSTIC_POOL.setUserUseReserveAsCollateral(asset, useAsCollateral);
    }

    /// @notice Triggers a flash loan on Mystic.
    function mysticFlashLoan(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        bytes calldata data
    ) 
        external 
        onlyBundler3 
    {
        require(assets.length > 0, ErrorsLib.DepositFailed());
        require(assets.length == amounts.length, ErrorsLib.DepositFailed());
        require(assets.length == interestRateModes.length, ErrorsLib.DepositFailed());
        
        for (uint256 i = 0; i < assets.length; i++) {
            require(amounts[i] != 0, ErrorsLib.ZeroAmount());
            
            // Mystic's allowance is not reset as it is trusted.
            SafeERC20.forceApprove(IERC20(assets[i]), address(MYSTIC_POOL), type(uint256).max);
        }

        MYSTIC_POOL.flashLoan(
            address(this),
            assets,
            amounts,
            interestRateModes,
            address(this),
            data,
            REFERRAL_CODE
        );
    }

    function permit2TransferFrom(address token, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(initiator);
        require(amount != 0, ErrorsLib.ZeroAmount());
        Permit2Lib.PERMIT2.transferFrom(initiator, receiver, amount.toUint160(), token);
    }

    function erc20TransferFrom(address token, address from, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if(from != address(0)) initiator = from;
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(initiator);

        require(amount != 0, ErrorsLib.ZeroAmount());
        SafeERC20.safeTransferFrom(IERC20(token), initiator, receiver, amount);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(MYSTIC_POOL), ErrorsLib.UnauthorizedSender());
        require(initiator == address(this), ErrorsLib.UnauthorizedSender());
        
        reenterBundler3(params);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountOwed = amounts[i] + premiums[i];
            SafeERC20.forceApprove(IERC20(assets[i]), address(MYSTIC_POOL), amountOwed);
        }
        return true;
    }

    function getAvailableLiquidity(address asset) external view returns (uint256) {
        ReserveData memory reserveData = MYSTIC_POOL.getReserveData(asset);
        return IERC20(asset).balanceOf(reserveData.aTokenAddress);
    }

    function getMainUserAccountData(address user) public view returns (uint256, uint256, uint256, uint256, uint256) {
         (uint256 totalCollateral, uint256 totalDebt , uint256 availableBorrowsETH, ,uint256 ltv , uint256 healthfactor) = MYSTIC_POOL.getUserAccountData(user);
         return (totalCollateral,totalDebt, availableBorrowsETH, ltv, healthfactor);
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        return IAavePriceOracle(IAaveProvider(MYSTIC_POOL.ADDRESSES_PROVIDER()).getPriceOracle()).getAssetPrice(address(asset));
    }

    function getAssetLtv(address asset) external view returns (uint256) {
        ReserveData memory reserveData = MYSTIC_POOL.getReserveData(asset);
        uint256 LTV_MASK = 0xFFFF;
        uint256 LTV_START_BIT_POSITION = 0;
        uint256 ltv = (reserveData.configuration.data & LTV_MASK) >> LTV_START_BIT_POSITION;
        return ltv;
    }

    function getBorrowableLiquidity(address user, address asset) public view returns (uint256) {
        address[] memory reserves = MYSTIC_POOL.getReservesList();
        uint256 totalCollateralETH = 0;
        uint256 totalDebtETH = 0;
        uint256 LTV_MASK = 0xFFFF;
        uint256 LTV_START_BIT_POSITION = 0;
        
        for (uint256 i = 0; i < reserves.length; i++) {
            address reserve = reserves[i];
            ReserveData memory reserveData = MYSTIC_POOL.getReserveData(reserve);
            uint256 assetPrice = getAssetPrice(reserve);
            uint256 decimals = IERC20Metadata(reserve).decimals();
            uint256 aTokenBalance = IERC20(reserveData.aTokenAddress).balanceOf(user);
            uint256 vDebtBalance = IERC20(reserveData.variableDebtTokenAddress).balanceOf(user);
            uint256 sDebtBalance = IERC20(reserveData.stableDebtTokenAddress).balanceOf(user);

            if (aTokenBalance > 0) {
                uint256 ltv = (reserveData.configuration.data & LTV_MASK) >> LTV_START_BIT_POSITION;
                ltv = ltv * 10**23;  // (10^27 / 10^4)
                uint256 collateralValueETH = (aTokenBalance * assetPrice * ltv) / (10**decimals * 10**27);
                totalCollateralETH += collateralValueETH;
            }

            if (vDebtBalance > 0 || sDebtBalance > 0) {
                uint256 debtValueETH = ((vDebtBalance + sDebtBalance) * assetPrice) / (10**decimals);
                totalDebtETH += debtValueETH;
            }
        }
        
        uint256 borrowableLiquidityETH = totalCollateralETH > totalDebtETH ?  totalCollateralETH - totalDebtETH : 0;        
        uint256 assetPrice = getAssetPrice(asset);
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        return (borrowableLiquidityETH * 10**assetDecimals) / assetPrice;
    }

    function getWithdrawableLiquidity(address user, address asset) public view returns(uint256) {
        ReserveData memory reserveData = IPool(address(MYSTIC_POOL)).getReserveData(asset);
        uint256 balance = IERC20(reserveData.aTokenAddress).balanceOf(user);
        uint256 amount = getBorrowableLiquidity(user, asset);

        if(amount > balance){
            amount = balance;
        }
        return amount;
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}