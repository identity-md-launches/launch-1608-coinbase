# Coinbase (COINBASE)

A fixed-supply ERC-20 built with Solidity 0.8.26 and the vendored OpenZeppelin
Contracts v5.0.2 implementation.

## Token behavior

| Property | Value |
| --- | --- |
| Solidity artifact | `src/Coinbase.sol:Coinbase` |
| Name | `Coinbase` |
| Symbol | `COINBASE` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None |
| Initial recipient | Immediate deployer (`msg.sender`) |
| Initialization or post-deployment settings | None |

The constructor mints the entire supply once and emits the standard mint
`Transfer` event. Transfers deliver the exact amount requested. There are no
fees, rebases, supply allocations inside the token, public mint or burn functions,
owner roles, pause controls, blacklists, upgrades, or external contract calls.
The deployer has the same transfer and allowance permissions as every holder.

`transfer`, `approve`, and `transferFrom` return `true` on success and revert with
OpenZeppelin ERC-20 custom errors on failure. Zero-value transfers are accepted;
transfers to the zero address and approvals to the zero spender are rejected.
Self-transfers preserve balances. Finite allowances decrease when spent, while
`type(uint256).max` is an unlimited allowance and is not decreased. `approve`
replaces the existing allowance, and approving zero revokes it. `transferFrom`
requires an allowance even when its caller owns the tokens.

Minting and transfers emit `Transfer`; explicit approvals emit `Approval`.
This implementation does not emit `Approval` when `transferFrom` spends an
allowance. Integrations should read `allowance` for its current value.

## Build and check

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
sha256sum --check DEPENDENCIES.sha256
```

All Solidity dependencies and their licenses are ordinary files under `lib/`;
no dependency download, submodule, RPC, environment variable, FFI, or filesystem
permission is needed by the tests. See [DEPENDENCIES.md](DEPENDENCIES.md) for
versions and provenance. Foundry itself and the pinned compiler are runtime
prerequisites supplied by the verification environment.

The configuration uses the Cancun EVM target, optimization with 200 runs, and
`bytecode_hash = "none"`. Unit tests exercise metadata, constructor minting and
events, direct and CREATE2 factory deployment, launch distribution transfers,
transfer/approval success and failure, atomic reverts, full balances, zero and
maximum values, self-transfers, and absence of privileged entrypoints/opcodes.
Four fuzz tests run 512 cases each. Two stateful invariants run 128 sequences of
64 calls each, comparing balances and allowances against an independent model.
Each test deploys fresh contracts and needs no shared state or environment.

The factory test models the token movements for distribution, claims, and pool
transfers. It does not simulate Uniswap pool initialization, liquidity math, or
swaps. The supplied protected launch harness belongs to the independent launch
verification environment and needs its factory/pool support contracts and launch
parameters. Those components are not part of this token project.

## Deployment parameters and responsibilities

The intended chain is Ethereum mainnet (chain ID 1). The launch system deploys
`Coinbase` directly from the compiled creation bytecode with **no constructor
arguments and no ETH value**. A contract factory receives the supply when it
deploys the token; the transaction sender or origin receives none automatically.
There are no constructor calls to external contracts and no linked libraries.
Inspect the creation bytecode locally with:

```sh
forge inspect src/Coinbase.sol:Coinbase bytecode
```

The launch operator must use the pinned build settings, verify the deployed
bytecode and metadata, and confirm the deploying factory initially holds all
`10^27` units. The separate launch process owns manifest creation, factory
authorization, pool setup, and distribution. This repository supplies the token
artifact and does not initiate transactions or provide a launch manifest.

For this assignment the supplied launch economics allocate 10% (100,000,000
tokens) to the factory's distributor, 88% (880,000,000 tokens) to liquidity, and
2% (20,000,000 tokens) to the requester's remainder recipient. The factory, not
the token constructor, executes these transfers. The launch process supplies the
paired currency, pool parameters, and remainder recipient from the assignment.
The token has no address configuration and does not enforce the allocation policy.

## After launch

There are no setters, administrator keys, scheduled operations, or ongoing token
maintenance. Holders control transfers and approvals; applications and the launch
operator remain responsible for custody and distribution. Tokens sent to a wrong
address, including the token contract itself, cannot be rescued by an admin.

Users should approve only the amount a spender needs and revoke unused allowances.
When changing an existing allowance, consider revoking it first and confirming
that transaction before granting a replacement: a spender can use an existing
allowance before its replacement is mined. Unlimited approvals expose the entire
current and future balance to that spender. These are standard ERC-20 semantics.

## Assumptions and security review

The requested behavior is interpreted as a plain transferable ERC-20 with an
immutable supply and no optional governance, permit, burn, tax, or vesting
extensions.

The local review checked the supplied security reference against the small token
surface: supply arithmetic and units, constructor-only minting, allowance
authorization and rollback, address validation, and unmodified ERC-20 accounting.
There are no external interactions, oracle reads, signatures, proxy delegates,
or payable functions in the token to introduce those attack surfaces.

Local validation uses compilation, unit/fuzz tests, stateful invariants, and
runtime opcode checks. Slither and Mythril were not run. Passing tests is not an
independent security audit. Independent adversarial review and deployed-source
verification remain the launch operator's pre-release responsibilities.
