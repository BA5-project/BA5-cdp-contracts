// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IOracle {
    /// @notice Oracle price for token.
    /// @param token Reference to token
    /// @return success True if call to an external oracle was successful, false otherwise
    /// @return priceX96 Price that satisfy token
    function price(address token) external view returns (bool success, uint256 priceX96);
}
