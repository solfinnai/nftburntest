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
| `web/` | No-build mint & swap page (`index.html`) and admin page (`admin.html`), plain HTML + [viem](https://viem.sh) |
| `api/` | Vercel functions: token metadata (keeps the image map private) and site config |
| `script/dev-server.mjs` | Runs `web/` + `api/` locally the way Vercel does |
| `script/export-web-contract.mjs` | Copies the compiled contract into `web/contract.js` for the admin page's browser deploy |
| `script/pack-image-map.mjs` | Packs the private Mooniez image map into the `IMAGE_MAP` environment variable |

## Mooniez burn test setup

The test uses the 555 inverted Mooniez hosted at `mooniez-burn-images.henryfinnai.workers.dev`. Their URLs come from a private map, `burn-test-urls.json`, which **must never be committed** (this repo is public) **or sent to browsers**: inverting an image gives back the original Mooniez, whose mint is still open.

How the site keeps it private:

- The map is packed into the Vercel environment variable `IMAGE_MAP` (encrypted at rest, only readable by the server functions). The raw file only ever lives in the git-ignored `private/` folder.
- The contract's metadata URL is `https://<site>/api/metadata/`. `api/metadata/[id].js` answers **only for tokens that exist on chain** (minted and not burned) and returns 404 for everything else, so unminted art never leaves the server.
- Token ids are matched to images with a keyed shuffle, so a token number says nothing about which Mooniez it shows. Mooniez ids never appear in the metadata.
- The mint page only shows the connected wallet's own tokens (400px `.webp` thumbnails in the grid, the PNG behind "Full size"). There is no gallery of unminted art.

Packing the map (writes only into `private/`):

```sh
node script/pack-image-map.mjs private/burn-test-urls.json
# -> private/image-map.txt (the IMAGE_MAP value), private/token-to-mooniez.csv, private/shuffle-secret.txt
```

Keep `shuffle-secret.txt`: re-packing with the same secret gives the same assignment (`SHUFFLE_SECRET=<it> node script/pack-image-map.mjs ...`). Never change the assignment once tokens are minted, or their images change.

Vercel environment variables:

| Variable | Value |
| --- | --- |
| `IMAGE_MAP` | contents of `private/image-map.txt` |
| `NETWORK` | `robinhoodTestnet` or `robinhood` |
| `CONTRACT_ADDRESS` | the deployed contract |
| `RPC_URL` | optional, a dedicated Robinhood Chain RPC |

Hosting: import this repo at vercel.com/new (no build settings needed, `vercel.json` covers them), add the variables above, deploy.

Running a test drop:

1. Open `https://<site>/admin`, connect the wallet that should own the contract, pick the network and press **Deploy**.
2. Set `CONTRACT_ADDRESS` (and `NETWORK`) to the new contract and redeploy the site. Until then the mint page works via `https://<site>/?network=...&contract=0x...` but shows no images.
3. On the admin page press **Open mint**, later **Close mint** and **Open swap**.

Local run with a stand-in map: pack a 555-entry map as above, start `anvil --block-time 1`, deploy (see below), then:

```sh
NETWORK=local CONTRACT_ADDRESS=0x... IMAGE_MAP_FILE=private/image-map.txt RPC_URL=http://127.0.0.1:8545 node script/dev-server.mjs
# http://127.0.0.1:3000/?rpc=http://127.0.0.1:8545 and /admin?network=local&rpc=http://127.0.0.1:8545
```

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

## Web pages

- `web/index.html`: connect a wallet, mint, reveal, select PFPs to swap. Swapped PFPs are tagged *final*. It adds/switches the wallet to Robinhood Chain automatically and lets people pick when they have several wallet extensions.
- `web/admin.html` (at `/admin`): deploy the contract from your own wallet and run the drop (open/close mint and swap, max per wallet, metadata URL, reveal pending). Only the owner wallet can change anything.

The pages read the network and contract from `/api/config` (the Vercel env vars), falling back to `web/config.js`; `?network=&contract=&rpc=` in the URL override both. They load viem from esm.sh, so there is no build step. After changing the contract, run `forge build && node script/export-web-contract.mjs`.

## Local end-to-end run

```sh
anvil --block-time 1                    # terminal 1
# terminal 2, using anvil's first dev key
NFT_NAME="Local" NFT_SYMBOL="LOC" BASE_URI="http://127.0.0.1:3000/api/metadata/" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# then start script/dev-server.mjs as shown in "Mooniez burn test setup"
```

## Things to know before launch

- **Bots.** A free mint with only a per-wallet limit can be farmed by anyone with many wallets. If that matters, add an allowlist, a signature from your backend, or a small price.
- **Randomness** depends on block hashes produced by Robinhood Chain's sequencer, which Robinhood runs. That's fine for a PFP drop; it just means the chain operator is trusted not to rig it.
- **Royalties** (ERC-2981) are not included.
- This code has tests but has not been audited.
