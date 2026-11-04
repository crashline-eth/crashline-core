// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// Chainlink's L2 sequencer uptime check. While the Arbitrum sequencer is
/// down no feed round lands, yet the last price still looks fresh; when it
/// comes back, everything queued meanwhile executes at once, before the
/// feeds have caught up. So nothing may use a price while the sequencer is
/// down, nor for `grace` seconds after it came back up.
///
/// The uptime feed answers 0 (up) or 1 (down); `startedAt` is when that
/// status began. It is 0 only while the feed is not initialized (Chainlink's
/// docs), which counts as down. A zero feed address disables the check (a
/// chain with no uptime feed, such as Arbitrum Sepolia, or a dev node).
library L2Sequencer {
    error SequencerDown();
    error SequencerGracePeriod(uint256 until);

    function check(IAggregatorV3 uptimeFeed, uint256 grace) internal view {
        if (address(uptimeFeed) == address(0)) return;
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer, uint256 startedAt,,) = uptimeFeed.latestRoundData();
        if (answer != 0 || startedAt == 0) revert SequencerDown();
        if (block.timestamp < startedAt + grace) revert SequencerGracePeriod(startedAt + grace);
    }
}
