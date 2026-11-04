// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IFixingsRecorder} from "./interfaces/IFixingsRecorder.sol";
import {L2Sequencer} from "./L2Sequencer.sol";

/// L0: one recorder per feed. Permissionless and trustless: anyone can record
/// a fixing, and every recorded fixing is verified against feed rounds
/// on-chain (docs/v2-spec.md §5).
///
/// The fixing for a scheduled observation time `obsTime` is the last round
/// with updatedAt <= obsTime, at most MAX_FIX_AGE old. A round after obsTime
/// is never a fixing (RoundAfterObservation): a fixing with no round in the
/// MAX_FIX_AGE before its time is never recorded, and the series falls back
/// on its own (PerpSeries.FALLBACK_GRACE).
///
/// The limits are set by the factory that deploys the recorder, sized to the
/// feed: for ETH and BTC on Arbitrum (24/7, a 29-minute heartbeat) see
/// DeployPerp.s.sol. On an L2, nothing is recorded while the sequencer is
/// down or within its grace period (L2Sequencer): right after a restart the
/// feed's last round can predate an observation time it says nothing about.
contract FixingsRecorder is IFixingsRecorder {
    /// How old a fixing's round may be at its observation time.
    uint40 public immutable MAX_FIX_AGE;
    /// Highest accepted answer. Rejects a mis-scaled answer from an early feed round.
    int256 public immutable PRICE_MAX;
    /// The L2 sequencer uptime feed; 0: no check.
    IAggregatorV3 public immutable sequencer;
    uint40 public immutable SEQUENCER_GRACE;

    IAggregatorV3 public immutable feed;

    mapping(uint40 obsTime => Fixing) public fixings;

    error BadLimits();

    constructor(address feed_, uint40 maxFixAge, int256 priceMax, address sequencer_, uint40 sequencerGrace) {
        // the price is stored as uint96
        if (maxFixAge == 0 || priceMax <= 0 || priceMax > int256(uint256(type(uint96).max))) revert BadLimits();
        feed = IAggregatorV3(feed_);
        MAX_FIX_AGE = maxFixAge;
        PRICE_MAX = priceMax;
        sequencer = IAggregatorV3(sequencer_);
        SEQUENCER_GRACE = sequencerGrace;
    }

    function recordFixing(uint40 obsTime, uint80 roundId) external {
        L2Sequencer.check(sequencer, SEQUENCER_GRACE);
        // Strictly in the past: several blocks share a timestamp, so a round
        // with updatedAt == obsTime can still arrive after this call.
        if (obsTime >= block.timestamp) revert FutureObservation(obsTime);
        if (fixings[obsTime].timestamp != 0) revert AlreadyRecorded(obsTime);

        (int256 answer, uint40 updatedAt) = _round(roundId);
        if (answer <= 0 || answer > PRICE_MAX) revert BadPrice(answer);

        // At or before obsTime, and fresh enough.
        if (updatedAt > obsTime) revert RoundAfterObservation(roundId, obsTime);
        if (obsTime - updatedAt > MAX_FIX_AGE) revert FixingTooStale(updatedAt, obsTime);
        // The last such round: the next round is after obsTime, or there is none and this is the
        // feed's latest round. A feed may revert for a round it doesn't have (the mocks) or answer
        // zeros (Chainlink's OCR aggregators). That also refuses the last round of an earlier phase:
        // the next aggregator's rounds overlap it in time, and one of them is the fixing (it ran for
        // weeks before the switch).
        bool hasNext = false;
        try feed.getRoundData(roundId + 1) returns (uint80, int256, uint256, uint256 nextUpdatedAt, uint80) {
            hasNext = nextUpdatedAt != 0;
            if (hasNext && nextUpdatedAt <= obsTime) revert NotLastRoundBefore(roundId, obsTime);
        } catch {}
        if (!hasNext && roundId != feed.latestRound()) revert NotLastRoundBefore(roundId, obsTime);

        // 0 < answer <= PRICE_MAX <= type(uint96).max (constructor)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 price = uint96(uint256(answer));
        fixings[obsTime] = Fixing({timestamp: updatedAt, price: price, roundId: roundId});
        emit FixingRecorded(obsTime, roundId, price, updatedAt);
    }

    function fixingOf(uint40 obsTime) external view returns (Fixing memory) {
        return fixings[obsTime];
    }

    function isRecorded(uint40 obsTime) external view returns (bool) {
        return fixings[obsTime].timestamp != 0;
    }

    function _round(uint80 roundId) internal view returns (int256 answer, uint40 updatedAt) {
        uint256 u;
        // forge-lint: disable-next-line(unused-return)
        (, answer,, u,) = feed.getRoundData(roundId);
        // unix seconds fit uint40 until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        updatedAt = uint40(u);
    }
}
