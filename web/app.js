import { abi } from "./contract.js";
import {
  $,
  connectWallet,
  ensureChain,
  explain,
  loadSettings,
  makePublicClient,
  shortAddress,
  toast,
  toastLink,
} from "./shared.js";

const MAX_PER_TX = 20;
const REVEAL_BATCH = 10;

const settings = await loadSettings();
const { chain, contract } = settings;

let publicClient;
let walletClient;
let provider;
let account;
let pollTimer = null;
let busy = false; // a transaction is in flight; its own refresh reports the outcome

const state = {
  owned: [],
  ownedLoaded: false,
  final: new Set(), // owned tokens that came from a swap
  fresh: new Set(), // tokens that arrived while the page was open
  selected: new Set(),
  pending: 0n,
  mintOpen: false,
  swapOpen: false,
  mintable: 0,
  available: 0n,
};
const metaCache = new Map(); // id -> Promise<{ thumb, full } | null>
const loaded = new Map(); // id -> { thumb, full }, once fetched
let base = "";
let suffix = "";

const read = (functionName, args = []) => publicClient.readContract({ address: contract, abi, functionName, args });

// ---- metadata -------------------------------------------------------------

const gateway = (uri) => (uri?.startsWith("ipfs://") ? settings.ipfsGateway + uri.slice(7) : uri);

/** Thumbnail and full image for a token we know exists. The metadata server only answers for minted tokens. */
function artFor(id) {
  if (!base) return Promise.resolve(null);
  if (!metaCache.has(id)) {
    const request = fetch(gateway(`${base}${id}${suffix}`))
      .then((r) => (r.ok ? r.json() : null))
      .then((meta) => {
        if (!meta) {
          metaCache.delete(id); // not there yet (just revealed, or a brief outage): try again next refresh
          return null;
        }
        const art = { thumb: gateway(meta.thumbnail ?? meta.image), full: gateway(meta.image) };
        loaded.set(id, art);
        return art;
      })
      .catch(() => {
        metaCache.delete(id);
        return null;
      });
    metaCache.set(id, request);
  }
  return metaCache.get(id);
}

function showArt(cardEl, art) {
  const pic = cardEl.querySelector(".art");
  pic.style.backgroundImage = `url("${art.thumb}")`;
  pic.textContent = "";
  const link = cardEl.querySelector("a.full");
  link.href = art.full;
  link.hidden = false;
}

const lazyArt = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    lazyArt.unobserve(entry.target);
    const cardEl = entry.target;
    artFor(Number(cardEl.dataset.id)).then((art) => art && showArt(cardEl, art));
  }
});

// ---- rendering ------------------------------------------------------------

function card(id, { tag = "", tagClass = "", selected = false, onClick = null } = {}) {
  const el = document.createElement("div");
  el.className = selected ? "card selected" : "card";
  el.dataset.id = id;

  const pic = document.createElement(onClick ? "button" : "div");
  pic.className = "art";
  pic.textContent = `#${id}`;
  if (onClick) {
    pic.type = "button";
    pic.setAttribute("aria-pressed", String(selected));
    pic.setAttribute("aria-label", `Select #${id} to swap`);
    pic.addEventListener("click", onClick);
  }

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
  const full = document.createElement("a");
  full.className = "full";
  full.textContent = "Full size";
  full.target = "_blank";
  full.rel = "noopener";
  full.hidden = true;
  label.append(full);

  el.append(pic, label);
  if (loaded.has(id)) showArt(el, loaded.get(id));
  else lazyArt.observe(el);
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

function renderSwapBar() {
  const n = state.selected.size;
  $("swapbar").hidden = n === 0;
  const ids = [...state.selected].map((id) => `#${id}`).join(", ");
  $("swapText").textContent =
    `Burn ${ids} forever and get ${n === 1 ? "a random unminted PFP" : `${n} random unminted PFPs`}. ` +
    "What you get is final.";
  $("swapBtn").textContent = n > 1 ? `Burn & swap ${n}` : "Burn & swap";
  $("swapBtn").disabled = !(account && state.swapOpen && n > 0 && BigInt(n) <= state.available);
}

async function renderPending() {
  const show = Boolean(account) && state.pending > 0n;
  $("pending").hidden = !show;
  if (!show) return;
  const myRequest = await read("lastRequestOf", [account]);
  const ready = await read("isRevealReady", [myRequest]);
  const n = Number(state.pending);
  $("pendingText").textContent = ready
    ? `${n} PFP${n === 1 ? " is" : "s are"} ready to reveal.`
    : `${n} PFP${n === 1 ? " is" : "s are"} being rolled. Reveal unlocks in about 15 seconds.`;
  $("revealBtn").disabled = !ready;
  $("revealBtn").dataset.request = String(myRequest);
}

// ---- data -----------------------------------------------------------------

async function refresh() {
  const [name, minted, available, burned, supply, mintOpen, swapOpen, perWallet] = await Promise.all([
    read("name"),
    read("publicMinted"),
    read("available"),
    read("totalBurned"),
    read("totalSupply"),
    read("mintOpen"),
    read("swapOpen"),
    read("maxPerWallet"),
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
  if (Number($("qty").value) > state.mintable) $("qty").value = String(Math.max(1, state.mintable));
  $("mintHelp").textContent = account
    ? `Random PFPs from the unminted pool, free apart from gas. You have minted ${mintedByMe} of ${perWallet}.`
    : `Random PFPs from the unminted pool, free apart from gas. Up to ${perWallet} per wallet.`;
  $("mintBtn").disabled = !(account && mintOpen && state.mintable > 0);

  renderOwned();
  renderSwapBar();
  await renderPending();
  if (revealedMsg) toast(revealedMsg);
  schedulePoll();
}

/** While something is waiting to be revealed, check back every few seconds (someone else may reveal it). */
function schedulePoll() {
  clearTimeout(pollTimer);
  if (account && state.pending > 0n) {
    pollTimer = setTimeout(() => (busy ? schedulePoll() : refresh().catch(() => schedulePoll())), 4000);
  }
}

// ---- wallet & transactions -------------------------------------------------

async function connect() {
  const wallet = await connectWallet(chain);
  if (!wallet) return;
  const sameProvider = wallet.provider === provider;
  ({ provider, walletClient, account } = wallet);
  $("connect").textContent = shortAddress(account);
  if (!sameProvider) provider.on?.("accountsChanged", (accounts) => {
    account = accounts[0];
    state.owned = [];
    state.ownedLoaded = false;
    state.pending = 0n;
    state.selected.clear();
    state.fresh.clear();
    $("connect").textContent = account ? shortAddress(account) : "Connect wallet";
    refresh().catch((err) => toast(explain(err), true));
  });
  await refresh();
}

/** Returns true when the transaction was mined successfully. */
async function send(functionName, args, pending, done) {
  busy = true;
  try {
    await ensureChain(walletClient, chain);
    // Simulate first so a revert shows a readable reason before the wallet pops up.
    const { request } = await publicClient.simulateContract({ address: contract, abi, functionName, args, account });
    const hash = await walletClient.writeContract(request);
    toastLink(chain, pending, hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("Transaction failed.");
    toastLink(chain, done, hash);
    return true;
  } catch (err) {
    toast(explain(err), true);
    return false;
  } finally {
    busy = false;
    await refresh().catch(() => {});
  }
}

$("connect").addEventListener("click", () => connect().catch((err) => toast(explain(err), true)));

$("mintBtn").addEventListener("click", async () => {
  const qty = Math.min(Math.max(1, Math.floor(Number($("qty").value)) || 1), state.mintable);
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

if (!chain) {
  toast(`Unknown network "${settings.network}".`, true);
} else if (!contract) {
  $("network").textContent = chain.name;
  toast("This site isn't connected to a contract yet.", true);
} else {
  $("network").textContent = chain.name;
  publicClient = makePublicClient(chain, settings.rpcUrl);
  Promise.all([read("baseURI"), read("uriSuffix")])
    .then(([b, s]) => {
      base = b;
      suffix = s;
    })
    .then(refresh)
    .catch((err) => toast(`Could not load the contract: ${explain(err)}`, true));
}
