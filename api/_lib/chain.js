// Minimal JSON-RPC reads, so the functions need no dependencies.

const OWNER_OF = "0x6352211e"; // ownerOf(uint256)
const SWAPPED_IN = "0xa287f77a"; // swappedIn(uint256)

async function call(rpcUrl, to, selector, tokenId) {
  const data = selector + BigInt(tokenId).toString(16).padStart(64, "0");
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  if (!res.ok) throw new Error(`RPC responded ${res.status}`);
  return res.json();
}

/** { exists, swapped } for a token. Throws when the chain can't be reached, so a failure is never cached as "not minted". */
export async function readToken(rpcUrl, contract, tokenId) {
  const [owner, swapped] = await Promise.all([
    call(rpcUrl, contract, OWNER_OF, tokenId),
    call(rpcUrl, contract, SWAPPED_IN, tokenId),
  ]);
  if (owner.error) {
    // ownerOf reverts (ERC721NonexistentToken) for unminted and burned tokens
    if (owner.error.code === 3 || /revert/i.test(owner.error.message || "")) return { exists: false, swapped: false };
    throw new Error(owner.error.message || "RPC error");
  }
  if (swapped.error) throw new Error(swapped.error.message || "RPC error");
  return { exists: true, swapped: BigInt(swapped.result) === 1n };
}
