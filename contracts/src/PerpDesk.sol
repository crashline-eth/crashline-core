// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPerpDesk} from "./interfaces/IPerpDesk.sol";
import {IDeskQueue} from "./interfaces/IDeskQueue.sol";
import {IPerpQuoter, PerpQuote} from "./interfaces/IPerpQuoter.sol";
import {IPerpPricer, LineBands, PerpProduct} from "./interfaces/IPerpPricer.sol";
import {IPerpFactory} from "./interfaces/IPerpFactory.sol";
import {IPerpSeries, PerpTerms, PerpState, PerpPhase} from "./interfaces/IPerpSeries.sol";

/// L3 of the v2 perpetual note: the market for both legs of a perpetual
/// series (IPerpDesk) and its LPs' deposit and redemption requests
/// (IDeskQueue). The v1 Desk carried over to a note that never settles: an
/// ERC-4626 vault on USDC; LPs deposit USDC; the Desk sells and buys back NOTE and COVER
/// around the quoter's price at two prices, and the spread stays in the
/// vault. Every trade is served from inventory first; for the shortfall the
/// Desk mints a pair and keeps the other leg, and a leg handed in is paired
/// with the other leg it holds and redeemed. The owner is the curator:
/// listings (which model, COVER cap), market data per feed (vol, carry) and
/// its limits, the market keeper, spreads, the risk budget per feed, and the
/// band before each fixing. The market keeper writes market data only, within
/// the limits. Nothing here can touch series collateral.
///
/// Share price. totalAssets = idle USDC (less the USDC set aside for claims
/// and the pending deposits) + the USDC the series have released to the
/// Desk's tokens and not yet collected + the Desk's NOTE and COVER at the
/// quoter's price (mid, at the feed's vol and carry, from the feed; COVER =
/// pair value - NOTE). A closed series holds nothing but released USDC.
///
/// LP flows are requests (IDeskQueue, #45): a keeper write is a
/// step in the share price that anyone can see coming, so deposits and
/// redemptions are binding requests, due DELAY after they are made, that
/// settle only in the market keeper's `setMarkets`, after its writes, at the
/// mark they give. As ERC-4626 asks of a vault that takes no instant flows,
/// maxDeposit / maxMint / maxWithdraw / maxRedeem return 0 and deposit / mint /
/// withdraw / redeem revert (AsyncOnly). totalAssets, convertToShares/Assets
/// and the previews are views of the current mark; as in v1 they revert, with
/// the quoter's or model's error, while a held series can't be quoted (a stale
/// feed, no or stale market data, a pending fixing, a state the model refuses).
/// Inflation: OpenZeppelin's virtual shares with a 6-decimal offset.
contract PerpDesk is IPerpDesk, IDeskQueue, ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant UNIT = 1e6; // base units per USDC of notional
    uint256 internal constant UNIT_PER_BPS = UNIT / BPS;
    uint256 internal constant RAY = 1e27; // notional per token

    uint16 public constant MAX_FEE_BPS = 200;
    uint16 public constant MAX_COVER_FEE_BPS = 1_000; // of the premium (MAX_FEE_BPS is of notional)
    uint16 public constant BACKSTOP_SHARE_BPS = 5_000; // half of every fee stays with the LPs
    uint256 public constant MAX_HELD_SERIES = 64; // bounds the totalAssets loop
    uint16 public constant MAX_SPREAD_BPS = 1_000;
    uint256 public constant MIN_REQUEST_SHARES = 10e12; // 10 USDC at the first deposit's share price
    uint256 public constant MIN_DEPOSIT_ASSETS = 100e6; // 100 USDC
    uint40 public constant DELAY = 1 hours; // a request is due this long after it is made
    uint40 public constant STALL = 6 hours; // and can be cancelled this long after it is due, if unsettled
    uint256 public constant MAX_SETTLE = 64; // requests one settlement visits, at most
    uint32 internal constant MAX_MARKET_AGE = 1 days; // the most setMarketLimits accepts

    IPerpFactory public immutable factory;
    IPerpQuoter public immutable quoter;
    uint32 public minSecsToFixing;
    // the market data limits (MarketLimits) and shortfall share minSecsToFixing's slot (4 + 4 +
    // 4 + 2 + 2 + 1 bytes), so a trade reads maxMarketAge and shortfall from a slot it reads
    // anyway; keeper has its own
    uint32 public maxMarketAge;
    uint32 public minUpdateGap;
    uint16 public maxVolStepBps;
    uint16 public maxCarryStepBps;
    bool public shortfall;
    address public keeper;

    mapping(address => Listing) internal _listings;
    mapping(address => Spread) internal _spreads;
    mapping(address feed => uint16) public riskBudgetBps;
    mapping(address feed => Market) public market;
    address[] internal _listed;
    EnumerableSet.AddressSet internal _held;

    /// A deposit (`amount` in USDC) or a redemption (in shares); `amount` is the
    /// unfilled rest (0 once filled or cancelled).
    struct Request {
        address owner;
        uint40 dueAt;
        uint256 amount;
    }

    Request[] internal _deposits;
    uint256 internal _depositHead;
    uint256 public pendingDepositAssets;
    Request[] internal _queue; // redemptions
    uint256 internal _queueHead;
    uint256 public queuedShares;
    uint256 public reservedAssets;
    mapping(address owner => uint256) public claimableAssets;

    error HeldSeriesLimit();
    error WrongAsset();

    constructor(
        IERC20 usdc,
        IPerpFactory factory_,
        IPerpQuoter quoter_,
        address owner_,
        uint32 minSecs,
        MarketLimits memory limits,
        address keeper_
    ) ERC20("Surrogate Pricer Perpetual Desk", "spPDESK") ERC4626(usdc) Ownable(owner_) {
        if (factory_.collateral() != address(usdc)) revert WrongAsset();
        factory = factory_;
        quoter = quoter_;
        minSecsToFixing = minSecs;
        emit MinSecsToFixingSet(minSecs);
        _setMarketLimits(limits.maxMarketAge, limits.maxVolStepBps, limits.maxCarryStepBps, limits.minUpdateGap);
        _setKeeper(keeper_);
    }

    // --- views ------------------------------------------------------------------

    function listing(address series) external view returns (Listing memory) {
        return _listings[series];
    }

    /// Every series ever listed, including delisted ones (sells stay open).
    function listedSeries() external view returns (address[] memory) {
        return _listed;
    }

    /// Series whose NOTE or COVER the Desk holds, or held until the last `collect`.
    function heldSeries() external view returns (address[] memory) {
        return _held.values();
    }

    function spread(address series) external view returns (Spread memory) {
        return _spreads[series];
    }

    /// @inheritdoc IPerpDesk
    function midPriceBps(address series) external view returns (uint16) {
        return _mid(series, IPerpSeries(series).terms().feed);
    }

    /// @inheritdoc IPerpDesk
    function risk(address feed) public view returns (uint256 atRisk, uint256 limit) {
        uint256 assets = _idle();
        uint256 n = _held.length();
        for (uint256 i = 0; i < n; i++) {
            (, uint256 value, uint256 seriesRisk, address seriesFeed) = _position(_held.at(i), false);
            assets += value;
            if (seriesFeed == feed) atRisk += seriesRisk;
        }
        limit = Math.mulDiv(assets, riskBudgetBps[feed], BPS);
    }

    /// @inheritdoc IPerpDesk
    function quote(address series, Side side, uint256 amount, uint16 feeBps)
        external
        view
        returns (uint256 paid, uint16 priceBps, uint256 newPosition)
    {
        Trade memory t = _trade(series, amount, feeBps, address(0), address(0), side);
        if (side == Side.BuyNote || side == Side.BuyCover) paid = _buyCost(t);
        else (paid,) = _sellProceeds(t);
        return (paid, t.priceBps, t.growth);
    }

    // --- trading ------------------------------------------------------------------

    function buy(address series, uint256 amount, uint256 maxCost, uint16 feeBps, address feeReceiver, address to)
        external
        nonReentrant
        returns (uint256 cost)
    {
        return _buy(_trade(series, amount, feeBps, feeReceiver, to, Side.BuyNote), maxCost);
    }

    function sell(address series, uint256 amount, uint256 minProceeds, uint16 feeBps, address feeReceiver, address to)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        return _sell(_trade(series, amount, feeBps, feeReceiver, to, Side.SellNote), minProceeds);
    }

    function buyCover(address series, uint256 amount, uint256 maxCost, uint16 feeBps, address feeReceiver, address to)
        external
        nonReentrant
        returns (uint256 cost)
    {
        return _buy(_trade(series, amount, feeBps, feeReceiver, to, Side.BuyCover), maxCost);
    }

    function sellCover(
        address series,
        uint256 amount,
        uint256 minProceeds,
        uint16 feeBps,
        address feeReceiver,
        address to
    ) external nonReentrant returns (uint256 proceeds) {
        return _sell(_trade(series, amount, feeBps, feeReceiver, to, Side.SellCover), minProceeds);
    }

    /// Permissionless: redeem the pairs the Desk holds, pull the USDC released to its
    /// tokens, and forget the series once nothing of it is left.
    function collect(address series) external nonReentrant returns (uint256 collateralOut) {
        if (!factory.isSeries(series)) revert NotFactorySeries(series);
        IPerpSeries s = IPerpSeries(series);
        uint256 n = _balance(s.note());
        uint256 w = _balance(s.cover());
        uint256 pairs = Math.min(n, w);
        if (pairs != 0) collateralOut = s.redeemPair(pairs, address(this));
        collateralOut += s.claim(address(this));
        if (n == w || s.state().phase == PerpPhase.Closed) _held.remove(series);
        emit Collected(series, collateralOut);
    }

    // --- LP requests (IDeskQueue) -------------------------------------------------------

    function depositQueue() external view returns (uint256 head, uint256 length) {
        return (_depositHead, _deposits.length);
    }

    function queue() external view returns (uint256 head, uint256 length) {
        return (_queueHead, _queue.length);
    }

    function depositRequest(uint256 id) external view returns (address owner_, uint40 dueAt, uint256 assets) {
        Request memory r = _deposits[id];
        return (r.owner, r.dueAt, r.amount);
    }

    function redeemRequest(uint256 id) external view returns (address owner_, uint40 dueAt, uint256 shares) {
        Request memory r = _queue[id];
        return (r.owner, r.dueAt, r.amount);
    }

    function requestDeposit(uint256 assets) external nonReentrant returns (uint256 id) {
        if (assets < MIN_DEPOSIT_ASSETS) revert RequestTooSmall(assets, MIN_DEPOSIT_ASSETS);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        pendingDepositAssets += assets;
        id = _request(_deposits, assets);
        emit DepositRequested(id, msg.sender, assets);
    }

    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares < MIN_REQUEST_SHARES) revert RequestTooSmall(shares, MIN_REQUEST_SHARES);
        _transfer(msg.sender, address(this), shares);
        // no rest that couldn't be requested in turn: all of it, or at least the minimum left
        uint256 rest = balanceOf(msg.sender);
        if (rest != 0 && rest < MIN_REQUEST_SHARES) revert RestTooSmall(rest, MIN_REQUEST_SHARES);
        queuedShares += shares;
        id = _request(_queue, shares);
        emit RedeemRequested(id, msg.sender, shares);
    }

    function cancelDeposit(uint256 id) external nonReentrant returns (uint256 assets) {
        assets = _cancel(_deposits, id);
        pendingDepositAssets -= assets;
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit DepositCancelled(id, msg.sender, assets);
    }

    function cancelRedeem(uint256 id) external nonReentrant returns (uint256 shares) {
        shares = _cancel(_queue, id);
        queuedShares -= shares;
        _transfer(address(this), msg.sender, shares);
        emit RedeemCancelled(id, msg.sender, shares);
    }

    function claim(address to) external nonReentrant returns (uint256 assets) {
        assets = claimableAssets[msg.sender];
        if (assets == 0) revert NothingToClaim();
        claimableAssets[msg.sender] = 0;
        reservedAssets -= assets;
        IERC20(asset()).safeTransfer(to, assets);
        emit RedeemClaimed(msg.sender, to, assets);
    }

    // --- curator ------------------------------------------------------------------

    function listSeries(address series, IPerpPricer pricer, uint128 capNotional) external onlyOwner {
        if (!factory.isSeries(series)) revert NotFactorySeries(series);
        PerpTerms memory t = IPerpSeries(series).terms();
        PerpProduct memory p = pricer.product();
        if (p.kiBarrierBps != t.kiBarrierBps) revert ModelMismatch(0);
        if (p.meltShare != t.meltShare) revert ModelMismatch(1);
        if (p.fixingInterval != t.fixingInterval) revert ModelMismatch(2);
        // every trade needs the pricer's line bands: a pricer without them is refused here, and so
        // is one whose discount comes without a minimum vol band (the discount is sized for one)
        LineBands memory b = _lineBands(pricer);
        if (b.buyBackDiscountBps != 0 && b.minVolBandBps == 0) revert VolBandTooNarrow(0);

        Listing storage l = _listings[series];
        if (address(l.pricer) == address(0)) _listed.push(series);
        l.active = true;
        l.pricer = pricer;
        l.capNotional = capNotional;
        emit SeriesListed(series, address(pricer), pricer.weightsHash(), capNotional);
    }

    /// By the owner or the market keeper (IPerpDesk): every write first, then, on the keeper's
    /// call only, the settlement of the due LP requests at the mark the writes give (IDeskQueue).
    function setMarkets(MarketUpdate[] calldata updates) external nonReentrant {
        bool byKeeper = msg.sender != owner();
        if (byKeeper && msg.sender != keeper) revert OwnableUnauthorizedAccount(msg.sender);
        for (uint256 i = 0; i < updates.length; i++) {
            _setMarket(updates[i], byKeeper);
        }
        if (byKeeper) _settle();
    }

    function setKeeper(address keeper_) external onlyOwner {
        _setKeeper(keeper_);
    }

    /// The owner's writes never settle: as the keeper too, it would leave LP requests unsettled.
    function _setKeeper(address keeper_) internal {
        if (keeper_ == owner()) revert KeeperIsOwner();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setMarketLimits(uint32 maxAge, uint16 volStepBps, uint16 carryStepBps, uint32 gap) external onlyOwner {
        _setMarketLimits(maxAge, volStepBps, carryStepBps, gap);
    }

    function delistSeries(address series) external onlyOwner {
        Listing storage l = _listings[series];
        if (address(l.pricer) == address(0)) revert NotListed(series);
        l.active = false;
        emit SeriesDelisted(series);
    }

    function setSpread(address series, uint16 bidBps, uint16 askBps, uint16 volBandBps) external onlyOwner {
        IPerpPricer pricer = _listings[series].pricer;
        if (address(pricer) == address(0)) revert NotListed(series);
        if (bidBps > MAX_SPREAD_BPS) revert SpreadTooWide(bidBps);
        if (askBps > MAX_SPREAD_BPS) revert SpreadTooWide(askBps);
        uint16 minVolBand = _lineBands(pricer).minVolBandBps;
        if (volBandBps < minVolBand) revert VolBandTooNarrow(minVolBand);
        _spreads[series] = Spread({bidBps: bidBps, askBps: askBps, volBandBps: volBandBps});
        emit SpreadSet(series, bidBps, askBps, volBandBps);
    }

    function setRiskBudget(address feed, uint16 budgetBps) external onlyOwner {
        if (budgetBps > BPS) revert BudgetTooHigh(budgetBps);
        riskBudgetBps[feed] = budgetBps;
        emit RiskBudgetSet(feed, budgetBps);
    }

    function setMinSecsToFixing(uint32 secs) external onlyOwner {
        minSecsToFixing = secs;
        emit MinSecsToFixingSet(secs);
    }

    // --- ERC-4626 -----------------------------------------------------------------

    /// Reverts (with the quoter's or model's error) while a held series can't be quoted from its feed.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 assets) {
        assets = _idle();
        uint256 n = _held.length();
        for (uint256 i = 0; i < n; i++) {
            (, uint256 v,,) = _position(_held.at(i), true);
            assets += v;
        }
    }

    /// LP flows are requests (IDeskQueue): no instant deposit, mint, withdrawal or redemption.
    function maxDeposit(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    function deposit(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncOnly();
    }

    function mint(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncOnly();
    }

    function withdraw(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncOnly();
    }

    function redeem(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncOnly();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // --- internals ------------------------------------------------------------------

    /// One trade's parameters and quote, kept in memory (the events are wide).
    struct Trade {
        address series;
        uint256 amount; // NOTE or COVER tokens
        uint16 feeBps;
        address feeReceiver;
        address to;
        Side side;
        uint256 notionalPerToken;
        uint16 priceBps; // of the traded leg per unit of notional, spread included
        bytes32 weightsHash;
        uint256 fee;
        uint256 growth; // part of `amount` that becomes a new position of the Desk (quote's newPosition)
        uint256 paid; // cost of a buy, proceeds of a sell
    }

    /// Price, near-line, fee and cap checks shared by quotes and trades. Buys need an
    /// active listing; sells only a listing (delisted series stay sellable).
    function _trade(address series, uint256 amount, uint16 feeBps, address feeReceiver, address to, Side side)
        internal
        view
        returns (Trade memory t)
    {
        if (amount == 0) revert ZeroAmount();
        bool isCover = side == Side.BuyCover || side == Side.SellCover;
        bool isBuy = side == Side.BuyNote || side == Side.BuyCover;
        if (feeBps > (isCover ? MAX_COVER_FEE_BPS : MAX_FEE_BPS)) revert FeeTooHigh(feeBps);
        Listing memory l = _listings[series];
        if (isBuy ? !l.active : address(l.pricer) == address(0)) revert NotListed(series);

        t.series = series;
        t.amount = amount;
        t.feeBps = feeBps;
        t.feeReceiver = feeReceiver;
        t.to = to;
        t.side = side;
        PerpState memory st = IPerpSeries(series).state();
        (t.priceBps, t.weightsHash) = _sidePrice(series, l.pricer, side, st);
        // Live with no fixing pending: the quotes succeeded
        if (uint256(st.nextFixing) < block.timestamp + minSecsToFixing) revert TooCloseToFixing(st.nextFixing);
        t.notionalPerToken = st.notionalPerToken;

        // the integrator fee is a share of the notional for NOTE, of the premium for cover
        uint256 feeBase = isCover
            ? _legValue(t, isBuy ? Math.Rounding.Ceil : Math.Rounding.Floor)
            : Math.mulDiv(amount, st.notionalPerToken, RAY);
        t.fee = Math.mulDiv(feeBase, feeBps, BPS, Math.Rounding.Ceil);
        t.growth = _growth(series, amount, side, l.capNotional, st.notionalPerToken);
    }

    /// The trader pays, the Desk mints pairs for what its inventory lacks and hands over the leg.
    function _buy(Trade memory t, uint256 maxCost) internal returns (uint256 cost) {
        IPerpSeries s = IPerpSeries(t.series);
        cost = t.paid = _buyCost(t);
        if (cost > maxCost) revert Slippage(cost, maxCost);
        if (t.growth != 0) _queueFirst();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), cost);
        if (t.growth != 0) {
            IERC20(asset()).forceApprove(t.series, s.previewMint(t.growth));
            // forge-lint: disable-next-line(unused-return)
            s.mint(t.growth, address(this)); // collateral = the previewMint approved above
            _hold(t.series);
        }
        IERC20(t.side == Side.BuyNote ? s.note() : s.cover()).safeTransfer(t.to, t.amount);
        _payFee(t.feeReceiver, t.fee);
        if (t.growth != 0) _checkRisk(t.series);
        _checkReserve();
        _emitTrade(t);
    }

    /// The trader hands the leg in, the Desk redeems the pairs it can form and pays.
    function _sell(Trade memory t, uint256 minProceeds) internal returns (uint256 proceeds) {
        IPerpSeries s = IPerpSeries(t.series);
        (proceeds, t.fee) = _sellProceeds(t);
        t.paid = proceeds;
        if (proceeds < minProceeds) revert Slippage(proceeds, minProceeds);
        if (t.growth != 0) _queueFirst();

        IERC20(t.side == Side.SellNote ? s.note() : s.cover()).safeTransferFrom(msg.sender, address(this), t.amount);
        uint256 pairs = t.amount - t.growth;
        // forge-lint: disable-next-line(unused-return)
        if (pairs != 0) s.redeemPair(pairs, address(this)); // USDC lands in idle
        if (t.growth != 0) _hold(t.series);
        IERC20(asset()).safeTransfer(t.to, proceeds);
        _payFee(t.feeReceiver, t.fee);
        if (t.growth != 0) _checkRisk(t.series);
        _checkReserve();
        _emitTrade(t);
    }

    function _emitTrade(Trade memory t) internal {
        emit Traded(
            t.series,
            msg.sender,
            t.side,
            t.to,
            t.amount,
            Math.mulDiv(t.amount, t.notionalPerToken, RAY),
            t.priceBps,
            t.paid,
            t.feeBps,
            t.feeReceiver,
            t.weightsHash
        );
    }

    /// amount * notionalPerToken * priceBps: what the traded leg is worth at the price applied.
    function _legValue(Trade memory t, Math.Rounding rounding) internal pure returns (uint256) {
        return Math.mulDiv(t.amount, t.notionalPerToken * t.priceBps, RAY * BPS, rounding);
    }

    /// ceil(value) + fee
    function _buyCost(Trade memory t) internal pure returns (uint256) {
        return _legValue(t, Math.Rounding.Ceil) + t.fee;
    }

    /// floor(value) - fee, and the fee can't exceed the gross amount
    /// (otherwise the integrator's cut would come out of the LPs).
    function _sellProceeds(Trade memory t) internal pure returns (uint256 proceeds, uint256 feeTaken) {
        uint256 gross = _legValue(t, Math.Rounding.Floor);
        feeTaken = Math.min(t.fee, gross);
        proceeds = gross - feeTaken;
    }

    // The price helper below reverts on purpose, also when totalAssets loops over the
    // held series: the share price is unknown while one of them can't be marked.
    // forge-lint: disable-start(require-revert-in-loop)

    /// The NOTE mid at the feed's vol and carry and the live feed's spot; `feed` is the series' feed.
    function _mid(address series, address feed) internal view returns (uint16) {
        (uint16 vol, int16 carry) = _market(feed);
        return quoter.quote(IPerpSeries(series), _listings[series].pricer, vol, carry).priceBps;
    }

    /// The feed's vol and carry, or NoMarketData, or MarketStale once older than maxMarketAge
    /// from its sourceTime (exactly maxMarketAge old is fresh), like the quoter's FeedStale.
    function _market(address feed) internal view returns (uint16, int16) {
        Market storage m = market[feed];
        uint40 t = m.sourceTime;
        if (t == 0) revert NoMarketData(feed);
        if (uint256(t) + maxMarketAge < block.timestamp) revert MarketStale(feed, t);
        return (m.volBpsAnnual, m.carryBpsAnnual);
    }

    /// One feed's write. The owner's is not bounded: any value is accepted, and a series outside
    /// its pricer's ranges is simply not quoted; any sourceTime up to now, so a keeper write that
    /// lands first can't block it; it sets atBound, so its values are no settlement price until
    /// the keeper's own write of the feed. The keeper's moves a feed that has data, within the
    /// limits, and only forward in sourceTime; atBound records a move by a full limit (with a
    /// limit of 0, every keeper write).
    function _setMarket(MarketUpdate calldata u, bool byKeeper) internal {
        Market storage m = market[u.feed];
        uint40 last = 0; // the owner's sourceTime only needs to be data: not 0
        bool atBound = !byKeeper; // owner values hold settlement until the keeper writes the feed
        if (byKeeper) {
            last = m.sourceTime;
            if (last == 0) revert NoMarketData(u.feed); // the owner writes the first value
            unchecked {
                // the gap is on the chain's clock: one keeper step per minUpdateGap, back-dated or
                // not. writtenAt was a block's timestamp: far from 2^40 - 2^32
                if (block.timestamp < m.writtenAt + minUpdateGap) revert MarketUpdateTooSoon();
            }
            uint256 volStep = _step(int256(uint256(u.volBpsAnnual)), int256(uint256(m.volBpsAnnual)));
            uint256 carryStep = _step(u.carryBpsAnnual, m.carryBpsAnnual);
            if (volStep > maxVolStepBps || carryStep > maxCarryStepBps) revert MarketStepTooLarge();
            atBound = volStep == maxVolStepBps || carryStep == maxCarryStepBps;
        }
        if (u.sourceTime > block.timestamp || u.sourceTime <= last) revert BadSourceTime(u.sourceTime);
        (m.volBpsAnnual, m.carryBpsAnnual, m.sourceTime) = (u.volBpsAnnual, u.carryBpsAnnual, u.sourceTime);
        // forge-lint: disable-next-line(unsafe-typecast)
        (m.writtenAt, m.atBound) = (uint40(block.timestamp), atBound); // a block's time fits until 36812
        emit MarketSet(u.feed, u.volBpsAnnual, u.carryBpsAnnual, u.sourceTime, u.source);
    }

    // forge-lint: disable-end(require-revert-in-loop)

    /// |a - b|, for the keeper's steps: a and b are a uint16 vol or an int16 carry.
    function _step(int256 a, int256 b) internal pure returns (uint256) {
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(a > b ? a - b : b - a); // not negative
        }
    }

    /// 0 < gap < maxAge <= MAX_MARKET_AGE: without a gap the keeper could chain its steps in
    /// one block, and with one as long as the age the data would go stale between two of its
    /// writes. Any steps: 0 lets the keeper only refresh the time.
    function _setMarketLimits(uint32 maxAge, uint16 volStep, uint16 carryStep, uint32 gap) internal {
        if (gap == 0 || gap >= maxAge || maxAge > MAX_MARKET_AGE) revert BadMarketLimits();
        maxMarketAge = maxAge;
        minUpdateGap = gap;
        maxVolStepBps = volStep;
        maxCarryStepBps = carryStep;
        emit MarketLimitsSet(maxAge, volStep, carryStep, gap);
    }

    /// Processes every processable fixing of the held series, so that a fixing which
    /// is past its fallback deadline is settled before the share price is used: once
    /// stored, a late recording can no longer change it. False, without reverting, when
    /// a series' advance() fails (a backlog too long for the gas given, say): then the
    /// keeper's update doesn't settle, and its writes still land. The caller is
    /// nonReentrant, and a series' advance() calls only its recorder (a view) and, for an
    /// overdue fixing, the L2 sequencer uptime feed (a staticcall): neither can re-enter.
    function _advanceHeld() internal returns (bool) {
        uint256 n = _held.length();
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            try IPerpSeries(_held.at(i)).advance() {}
            catch {
                return false;
            }
        }
        return true;
    }

    /// The quoter's lower or higher NOTE quote (at the two ends of the vol
    /// band, at least the pricer's minimum, at the feed's carry) moved by the
    /// flat spread, against the trader; the cover price is what is left of a
    /// pair (IPerpDesk). Near a line, once the pricer has answered (its own
    /// refusals come first): clean, no side in the crash line's strip, and above
    /// it the two sides priced at the NOTE ask at a discount; knocked in, no side
    /// near the high.
    function _sidePrice(address series, IPerpPricer pricer, Side side, PerpState memory st)
        internal
        view
        returns (uint16 priceBps, bytes32 weightsHash)
    {
        PerpTerms memory t = IPerpSeries(series).terms();
        Spread memory sp = _spreads[series];
        LineBands memory b = _lineBands(pricer);
        // a spread never set (a new listing) or set under another pricer's minimum prices at the minimum
        if (sp.volBandBps < b.minVolBandBps) sp.volBandBps = b.minVolBandBps;
        uint256 spot;
        uint256 lo;
        uint256 hi;
        {
            (uint256 vol, int16 carry) = _market(t.feed);
            spot = quoter.spot(IPerpSeries(series)); // one read of the feed for both quotes
            // vol -/+ band, floored at 0 and capped at 65,535: there every pricer refuses (the closed
            // form takes no vol below 1% or above 300%)
            (lo, weightsHash) = _noteBps(series, pricer, vol > sp.volBandBps ? vol - sp.volBandBps : 0, carry, spot);
            if (sp.volBandBps == 0) {
                hi = lo;
            } else {
                (hi,) = _noteBps(series, pricer, Math.min(vol + sp.volBandBps, type(uint16).max), carry, spot);
                if (hi < lo) (lo, hi) = (hi, lo);
            }
        }
        uint256 pairBps = (UNIT + t.couponReserve) / UNIT_PER_BPS;
        uint256 note;
        if (side == Side.BuyNote || side == Side.SellCover) {
            note = Math.min(hi + sp.askBps + _nearLine(b, spot, st, t.kiBarrierBps), pairBps);
        } else {
            _nearLine(b, spot, st, t.kiBarrierBps);
            lo = Math.min(lo, pairBps);
            note = lo > sp.bidBps ? lo - sp.bidBps : 0;
        }
        priceBps = SafeCast.toUint16(side == Side.BuyNote || side == Side.SellNote ? note : pairBps - note);
    }

    /// Near a line, at any time of day (docs/v2-spec.md §8), with the spot in bps of the reference as
    /// the quoter gave it to the pricer and the pricer's bands (LineBands): NearLine from `below`
    /// under the line to `above` over it, edges included, as PerpFormulaPricer compares them in its
    /// fixing band (clean, the crash line `line` and its strip; knocked in, the reference and the
    /// heal band). Else the discount on the NOTE ask: a clean note above the strip and short of the
    /// discount's reach, ceil(D * (k + reach - x) / (reach - stripAbove)), from D just above the
    /// strip to 0 at the reach (where the closed form's low NOTE price would cost the LPs on a
    /// buy-back); 0 elsewhere.
    function _nearLine(LineBands memory b, uint256 spot, PerpState memory st, uint256 line)
        internal
        pure
        returns (uint256 discount)
    {
        (uint256 below, uint256 above) = (b.stripBelowBps, b.stripAboveBps);
        if (st.knockedIn) (line, below, above) = (BPS, b.healBandBps, b.healBandBps);
        unchecked {
            // the quoter took the same quotient (< 2^16) without overflow; bands < 2^16, line <= 10,000
            uint256 x = spot * BPS / st.referenceFixing;
            if (x + below >= line && x <= line + above) revert NearLine(x);
            uint256 reach = line + b.discountReachBps;
            // x past the strip and short of the reach: reach - (line + above) >= 2; every factor < 2^17
            if (!st.knockedIn && x > line + above && x < reach) {
                uint256 span = b.discountReachBps - above;
                discount = (b.buyBackDiscountBps * (reach - x) + span - 1) / span;
            }
        }
    }

    /// The pricer's lines (one call site: listing, setSpread and every quote share its code).
    function _lineBands(IPerpPricer pricer) internal view returns (LineBands memory) {
        return pricer.lineBands();
    }

    /// `vol` is at most 65,535 (the caller caps it).
    function _noteBps(address series, IPerpPricer pricer, uint256 vol, int16 carry, uint256 spot)
        internal
        view
        returns (uint256 priceBps, bytes32 weightsHash)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        PerpQuote memory q = quoter.quoteAtSpot(IPerpSeries(series), pricer, uint16(vol), carry, spot);
        return (q.priceBps, q.weightsHash);
    }

    /// The part of a trade the Desk can't serve from, or pair with, what it
    /// holds. It becomes a new position: COVER when the Desk sells NOTE or
    /// buys cover back (limited by the listing's cap, in notional), NOTE otherwise.
    function _growth(address series, uint256 amount, Side side, uint256 capNotional, uint256 notionalPerToken)
        internal
        view
        returns (uint256 growth)
    {
        IPerpSeries s = IPerpSeries(series);
        bool growsCover = side == Side.BuyNote || side == Side.SellCover;
        growth = amount - Math.min(amount, _balance(growsCover ? s.note() : s.cover()));
        if (growth == 0 || !growsCover) return growth;
        uint256 held = _balance(s.cover());
        uint256 capTokens = notionalPerToken == 0 ? 0 : Math.mulDiv(capNotional, RAY, notionalPerToken);
        uint256 room = capTokens > held ? capTokens - held : 0;
        if (growth > room) revert CapExceeded(amount, amount - growth + room);
    }

    /// After a trade that added to a position: the feed's positions must fit its budget.
    function _checkRisk(address series) internal view {
        (uint256 atRisk, uint256 limit) = risk(IPerpSeries(series).terms().feed);
        if (atRisk > limit) revert RiskBudgetExceeded(atRisk, limit);
    }

    /// The integrator keeps the fee minus the backstop slice (rounded up, in
    /// the LPs' favor); with no receiver the whole fee stays in the vault.
    function _payFee(address feeReceiver, uint256 fee) internal {
        if (fee == 0 || feeReceiver == address(0)) return;
        uint256 slice = Math.mulDiv(fee, BACKSTOP_SHARE_BPS, BPS, Math.Rounding.Ceil);
        if (fee > slice) IERC20(asset()).safeTransfer(feeReceiver, fee - slice);
    }

    function _hold(address series) internal {
        if (_held.add(series) && _held.length() > MAX_HELD_SERIES) revert HeldSeriesLimit();
    }

    /// USDC the vault can use: its balance minus what is set aside for filled redemptions and
    /// the pending deposits.
    function _idle() internal view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 locked = reservedAssets + pendingDepositAssets;
        return balance > locked ? balance - locked : 0;
    }

    /// A trade paid out: it must not have dipped into the USDC set aside for claims or the
    /// pending deposits.
    function _checkReserve() internal view {
        if (IERC20(asset()).balanceOf(address(this)) < reservedAssets + pendingDepositAssets) {
            revert ReservedForClaims();
        }
    }

    /// Before a trade adds to a position: not while a due redemption lacks idle USDC.
    function _queueFirst() internal view {
        if (shortfall) revert QueuePending(queuedShares);
    }

    /// A new request of the caller, due DELAY from now.
    function _request(Request[] storage q, uint256 amount) internal returns (uint256 id) {
        id = q.length;
        // forge-lint: disable-next-line(unsafe-typecast)
        q.push(Request({owner: msg.sender, dueAt: uint40(block.timestamp) + DELAY, amount: amount}));
    }

    /// The caller's request, once STALL past due: its unfilled rest, now 0.
    function _cancel(Request[] storage q, uint256 id) internal returns (uint256 amount) {
        if (id >= q.length || q[id].owner != msg.sender) revert NotRequestOwner(id);
        Request storage r = q[id];
        uint40 from = r.dueAt + STALL;
        if (block.timestamp < from) revert CancelTooEarly(from);
        amount = r.amount;
        r.amount = 0;
    }

    /// The keeper's settlement, after its writes (IDeskQueue): skipped, never reverting, while
    /// a held series can't be advanced or there is no mark to settle at (_mark). Otherwise one
    /// price, OpenZeppelin's (nav + 1) / (supply + 1e6) with totalAssets at the new mark; the
    /// due deposits are filled first, at it and rounded down (their USDC becomes idle and can
    /// pay the redemptions), then the due redemptions out of idle USDC, rounded down, the last
    /// one partly if the USDC runs out. Each fill leaves the price per share where it was or
    /// higher. Each queue has its own MAX_SETTLE visits, cancelled requests counted too, so
    /// deposits can't crowd redemptions out. Nothing here calls out to an owner.
    function _settle() internal {
        // no request due yet (due times only grow along each queue): nothing to mark
        if (!_headDue(_deposits, _depositHead) && !_headDue(_queue, _queueHead)) return;
        if (!_advanceHeld()) return;
        (bool ok, uint256 nav, uint256 cutoff) = _mark();
        if (!ok) return;
        uint256 supply = totalSupply();
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Settled(uint40(cutoff), nav, supply); // cutoff <= now
        nav += 1;
        supply += 10 ** _decimalsOffset();
        uint256 budget = MAX_SETTLE;

        uint256 head = _depositHead;
        uint256 len = _deposits.length;
        uint256 assetsIn = 0;
        for (; head < len && budget != 0; budget--) {
            Request storage r = _deposits[head];
            if (r.dueAt > cutoff) break; // due times only grow along the queue
            uint256 assets = r.amount;
            if (assets != 0) {
                uint256 shares = Math.mulDiv(assets, supply, nav);
                r.amount = 0;
                assetsIn += assets;
                nav += assets;
                supply += shares;
                _mint(r.owner, shares);
                emit DepositFilled(head, r.owner, assets, shares);
            }
            head++;
        }
        _depositHead = head;
        pendingDepositAssets -= assetsIn;

        uint256 idle = _idle();
        budget = MAX_SETTLE;
        head = _queueHead;
        len = _queue.length;
        uint256 sharesOut = 0;
        uint256 assetsOut = 0;
        bool short = false;
        for (; head < len && budget != 0; budget--) {
            Request storage r = _queue[head];
            if (r.dueAt > cutoff) break;
            uint256 shares = r.amount;
            if (shares != 0) {
                uint256 assets = Math.mulDiv(shares, nav, supply);
                if (assets > idle) {
                    short = true;
                    shares = Math.mulDiv(shares, idle, assets);
                    assets = Math.mulDiv(shares, nav, supply); // <= idle
                }
                if (shares != 0) {
                    r.amount -= shares;
                    idle -= assets;
                    claimableAssets[r.owner] += assets;
                    sharesOut += shares;
                    assetsOut += assets;
                    emit RedeemFilled(head, r.owner, shares, assets);
                }
                if (short) break; // the USDC ran out: the rest waits
            }
            head++;
        }
        _queueHead = head;
        // the flag says whether a due redemption lacks USDC; it stays as it was only when the
        // visits ran out before one that is due, so this call couldn't tell
        if (short || budget != 0 || head == len || _queue[head].dueAt > cutoff) shortfall = short;
        if (sharesOut != 0) {
            queuedShares -= sharesOut;
            reservedAssets += assetsOut;
            _burn(address(this), sharesOut);
        }
    }

    function _headDue(Request[] storage q, uint256 head) internal view returns (bool) {
        return head < q.length && q[head].dueAt <= block.timestamp;
    }

    /// The mark settlement needs, in one pass over the held series without reverting:
    /// totalAssets (`nav`) and `cutoff`, the oldest sourceTime of the feeds of the series the
    /// Desk holds a position in (now when there is none). Not ok while a held series can't be
    /// quoted at the mid, while one of those feeds is atBound (its last write moved by a full
    /// step limit: the keeper is still catching up, and its next step is known; or was the
    /// owner's: no settlement price until the keeper's own write), or when that data is older
    /// than minUpdateGap.
    function _mark() internal view returns (bool ok, uint256 nav, uint256 cutoff) {
        nav = _idle();
        cutoff = block.timestamp;
        uint256 n = _held.length();
        for (uint256 i = 0; i < n; i++) {
            (bool quoted, uint256 value,, address feed) = _position(_held.at(i), false);
            if (!quoted) return (false, 0, 0);
            nav += value;
            if (feed != address(0)) {
                Market storage m = market[feed];
                if (m.atBound) return (false, 0, 0);
                cutoff = Math.min(cutoff, m.sourceTime);
            }
        }
        ok = block.timestamp - cutoff <= minUpdateGap;
    }

    function _balance(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// The Desk's NOTE + COVER of one series and the USDC released to them:
    /// their value and what they can still lose (IPerpDesk, risk budget), and
    /// the series' feed while the Desk has a position in it (address(0)
    /// otherwise). An unquotable series returns ok = false with its least value
    /// and its most at risk, unless `strict`, which bubbles the quoter's revert
    /// (totalAssets).
    function _position(address series, bool strict)
        internal
        view
        returns (bool ok, uint256 value, uint256 atRisk, address feed)
    {
        IPerpSeries s = IPerpSeries(series);
        value = s.claimable(address(this)); // the released cash, first
        uint256 n = _balance(s.note());
        uint256 w = _balance(s.cover());
        if (n == 0 && w == 0) return (true, value, 0, address(0));
        uint256 reserve;
        {
            PerpState memory st = s.state();
            if (st.phase == PerpPhase.Closed) return (true, value, 0, address(0)); // everything was released
            PerpTerms memory t = s.terms();
            feed = t.feed;
            reserve = t.couponReserve;
            n = Math.mulDiv(n, st.notionalPerToken, RAY); // from here on: USDC of live notional
            w = Math.mulDiv(w, st.notionalPerToken, RAY);
        }
        uint256 floorValue = Math.mulDiv(n, reserve, UNIT); // a NOTE is paid at least its coupon reserve

        uint256 noteBps = 0;
        if (strict) {
            noteBps = _mid(series, feed);
        } else {
            try this.midPriceBps(series) returns (uint16 p) {
                noteBps = p;
            } catch {
                return (false, value + floorValue, n + w, feed); // either leg can lose at most 1 USDC per unit
            }
        }
        uint256 pairBps = (UNIT + reserve) / UNIT_PER_BPS;
        noteBps = Math.min(noteBps, pairBps);
        uint256 noteValue = Math.mulDiv(n, noteBps, BPS);
        uint256 coverValue = Math.mulDiv(w, pairBps - noteBps, BPS);
        atRisk = coverValue + noteValue - Math.min(noteValue, floorValue);
        return (true, value + noteValue + coverValue, atRisk, feed);
    }
}
