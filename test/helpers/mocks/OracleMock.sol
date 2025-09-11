// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IOracle} from "../../../lib/morpho-blue/src/interfaces/IOracle.sol";

/**
 * @title OracleMock
 * @notice Mock implementation of the Oracle interface for testing
 */
contract OracleMock is IOracle {
    uint256 private _price;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
    }
    
    function price() external view override returns (uint256) {
        return _price;
    }
    
    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }
} 