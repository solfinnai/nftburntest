import { createPublicClient, createWalletClient, custom, http, parseAbi } from "https://esm.sh/viem@2.57.3";
import { robinhood, robinhoodTestnet, foundry } from "https://esm.sh/viem@2.57.3/chains";
import config from "./config.js";

const NETWORKS = { robinhood, robinhoodTestnet, local: foundry };

const params = new URLSearchParams(location.search);
const networkKey = params.get("network") || config.network;
const chain = NETWORKS[networkKey];
if (!chain) {
  const message = `Unknown network "${networkKey}". Use robinhood, robinhoodTestnet or local.`;
  document.getElementById("toast").textContent = message;
  throw new Error(message);
}
const contract = params.get("contract") || config.contractAddress;
const rpcUrl = params.get("rpc") || config.rpcUrl || chain.rpcUrls.default.http[0];

const abi = parseAbi([
  "function name() view returns (string)",
  "function unmintedCount() view returns (uint256)",
  "function publicMinted() view returns (uint256)",
  "function publicMintCap() view returns (uint256)",
  "function maxPerWallet() view returns (uint256)",
  "function totalBurned() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function mintOpen() view returns (bool)",
  "function swapOpen() view returns (bool)",
  "function mintedBy(address) view returns (uint256)",
  "function unmintedTokenIds() view returns (uint256[])",
  "function tokensOfOwner(address) view returns (uint256[])",
  "function baseURI() view returns (string)",
  "function uriSuffix() view returns (string)",
  "function mint(uint256 quantity)",
  "function swap(uint256 burnId, uint256 newId)",
  "error MintClosed()",
  "error SwapClosed()",
  "error ZeroQuantity()",
  "error ExceedsPublicMintCap()",
  "error ExceedsWalletLimit()",
  "error PoolExhausted()",
  "error NotTokenOwner(uint256 tokenId)",
  "error NotUnminted(uint256 tokenId)",
]);

const FRIENDLY_ERRORS = {
  MintClosed: "Minting is not open right now.",
  SwapClosed: "Swapping is not open right now.",
  ZeroQuantity: "Pick a quantity of at least 1.",
  ExceedsPublicMintCap: "The free mint is fully claimed.",
  ExceedsWalletLimit: "You have reached the per-wallet mint limit.",
  PoolExhausted: "There are no unminted PFPs left.",
  NotTokenOwner: "You don't own that PFP anymore.",
  NotUnminted: "Someone just claimed that one. Pick another.",
};

const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
let walletClient;
let account;
let listening = false;

const state = { owned: [], pool: [], burnId: null, claimId: null, mintOpen: false, swapOpen: false, mintable: 0 };
const metaCache = new Map(); // id -> Promise<image url | null>
const images = new Map(); // id -> image url, once loaded
let base = "";
let suffix = "";

const $ = (id) => document.getElementById(id);
const read = (functionName, args = []) => publicClient.readContract({ address: contract, abi, functionName, args });

function toast(message, isError = false) {
  const el = $("toast");
  el.textContent = message;
  el.className = isError ? "error" : "";
}

function toastLink(message, hash) {
  const el = $("toast");
  el.className = "";
  el.textContent = message + " ";
  const explorer = chain.blockExplorers?.default?.url;
  if (explorer) {
    const a = document.createElement("a");
    a.href = `${explorer}/tx/${hash}`;
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = "View transaction";
    el.append(a);
  }
}

// ---- metadata -------------------------------------------------------------

const gateway = (uri) => (uri?.startsWith("ipfs://") ? config.ipfsGateway + uri.slice(7) : uri);

async function imageFor(id) {
  if (!base) return null;
  if (!metaCache.has(id)) {
    metaCache.set(
      id,
      fetch(gateway(`${base}${id}${suffix}`))
        .then((r) => (r.ok ? r.json() : null))
        .then((meta) => gateway(meta?.image ?? null))
        .then((src) => {
          if (src) images.set(id, src);
          return src;
        })
        .catch(() => null),
    );
  }
  return metaCache.get(id);
}

const lazyArt = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    lazyArt.unobserve(entry.target);
    const art = entry.target;
    imageFor(Number(art.dataset.id)).then((src) => src && showImage(art, src));
  }
});

function showImage(art, src) {
  art.style.backgroundImage = `url("${src}")`;
  art.textContent = "";
}

// ---- rendering ------------------------------------------------------------

function card(id, kind, selected, onClick) {
  const btn = document.createElement("button");
  btn.className = `card ${kind}`;
  btn.setAttribute("aria-pressed", String(selected));
  const art = document.createElement("div");
  art.className = "art";
  art.dataset.id = id;
  art.textContent = `#${id}`;
  const label = document.createElement("div");
  label.className = "label";
  label.textContent = `#${id}`;
  btn.append(art, label);
  btn.addEventListener("click", onClick);
  if (images.has(id)) showImage(art, images.get(id));
  else lazyArt.observe(art);
  return btn;
}

function renderOwned() {
  const el = $("owned");
  el.replaceChildren();
  if (!account) {
    el.innerHTML = '<p class="muted">Connect your wallet to see your PFPs.</p>';
    return;
  }
  if (state.owned.length === 0) {
    el.innerHTML = '<p class="muted">You don\'t hold any yet.</p>';
    return;
  }
  for (const id of state.owned) {
    el.append(
      card(id, "burn", id === state.burnId, () => {
        state.burnId = state.burnId === id ? null : id;
        renderOwned();
        renderSwapBar();
      }),
    );
  }
}

function renderPool() {
  const el = $("pool");
  el.replaceChildren();
  const q = $("search").value.replace(/[^0-9]/g, "");
  const ids = q ? state.pool.filter((id) => String(id).includes(q)) : state.pool;
  if (ids.length === 0) {
    el.innerHTML = `<p class="muted">${state.pool.length ? "No match." : "Nothing left in the pool."}</p>`;
    return;
  }
  for (const id of ids) {
    el.append(
      card(id, "claim", id === state.claimId, () => {
        state.claimId = state.claimId === id ? null : id;
        renderPool();
        renderSwapBar();
      }),
    );
  }
}

function renderSwapBar() {
  const show = state.burnId !== null || state.claimId !== null;
  $("swapbar").style.display = show ? "block" : "none";
  const burn = state.burnId !== null ? `#${state.burnId}` : "(pick one of yours)";
  const claim = state.claimId !== null ? `#${state.claimId}` : "(pick an unminted one)";
  $("swapText").textContent = `Burn ${burn} forever and claim ${claim}`;
  $("swapBtn").disabled = !(account && state.swapOpen && state.burnId !== null && state.claimId !== null);
}

// ---- data -----------------------------------------------------------------

async function refresh() {
  const [name, minted, cap, pool, burned, supply, mintOpen, swapOpen, perWallet, poolIds] = await Promise.all([
    read("name"),
    read("publicMinted"),
    read("publicMintCap"),
    read("unmintedCount"),
    read("totalBurned"),
    read("totalSupply"),
    read("mintOpen"),
    read("swapOpen"),
    read("maxPerWallet"),
    read("unmintedTokenIds"),
  ]);

  document.title = `${name} · Mint & Swap`;
  $("title").textContent = name;
  $("statMinted").textContent = `${minted} / ${cap}`;
  $("statPool").textContent = String(pool);
  $("statBurned").textContent = String(burned);
  $("statSupply").textContent = String(supply);
  $("mintBadge").textContent = mintOpen ? "mint open" : "mint closed";
  $("mintBadge").classList.toggle("on", mintOpen);
  $("swapBadge").textContent = swapOpen ? "swap open" : "swap closed";
  $("swapBadge").classList.toggle("on", swapOpen);

  state.mintOpen = mintOpen;
  state.swapOpen = swapOpen;
  state.pool = poolIds.map(Number).sort((a, b) => a - b);
  if (state.claimId !== null && !state.pool.includes(state.claimId)) state.claimId = null;

  let mintedByMe = 0n;
  if (account) {
    const [owned, mine] = await Promise.all([read("tokensOfOwner", [account]), read("mintedBy", [account])]);
    state.owned = owned.map(Number);
    mintedByMe = mine;
    if (state.burnId !== null && !state.owned.includes(state.burnId)) state.burnId = null;
  }

  const capLeft = cap - minted;
  const walletLeft = perWallet > mintedByMe ? perWallet - mintedByMe : 0n;
  const left = [capLeft, walletLeft, pool].reduce((a, b) => (b < a ? b : a));
  state.mintable = Number(left);
  $("qty").max = String(Math.max(1, state.mintable));
  $("mintHelp").textContent = account
    ? `Random PFPs from the unminted pool, free apart from gas. You have minted ${mintedByMe} of ${perWallet} allowed.`
    : "Random PFPs from the unminted pool, free apart from gas.";
  $("mintBtn").disabled = !(account && mintOpen && state.mintable > 0);

  renderOwned();
  renderPool();
  renderSwapBar();
}

// ---- wallet & transactions -------------------------------------------------

async function ensureChain() {
  const current = await walletClient.getChainId();
  if (current === chain.id) return;
  try {
    await walletClient.switchChain({ id: chain.id });
  } catch (err) {
    // 4902: the wallet doesn't know this chain yet
    if (err?.code === 4902 || err?.cause?.code === 4902) {
      await walletClient.addChain({ chain });
    } else {
      throw err;
    }
  }
}

async function connect() {
  if (!window.ethereum) {
    toast("No wallet found. Install a browser wallet such as MetaMask or Rabby.", true);
    return;
  }
  walletClient = createWalletClient({ chain, transport: custom(window.ethereum) });
  [account] = await walletClient.requestAddresses();
  await ensureChain();
  showAccount();
  if (!listening) {
    listening = true;
    window.ethereum.on?.("accountsChanged", (accounts) => {
      account = accounts[0];
      state.burnId = null;
      showAccount();
      refresh().catch((err) => toast(explain(err), true));
    });
  }
  await refresh();
}

function showAccount() {
  $("connect").textContent = account ? `${account.slice(0, 6)}…${account.slice(-4)}` : "Connect wallet";
}

function explain(err) {
  const reverted = err?.walk?.((e) => e?.data?.errorName);
  const name = reverted?.data?.errorName;
  if (name && FRIENDLY_ERRORS[name]) return FRIENDLY_ERRORS[name];
  if (err?.walk?.((e) => e?.name === "UserRejectedRequestError")) return "Transaction cancelled.";
  return err?.shortMessage || err?.message || String(err);
}

/** Returns true when the transaction was mined successfully. */
async function send(functionName, args, pending, done) {
  try {
    await ensureChain();
    // Simulate first so reverts show a readable reason before the wallet pops up.
    const { request } = await publicClient.simulateContract({ address: contract, abi, functionName, args, account });
    const hash = await walletClient.writeContract(request);
    toastLink(pending, hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("Transaction failed.");
    toastLink(done, hash);
    return true;
  } catch (err) {
    toast(explain(err), true);
    return false;
  } finally {
    await refresh().catch(() => {});
  }
}

$("connect").addEventListener("click", () => connect().catch((err) => toast(explain(err), true)));
$("search").addEventListener("input", renderPool);

$("mintBtn").addEventListener("click", async () => {
  const qty = Math.min(Math.max(1, Number($("qty").value) || 1), state.mintable);
  $("mintBtn").disabled = true;
  await send("mint", [BigInt(qty)], "Minting…", `Minted ${qty}!`);
});

$("swapBtn").addEventListener("click", async () => {
  const { burnId, claimId } = state;
  $("swapBtn").disabled = true;
  const ok = await send("swap", [BigInt(burnId), BigInt(claimId)], `Burning #${burnId}…`, `Swapped #${burnId} for #${claimId}.`);
  if (ok) {
    state.burnId = null;
    state.claimId = null;
    renderOwned();
    renderPool();
  }
  renderSwapBar();
});

// ---- boot -----------------------------------------------------------------

if (/^0x0{40}$/.test(contract)) {
  toast("Set the network and contractAddress in web/config.js.", true);
} else {
  $("network").textContent = chain.name;
  Promise.all([read("baseURI"), read("uriSuffix")])
    .then(([b, s]) => {
      base = b;
      suffix = s;
    })
    .then(refresh)
    .catch((err) => toast(`Could not load the contract: ${explain(err)}`, true));
}
