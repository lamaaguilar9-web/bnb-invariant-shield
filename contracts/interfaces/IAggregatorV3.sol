// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAggregatorV3 - Chainlink / Binance Oracle Price Feed Interface
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
