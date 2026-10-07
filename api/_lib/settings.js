// Server-side settings, all from Vercel environment variables.
//   NETWORK            robinhood | robinhoodTestnet | local
//   CONTRACT_ADDRESS   the BurnSwapPFP contract this site serves
//   SHUFFLE_SECRET     random secret that decides which image each token id gets (never change it after minting)
//   RPC_URL            optional, overrides the network's public RPC

const PUBLIC_RPCS = {
  robinhood: "https://rpc.mainnet.chain.robinhood.com",
  robinhoodTestnet: "https://rpc.testnet.chain.robinhood.com",
  local: "http://127.0.0.1:8545",
};

export function settings() {
  const network = process.env.NETWORK || "robinhoodTestnet";
  const contract = (process.env.CONTRACT_ADDRESS || "").trim();
  return {
    network,
    contract: /^0x[0-9a-fA-F]{40}$/.test(contract) ? contract : "",
    rpcUrl: process.env.RPC_URL || PUBLIC_RPCS[network],
    shuffleSecret: process.env.SHUFFLE_SECRET || "",
  };
}

export function json(status, body, maxAge = 0) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "cache-control": maxAge ? `public, max-age=${maxAge}, s-maxage=${maxAge}` : "no-store",
    },
  });
}
