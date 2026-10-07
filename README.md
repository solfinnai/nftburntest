# Burn & Swap PFP

A 555 piece PFP collection for [Robinhood Chain](https://docs.robinhood.com/chain/) with a free mint and a random burn-to-swap:

1. **Free mint.** Anyone can mint for free (gas only), up to 10 per wallet. Each mint gives you random tokens from the pool of unminted tokens.
2. **Burn & swap.** Don't like one? Burn it and get a random unminted token instead. The token you get from a swap is **final**: it can never be swapped (burned) again.

Burned tokens are gone for good: they never go back into the pool. There is no fixed swap reserve: whatever the mint leaves unminted is the swap pool (e.g. if 250 are minted, the other 305 can be swapped into). Every swap shrinks the collection by one.

```
mint:  unminted pool --(random ID)--> you
swap:  your token    --(burned)-----> gone forever
       unminted pool --(random ID)--> you   (final, can't be swapped again)
```

## What's in here

| Path | What it is |
| --- | --- |
| `src/BurnSwapPFP.sol` | The ERC-721 contract (OpenZeppelin 5.6) |
| `test/BurnSwapPFP.t.sol` | Foundry tests, including a full 555 mint-out, fairness checks and a fuzz test |
| `script/Deploy.s.sol` | Deploy script, configured by env vars |
| `script/keeper.sh` | Optional bot that reveals everyone's mints and swaps automatically |
| `web/` | A no-build mint & swap page (plain HTML + [viem](https://viem.sh)) |

## How it works

### Mint and swap take two steps: roll, then reveal

If a mint or swap picked its random token in the same transaction, a bot could preview the result and only go through with it when it lands on a rare. To stop that:

1. **Roll.** `mint(quantity)` or `swap(tokenIds)` records a request. For swaps, the old tokens are burned right there, so there is no backing out.
2. **Reveal.** A few seconds later (once the next Ethereum block is in, usually under 15 seconds), `reveal()` hands out the tokens. The randomness comes from a block hash that didn't exist yet when the request was made.

Requests are revealed strictly in order, so the result is the same no matter who calls `reveal` or when. Anyone can call it: the holder (the web page shows a **Reveal** button), or the keeper bot below so nobody has to click. No outside randomness service or fees are involved.

### Rules

- Token IDs are `1` to `555`. All of them start in the unminted pool.
- `mint(quantity)`: free, up to `maxPerWallet` (default **10**) per wallet in total, at most 20 per transaction.
- `swap(tokenIds)`: burn one or more tokens you own (up to 20 at once), get the same number of random unminted tokens. Tokens that came out of a swap can't be swapped again, even after they're sold or transferred (`canSwap(id)` / `swappedIn(id)` tell you). Minted and airdropped tokens can be swapped once.
- Tokens promised to a pending request are set aside, so a mint or swap can never run out halfway.
- Mint and swap each have their own on/off switch, both off at deploy. The usual order: open mint, close mint, open swap.
- Metadata: `tokenURI(id) = baseURI + id + uriSuffix` (suffix defaults to `.json`). The web page shows the unminted art, so all art should be public from the start.
- Owner functions: `setMintOpen`, `setSwapOpen`, `setMaxPerWallet`, `setBaseURI`, `airdrop(to, ids)` (mints specific unminted IDs, e.g. a team allocation; only while no reveals are pending). Ownership transfer is two-step (`Ownable2Step`).
- Views for UIs: `available()`, `unmintedTokenIds()`, `tokensOfOwner(addr)`, `tokenState(id)` (`0` unminted, `1` owned, `2` burned), `canSwap(id)`, `pendingOf(addr)`, `isRevealReady(requestId)`, `previewURI(id)`.

Gas: a mint or swap request is about 150-170k gas, and a reveal roughly 75-100k gas per token. All of it is a fraction of a cent on Robinhood Chain.

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
cp .env.example .env              # fill in name, symbol, BASE_URI
cast wallet import deployer --interactive   # stores your key encrypted, once

# Testnet first
forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/

# Mainnet: same command with --rpc-url robinhood and
#   --verifier-url https://robinhoodchain.blockscout.com/api/
```

The deploying wallet becomes the owner (set `OWNER` in `.env` to use a different wallet). Keep that key safe: it controls the switches, the metadata link and airdrops.

### Running the drop

```sh
NFT=0xYourContract
RPC=robinhood_testnet   # or robinhood

cast send $NFT "setMintOpen(bool)" true  --rpc-url $RPC --account deployer   # start the free mint
cast send $NFT "setMintOpen(bool)" false --rpc-url $RPC --account deployer   # end it; what's left is the swap pool
cast send $NFT "setSwapOpen(bool)" true  --rpc-url $RPC --account deployer   # start swaps

cast send $NFT "setMaxPerWallet(uint256)" 5 --rpc-url $RPC --account deployer
cast send $NFT "setBaseURI(string,string)" "ipfs://<cid>/" ".json" --rpc-url $RPC --account deployer
cast send $NFT "airdrop(address,uint256[])" 0xTeamWallet "[1,2,3]" --rpc-url $RPC --account deployer

cast call $NFT "available()(uint256)" --rpc-url $RPC   # unminted and not already promised
```

### Keeper (optional, recommended)

Run this somewhere that stays on (a small server or your laptop during launch) so every mint and swap reveals within seconds without holders pressing **Reveal**. Use a separate wallet with a little ETH for gas; it doesn't need any special rights.

```sh
NFT=0xYourContract KEEPER_PRIVATE_KEY=0x... RPC=robinhood ./script/keeper.sh
```

Without a keeper, holders reveal with the button. A request left unrevealed for about 50 minutes simply gets a fresh random block when someone does reveal it.

## Web page

`web/` is a static page: connect a wallet, mint, reveal, select PFPs to swap. Swapped PFPs are tagged *final*. It adds/switches the wallet to Robinhood Chain automatically.

1. Edit `web/config.js`: set `network` (`robinhood` or `robinhoodTestnet`) and `contractAddress`. Set `rpcUrl` to a dedicated RPC (Alchemy, QuickNode, etc.) before a public launch; the public one is rate limited.
2. Host the `web/` folder anywhere static (Vercel, Netlify, IPFS, S3). Locally: `cd web && python3 -m http.server 8080`.

It loads viem from esm.sh, so there is no build step.

## Local end-to-end run

```sh
anvil --block-time 1                    # terminal 1
# terminal 2, using anvil's first dev key
NFT_NAME="Local" NFT_SYMBOL="LOC" BASE_URI="ipfs://<cid>/" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cd web && python3 -m http.server 8080
# open http://127.0.0.1:8080/?network=local&contract=<address>&rpc=http://127.0.0.1:8545
```

## Things to know before launch

- **Bots.** A free mint with only a per-wallet limit can be farmed by anyone with many wallets. If that matters, add an allowlist, a signature from your backend, or a small price.
- **Randomness** depends on block hashes produced by Robinhood Chain's sequencer, which Robinhood runs. That's fine for a PFP drop; it just means the chain operator is trusted not to rig it.
- **Royalties** (ERC-2981) are not included.
- This code has tests but has not been audited.
