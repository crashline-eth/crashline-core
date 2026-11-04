// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpTerms} from "./IPerpSeries.sol";

/// L1 entry point of the v2 perpetual note. Permissionless, deterministic, no
/// admin. Series, NOTE and COVER are EIP-1167 clones at CREATE2 addresses
/// derived from seriesId, as in v1. Fixings come from one
/// FixingsRecorder per feed, deployed by this factory with its recorder
/// limits (fixing age, price cap, L2 sequencer check).
interface IPerpFactory {
    /// The limits every recorder of this factory is deployed with (FixingsRecorder).
    struct RecorderLimits {
        uint40 maxFixAge; // how old a fixing's round may be at its observation time
        int256 priceMax; // highest accepted answer, feed decimals; at most type(uint96).max
        address sequencer; // L2 sequencer uptime feed; 0: no check
        uint40 sequencerGrace; // no recording this long after the sequencer came back up
    }

    event RecorderDeployed(address indexed feed, address recorder);

    event PerpSeriesCreated(
        bytes32 indexed seriesId, address indexed feed, address series, address note, address cover, PerpTerms terms
    );

    error BadRecorderLimits(); // an age of 0, or a price cap outside (0, type(uint96).max]
    error BadFeed(); // no code, or not 8 decimals
    error BadSchedule(); // interval < 1 h or firstFixing == 0
    error BadBarrier(); // not 0 < k <= 10_000
    error BadMeltShare(); // not 0 < a < 1e18
    error BadCouponReserve(); // R > MAX_COUPON_RESERVE, or not a whole number of bps (a multiple of 100)

    function collateral() external view returns (address); // USDC, immutable
    function recorderLimits() external view returns (RecorderLimits memory);

    function seriesId(PerpTerms calldata terms) external pure returns (bytes32);
    function predictSeries(PerpTerms calldata terms) external view returns (address series, address note, address cover);
    function seriesOf(bytes32 seriesId) external view returns (address); // 0 if not created
    function isSeries(address series) external view returns (bool); // provenance check
    function allSeries() external view returns (address[] memory);
    function recorderOf(address feed) external view returns (address); // deterministic, may be undeployed
    function deployRecorder(address feed) external returns (address recorder); // idempotent

    /// Idempotent: returns the existing series for identical terms. Deploys
    /// the feed's recorder if needed.
    function createSeries(PerpTerms calldata terms) external returns (address series);
}
