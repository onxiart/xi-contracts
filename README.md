# XI

Smart contracts for XI, an ERC20 + on-chain pixel SVG NFT protocol deployed on
BNB Smart Chain. XI tokens are minted as Player cards through a PancakeSwap
Infinity v4 hook on every swap; each card is a deterministic SVG generated
in Solidity with no IPFS or off-chain storage.

## Layout

```
src/
├── xi/              ERC20 + Player Tier 1 container + identity registry
├── xi_hook/         CL hook (afterAddLiquidity start, afterSwap gacha + 1% fee skim)
├── presale/         Fixed-price presale, finalize mints LP + burns position NFT
├── svg/             On-chain Player SVG (SSTORE2 part library + deterministic seed)
├── token/           IStartableToken interface
├── util/            SwapHelper (lock-and-call entrypoint for direct BNB <-> XI swap)
└── library/         OwnableBase / RandomLib / IRandomSeedProvider
```

## Build dependencies

The contracts depend on the following external libraries (not vendored here;
add as forge submodules or remappings to compile):

- [`solady`](https://github.com/Vectorized/solady) — ERC20 base
- [`solmate`](https://github.com/transmissions11/solmate) — SSTORE2
- [`@openzeppelin/contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) ^5.0
- [`infinity-core`](https://github.com/pancakeswap/infinity-core) — PancakeSwap Infinity v4 primitives
- [`infinity-periphery`](https://github.com/pancakeswap/infinity-periphery)
- [`permit2`](https://github.com/Uniswap/permit2)

Solidity `^0.8.20` minimum; `^0.8.24` for files using transient storage / Cancun opcodes.

## License

MIT — see [LICENSE](./LICENSE).

`src/xi_hook/CLBaseHook.sol` is adapted from PancakeSwap Infinity upstream; its
SPDX header reflects the upstream declaration.
