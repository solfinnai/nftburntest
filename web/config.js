// Edit this after deploying. Any value can also be overridden with a URL query param,
// e.g. index.html?network=local&contract=0x...&rpc=http://127.0.0.1:8545
export default {
  // "robinhood" (mainnet, chain 4663), "robinhoodTestnet" (chain 46630) or "local" (anvil, chain 31337)
  network: "robinhoodTestnet",
  contractAddress: "0x0000000000000000000000000000000000000000",
  // Optional. Defaults to the chain's public RPC, which is rate limited; use a dedicated RPC for launch day.
  rpcUrl: "",
  // Used to turn ipfs:// metadata and image links into https:// links.
  ipfsGateway: "https://ipfs.io/ipfs/",
};
