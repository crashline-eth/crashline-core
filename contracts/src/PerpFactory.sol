// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPerpFactory} from "./interfaces/IPerpFactory.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {PerpTerms} from "./interfaces/IPerpSeries.sol";
import {PerpSeries} from "./PerpSeries.sol";
import {PerpToken} from "./PerpToken.sol";
import {FixingsRecorder} from "./FixingsRecorder.sol";

/// L1 entry point of the v2 perpetual note. Permissionless, deterministic, no
/// admin. Deploys its own PerpSeries and PerpToken implementations, so only
/// clones initialized by this factory exist behind `isSeries`. Series, NOTE
/// and COVER are clones at CREATE2 addresses derived from seriesId. One
/// FixingsRecorder per feed (8 decimals), deployed by this factory at a
/// CREATE2 address with the factory's recorder limits, shared by every series
/// on that feed. Nothing here depends on v1.
contract PerpFactory is IPerpFactory {
    uint8 public constant COLLATERAL_DECIMALS = 6; // amounts are per 1e6 base units
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint16 public constant MAX_BARRIER_BPS = 10_000; // the knock-in sits at or below the reference
    uint64 public constant MAX_MELT_SHARE = 1e18; // exclusive
    uint64 public constant MAX_COUPON_RESERVE = 5e6; // 5 x the notional: keeps a price in bps inside uint16
    uint64 public constant COUPON_RESERVE_STEP = 100; // 1 bps of notional: prices are in bps, the pair value must be exact in them

    address public immutable collateral;
    uint40 internal immutable _maxFixAge;
    int256 internal immutable _priceMax;
    address internal immutable _sequencer;
    uint40 internal immutable _sequencerGrace;
    address public immutable seriesImplementation;
    address public immutable tokenImplementation;

    mapping(bytes32 => address) public seriesOf;
    mapping(address => bool) public isSeries;
    address[] internal _allSeries;

    error BadCollateral();

    constructor(address collateral_, RecorderLimits memory limits) {
        if (IERC20Metadata(collateral_).decimals() != COLLATERAL_DECIMALS) revert BadCollateral();
        collateral = collateral_;
        // the recorder stores a price as uint96
        if (limits.maxFixAge == 0 || limits.priceMax <= 0 || limits.priceMax > int256(uint256(type(uint96).max))) {
            revert BadRecorderLimits();
        }
        _maxFixAge = limits.maxFixAge;
        _priceMax = limits.priceMax;
        _sequencer = limits.sequencer;
        _sequencerGrace = limits.sequencerGrace;
        seriesImplementation = address(new PerpSeries(limits.sequencer, limits.sequencerGrace));
        tokenImplementation = address(new PerpToken());
    }

    // --- views ------------------------------------------------------------------

    function seriesId(PerpTerms calldata terms) public pure returns (bytes32) {
        return keccak256(abi.encode(terms));
    }

    function predictSeries(PerpTerms calldata terms)
        external
        view
        returns (address series, address note, address cover)
    {
        bytes32 id = seriesId(terms);
        series = Clones.predictDeterministicAddress(seriesImplementation, id);
        note = Clones.predictDeterministicAddress(tokenImplementation, _tokenSalt(id, true));
        cover = Clones.predictDeterministicAddress(tokenImplementation, _tokenSalt(id, false));
    }

    function allSeries() external view returns (address[] memory) {
        return _allSeries;
    }

    function recorderLimits() external view returns (RecorderLimits memory) {
        return RecorderLimits({
            maxFixAge: _maxFixAge, priceMax: _priceMax, sequencer: _sequencer, sequencerGrace: _sequencerGrace
        });
    }

    function recorderOf(address feed) public view returns (address) {
        return Create2.computeAddress(bytes32(0), keccak256(_recorderInitCode(feed)));
    }

    /// Permissionless and idempotent: the feed's recorder, deployed if needed.
    function deployRecorder(address feed) public returns (address recorder) {
        recorder = recorderOf(feed);
        if (recorder.code.length != 0) return recorder;
        _checkFeed(feed);
        Create2.deploy(0, bytes32(0), _recorderInitCode(feed));
        emit RecorderDeployed(feed, recorder);
    }

    // --- permissionless deployment ---------------------------------------------

    function createSeries(PerpTerms calldata terms) external returns (address series) {
        bytes32 id = seriesId(terms);
        series = seriesOf[id];
        if (series != address(0)) return series;

        _checkTerms(terms);

        series = Clones.cloneDeterministic(seriesImplementation, id);
        address note = Clones.cloneDeterministic(tokenImplementation, _tokenSalt(id, true));
        address cover = Clones.cloneDeterministic(tokenImplementation, _tokenSalt(id, false));
        // register before the external calls: the feed (checked, BadFeed) and the trusted initialize calls
        seriesOf[id] = series;
        isSeries[series] = true;
        _allSeries.push(series);
        address recorder = deployRecorder(terms.feed);

        // forge-lint: disable-next-line(unsafe-typecast)
        string memory tag = Strings.toHexString(uint256(uint32(bytes4(id))), 4); // bytes4 -> uint32 is exact
        PerpToken(note)
            .initialize(
                series, true, COLLATERAL_DECIMALS, string.concat("Perpetual NOTE ", tag), string.concat("pNOTE-", tag)
            );
        PerpToken(cover)
            .initialize(
                series,
                false,
                COLLATERAL_DECIMALS,
                string.concat("Perpetual COVER ", tag),
                string.concat("pCOVER-", tag)
            );
        PerpSeries(series).initialize(id, terms, note, cover, recorder, collateral);
        emit PerpSeriesCreated(id, terms.feed, series, note, cover, terms);
    }

    // --- internals --------------------------------------------------------------

    function _checkTerms(PerpTerms calldata t) internal pure {
        if (t.firstFixing == 0 || t.fixingInterval < MIN_INTERVAL) revert BadSchedule();
        if (t.kiBarrierBps == 0 || t.kiBarrierBps > MAX_BARRIER_BPS) revert BadBarrier();
        if (t.meltShare == 0 || t.meltShare >= MAX_MELT_SHARE) revert BadMeltShare();
        if (t.couponReserve > MAX_COUPON_RESERVE || t.couponReserve % COUPON_RESERVE_STEP != 0) {
            revert BadCouponReserve();
        }
    }

    function _checkFeed(address feed) internal view {
        if (feed.code.length == 0) revert BadFeed();
        try IAggregatorV3(feed).decimals() returns (uint8 d) {
            if (d != 8) revert BadFeed();
        } catch {
            revert BadFeed();
        }
    }

    /// Creation code + ABI-encoded constructor arguments: the standard CREATE2 init code.
    // forge-lint: disable-next-item(encode-packed-collision)
    function _recorderInitCode(address feed) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(FixingsRecorder).creationCode, abi.encode(feed, _maxFixAge, _priceMax, _sequencer, _sequencerGrace)
        );
    }

    function _tokenSalt(bytes32 id, bool isNote) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, isNote));
    }
}
