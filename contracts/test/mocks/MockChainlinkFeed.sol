// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MockChainlinkFeed — test stand-in for a Chainlink price feed (ETH/USD, BTC/USD at launch).
/// Faithful to the REAL feed interface as probed on mainnet 2026-09-29:
/// latestRoundData / getRoundData / latestRound / decimals / description,
/// roundId = 2^64 + n. Deliberately NO oraclePaused() — the real feed doesn't
/// have one.
/// A stopped feed is NOT simulated in-contract: it emerges from not pushing.
/// pushRoundAt exists so tests can stage backdated rounds and gaps.
/// startPhase stages an aggregator upgrade: roundId = (phaseId << 64) + n,
/// with n restarting at 1 and the earlier phases' rounds still readable.
contract MockChainlinkFeed {
    uint80 public constant PHASE_OFFSET = uint80(1) << 64; // roundId = 2^64 + n in phase 1

    struct Round {
        int256 answer; // 8 decimals
        uint40 updatedAt;
    }

    address public owner;
    uint16 public phaseId = 1;
    mapping(uint16 phase => Round[]) internal _rounds; // _rounds[p][i] is round n = i+1 of phase p
    string public description;

    error NotOwner();
    error NoRounds();
    error UnknownRound(uint80 roundId);
    error NonMonotonic(uint40 updatedAt, uint40 last);

    constructor(string memory description_) {
        owner = msg.sender;
        description = description_;
    }

    /// Answer zeros for a round that doesn't exist instead of reverting, as Chainlink's
    /// OCR aggregators do (ETH/USD and BTC/USD on Arbitrum One).
    bool public zerosForUnknownRounds;

    function setZerosForUnknownRounds(bool on) external {
        if (msg.sender != owner) revert NotOwner();
        zerosForUnknownRounds = on;
    }

    /// A new aggregator behind the proxy: later pushes go to the new phase, from round 1.
    /// Its rounds may be backdated before the old phase's last one, as Chainlink runs
    /// the new aggregator alongside the old one before the switch.
    function startPhase() external {
        if (msg.sender != owner) revert NotOwner();
        phaseId++;
    }

    function pushRound(int256 answer) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        _push(answer, uint40(block.timestamp));
    }

    /// Tests only: a backdated round, to stage gaps and halts.
    function pushRoundAt(int256 answer, uint40 updatedAt) external {
        _push(answer, updatedAt);
    }

    function _push(int256 answer, uint40 updatedAt) internal {
        if (msg.sender != owner) revert NotOwner();
        Round[] storage rounds = _rounds[phaseId];
        uint256 n = rounds.length;
        if (n > 0 && updatedAt <= rounds[n - 1].updatedAt) revert NonMonotonic(updatedAt, rounds[n - 1].updatedAt);
        rounds.push(Round({answer: answer, updatedAt: updatedAt}));
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRound() external view returns (uint256) {
        uint256 n = _rounds[phaseId].length;
        if (n == 0) revert NoRounds();
        return (uint256(phaseId) << 64) + n;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        return getRoundData(uint80((uint256(phaseId) << 64) + _rounds[phaseId].length));
    }

    function getRoundData(uint80 roundId)
        public
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80)
    {
        uint256 phase = uint256(roundId) >> 64;
        uint256 n = uint64(roundId);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (phase == 0 || phase > phaseId || n == 0 || n > _rounds[uint16(phase)].length) {
            if (zerosForUnknownRounds) return (roundId, 0, 0, 0, roundId);
            revert UnknownRound(roundId);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        Round storage r = _rounds[uint16(phase)][n - 1]; // phase <= phaseId, a uint16
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}
