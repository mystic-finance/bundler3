// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMaverickV2Pool} from "./IMaverickV2Pool.sol";

/**
 * @title IMaverickV2Quoter
 * @notice Interface for Maverick V2 Quoter
 */
interface IMaverickV2Quoter {
    function calculateSwap(
        IMaverickV2Pool pool,
        uint128 amount,
        bool tokenAIn,
        bool exactOutput,
        int32 tickLimit
    ) external  returns (uint256 amountIn, uint256 amountOut, uint256 feeAmount);
} 