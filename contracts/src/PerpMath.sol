// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// 1e18 fixed-point exp, ln and sqrt for PerpFormula. Written to be mirrored
/// line by line with plain integers (tools/perp_formula.py is the bit-exact
/// twin; PerpFormula.t.sol requires equality): range reduction by powers of
/// two, then a fixed number of series terms, every division truncating
/// towards zero. Absolute error of exp and ln is below 1e-16 over the ranges
/// the formula uses (measured against 50-digit references in the twin).
/// The series run unchecked: every operand is bounded by the range reduction
/// (products stay below 2^125), and the reduction itself is checked.
library PerpMath {
    int256 internal constant WAD = 1e18;
    int256 internal constant LN2 = 693_147_180_559_945_309; // ln 2, WAD
    int256 internal constant EXP_MIN = -41_446_531_673_892_822_312; // e^x < 1e-18 below this: returns 0
    int256 internal constant EXP_MAX = 80e18; // far beyond any use here; keeps the shift in range

    error ExpOverflow(int256 x);
    error LnNonPositive();

    // Fixed point: a product of two WAD values is divided by WAD before the next
    // multiplication, and the range reductions multiply a truncated quotient back on purpose.
    // forge-lint: disable-start(divide-before-multiply)

    /// e^x, x and the result in WAD.
    function expWad(int256 x) internal pure returns (int256) {
        if (x <= EXP_MIN) return 0;
        if (x > EXP_MAX) revert ExpOverflow(x);
        // x = k * ln2 + r with |r| <= ln2 / 2 (k rounded to nearest)
        int256 k = (x >= 0 ? x + LN2 / 2 : x - LN2 / 2) / LN2;
        int256 r = x - k * LN2;
        // e^r by its Taylor series: |r| < 0.35, 16 terms leave less than 1e-20
        int256 term = WAD;
        int256 sum = WAD;
        unchecked {
            for (int256 n = 1; n <= 16; n++) {
                term = term * r / (n * WAD);
                sum += term;
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return k >= 0 ? sum << uint256(k) : sum >> uint256(-k); // |k| <= 116
    }

    /// ln x, x > 0 and the result in WAD.
    function lnWad(int256 x) internal pure returns (int256) {
        if (x <= 0) revert LnNonPositive();
        // x = y * 2^k with y in [2^59, 2^60), i.e. y / WAD in [0.576, 1.153)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 k = int256(Math.log2(uint256(x))) - 59; // x > 0, log2 < 256
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 y = k >= 0 ? x >> uint256(k) : x << uint256(-k);
        // ln y = 2 * atanh(z), z = (y - 1) / (y + 1), |z| < 0.27: odd powers up to 33 leave less than 1e-20
        unchecked {
            int256 z = (y - WAD) * WAD / (y + WAD);
            int256 z2 = z * z / WAD;
            int256 power = z;
            int256 sum = z;
            for (int256 n = 3; n <= 33; n += 2) {
                power = power * z2 / WAD;
                sum += power / n;
            }
            return 2 * sum + k * LN2;
        }
    }

    // forge-lint: disable-end(divide-before-multiply)

    /// sqrt(x), x and the result in WAD, rounded down.
    function sqrtWad(uint256 x) internal pure returns (uint256) {
        return Math.sqrt(x * 1e18);
    }

    /// x^y = e^(y * ln x), x > 0; all in WAD.
    function powWad(int256 lnX, int256 y) internal pure returns (int256) {
        return expWad(y * lnX / WAD);
    }
}
