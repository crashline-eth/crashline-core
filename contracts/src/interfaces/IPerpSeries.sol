// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFixingsRecorder} from "./IFixingsRecorder.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// Everything that defines a perpetual series' payout (docs/v2-spec.md §4).
/// seriesId = keccak256(abi.encode(terms)). No strike date, no maturity, no
/// observation count: `firstFixing` only anchors the fixing grid and tells
/// vintages apart (a fresh series after a crash has the same terms and a new
/// `firstFixing`). Implied vol is not a term: it changes the price, never
/// the payout, and lives in the Desk.
struct PerpTerms {
    address feed; // underlying: AggregatorV3 feed, 8 decimals
    uint40 firstFixing; // the fixing that sets the reference H; fixing n is at firstFixing + n * fixingInterval
    uint32 fixingInterval; // seconds between fixings; >= 1 hour (86,400 at launch: daily at 08:00 UTC)
    uint16 kiBarrierBps; // knock-in k, bps of the reference; 0 < k <= 10_000
    uint64 meltShare; // a = 1 - e^(-phi * interval), 1e18 fixed point: share of the pool released per fixing
    uint64 couponReserve; // R = c / phi, USDC base units per 1e6 base units of live notional; a multiple of 100 (1 bps)
}

enum PerpPhase {
    Pending, // first fixing not processed yet: no mint
    Live, // mint, redeemPair, claim
    Closed // terminated: everything is released; redeemPair (pays 0), claim
}

/// Up-to-date state. `state()` includes fixings that are recorded (or past
/// their fallback deadline) but not yet processed by `advance()`.
struct PerpState {
    PerpPhase phase;
    uint96 referenceFixing; // H, feed decimals; 0 while Pending. Moves up to every fixing at or above it
    uint96 lastFixing; // the last processed fixing: what a missed fixing reuses
    bool knockedIn; // set by a fixing below k * H, cleared by a fixing at or above H
    uint16 missedInARow; // consecutive fixings processed without a recorded price
    uint32 fixingsDone; // processed fixings after the first
    uint40 nextFixing; // time of the next fixing; 0 once Closed
    uint256 notionalPerToken; // live notional of one token, 1e27 fixed point; shrinks by (1 - a) per fixing
    uint256 noteIndex; // USDC released per NOTE so far, 1e27 fixed point
    uint256 coverIndex; // USDC released per COVER so far, 1e27 fixed point
}

/// L1 core of the v2 perpetual note. One series = one USDC escrow + two
/// ERC-20s (NOTE, COVER), no expiry. No model, no admin, no pause, no
/// upgrade. Every state-changing entry point, token transfers included, first
/// processes all processable fixings (same as calling advance()).
///
/// Normative rule (docs/v2-spec.md §4; tools/perp_vectors.py is the Python
/// twin). The first fixing sets the reference H. At every later fixing f:
///   1. f >= H             ->  H = f, knockedIn = false   (the ratchet: nothing is redeemed)
///   2. else f < k * H     ->  knockedIn = true
///   3. a share a of the pool is released. Per unit of live notional
///        NOTE   gets a * (p + R),   p = 1 if clean, f / H if knocked in
///        COVER  gets a * (1 - p)
///      and the live notional of every token shrinks by (1 - a).
/// A pair locks 1 + R per unit of live notional and each fixing releases the
/// same share of everything, so the escrow always covers both legs: no
/// liquidations, no top-ups.
///
/// Released USDC is pulled: a cumulative index per token, checkpointed for a
/// holder whenever its balance changes. A contract that holds NOTE and never
/// calls `claim` strands its cash: it must call `claim` itself (as the Earn
/// vaults planned in #33 will).
///
/// Missed fixings and the end. A fixing still unrecorded FALLBACK_GRACE
/// (6 hours) after its time reuses the last fixing and counts as missed; one
/// recorded before the series processes it always wins, even after that. The
/// clock pauses while the L2 sequencer keeps the recorder from recording:
/// nothing falls back while it is down, and with it up since `startedAt`, not
/// before max(fixing time, startedAt + SEQUENCER_GRACE) + FALLBACK_GRACE. An
/// uptime feed that reverts, answers nonsense, or has read down for
/// CLOSE_AFTER_DEAD counts as none (the plain rule).
/// Missed fixings in a row that span CLOSE_AFTER_DEAD (14 days:
/// missedInARow * fixingInterval >= CLOSE_AFTER_DEAD; a dead feed, or a feed
/// Chainlink retires) close the series: that fixing releases everything (a = 1)
/// at the last good fixing under the same rule. A recorded fixing resets the
/// count. The first fixing has no fallback.
interface IPerpSeries {
    event Struck(uint96 referenceFixing);
    /// `noteRelease` / `coverRelease`: USDC released per token at this fixing, 1e27 fixed point.
    event FixingProcessed(
        uint32 indexed index,
        uint40 fixingTime,
        uint96 fixing,
        uint96 referenceFixing,
        bool knockedIn,
        bool missed,
        uint256 notionalPerToken,
        uint256 noteRelease,
        uint256 coverRelease
    );
    event Closed(uint32 atFixing, uint96 lastFixing);
    event Minted(address indexed caller, address indexed to, uint256 amount, uint256 collateralIn);
    event PairRedeemed(address indexed caller, address indexed to, uint256 amount, uint256 collateralOut);
    event Claimed(address indexed holder, address indexed to, uint256 amount);

    error NotStruck();
    error SeriesClosed();
    error ZeroAmount();
    error OnlyToken();

    // --- identity -------------------------------------------------------------
    function factory() external view returns (address);
    function id() external view returns (bytes32);
    function terms() external view returns (PerpTerms memory);
    function note() external view returns (address);
    function cover() external view returns (address);
    function recorder() external view returns (IFixingsRecorder);
    function collateral() external view returns (address); // USDC

    // --- economics ------------------------------------------------------------
    /// USDC base units a pair is worth per 1e6 base units of live notional (= 1e6 + couponReserve).
    function pairValuePerNotional() external view returns (uint256);
    /// 6 hours: a fixing still unrecorded this long after its time is missed (it reuses the last one).
    function FALLBACK_GRACE() external view returns (uint40);
    /// The recorder's L2 sequencer uptime feed (0: no check) and its grace: the fallback clock
    /// stops while they keep the recorder from recording.
    function sequencer() external view returns (IAggregatorV3);
    function SEQUENCER_GRACE() external view returns (uint40);
    /// 14 days: the missed fixing that makes the missed fixings in a row span this long
    /// (missedInARow * fixingInterval >= CLOSE_AFTER_DEAD) closes the series with a full release.
    function CLOSE_AFTER_DEAD() external view returns (uint40);

    // --- state ----------------------------------------------------------------
    function state() external view returns (PerpState memory);

    /// A fixing time has passed but the fixing can't be processed yet. While
    /// true the note's state is unknown, and quoters must refuse to price.
    function pendingFixing() external view returns (bool pending, uint40 fixingTime);

    /// Permissionless: processes the first fixing and every later one that is
    /// recorded or past its fallback deadline, in order. Moves no tokens.
    function advance() external returns (PerpState memory);

    /// The same, at most `maxFixings` of them: for catching up a long backlog in several transactions.
    function advanceBy(uint256 maxFixings) external returns (PerpState memory);

    // --- positions (collateral is pulled with transferFrom: approve the series) ---
    /// Live only. Locks ceil(amount * notionalPerToken * pairValuePerNotional / 1e33) USDC and
    /// mints `amount` NOTE and COVER to `to`.
    function mint(uint256 amount, address to) external returns (uint256 collateralIn);

    /// Burns `amount` NOTE and COVER from the caller and pays the floor of the same
    /// expression. Any phase after the first fixing (a Closed series pays 0).
    function redeemPair(uint256 amount, address to) external returns (uint256 collateralOut);

    /// Pays the USDC released to the caller's NOTE and COVER so far to `to`.
    function claim(address to) external returns (uint256 amount);

    /// Called by NOTE or COVER before a transfer changes balances: settles both holders.
    function checkpoint(address from, uint256 fromBalance, address to, uint256 toBalance) external;

    function claimable(address holder) external view returns (uint256 amount);
    function previewMint(uint256 amount) external view returns (uint256 collateralIn);
    function previewRedeemPair(uint256 amount) external view returns (uint256 collateralOut);
    /// Live notional of `amount` tokens in USDC base units, rounded down.
    function notionalOf(uint256 amount) external view returns (uint256);
}
