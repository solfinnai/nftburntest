# Burn & Swap PFP

A 555 piece PFP collection for [Robinhood Chain](https://docs.robinhood.com/chain/) with a free mint and a burn-to-swap mechanic:

1. **Free mint.** Anyone can mint for free (gas only). Each mint hands out a random token from the pool of unminted tokens.
2. **Burn & swap.** A holder burns a token they own and, in exchange, picks any specific token that is still unminted.

Burned tokens are gone for good: they never go back into the pool. Every swap shrinks the collection by one, and the pool of unminted tokens is what both the mint and the swaps draw from.

```
mint:  unminted pool --(random ID)----> you
swap:  your token    --(burned)-------> gone forever
       unminted pool --(ID you pick)--> you
```

## What's in here

| Path | What it is |
| --- | --- |
| `src/BurnSwapPFP.sol` | The ERC-721 contract (OpenZeppelin 5.6) |
| `test/BurnSwapPFP.t.sol` | Foundry tests, including a full 555 mint-out and a fuzz test of the pool |
| `script/Deploy.s.sol` | Deploy script, configured by env vars |
| `web/` | A no-build mint & swap page (plain HTML + [viem](https://viem.sh)) |

## How the contract works

- Token IDs are `1` to `555`. All of them start in the unminted pool.
- `mint(quantity)`: free, random IDs from the pool. Limited by `maxPerWallet` and by `publicMintCap`.
- `swap(burnId, newId)`: caller must own `burnId`; `newId` must be unminted. Burns `burnId`, mints `newId` to the caller. If two people go for the same `newId`, the second transaction reverts and nothing is burned.
- **Swap reserve.** If the free mint hands out all 555, there is nothing left to swap into. `publicMintCap` (default **444**) stops the free mint early so the remaining **111** stay in the pool for swaps. Closing the mint early has the same effect: whatever is still unminted becomes the swap pool.
- Mint and swap each have their own on/off switch, both off at deploy.
- Metadata: `tokenURI(id) = baseURI + id + uriSuffix` (suffix defaults to `.json`). Because swappers choose from the unminted tokens, the art for every ID should be public from the start; there is no hidden reveal.
- Owner functions: `setMintOpen`, `setSwapOpen`, `setPublicMintCap`, `setMaxPerWallet`, `setBaseURI`, `airdrop(to, ids)` (mints specific unminted IDs, e.g. a team allocation). Ownership transfer is two-step (`Ownable2Step`).
- Views for UIs: `unmintedTokenIds()`, `tokensOfOwner(addr)`, `tokenState(id)` (`0` unminted, `1` owned, `2` burned), `isUnminted(id)`, `previewURI(id)` (works for unminted IDs too), `totalSupply()`, `totalBurned()`.

Gas: a mint is about 173k gas and a swap about 136k gas, which is a fraction of a cent on Robinhood Chain.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recurse-submodules <this repo>
cd nftburntest
forge test
```

If you already cloned without submodules: `git submodule update --init`.

## Metadata

Upload a folder with `1.json` through `555.json` (to IPFS, Arweave or any HTTPS host), each in the usual format:

```json
{ "name": "PFP #1", "image": "ipfs://<image-cid>/1.png", "attributes": [{ "trait_type": "Background", "value": "Blue" }] }
```

Then use the folder as `BASE_URI`, e.g. `ipfs://<metadata-cid>/`. It can also be set or changed after deploy with `setBaseURI`.

## Deploy to Robinhood Chain

| | Mainnet | Testnet |
| --- | --- | --- |
| Chain ID | 4663 | 46630 |
| RPC (public, rate limited) | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer (Blockscout) | https://robinhoodchain.blockscout.com | https://explorer.testnet.chain.robinhood.com |
| `foundry.toml` alias | `robinhood` | `robinhood_testnet` |

Gas is paid in ETH. Get testnet ETH from the faucet linked in Robinhood's docs.

```sh
cp .env.example .env              # fill in name, symbol, BASE_URI, caps
cast wallet import deployer --interactive   # stores your key encrypted, once

# Testnet first
forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/

# Mainnet: same command with --rpc-url robinhood and
#   --verifier-url https://robinhoodchain.blockscout.com/api/
```

Set `OWNER` in `.env` to a multisig if you don't want the deployer key to own the collection.

### Running the drop

```sh
NFT=0xYourContract
RPC=robinhood_testnet   # or robinhood

cast send $NFT "setMintOpen(bool)" true  --rpc-url $RPC --account deployer   # start the free mint
cast send $NFT "setMintOpen(bool)" false --rpc-url $RPC --account deployer   # end it
cast send $NFT "setSwapOpen(bool)" true  --rpc-url $RPC --account deployer   # start swaps

cast send $NFT "setPublicMintCap(uint256)" 400 --rpc-url $RPC --account deployer
cast send $NFT "setMaxPerWallet(uint256)" 2   --rpc-url $RPC --account deployer
cast send $NFT "setBaseURI(string,string)" "ipfs://<cid>/" ".json" --rpc-url $RPC --account deployer
cast send $NFT "airdrop(address,uint256[])" 0xTeamWallet "[1,2,3]" --rpc-url $RPC --account deployer

cast call $NFT "unmintedCount()(uint256)" --rpc-url $RPC
```

## Web page

`web/` is a static page: connect a wallet, mint, then pick one of your PFPs to burn and an unminted one to claim. It adds/switches the wallet to Robinhood Chain automatically.

1. Edit `web/config.js`: set `network` (`robinhood` or `robinhoodTestnet`) and `contractAddress`. Set `rpcUrl` to a dedicated RPC (Alchemy, QuickNode, etc.) before a public launch; the public one is rate limited.
2. Host the `web/` folder anywhere static (Vercel, Netlify, IPFS, S3). Locally: `cd web && python3 -m http.server 8080`.

It loads viem from esm.sh, so there is no build step.

## Local end-to-end run

```sh
anvil                                   # terminal 1
# terminal 2, using anvil's first dev key
NFT_NAME="Local" NFT_SYMBOL="LOC" BASE_URI="ipfs://<cid>/" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cd web && python3 -m http.server 8080
# open http://127.0.0.1:8080/?network=local&contract=<address>&rpc=http://127.0.0.1:8545
```

## Things to decide before launch

- **Bots.** A free mint with only a per-wallet limit can be farmed by anyone with many wallets. If that matters, add an allowlist (Merkle root), a signature from your backend, or a small price.
- **Mint randomness** uses block data. It is not tamper proof: a contract can retry until it gets an ID it likes. Since anyone can pick a specific unminted ID through `swap` anyway, there is little to gain, but if you want provably fair random mints you would need a VRF on Robinhood Chain.
- **Owner trust.** The owner can change caps, metadata and airdrop unminted IDs (which shrinks the swap pool). Use a multisig as owner.
- **Royalties** (ERC-2981) are not included.
- This code has tests but has not been audited.
