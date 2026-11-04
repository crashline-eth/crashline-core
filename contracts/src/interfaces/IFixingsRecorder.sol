// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "./IAggregatorV3.sol";

/// L0: one recorder per feed. Permissionless and trustless: anyone records the
/// fixing for an observation time by naming a feed round, and the recorder
/// proves on-chain that it is the right one (docs/v2-spec.md §5): the last
/// round with updatedAt <= obsTime, at most MAX_FIX_AGE old. A round after
/// obsTime is refused, so a fixing with no round in the MAX_FIX_AGE before its
/// time is never recorded; the series falls back on its own (IPerpSeries).
/// Finding the round is off-chain work (binary search over getRoundData).
/// The limits are per recorder, set by the factory that deploys it. With an
/// uptime feed set, recording reverts L2Sequencer.SequencerDown /
/// SequencerGracePeriod while the sequencer is down or just back up.
interface IFixingsRecorder {
    struct Fixing {
        uint40 timestamp; // the feed round's updatedAt, not obsTime; 0 = not recorded
        uint96 price; // feed decimals (8)
        uint80 roundId;
    }

    event FixingRecorded(uint40 indexed obsTime, uint80 roundId, uint96 price, uint40 timestamp);

    error AlreadyRecorded(uint40 obsTime);
    error FutureObservation(uint40 obsTime);
    error BadPrice(int256 answer);
    error NotLastRoundBefore(uint80 roundId, uint40 obsTime);
    error FixingTooStale(uint40 updatedAt, uint40 obsTime);
    error RoundAfterObservation(uint80 roundId, uint40 obsTime); // its updatedAt is after obsTime: never a fixing

    function feed() external view returns (IAggregatorV3);
    function MAX_FIX_AGE() external view returns (uint40);
    function PRICE_MAX() external view returns (int256);
    function sequencer() external view returns (IAggregatorV3); // L2 sequencer uptime feed; 0: no check
    function SEQUENCER_GRACE() external view returns (uint40);

    function recordFixing(uint40 obsTime, uint80 roundId) external;
    function fixingOf(uint40 obsTime) external view returns (Fixing memory);
    function isRecorded(uint40 obsTime) external view returns (bool);
}
