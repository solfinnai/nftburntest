// Shared by the mint page and the admin page: settings, chain clients, wallet connection, error text.
import { createPublicClient, createWalletClient, custom, http } from "https://esm.sh/viem@2.57.3";
import { foundry, robinhood, robinhoodTestnet } from "https://esm.sh/viem@2.57.3/chains";
import defaults from "./config.js";

export const NETWORKS = { robinhood, robinhoodTestnet, local: foundry };

const ZERO = /^0x0{40}$/;

/**
 * Network and contract, in priority order: URL params (?network=&contract=&rpc=), then this
 * deployment's /api/config, then web/config.js.
 */
export async function loadSettings() {
  const params = new URLSearchParams(location.search);
  let server = {};
  try {
    const res = await fetch("/api/config", { cache: "no-store" });
    if (res.ok) server = await res.json();
  } catch {}

  const network = params.get("network") || server.network || defaults.network;
  const contract = [params.get("contract"), server.contractAddress, defaults.contractAddress].find(
    (a) => a && /^0x[0-9a-fA-F]{40}$/.test(a) && !ZERO.test(a),
  );
  const chain = NETWORKS[network];
  return {
    network,
    chain,
    contract: contract || "",
    rpcUrl: params.get("rpc") || defaults.rpcUrl || chain?.rpcUrls.default.http[0],
    ipfsGateway: defaults.ipfsGateway,
  };
}

export function makePublicClient(chain, rpcUrl) {
  // On Robinhood Chain, batch reads into one multicall request to stay under public RPC rate limits.
  return createPublicClient({
    chain,
    transport: http(rpcUrl),
    batch: chain.contracts?.multicall3 ? { multicall: true } : undefined,
  });
}

// ---- wallets ---------------------------------------------------------------

// EIP-6963: wallets announce themselves, so people with several extensions can choose one.
const announced = new Map();
window.addEventListener("eip6963:announceProvider", (event) => {
  announced.set(event.detail.info.uuid, event.detail);
});
window.dispatchEvent(new Event("eip6963:requestProvider"));

function chooseWallet(options) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog");
    dialog.className = "wallet-picker";
    const title = document.createElement("h2");
    title.textContent = "Choose a wallet";
    dialog.append(title);
    for (const { info, provider } of options) {
      const btn = document.createElement("button");
      btn.type = "button";
      if (info.icon) {
        const icon = document.createElement("img");
        icon.src = info.icon;
        icon.alt = "";
        btn.append(icon);
      }
      btn.append(info.name);
      btn.addEventListener("click", () => {
        dialog.close();
        resolve(provider);
      });
      dialog.append(btn);
    }
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "link";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", () => dialog.close());
    dialog.append(cancel);
    dialog.addEventListener("close", () => {
      dialog.remove();
      resolve(null);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

/** Asks the user for a wallet and returns { provider, walletClient, account }, or null if they backed out. */
export async function connectWallet(chain) {
  const options = [...announced.values()];
  const provider = options.length > 1 ? await chooseWallet(options) : (options[0]?.provider ?? window.ethereum);
  if (!provider) {
    if (options.length === 0 && !window.ethereum) {
      throw new Error("No wallet found. Install a browser wallet such as MetaMask or Rabby, or open this page in your wallet app's browser.");
    }
    return null;
  }
  const walletClient = createWalletClient({ chain, transport: custom(provider) });
  const [account] = await walletClient.requestAddresses();
  await ensureChain(walletClient, chain);
  return { provider, walletClient, account };
}

export async function ensureChain(walletClient, chain) {
  if ((await walletClient.getChainId()) === chain.id) return;
  try {
    await walletClient.switchChain({ id: chain.id });
  } catch (err) {
    // 4902: the wallet doesn't know this chain yet
    if (err?.code === 4902 || err?.cause?.code === 4902 || /unrecognized chain/i.test(err?.message ?? "")) {
      await walletClient.addChain({ chain });
    } else {
      throw err;
    }
  }
}

export const shortAddress = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

// ---- errors ----------------------------------------------------------------

const FRIENDLY_ERRORS = {
  MintClosed: "Minting is not open right now.",
  SwapClosed: "Swapping is not open right now.",
  ZeroQuantity: "Pick a quantity of at least 1.",
  TooManyPerTx: "At most 20 per transaction.",
  ExceedsWalletLimit: "You have reached the per-wallet mint limit.",
  NotEnoughUnminted: "There aren't enough unminted PFPs left for that.",
  NotTokenOwner: "You don't own that PFP anymore.",
  AlreadySwapped: "That PFP came from a swap, so it can't be swapped again.",
  RevealsPending: "Wait until pending reveals are done, then try again.",
  OwnableUnauthorizedAccount: "Only the contract owner can do that. Switch to the owner wallet.",
};

export function explain(err) {
  const reverted = err?.walk?.((e) => e?.data?.errorName);
  const name = reverted?.data?.errorName;
  if (name && FRIENDLY_ERRORS[name]) return FRIENDLY_ERRORS[name];
  if (err?.walk?.((e) => e?.name === "UserRejectedRequestError")) return "Transaction cancelled.";
  if (err?.walk?.((e) => e?.name === "InsufficientFundsError")) {
    return "Not enough ETH on Robinhood Chain to pay the gas fee.";
  }
  return err?.shortMessage || err?.message || String(err);
}

// ---- page helpers ----------------------------------------------------------

export const $ = (id) => document.getElementById(id);

export function toast(message, isError = false) {
  const el = $("toast");
  el.textContent = message;
  el.className = isError ? "error" : "";
}

export function toastLink(chain, message, hash) {
  const el = $("toast");
  el.className = "";
  el.textContent = `${message} `;
  const explorer = chain.blockExplorers?.default?.url;
  if (explorer && hash) {
    const a = document.createElement("a");
    a.href = `${explorer}/tx/${hash}`;
    a.target = "_blank";
    a.rel = "noopener";
    a.textContent = "View transaction";
    el.append(a);
  }
}
