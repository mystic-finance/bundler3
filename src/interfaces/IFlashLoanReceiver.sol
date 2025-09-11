// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/**
 * @title IFlashLoanReceiver
 * @notice Interface for Aave V3 Flash Loan receiver implementation
 * @dev Any contract that wants to receive flash loans from Aave must implement this interface
 */
interface IFlashLoanReceiver {
    /**
     * @notice Executes an operation after receiving the flash-borrowed assets
     * @param assets The addresses of the flash-borrowed assets
     * @param amounts The amounts of the flash-borrowed assets
     * @param premiums The fee that must be repaid alongside the borrowed amount for each asset
     * @param initiator The address of the flashloan initiator
     * @param params Arbitrary bytes passed from the flash loan initiator
     * @return success Whether the operation was successful or not (must return true)
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
} 