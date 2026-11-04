// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// L3, LP side of the Desk: deposits and redemptions are requests that settle
/// later, at the market keeper's next update (docs/v2-spec.md §8, #45).
/// Implemented by PerpDesk (on USDC). It extends v1's redemption queue
/// with a deposit queue; it is not ERC-7540.
///
/// Why. The Desk marks its positions at each feed's vol and carry, which the
/// market keeper writes from a public source (the options market). A keeper write is a
/// step in the share price that anyone can see coming, so with instant
/// deposits and withdrawals anyone could trade ahead of it. A request is
/// binding and settles at a mark the requester could not see or time when
/// making it: due DELAY (1 h) after the request, and settled only inside the
/// keeper's own update, after the new vol and carry are written. The ERC-4626
/// `deposit`, `mint`, `withdraw` and `redeem` revert (`AsyncOnly`) and the
/// four `max*` functions return 0; `convertTo*` and the previews stay views of
/// the current mark.
///
/// Lifecycle of a request (one FIFO queue each for deposits and redemptions):
///   requestDeposit(assets)  any time, at least MIN_DEPOSIT_ASSETS (100 USDC).
///                           The USDC moves into the Desk and is pending: not
///                           part of totalAssets, not spendable, no shares yet.
///   requestRedeem(shares)   any time, at least MIN_REQUEST_SHARES, and leaving
///                           the caller none or at least MIN_REQUEST_SHARES
///                           (RestTooSmall). The shares move into the Desk and
///                           keep their share of gains and losses until filled.
///   settlement              only in the market keeper's `setMarkets` (never
///                           the owner's, never a trade, never anyone else),
///                           when a request at the head of a queue is due,
///                           after its writes, for requests due at or before
///                           `cutoff`, the oldest sourceTime of the feeds the
///                           Desk holds a position on. It is skipped (the
///                           writes still apply) while a held series can't be
///                           advanced or marked, while one of those feeds' last write moved
///                           by its full step limit or was the owner's (`atBound`:
///                           the keeper is still catching up, or hasn't written
///                           since the owner), or when that data is older than
///                           `minUpdateGap`. Otherwise one price is fixed
///                           (OpenZeppelin's, with totalAssets at the new mark),
///                           due deposits are filled first (shares minted to
///                           their owners, rounded down), then due redemptions
///                           out of idle USDC (shares burned, USDC set aside,
///                           rounded down; the last one partly if the USDC runs
///                           out), visiting at most MAX_SETTLE requests of each
///                           queue per call.
///                           Rounding favours the LPs who stay.
///   claim(to)               the owner of filled redemptions pulls the USDC set
///                           aside, to any address (USDC can freeze a single
///                           account; settlement itself never sends USDC).
///   cancelDeposit(id) /     only once a request is STALL (6 h) past due and
///   cancelRedeem(id)        still unsettled (a keeper outage): the owner takes
///                           the unfilled rest back. Before that: CancelTooEarly.
///                           A request already filled or cancelled returns 0
///                           (and the event says 0); no revert.
///
/// The queue comes first:
///  - `shortfall` is set when a settlement reaches a due redemption it can't pay
///    in full out of idle USDC. While it is, every trade that adds to the Desk's
///    position (IPerpDesk) reverts QueuePending: no new risk while LPs wait for
///    their money. Trades that shrink a position and `collect` keep working;
///    they free USDC. The next settlement that gets past every due redemption
///    (pays them, or finds the short one cancelled) clears it; one whose
///    MAX_SETTLE redemption visits run out before a due one leaves it as it was.
///  - USDC set aside for claims and pending deposits are not part of
///    totalAssets, of the idle USDC or of what a trade may spend
///    (ReservedForClaims).
///
/// FRONTENDS: quotes don't look at the queue. A quote's `newPosition`
/// (IPerpDesk.quote) is the part of the trade that adds to the Desk's
/// position: read `shortfall()` with it; while it is set, a trade with
/// `newPosition > 0` reverts QueuePending and one with `newPosition` 0 goes on.
interface IDeskQueue {
    event DepositRequested(uint256 indexed id, address indexed owner, uint256 assets);
    /// `assets` USDC of a pending deposit turned into `shares`, minted to `owner`.
    event DepositFilled(uint256 indexed id, address indexed owner, uint256 assets, uint256 shares);
    event DepositCancelled(uint256 indexed id, address indexed owner, uint256 assets);
    event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares);
    /// `shares` burned for `assets` USDC, now claimable by `owner`; emitted per fill (a request can fill in parts).
    event RedeemFilled(uint256 indexed id, address indexed owner, uint256 shares, uint256 assets);
    event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event RedeemClaimed(address indexed owner, address to, uint256 assets);
    /// A keeper update with a request due settled the requests due at or before `cutoff` at the price
    /// (nav + 1) / (supply + 1e6): `nav` = totalAssets and `supply` = totalSupply at the
    /// new mark, before the fills.
    event Settled(uint40 cutoff, uint256 nav, uint256 supply);

    /// Below MIN_DEPOSIT_ASSETS (deposits) or MIN_REQUEST_SHARES (redemptions).
    error RequestTooSmall(uint256 amount, uint256 minAmount);
    error NotRequestOwner(uint256 id);
    /// A request can be cancelled only from `cancelFrom` = its due time + STALL.
    error CancelTooEarly(uint40 cancelFrom);
    /// `deposit`, `mint`, `withdraw` and `redeem`: LP flows are requests.
    error AsyncOnly();
    error NothingToClaim();
    /// A trade that adds to a position while `shortfall` is set.
    error QueuePending(uint256 queuedShares);
    error ReservedForClaims();
    /// requestRedeem would leave the caller `rest` shares, more than 0 and fewer than
    /// MIN_REQUEST_SHARES: a rest it couldn't request in turn. Request all of it, or less.
    error RestTooSmall(uint256 rest, uint256 minShares);

    /// A request is due this long after it is made (1 hour).
    function DELAY() external view returns (uint40);
    /// It can be cancelled this long after it is due, if still unsettled (6 hours).
    function STALL() external view returns (uint40);
    /// The most requests of each queue one settlement visits, filled or skipped (64).
    function MAX_SETTLE() external view returns (uint256);
    /// Smallest deposit request, in USDC base units (100 USDC).
    function MIN_DEPOSIT_ASSETS() external view returns (uint256);
    /// Smallest redemption request, in shares (12 decimals): keeps the queue from filling with dust.
    function MIN_REQUEST_SHARES() external view returns (uint256);

    /// USDC of deposit requests not yet filled or cancelled (held by the Desk, outside totalAssets).
    function pendingDepositAssets() external view returns (uint256);
    /// Shares waiting in the redemption queue (held by the Desk itself, still part of totalSupply).
    function queuedShares() external view returns (uint256);
    /// USDC set aside for filled redemptions and not yet claimed.
    function reservedAssets() external view returns (uint256);
    function claimableAssets(address owner) external view returns (uint256);
    /// The last settlement reached a due redemption it could not pay in full: trades that add
    /// to a position revert QueuePending until a settlement gets past every due redemption.
    function shortfall() external view returns (bool);
    /// Deposit requests `head` .. `length - 1` are not settled yet (cancelled ones have 0 assets).
    function depositQueue() external view returns (uint256 head, uint256 length);
    /// Redemption requests `head` .. `length - 1` are not fully filled yet (cancelled ones have 0 shares).
    function queue() external view returns (uint256 head, uint256 length);
    /// `assets` is what is still pending: 0 once filled or cancelled.
    function depositRequest(uint256 id) external view returns (address owner, uint40 dueAt, uint256 assets);
    /// `shares` is the unfilled rest: 0 once filled or cancelled.
    function redeemRequest(uint256 id) external view returns (address owner, uint40 dueAt, uint256 shares);

    /// Moves `assets` USDC of the caller into the deposit queue (approve the Desk), due DELAY from now.
    function requestDeposit(uint256 assets) external returns (uint256 id);
    /// Moves `shares` of the caller into the redemption queue, due DELAY from now. The caller
    /// keeps none or at least MIN_REQUEST_SHARES (RestTooSmall).
    function requestRedeem(uint256 shares) external returns (uint256 id);
    /// Returns the pending USDC of the caller's deposit request, once it is STALL past due (0 when
    /// it was filled or cancelled already).
    function cancelDeposit(uint256 id) external returns (uint256 assets);
    /// Returns the unfilled shares of the caller's redemption request, once it is STALL past due
    /// (0 when it was filled or cancelled already; the rest of a partly filled one may be below
    /// MIN_REQUEST_SHARES: top it up with a deposit, or transfer it).
    function cancelRedeem(uint256 id) external returns (uint256 shares);
    /// Pays the caller's claimable USDC to `to`.
    function claim(address to) external returns (uint256 assets);
}
