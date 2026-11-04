// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PerpBase} from "./PerpBase.t.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpToken} from "../src/PerpToken.sol";
import {IPerpSeries, PerpTerms} from "../src/interfaces/IPerpSeries.sol";
import {ISeriesToken} from "../src/interfaces/ISeriesToken.sol";

/// EIP-2612 permit and the ERC-5267 domain on NOTE and COVER (docs/v2-spec.md §9). The
/// tokens are clones: each must sign on its own domain (its name, version "1", the
/// chain, its own address), never on the implementation's. Digests here are built
/// independently of the token: by hand from `name()`, and from a wallet's typed-data JSON.
contract PerpTokenPermitTest is PerpBase {
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// Two first fixings at 08:00 UTC (whole days after T0 + 1 hour) whose ETH launch terms on
    /// a feed at FEED_AT give seriesIds with the same first 4 bytes, so their NOTEs (and COVERs)
    /// carry the same name. Found offline by a birthday search over keccak256(abi.encode(terms)),
    /// 58,709 candidates; the test checks the names still collide.
    address constant FEED_AT = address(0xFEED);
    uint40 constant SAME_TAG_FIRST_A = 3_556_252_800; // both tagged 0x1143063b
    uint40 constant SAME_TAG_FIRST_B = 6_862_348_800;

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    PerpSeries s;
    PerpToken note;
    PerpToken cover;
    uint40 first;
    address owner;
    uint256 ownerKey;
    address spender = makeAddr("spender");

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("owner");
        first = T0 + 1 hours;
        s = _create(_terms(first));
        note = _note(s);
        cover = _cover(s);
        _fix(s, 0, 10000);
        _mintPairs(s, owner, 100e6);
    }

    // --- helpers: the digest a wallet signs, built without the token's help -----------

    function _domain(PerpToken t) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(t.name())), keccak256("1"), block.chainid, address(t))
            );
    }

    function _digest(PerpToken t, address o, address sp, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, o, sp, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domain(t), structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (Sig memory sig) {
        (sig.v, sig.r, sig.s) = vm.sign(key, digest);
    }

    /// The owner's signature for `t` at the owner's current nonce there.
    function _signFor(PerpToken t, address sp, uint256 value, uint256 deadline) internal view returns (Sig memory) {
        return _sign(ownerKey, _digest(t, owner, sp, value, t.nonces(owner), deadline));
    }

    function _permit(PerpToken t, address o, address sp, uint256 value, uint256 deadline, Sig memory sig) internal {
        t.permit(o, sp, value, deadline, sig.v, sig.r, sig.s);
    }

    /// What `t` recovers from `sig` for these values at the owner's current nonce: the
    /// signer in the ERC2612InvalidSigner of a signature made for something else.
    function _recovered(PerpToken t, address sp, uint256 value, uint256 deadline, Sig memory sig)
        internal
        view
        returns (address)
    {
        return ecrecover(_digest(t, owner, sp, value, t.nonces(owner), deadline), sig.v, sig.r, sig.s);
    }

    function _expectInvalidSigner(PerpToken t, address sp, uint256 value, uint256 deadline, Sig memory sig) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeriesToken.ERC2612InvalidSigner.selector, _recovered(t, sp, value, deadline, sig), owner
            )
        );
    }

    /// `name()` as the spec writes it: the first 4 bytes of seriesId as 0x and 8 hex digits.
    function _tag(PerpTerms memory t) internal view returns (string memory) {
        return Strings.toHexString(uint256(uint32(bytes4(factory.seriesId(t)))), 4);
    }

    // --- the domain -----------------------------------------------------------------

    function test_domain_is_the_clones_own() public view {
        string memory tag = _tag(_terms(first));
        assertEq(note.name(), string.concat("Perpetual NOTE ", tag));
        assertEq(cover.name(), string.concat("Perpetual COVER ", tag));

        PerpToken[2] memory tokens = [note, cover];
        for (uint256 i; i < 2; ++i) {
            PerpToken t = tokens[i];
            (
                bytes1 fields,
                string memory name,
                string memory version,
                uint256 chainId,
                address verifyingContract,
                bytes32 salt,
                uint256[] memory extensions
            ) = t.eip712Domain();
            assertEq(uint8(fields), 0x0f); // name, version, chainId, verifyingContract
            assertEq(name, t.name());
            assertEq(version, "1");
            assertEq(chainId, block.chainid);
            assertEq(verifyingContract, address(t));
            assertEq(salt, bytes32(0));
            assertEq(extensions.length, 0);
            // the separator equals the one built from name() and the one ERC-5267 says to build
            assertEq(t.DOMAIN_SEPARATOR(), _domain(t));
            assertEq(
                t.DOMAIN_SEPARATOR(),
                MessageHashUtils.toDomainSeparator(fields, name, version, chainId, verifyingContract, salt)
            );
        }
        assertTrue(note.DOMAIN_SEPARATOR() != cover.DOMAIN_SEPARATOR());
    }

    /// A wallet's eth_signTypedData_v4 payload, its domain filled from name(): what it signs
    /// is what permit accepts.
    function test_wallet_typed_data_from_name_is_accepted() public {
        uint256 deadline = block.timestamp + 1 hours;
        string memory json = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},',
            '{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},',
            '"primaryType":"Permit","domain":{"name":"',
            note.name(),
            '","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(note)),
            '"},"message":{"owner":"',
            vm.toString(owner),
            '","spender":"',
            vm.toString(spender),
            '","value":"25000000","nonce":"0","deadline":"',
            vm.toString(deadline),
            '"}}'
        );
        bytes32 digest = vm.eip712HashTypedData(json);
        assertEq(digest, _digest(note, owner, spender, 25e6, 0, deadline));
        _permit(note, owner, spender, 25e6, deadline, _sign(ownerKey, digest));
        assertEq(note.allowance(owner, spender), 25e6);
    }

    // --- permit ---------------------------------------------------------------------

    function test_permit_then_transferFrom() public {
        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(note, spender, 30e6, deadline);
        vm.expectEmit(address(note));
        emit IERC20.Approval(owner, spender, 30e6);
        vm.prank(bob); // anyone may submit it
        _permit(note, owner, spender, 30e6, deadline, sig);
        assertEq(note.allowance(owner, spender), 30e6);
        assertEq(note.nonces(owner), 1);

        vm.prank(spender);
        note.transferFrom(owner, bob, 30e6);
        assertEq(note.balanceOf(owner), 70e6);
        assertEq(note.balanceOf(bob), 30e6);
        assertEq(note.allowance(owner, spender), 0);
        assertEq(cover.balanceOf(owner), 100e6); // the sibling is untouched
    }

    function test_permit_at_the_deadline_is_accepted() public {
        uint256 deadline = block.timestamp;
        _permit(note, owner, spender, 1e6, deadline, _signFor(note, spender, 1e6, deadline));
        assertEq(note.allowance(owner, spender), 1e6);
    }

    function test_permit_replaces_the_allowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(owner);
        note.approve(spender, 50e6);
        _permit(note, owner, spender, 5e6, deadline, _signFor(note, spender, 5e6, deadline));
        assertEq(note.allowance(owner, spender), 5e6);
        _permit(note, owner, spender, 0, deadline, _signFor(note, spender, 0, deadline));
        assertEq(note.allowance(owner, spender), 0);
    }

    function test_replay_is_rejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(note, spender, 30e6, deadline);
        _permit(note, owner, spender, 30e6, deadline, sig);
        vm.prank(spender);
        note.transferFrom(owner, spender, 30e6);

        // the nonce moved on: the same signature recovers to someone else
        _expectInvalidSigner(note, spender, 30e6, deadline, sig);
        _permit(note, owner, spender, 30e6, deadline, sig);
        assertEq(note.allowance(owner, spender), 0);
        assertEq(note.nonces(owner), 1);
    }

    function test_expired_is_rejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(note, spender, 30e6, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ISeriesToken.ERC2612ExpiredSignature.selector, deadline));
        _permit(note, owner, spender, 30e6, deadline, sig);
        assertEq(note.nonces(owner), 0);
    }

    function test_wrong_signer_is_rejected() public {
        (address mallory, uint256 malloryKey) = makeAddrAndKey("mallory");
        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _sign(malloryKey, _digest(note, owner, mallory, 100e6, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ISeriesToken.ERC2612InvalidSigner.selector, mallory, owner));
        _permit(note, owner, mallory, 100e6, deadline, sig);
        // a signature for other values than the ones submitted
        sig = _signFor(note, spender, 1e6, deadline);
        _expectInvalidSigner(note, spender, 100e6, deadline, sig);
        _permit(note, owner, spender, 100e6, deadline, sig);
        // owner 0: recover never returns address(0), so no signature permits it
        sig = _sign(ownerKey, _digest(note, address(0), spender, 1e6, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ISeriesToken.ERC2612InvalidSigner.selector, owner, address(0)));
        _permit(note, address(0), spender, 1e6, deadline, sig);
        assertEq(note.nonces(owner), 0);
        assertEq(note.nonces(address(0)), 0);
    }

    function test_malleable_signature_is_rejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(note, spender, 30e6, deadline);
        // the same signature with s mirrored to the upper half: ecrecover accepts it, ECDSA doesn't
        Sig memory flipped = Sig({v: sig.v == 27 ? 28 : 27, r: sig.r, s: bytes32(SECP256K1_N - uint256(sig.s))});
        assertEq(_recovered(note, spender, 30e6, deadline, flipped), owner);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, flipped.s));
        _permit(note, owner, spender, 30e6, deadline, flipped);
        // a v that is neither 27 nor 28
        Sig memory badV = Sig({v: 29, r: sig.r, s: sig.s});
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _permit(note, owner, spender, 30e6, deadline, badV);
    }

    function test_nonces_count_per_token_and_owner() public {
        uint256 deadline = block.timestamp + 1 hours;
        for (uint256 i; i < 3; ++i) {
            assertEq(note.nonces(owner), i);
            _permit(note, owner, spender, i, deadline, _signFor(note, spender, i, deadline));
        }
        assertEq(note.nonces(owner), 3);
        assertEq(cover.nonces(owner), 0);
        assertEq(note.nonces(spender), 0);
        _permit(cover, owner, spender, 7, deadline, _signFor(cover, spender, 7, deadline));
        assertEq(cover.nonces(owner), 1);
        assertEq(note.nonces(owner), 3);
    }

    // --- a signature is valid on one token only ------------------------------------------

    function test_note_signature_is_rejected_by_its_cover_and_another_series() public {
        PerpSeries other = _create(_terms(first + DAY));
        PerpToken otherNote = _note(other);
        assertEq(note.nonces(owner), cover.nonces(owner));
        assertEq(note.nonces(owner), otherNote.nonces(owner));

        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(note, spender, 30e6, deadline);
        _expectInvalidSigner(cover, spender, 30e6, deadline, sig);
        _permit(cover, owner, spender, 30e6, deadline, sig);
        _expectInvalidSigner(otherNote, spender, 30e6, deadline, sig);
        _permit(otherNote, owner, spender, 30e6, deadline, sig);
        // and the COVER's own signature is no good on the NOTE
        Sig memory coverSig = _signFor(cover, spender, 30e6, deadline);
        _expectInvalidSigner(note, spender, 30e6, deadline, coverSig);
        _permit(note, owner, spender, 30e6, deadline, coverSig);

        _permit(note, owner, spender, 30e6, deadline, sig);
        assertEq(note.allowance(owner, spender), 30e6);
        assertEq(cover.allowance(owner, spender), 0);
        assertEq(otherNote.allowance(owner, spender), 0);
    }

    /// Two series whose seriesIds share their first 4 bytes: their NOTEs have the same name,
    /// and the domain still tells them apart by address.
    function test_same_name_different_token_rejected() public {
        vm.etch(FEED_AT, address(feed).code);
        PerpTerms memory ta = _terms(SAME_TAG_FIRST_A);
        PerpTerms memory tb = _terms(SAME_TAG_FIRST_B);
        ta.feed = FEED_AT;
        tb.feed = FEED_AT;
        assertTrue(factory.seriesId(ta) != factory.seriesId(tb));
        PerpToken a = _note(_create(ta));
        PerpToken b = _note(_create(tb));
        assertEq(a.name(), b.name(), "the two first fixings no longer share a tag");
        assertEq(_cover(PerpSeries(a.series())).name(), _cover(PerpSeries(b.series())).name());
        assertTrue(a.DOMAIN_SEPARATOR() != b.DOMAIN_SEPARATOR());

        uint256 deadline = block.timestamp + 1 hours;
        Sig memory sig = _signFor(a, spender, 30e6, deadline);
        _expectInvalidSigner(b, spender, 30e6, deadline, sig);
        _permit(b, owner, spender, 30e6, deadline, sig);
        _permit(a, owner, spender, 30e6, deadline, sig);
        assertEq(a.allowance(owner, spender), 30e6);
        assertEq(b.allowance(owner, spender), 0);
    }

    // --- the implementation ---------------------------------------------------------------

    /// The implementation's domain has an empty name and its own address. A permit there
    /// writes an allowance into the implementation's storage, which holds no balance and
    /// can't move one; the clones keep their own storage and domain.
    function test_implementation_permit_touches_no_clone() public {
        PerpToken impl = PerpToken(factory.tokenImplementation());
        (, string memory name,,, address verifyingContract,,) = impl.eip712Domain();
        assertEq(name, "");
        assertEq(verifyingContract, address(impl));
        assertEq(impl.DOMAIN_SEPARATOR(), _domain(impl));
        assertTrue(impl.DOMAIN_SEPARATOR() != note.DOMAIN_SEPARATOR());

        uint256 deadline = block.timestamp + 1 hours;
        // a clone's signature is no good on the implementation, and the other way round
        Sig memory noteSig = _signFor(note, spender, 30e6, deadline);
        _expectInvalidSigner(impl, spender, 30e6, deadline, noteSig);
        _permit(impl, owner, spender, 30e6, deadline, noteSig);
        Sig memory implSig = _signFor(impl, spender, 30e6, deadline);
        _expectInvalidSigner(note, spender, 30e6, deadline, implSig);
        _permit(note, owner, spender, 30e6, deadline, implSig);
        _expectInvalidSigner(cover, spender, 30e6, deadline, implSig);
        _permit(cover, owner, spender, 30e6, deadline, implSig);

        // on its own domain it sets the implementation's allowance only
        _permit(impl, owner, spender, 30e6, deadline, implSig);
        assertEq(impl.allowance(owner, spender), 30e6);
        assertEq(impl.nonces(owner), 1);
        assertEq(note.allowance(owner, spender), 0);
        assertEq(cover.allowance(owner, spender), 0);
        assertEq(note.nonces(owner), 0);
        assertEq(cover.nonces(owner), 0);

        // which moves nothing: no balance there, and a transfer calls checkpoint on the
        // implementation itself, which has no such function
        assertEq(impl.totalSupply(), 0);
        assertEq(impl.balanceOf(owner), 0);
        vm.prank(spender);
        vm.expectRevert();
        impl.transferFrom(owner, spender, 0);
        vm.expectRevert(ISeriesToken.OnlySeries.selector);
        impl.mint(owner, 1);
    }

    // --- a chain id change -------------------------------------------------------------

    function test_chain_id_change_moves_the_domain() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 before = note.DOMAIN_SEPARATOR();
        Sig memory oldChain = _signFor(note, spender, 30e6, deadline);

        vm.chainId(42_161);
        assertTrue(note.DOMAIN_SEPARATOR() != before);
        assertEq(note.DOMAIN_SEPARATOR(), _domain(note));
        (,,, uint256 chainId,,,) = note.eip712Domain();
        assertEq(chainId, 42_161);

        // a signature from the old chain is not valid on the new one
        _expectInvalidSigner(note, spender, 30e6, deadline, oldChain);
        _permit(note, owner, spender, 30e6, deadline, oldChain);
        _permit(note, owner, spender, 30e6, deadline, _signFor(note, spender, 30e6, deadline));
        assertEq(note.allowance(owner, spender), 30e6);

        // and back
        vm.chainId(31_337);
        assertEq(note.DOMAIN_SEPARATOR(), before);
    }

    // --- the series' accounting through a permit ------------------------------------------

    /// PerpSeriesTest.test_transfer_settles_both_holders, the transfer made by a spender on
    /// a permit: transferFrom checkpoints both holders, the spender holds nothing.
    function test_permit_transferFrom_settles_both_holders() public {
        _fix(s, 1, 9000);
        s.advance();
        uint256 rel1 = s.state().noteIndex;

        uint256 deadline = block.timestamp + 1 hours;
        _permit(note, owner, spender, 40e6, deadline, _signFor(note, spender, 40e6, deadline));
        vm.prank(spender);
        note.transferFrom(owner, bob, 40e6);
        assertEq(s.claimable(owner), 100e6 * rel1 / RAY);
        assertEq(s.claimable(bob), 0);

        _fix(s, 2, 9500);
        s.advance();
        uint256 rel2 = s.state().noteIndex - rel1;
        assertEq(s.claimable(owner), 100e6 * rel1 / RAY + 60e6 * rel2 / RAY);
        assertEq(s.claimable(bob), 40e6 * rel2 / RAY);
        assertEq(s.claimable(spender), 0);
    }

    /// PerpSeriesTest.test_transfer_processes_a_recorded_fixing_first, on a permit: the
    /// release of fixing 1 belongs to the holder at the fixing.
    function test_permit_transferFrom_processes_a_recorded_fixing_first() public {
        _fix(s, 1, 9000); // recorded, not advanced
        uint256 deadline = block.timestamp + 1 hours;
        _permit(note, owner, spender, 100e6, deadline, _signFor(note, spender, 100e6, deadline));
        // the permit left the fixing alone: the transfer processes it
        vm.expectEmit(true, false, false, false, address(s));
        emit IPerpSeries.FixingProcessed(1, 0, 0, 0, false, false, 0, 0, 0);
        vm.prank(spender);
        note.transferFrom(owner, bob, 100e6);
        assertEq(s.claimable(owner), 273_597);
        assertEq(s.claimable(bob), 0);
        assertEq(s.state().fixingsDone, 1);
    }

    /// PerpSeriesTest.test_cover_leg_is_settled_separately, the COVER moved on a permit.
    function test_permit_transferFrom_settles_the_cover_leg() public {
        uint256 deadline = block.timestamp + 1 hours;
        _permit(cover, owner, spender, 100e6, deadline, _signFor(cover, spender, 100e6, deadline));
        vm.prank(spender);
        cover.transferFrom(owner, bob, 100e6); // bob is the hedger, owner keeps NOTE
        _fix(s, 1, 3000);
        s.advance();
        assertEq(s.claimable(owner), 82_079);
        assertEq(s.claimable(bob), 191_518);
        assertEq(s.claimable(spender), 0);
    }

    // --- fuzz -----------------------------------------------------------------------------

    function testFuzz_permit_sets_the_allowance(uint256 key, address sp, uint256 value, uint256 deadline) public {
        vm.assume(sp != address(0)); // OpenZeppelin's _approve: ERC20InvalidSpender
        key = bound(key, 1, SECP256K1_N - 1);
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        address o = vm.addr(key);
        Sig memory sig = _sign(key, _digest(note, o, sp, value, 0, deadline));
        _permit(note, o, sp, value, deadline, sig);
        assertEq(note.allowance(o, sp), value);
        assertEq(note.nonces(o), 1);
        // and only on this token: its sibling recovers some other address from the same signature
        address recovered = ecrecover(_digest(cover, o, sp, value, 0, deadline), sig.v, sig.r, sig.s);
        vm.expectRevert(abi.encodeWithSelector(ISeriesToken.ERC2612InvalidSigner.selector, recovered, o));
        _permit(cover, o, sp, value, deadline, sig);
    }

    function testFuzz_expired_is_rejected(uint256 value, uint256 deadline, uint256 later) public {
        deadline = bound(deadline, 0, type(uint256).max - 1);
        later = bound(later, deadline + 1, type(uint256).max);
        Sig memory sig = _sign(ownerKey, _digest(note, owner, spender, value, 0, deadline));
        vm.warp(later);
        vm.expectRevert(abi.encodeWithSelector(ISeriesToken.ERC2612ExpiredSignature.selector, deadline));
        _permit(note, owner, spender, value, deadline, sig);
    }

    function testFuzz_permit_then_transferFrom(uint256 value, uint256 amount) public {
        uint256 deadline = block.timestamp + 1 hours;
        amount = bound(amount, 0, value < 100e6 ? value : 100e6);
        _permit(note, owner, spender, value, deadline, _signFor(note, spender, value, deadline));
        vm.prank(spender);
        note.transferFrom(owner, bob, amount);
        assertEq(note.balanceOf(owner), 100e6 - amount);
        assertEq(note.balanceOf(bob), amount);
        // OpenZeppelin's ERC20: an allowance of type(uint256).max is never spent
        assertEq(note.allowance(owner, spender), value == type(uint256).max ? value : value - amount);
    }
}
