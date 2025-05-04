// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IMaverickV2Pool
 * @notice Interface for Maverick V2 Pool
 */
interface IMaverickV2Pool {
    struct SwapParams {
        uint256 amount;
        bool tokenAIn;
        bool exactOutput;
        int32 tickLimit;
    }

    struct PoolState {
        uint256 reserveA;
        uint256 reserveB;
        int32 activeTick;
        // Other fields might be included in the actual implementation
    }

    function tokenA() external view returns (IERC20);
    function tokenB() external view returns (IERC20);
    function getState() external view returns (PoolState memory);
    function swap(
        address recipient,
        SwapParams calldata params,
        bytes calldata data
    ) external returns (uint256 amountIn, uint256 amountOut);
} 