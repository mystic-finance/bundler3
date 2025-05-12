// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IMaverickV2Pool} from "../interfaces/IMaverickV2Pool.sol";
import {IMaverickV2Factory} from "../interfaces/IMaverickV2Factory.sol";
import {IMaverickV2Quoter} from "../interfaces/IMaverickV2Quoter.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MaverickSwapAdapter
 * @notice Adapter for interacting with Maverick V2 pools
 * @dev Handles token transfers and swap execution with smart balance management
 */
contract MaverickSwapAdapter is Ownable {
    using SafeERC20 for IERC20;
    
    IMaverickV2Factory public immutable factory;
    IMaverickV2Quoter public immutable quoter;
    
    uint256 public constant SLIPPAGE_SCALE = 10000; // 10000 = 100%
    
    constructor(address _factory, address _quoter) Ownable(msg.sender) {
        factory = IMaverickV2Factory(_factory);
        quoter = IMaverickV2Quoter(_quoter);
    }

    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 slippage,
        address to,
        int32 tickRange
    ) external returns (uint256 amountOut) {
        // Get the best pool for this pair
        IMaverickV2Pool pool = getBestPool(tokenIn, tokenOut);
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));

        if (amountIn == type(uint256).max || amountIn > balance) {
            amountIn = balance;
            amountOutMin = amountIn * slippage / SLIPPAGE_SCALE;
        }
        
        IERC20(tokenIn).safeTransfer(address(pool), amountIn);
        bool tokenAIn = address(pool.tokenA()) == tokenIn;
        int32 tickLimit = tokenAIn ? type(int32).max : type(int32).min;
        
        IMaverickV2Pool.SwapParams memory swapParams = IMaverickV2Pool.SwapParams({
            amount: amountIn,
            tokenAIn: tokenAIn,
            exactOutput: false,
            tickLimit: tickLimit
        });
        
        (, uint256 amountOutReceived) = pool.swap{gas: 800_000}(to, swapParams, "");
        require(amountOutReceived >= amountOutMin, "Insufficient output amount");
        return amountOutReceived;
    }

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool exactOutput,
        int32 tickRange
    ) external returns (uint256 expectedOut) {
        IMaverickV2Pool pool = getBestPool(tokenIn, tokenOut);
        bool tokenAIn = address(pool.tokenA()) == tokenIn;
        // int32 tickLimit = tokenAIn ? pool.getState().activeTick + tickRange : pool.getState().activeTick - tickRange;
        int32 tickLimit = tokenAIn ? type(int32).max : type(int32).min;

        (, uint256 expectedAmount, ) = quoter.calculateSwap{gas: 800_000}(
            pool,
            uint128(amountIn),
            tokenAIn,
            exactOutput,
            tickLimit
        );
        
        return expectedAmount;
    }
    
    function getBestPool(address tokenIn, address tokenOut) public view returns (IMaverickV2Pool) {
        IMaverickV2Pool[] memory pools = factory.lookup(IERC20(tokenIn), IERC20(tokenOut), 0, 100);
        require(pools.length > 0, "No pool available");
        
        IMaverickV2Pool bestPool = pools[0];
        uint256 bestLiquidity = 0;
        
        for (uint64 i = 0; i < pools.length; i++) {
            IMaverickV2Pool pool = pools[i];
            uint256 liquidity = pool.getState().reserveA + pool.getState().reserveB;
            
            if (liquidity > bestLiquidity) {
                bestLiquidity = liquidity;
                bestPool = pool;
            }
        }
        
        return bestPool;
    }
    
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}