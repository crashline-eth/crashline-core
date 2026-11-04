// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Chainlink AggregatorV3 plus `latestRound()`. ETH/USD and BTC/USD on Arbitrum One:
/// 8 decimals, 24/7, roundId = (phaseId << 64) | n, full `getRoundData` history.
/// Pauses show up only as staleness (`oraclePaused()` does not exist on-chain).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRound() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
