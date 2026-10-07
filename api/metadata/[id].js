// GET /api/metadata/<tokenId>  (a trailing .json is accepted)
//
// Token metadata for wallets, marketplaces and the mint page. Only tokens that exist on chain get an
// answer; unminted and burned ids return 404, so unminted art is never revealed.

import { readToken } from "../_lib/chain.js";
import { SUPPLY, loadImages } from "../_lib/images.js";
import { json, settings } from "../_lib/settings.js";

export async function GET(request) {
  const match = new URL(request.url).pathname.match(/\/api\/metadata\/(\d+)(?:\.json)?\/?$/);
  const tokenId = match ? Number(match[1]) : 0;
  if (!Number.isInteger(tokenId) || tokenId < 1 || tokenId > SUPPLY) return json(404, { error: "Unknown token" }, 3600);

  const { contract, rpcUrl, shuffleSecret } = settings();
  if (!contract) return json(503, { error: "The site is not connected to a contract yet" });

  let images;
  try {
    images = loadImages(shuffleSecret);
  } catch (err) {
    return json(503, { error: err.message });
  }

  let token;
  try {
    token = await readToken(rpcUrl, contract, tokenId);
  } catch {
    return json(502, { error: "Could not reach Robinhood Chain, try again" });
  }
  if (!token.exists) return json(404, { error: "Not minted" }, 5);

  const { image, thumbnail } = images.imageFor(tokenId);
  return json(
    200,
    {
      name: `Mooniez Burn Test #${tokenId}`,
      description: "Test token for the Mooniez burn & swap on Robinhood Chain.",
      image,
      thumbnail,
      attributes: [{ trait_type: "Status", value: token.swapped ? "Swapped (final)" : "Original" }],
    },
    // A token's image never changes. Its status is fixed at mint, and a burn only matters for listing.
    300,
  );
}
