// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/// NOTE or COVER of one series: a plain ERC-20 (no hooks, no rebasing, no
/// fees), decimals = the collateral's (6: USDC in v2, USDG in v1). Only its series can mint or burn.
///
/// EIP-2612 permit (`permit`, `nonces`, `DOMAIN_SEPARATOR`) and ERC-5267
/// `eip712Domain()`. The EIP-712 domain is the token's own: name = `name()`,
/// version "1", chainId = the current chain, verifyingContract = the token
/// (the series' clone, never the shared implementation); no salt, no
/// extensions. A wallet that builds the domain from `name()` or from
/// `eip712Domain()` signs the right one, and a signature for one token is
/// invalid on every other, NOTE and COVER of the same series included.
/// `permit` reverts with ERC2612ExpiredSignature once `block.timestamp > deadline`,
/// with ERC2612InvalidSigner when the signature is not the owner's for this
/// domain and the owner's current nonce (a replay included), and with
/// OpenZeppelin's ECDSA errors on a malformed signature (high s, bad v).
interface ISeriesToken is IERC20Metadata, IERC20Permit, IERC5267 {
    error OnlySeries();
    error OnlyFactory(); // initialize called by anyone but the deploying factory
    error AlreadyInitialized(); // initialize called twice
    error ERC2612ExpiredSignature(uint256 deadline); // permit after its deadline
    error ERC2612InvalidSigner(address signer, address owner); // signer = who the signature recovers to

    function series() external view returns (address);
    function isNote() external view returns (bool); // false = COVER

    function mint(address to, uint256 amount) external; // only series
    function burn(address from, uint256 amount) external; // only series; the series burns its own caller's tokens
}
