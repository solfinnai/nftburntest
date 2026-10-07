import { abi, bytecode } from "./contract.js";
import {
  $,
  NETWORKS,
  connectWallet,
  ensureChain,
  explain,
  loadSettings,
  makePublicClient,
  shortAddress,
  toast,
  toastLink,
} from "./shared.js";

const settings = await loadSettings();
const params = new URLSearchParams(location.search);

let networkKey = settings.network in NETWORKS ? settings.network : "robinhoodTestnet";
let walletClient;
let account;
let current = null; // address of the loaded contract

if (networkKey === "local") {
  $("network").add(new Option("Local (anvil)", "local"));
}
$("network").value = networkKey;
$("dBase").value = `${location.origin}/api/metadata/`;
$("address").value = settings.contract;

const chain = () => NETWORKS[networkKey];
const rpcUrl = () => (networkKey === settings.network ? settings.rpcUrl : chain().rpcUrls.default.http[0]);
let publicClient = makePublicClient(chain(), rpcUrl());

function mintPageUrl(address) {
  const url = new URL("./", location.href);
  url.searchParams.set("network", networkKey);
  url.searchParams.set("contract", address);
  if (params.get("rpc")) url.searchParams.set("rpc", params.get("rpc"));
  return url.href;
}

async function send(request, pending, done) {
  try {
    await ensureChain(walletClient, chain());
    const { request: req } = await publicClient.simulateContract({ address: current, abi, account, ...request });
    const hash = await walletClient.writeContract({ ...req, chain: chain() });
    toastLink(chain(), pending, hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("Transaction failed.");
    toastLink(chain(), done, hash);
  } catch (err) {
    toast(explain(err), true);
  } finally {
    await load().catch(() => {});
  }
}

// ---- connect & network -------------------------------------------------------

$("connect").addEventListener("click", async () => {
  try {
    const wallet = await connectWallet(chain());
    if (!wallet) return;
    ({ walletClient, account } = wallet);
    $("connect").textContent = shortAddress(account);
    $("deployBtn").disabled = false;
    if (current) await load();
  } catch (err) {
    toast(explain(err), true);
  }
});

$("network").addEventListener("change", async () => {
  networkKey = $("network").value;
  publicClient = makePublicClient(chain(), rpcUrl());
  $("status").hidden = true;
  if (walletClient) {
    try {
      await ensureChain(walletClient, chain());
    } catch (err) {
      toast(explain(err), true);
    }
  }
});

// ---- deploy ------------------------------------------------------------------

$("deployBtn").addEventListener("click", async () => {
  const name = $("dName").value.trim();
  const symbol = $("dSymbol").value.trim();
  const max = BigInt(Math.max(1, Math.floor(Number($("dMax").value)) || 10));
  const base = $("dBase").value.trim();
  if (!name || !symbol) return toast("Fill in a name and a symbol.", true);

  $("deployBtn").disabled = true;
  try {
    await ensureChain(walletClient, chain());
    const hash = await walletClient.deployContract({
      abi,
      bytecode,
      account,
      chain: chain(), // the network picker may have changed since connecting
      args: [name, symbol, account, base, max],
    });
    toastLink(chain(), "Deploying…", hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success" || !receipt.contractAddress) throw new Error("Deployment failed.");
    const address = receipt.contractAddress;
    toastLink(chain(), "Deployed!", hash);

    const explorer = chain().blockExplorers?.default?.url;
    const out = $("deployResult");
    out.hidden = false;
    out.innerHTML = "";
    const lines = [
      ["Contract", address],
      ["Network", chain().name],
    ];
    for (const [k, v] of lines) {
      const p = document.createElement("p");
      p.innerHTML = `<span class="muted">${k}:</span> `;
      const c = document.createElement("code");
      c.textContent = v;
      p.append(c);
      out.append(p);
    }
    const next = document.createElement("p");
    next.textContent =
      "Send the contract address and network to whoever runs this site so it can be connected (this turns on the images). " +
      "Until then you can already use the mint page with this link: ";
    const a = document.createElement("a");
    a.href = mintPageUrl(address);
    a.textContent = "open mint page";
    next.append(a);
    if (explorer) {
      next.append(" · ");
      const e = document.createElement("a");
      e.href = `${explorer}/address/${address}`;
      e.target = "_blank";
      e.rel = "noopener";
      e.textContent = "view on explorer";
      next.append(e);
    }
    out.append(next);

    $("address").value = address;
    await load();
  } catch (err) {
    toast(explain(err), true);
  } finally {
    $("deployBtn").disabled = false;
  }
});

// ---- manage ------------------------------------------------------------------

async function load() {
  const address = $("address").value.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
    $("status").hidden = true;
    return;
  }
  current = address;
  const read = (functionName) => publicClient.readContract({ address, abi, functionName });
  const [name, owner, mintOpen, swapOpen, minted, available, burned, supply, perWallet, base, next, total] =
    await Promise.all(
      [
        "name",
        "owner",
        "mintOpen",
        "swapOpen",
        "publicMinted",
        "available",
        "totalBurned",
        "totalSupply",
        "maxPerWallet",
        "baseURI",
        "nextToReveal",
        "nextRequestId",
      ].map(read),
    );

  const rows = [
    ["Name", name],
    ["Owner", owner],
    ["Mint", mintOpen ? "open" : "closed"],
    ["Swap", swapOpen ? "open" : "closed"],
    ["Minted", minted],
    ["Left to mint or swap into", available],
    ["Burned in swaps", burned],
    ["Live supply", supply],
    ["Max per wallet", perWallet],
    ["Waiting to reveal", `${total - next} request${total - next === 1n ? "" : "s"}`],
    ["Metadata URL", base],
  ];
  const kv = $("kv");
  kv.replaceChildren();
  for (const [k, v] of rows) {
    const div = document.createElement("div");
    const label = document.createElement("span");
    label.textContent = k;
    const value = document.createElement("b");
    value.textContent = String(v);
    div.append(label, value);
    kv.append(div);
  }

  const isOwner = account && owner.toLowerCase() === account.toLowerCase();
  $("ownerNote").textContent = !account
    ? "Connect the owner wallet to change anything."
    : isOwner
      ? "You are the owner."
      : `Connected wallet ${shortAddress(account)} is not the owner, so changes will be rejected.`;
  $("mintToggle").textContent = mintOpen ? "Close mint" : "Open mint";
  $("mintToggle").dataset.open = String(!mintOpen);
  $("mintToggle").className = mintOpen ? "" : "primary";
  $("swapToggle").textContent = swapOpen ? "Close swap" : "Open swap";
  $("swapToggle").dataset.open = String(!swapOpen);
  $("swapToggle").className = swapOpen ? "" : "primary";
  for (const id of ["mintToggle", "swapToggle", "maxBtn", "baseBtn"]) $(id).disabled = !isOwner;
  $("revealBtn").disabled = !account || total === next;
  if (document.activeElement !== $("maxInput")) $("maxInput").value = String(perWallet);
  if (document.activeElement !== $("baseInput")) $("baseInput").value = base;
  $("mintLink").href = mintPageUrl(address);
  $("status").hidden = false;
}

$("loadBtn").addEventListener("click", () => load().catch((err) => toast(explain(err), true)));
$("address").addEventListener("keydown", (e) => {
  if (e.key === "Enter") load().catch((err) => toast(explain(err), true));
});

$("mintToggle").addEventListener("click", () => {
  const open = $("mintToggle").dataset.open === "true";
  send({ functionName: "setMintOpen", args: [open] }, "Updating…", open ? "Mint is open." : "Mint is closed.");
});
$("swapToggle").addEventListener("click", () => {
  const open = $("swapToggle").dataset.open === "true";
  send({ functionName: "setSwapOpen", args: [open] }, "Updating…", open ? "Swap is open." : "Swap is closed.");
});
$("maxBtn").addEventListener("click", () => {
  const max = BigInt(Math.max(0, Math.floor(Number($("maxInput").value)) || 0));
  send({ functionName: "setMaxPerWallet", args: [max] }, "Updating…", `Max per wallet is now ${max}.`);
});
$("baseBtn").addEventListener("click", async () => {
  const suffix = await publicClient.readContract({ address: current, abi, functionName: "uriSuffix" });
  send({ functionName: "setBaseURI", args: [$("baseInput").value.trim(), suffix] }, "Updating…", "Metadata URL saved.");
});
$("revealBtn").addEventListener("click", () => {
  send({ functionName: "reveal", args: [10n] }, "Revealing…", "Revealed.");
});

if (settings.contract) load().catch((err) => toast(explain(err), true));
