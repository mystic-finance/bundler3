// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IMaverickV2Pool} from "./IMaverickV2Pool.sol";

/**
 * @title IMaverickV2Factory
 * @notice Interface for Maverick V2 Factory
 */
interface IMaverickV2Factory {
    function lookup(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 startIndex,
        uint256 count
    ) external view returns (IMaverickV2Pool[] memory pools);
} 