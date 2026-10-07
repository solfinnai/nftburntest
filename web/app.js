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

const MAX_PER_TX = 20;
const REVEAL_BATCH = 10;

const abi = parseAbi([
  "function name() view returns (string)",
  "function available() view returns (uint256)",
  "function publicMinted() view returns (uint256)",
  "function maxPerWallet() view returns (uint256)",
  "function totalBurned() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function mintOpen() view returns (bool)",
  "function swapOpen() view returns (bool)",
  "function mintedBy(address) view returns (uint256)",
  "function pendingOf(address) view returns (uint256)",
  "function lastRequestOf(address) view returns (uint256)",
  "function nextToReveal() view returns (uint256)",
  "function isRevealReady(uint256) view returns (bool)",
  "function swappedIn(uint256) view returns (bool)",
  "function unmintedTokenIds() view returns (uint256[])",
  "function tokensOfOwner(address) view returns (uint256[])",
  "function baseURI() view returns (string)",
  "function uriSuffix() view returns (string)",
  "function mint(uint256 quantity)",
  "function swap(uint256[] burnIds)",
  "function reveal(uint256 maxRequests) returns (uint256)",
  "error MintClosed()",
  "error SwapClosed()",
  "error ZeroQuantity()",
  "error TooManyPerTx()",
  "error ExceedsWalletLimit()",
  "error NotEnoughUnminted()",
  "error NotTokenOwner(uint256 tokenId)",
  "error AlreadySwapped(uint256 tokenId)",
]);

const FRIENDLY_ERRORS = {
  MintClosed: "Minting is not open right now.",
  SwapClosed: "Swapping is not open right now.",
  ZeroQuantity: "Pick a quantity of at least 1.",
  TooManyPerTx: `At most ${MAX_PER_TX} per transaction.`,
  ExceedsWalletLimit: "You have reached the per-wallet mint limit.",
  NotEnoughUnminted: "There aren't enough unminted PFPs left for that.",
  NotTokenOwner: "You don't own that PFP anymore.",
  AlreadySwapped: "That PFP came from a swap, so it can't be swapped again.",
};

const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
let walletClient;
let account;
let listening = false;
let pollTimer = null;

const state = {
  owned: [],
  ownedLoaded: false,
  final: new Set(), // owned tokens that came from a swap
  fresh: new Set(), // tokens that arrived since the page loaded
  selected: new Set(),
  pool: [],
  pending: 0n,
  mintOpen: false,
  swapOpen: false,
  mintable: 0,
  available: 0n,
};
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

function card(id, { tag, tagClass = "", selected = false, onClick } = {}) {
  const el = document.createElement(onClick ? "button" : "div");
  el.className = "card";
  if (onClick) {
    el.setAttribute("aria-pressed", String(selected));
    el.addEventListener("click", onClick);
  }
  const art = document.createElement("div");
  art.className = "art";
  art.dataset.id = id;
  art.textContent = `#${id}`;
  const label = document.createElement("div");
  label.className = "label";
  const name = document.createElement("span");
  name.textContent = `#${id}`;
  label.append(name);
  if (tag) {
    const t = document.createElement("span");
    t.className = `tag ${tagClass}`;
    t.textContent = tag;
    label.append(t);
  }
  el.append(art, label);
  if (images.has(id)) showImage(art, images.get(id));
  else lazyArt.observe(art);
  return el;
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
    const isFinal = state.final.has(id);
    const isNew = state.fresh.has(id);
    el.append(
      card(id, {
        tag: isFinal ? "final" : isNew ? "new" : "",
        tagClass: isNew && !isFinal ? "new" : "",
        selected: state.selected.has(id),
        onClick: isFinal
          ? null
          : () => {
              if (state.selected.has(id)) state.selected.delete(id);
              else if (state.selected.size < MAX_PER_TX) state.selected.add(id);
              renderOwned();
              renderSwapBar();
            },
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
    el.innerHTML = `<p class="muted">${state.pool.length ? "No match." : "Everything has been minted."}</p>`;
    return;
  }
  for (const id of ids) el.append(card(id));
}

function renderSwapBar() {
  const n = state.selected.size;
  $("swapbar").style.display = n ? "block" : "none";
  const ids = [...state.selected].map((id) => `#${id}`).join(", ");
  $("swapText").textContent =
    `Burn ${ids} forever and get ${n === 1 ? "a random unminted PFP" : `${n} random unminted PFPs`}. ` +
    "What you get is final.";
  $("swapBtn").textContent = n > 1 ? `Burn & swap ${n}` : "Burn & swap";
  $("swapBtn").disabled = !(account && state.swapOpen && n > 0 && BigInt(n) <= state.available);
}

async function renderPending() {
  const show = account && state.pending > 0n;
  $("pending").style.display = show ? "block" : "none";
  if (!show) return;
  const myRequest = await read("lastRequestOf", [account]);
  const ready = await read("isRevealReady", [myRequest]);
  const n = Number(state.pending);
  $("pendingText").textContent = ready
    ? `${n} PFP${n === 1 ? " is" : "s are"} ready to reveal.`
    : `${n} PFP${n === 1 ? " is" : "s are"} being rolled. Reveal unlocks in a few seconds.`;
  $("revealBtn").disabled = !ready;
  $("revealBtn").dataset.request = String(myRequest);
}

// ---- data -----------------------------------------------------------------

async function refresh() {
  const [name, minted, available, burned, supply, mintOpen, swapOpen, perWallet, poolIds] = await Promise.all([
    read("name"),
    read("publicMinted"),
    read("available"),
    read("totalBurned"),
    read("totalSupply"),
    read("mintOpen"),
    read("swapOpen"),
    read("maxPerWallet"),
    read("unmintedTokenIds"),
  ]);

  document.title = `${name} · Mint & Swap`;
  $("title").textContent = name;
  $("statMinted").textContent = String(minted);
  $("statPool").textContent = String(available);
  $("statBurned").textContent = String(burned);
  $("statSupply").textContent = String(supply);
  $("mintBadge").textContent = mintOpen ? "mint open" : "mint closed";
  $("mintBadge").classList.toggle("on", mintOpen);
  $("swapBadge").textContent = swapOpen ? "swap open" : "swap closed";
  $("swapBadge").classList.toggle("on", swapOpen);

  state.mintOpen = mintOpen;
  state.swapOpen = swapOpen;
  state.available = available;
  state.pool = poolIds.map(Number).sort((a, b) => a - b);

  let mintedByMe = 0n;
  let revealedMsg = "";
  if (account) {
    const [owned, mine, pending] = await Promise.all([
      read("tokensOfOwner", [account]),
      read("mintedBy", [account]),
      read("pendingOf", [account]),
    ]);
    const before = state.ownedLoaded ? new Set(state.owned) : null;
    state.owned = owned.map(Number);
    state.ownedLoaded = true;
    if (before) {
      const arrived = state.owned.filter((id) => !before.has(id));
      for (const id of arrived) state.fresh.add(id);
      if (arrived.length && pending < state.pending) {
        revealedMsg = `Revealed: ${arrived.map((id) => `#${id}`).join(", ")}`;
      }
    }
    const finalFlags = await Promise.all(state.owned.map((id) => read("swappedIn", [BigInt(id)])));
    state.final = new Set(state.owned.filter((_, i) => finalFlags[i]));
    for (const id of [...state.selected]) if (!state.owned.includes(id) || state.final.has(id)) state.selected.delete(id);
    mintedByMe = mine;
    state.pending = pending;
  }

  const walletLeft = perWallet > mintedByMe ? perWallet - mintedByMe : 0n;
  const left = [walletLeft, available, BigInt(MAX_PER_TX)].reduce((a, b) => (b < a ? b : a));
  state.mintable = Number(left);
  $("qty").max = String(Math.max(1, state.mintable));
  $("mintHelp").textContent = account
    ? `Random PFPs from the unminted pool, free apart from gas. You have minted ${mintedByMe} of ${perWallet}.`
    : `Random PFPs from the unminted pool, free apart from gas. Up to ${perWallet} per wallet.`;
  $("mintBtn").disabled = !(account && mintOpen && state.mintable > 0);

  renderOwned();
  renderPool();
  renderSwapBar();
  await renderPending();
  if (revealedMsg) toast(revealedMsg);
  schedulePoll();
}

/** While something is waiting to be revealed, check back every few seconds (a keeper may reveal it for us). */
function schedulePoll() {
  clearTimeout(pollTimer);
  if (account && state.pending > 0n) {
    pollTimer = setTimeout(() => refresh().catch(() => schedulePoll()), 3000);
  }
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
      state.owned = [];
      state.ownedLoaded = false;
      state.pending = 0n;
      state.selected.clear();
      state.fresh.clear();
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
  await send("mint", [BigInt(qty)], "Minting…", `Minted ${qty}! Reveal in a few seconds.`);
});

$("swapBtn").addEventListener("click", async () => {
  const ids = [...state.selected];
  $("swapBtn").disabled = true;
  const ok = await send(
    "swap",
    [ids.map(BigInt)],
    `Burning ${ids.map((id) => `#${id}`).join(", ")}…`,
    "Burned! Your new PFPs reveal in a few seconds.",
  );
  if (ok) {
    state.selected.clear();
    renderOwned();
  }
  renderSwapBar();
});

$("revealBtn").addEventListener("click", async () => {
  $("revealBtn").disabled = true;
  // Requests are revealed oldest first, so reveal everything up to and including ours.
  const next = await read("nextToReveal");
  const mine = BigInt($("revealBtn").dataset.request);
  const count = mine >= next ? mine - next + 1n : 1n;
  await send("reveal", [count < BigInt(REVEAL_BATCH) ? count : BigInt(REVEAL_BATCH)], "Revealing…", "Revealed!");
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
