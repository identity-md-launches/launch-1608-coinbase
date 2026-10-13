# Vendored dependencies

All dependencies needed by the contracts and tests are checked in as ordinary
source files. No `forge install` or Git submodules are required. The upstream
files and licenses are unmodified; `DEPENDENCIES.sha256` records each file's
SHA-256 hash for a local integrity check.

| Dependency | Version | Local path | Included files | License |
| --- | --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | `lib/openzeppelin-contracts/` | ERC20 and its transitive Solidity imports (5 files), plus license | MIT |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | `lib/forge-std/` | `src/` (28 files), plus both licenses; test dependency only | Apache-2.0 or MIT |

Archive provenance:

- `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2`
  SHA-256: `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a`
- `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`
  SHA-256: `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`

The archives are provenance references; they are not needed at build time.
The vendored OpenZeppelin subset intentionally excludes unrelated extensions.
Review and re-run all tests before changing either dependency or the compiler.
