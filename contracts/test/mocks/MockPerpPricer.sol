// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPerpPricer, LineBands, PerpPricerInputs, PerpProduct} from "../../src/interfaces/IPerpPricer.sol";

/// Solidity stand-in for a Stylus model (featureSpecVersion 3) in unit tests.
/// Returns a set correction (or a set refusal), refuses a vol or a carry
/// outside its settable certified ranges, exposes a settable product and line
/// bands (the launch's by default), and can pin the exact input vector it
/// expects (to prove what the quoter sent).
contract MockPerpPricer is IPerpPricer {
    enum Mode {
        Correction,
        OutOfRangeErr,
        UncertifiedErr
    }

    int16 public correction;
    int16 public volSlope; // correction change in bps per 100 bps of vol above 7000 (the Desk fixture's vol)
    Mode public mode;
    uint8 public errA;
    int64 public errB;
    bytes32 public expectedInputs; // 0 = accept any
    bytes32 public weightsHash = keccak256("mock perp model");
    PerpProduct internal _product;
    // the launch's heal band and strip (docs/v2-spec.md §1), no buy-back discount and no minimum vol
    // band: a student without them (setLineBands sets the launch's)
    LineBands internal _lineBands = LineBands({
        healBandBps: 500,
        stripBelowBps: 200,
        stripAboveBps: 100,
        buyBackDiscountBps: 0,
        discountReachBps: 2000,
        minVolBandBps: 0
    });
    mapping(uint8 => int64) internal _min;
    mapping(uint8 => int64) internal _max;

    error UnexpectedInputs(PerpPricerInputs inputs);

    constructor() {
        // the launch's ETH product (daily fixings, k 40%) and its formula pricer's vol and carry ranges
        _product =
            PerpProduct({kiBarrierBps: 4000, meltShare: 2_735_976_403_140_715, fixingInterval: 86_400, discountBps: 0});
        _setRange(0, 2000, 13000);
        _setRange(1, 2400, 15_000);
        _setRange(2, 0, 86_400);
        _setRange(3, -2000, 5000);
        _setRange(4, 0, 1);
    }

    function _setRange(uint8 f, int64 lo, int64 hi) internal {
        _min[f] = lo;
        _max[f] = hi;
    }

    function setRange(uint8 f, int64 lo, int64 hi) external {
        _setRange(f, lo, hi);
    }

    function setProduct(PerpProduct calldata p) external {
        _product = p;
    }

    /// Any bands, ones PerpFormulaPricer refuses too (a reach inside the strip, say).
    function setLineBands(LineBands calldata b) external {
        _lineBands = b;
    }

    function setCorrection(int16 c) external {
        correction = c;
        mode = Mode.Correction;
    }

    /// A vol-sensitive model: correction + slope * (vol - 7000) / 100.
    function setVolSlope(int16 slope) external {
        volSlope = slope;
    }

    function setRefusal(Mode m, uint8 a, int64 b) external {
        mode = m;
        errA = a;
        errB = b;
    }

    function expect(bytes32 inputsHash) external {
        expectedInputs = inputsHash;
    }

    function setWeightsHash(bytes32 h) external {
        weightsHash = h;
    }

    function answer(PerpPricerInputs calldata inputs) external view returns (int16, PerpProduct memory, bytes32) {
        return (correctionBps(inputs), _product, weightsHash);
    }

    function correctionBps(PerpPricerInputs calldata inputs) public view returns (int16) {
        if (expectedInputs != bytes32(0) && keccak256(abi.encode(inputs)) != expectedInputs) {
            revert UnexpectedInputs(inputs);
        }
        if (mode == Mode.OutOfRangeErr) revert OutOfRange(errA, errB);
        if (mode == Mode.UncertifiedErr) revert Uncertified(errA);
        int64 vol = int64(uint64(inputs.volBpsAnnual));
        if (vol < _min[1] || vol > _max[1]) revert OutOfRange(1, vol);
        if (inputs.carryBpsAnnual < _min[3] || inputs.carryBpsAnnual > _max[3]) {
            revert OutOfRange(3, inputs.carryBpsAnnual);
        }
        return correction + int16(int256(volSlope) * (int256(vol) - 7000) / 100);
    }

    function certifiedRange(uint8 field) external view returns (int64, int64) {
        if (field > 4) revert OutOfRange(field, int64(uint64(field)));
        return (_min[field], _max[field]);
    }

    function lineBands() external view returns (LineBands memory) {
        return _lineBands;
    }

    function product() external view returns (PerpProduct memory) {
        return _product;
    }

    function featureSpecVersion() external pure returns (uint16) {
        return 3;
    }
}

/// A model from before IPerpPricer.lineBands (like today's Stylus student): the launch's ETH
/// product and a hash, everything a listing read before #32, and no lineBands.
contract MockPricerWithoutLineBands {
    function product() external pure returns (PerpProduct memory) {
        return
            PerpProduct({kiBarrierBps: 4000, meltShare: 2_735_976_403_140_715, fixingInterval: 86_400, discountBps: 0});
    }

    function weightsHash() external pure returns (bytes32) {
        return keccak256("a model without line bands");
    }

    function featureSpecVersion() external pure returns (uint16) {
        return 3;
    }
}

/// A model with #32's lineBands: the two bands, no strip (#67). Its answer is too short for the
/// Desk's LineBands, so it is refused at listing like a model without the view.
contract MockPricerWithTwoLineBands is MockPricerWithoutLineBands {
    function lineBands() external pure returns (uint16 knockInBandBps, uint16 healBandBps) {
        return (1000, 500);
    }
}
