// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// MockUSDC — local/devnode stand-in for Circle's native USDC: 6 decimals, no
/// transfer fee, and the two issuer powers the core must survive: freezing
/// (blacklisting) an account and pausing all transfers and approvals. Anyone can mint: this
/// is a test token, never deploy it where value is at stake.
contract MockUSDC is ERC20 {
    address public immutable issuer;
    bool public paused;
    mapping(address => bool) public frozen;

    error NotIssuer();
    error Paused();
    error Frozen(address account);

    constructor() ERC20("Mock USD Coin", "USDC") {
        issuer = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        if (msg.sender != issuer) revert NotIssuer();
        paused = paused_;
    }

    function setFrozen(address account, bool frozen_) external {
        if (msg.sender != issuer) revert NotIssuer();
        frozen[account] = frozen_;
    }

    /// As in Circle's FiatToken, an approval also needs both parties unfrozen and the token unpaused.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        if (paused) revert Paused();
        if (frozen[owner]) revert Frozen(owner);
        if (frozen[spender]) revert Frozen(spender);
        super._approve(owner, spender, value, emitEvent);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (frozen[from]) revert Frozen(from);
        if (frozen[to]) revert Frozen(to);
        super._update(from, to, value);
    }
}
