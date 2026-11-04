// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ISeriesToken} from "./interfaces/ISeriesToken.sol";
import {IPerpSeries} from "./interfaces/IPerpSeries.sol";

/// NOTE or COVER of one perpetual series: an OpenZeppelin ERC-20 clone like
/// v1's SeriesToken, with two additions. First, before a transfer changes balances
/// it tells its series, which settles the USDC released so far to both holders (the
/// cumulative index of IPerpSeries). The series is the only contract called;
/// receivers get no hook. Balances never rebase: one token stands for less
/// notional after each fixing (series.state().notionalPerToken), and prices
/// are quoted per token. Only its series can mint or burn, and the series
/// settles the holder itself on those paths.
///
/// Second, EIP-2612 permit with a clone-safe EIP-712 domain. OpenZeppelin's
/// EIP712 keeps the domain in immutables set by the constructor, which a clone
/// shares with the implementation (empty name, the implementation's address).
/// Here the domain is rebuilt on every use from the clone's own state: the name
/// stored by `initialize`, version "1", `block.chainid` and `address(this)`.
/// Nothing is cached, so a chain id change (a fork) takes effect at once. The
/// implementation's own domain (empty name, its own address) can only set
/// allowances in its own storage, where no balance can exist.
contract PerpToken is ERC20, Nonces, ISeriesToken {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant HASHED_VERSION = keccak256("1");

    /// The factory that deployed this implementation. Immutable, so every
    /// clone sees the same value through delegatecall: only that factory can
    /// initialize a clone.
    address public immutable factory;

    address public series;
    bool public isNote;
    uint8 private _decimals;
    string private _name;
    string private _symbol;

    constructor() ERC20("", "") {
        factory = msg.sender;
        series = address(this); // the implementation itself is never initialized
    }

    /// Called once by the factory right after cloning. Sets the name, and with
    /// it this token's EIP-712 domain.
    function initialize(address series_, bool isNote_, uint8 decimals_, string calldata name_, string calldata symbol_)
        external
    {
        if (msg.sender != factory) revert OnlyFactory();
        if (series != address(0)) revert AlreadyInitialized();
        series = series_;
        isNote = isNote_;
        _decimals = decimals_;
        _name = name_;
        _symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _mint(to, amount);
    }

    /// No allowance: the series only ever burns its own caller's tokens.
    function burn(address from, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _burn(from, amount);
    }

    // --- EIP-2612 permit, ERC-5267 domain --------------------------------------------

    /// OpenZeppelin's ERC20Permit.permit, on this token's own domain.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), v, r, s);
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
        _approve(owner, spender, value);
    }

    function nonces(address owner) public view override(IERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory)
    {
        // 0x0f: name, version, chainId, verifyingContract
        return (hex"0f", _name, "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    // --- ERC-20 metadata -------------------------------------------------------------

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return _name;
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return _symbol;
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    /// Transfers settle both holders at the series first; mint and burn are
    /// series calls, which settle the holder before they get here.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            IPerpSeries(series).checkpoint(from, balanceOf(from), to, balanceOf(to));
        }
        super._update(from, to, value);
    }

    /// The EIP-712 domain separator of this token, from its own state on every call.
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(_name)), HASHED_VERSION, block.chainid, address(this))
            );
    }
}
