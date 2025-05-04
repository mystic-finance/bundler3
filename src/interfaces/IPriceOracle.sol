interface IAavePriceOracle {
    /**
     * @dev returns the asset price in ETH
     * @param asset the address of the asset
     * @return the ETH price of the asset
     **/
    function getAssetPrice(address asset) external view returns (uint256);
}