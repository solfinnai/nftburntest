// The private image map: which inverted Mooniez image each token id (1..555) shows.
//
// It comes from the Vercel environment variable IMAGE_MAP (encrypted at rest, only readable by these
// functions), produced by `node script/pack-image-map.mjs` from the handoff's burn-test-urls.json.
// The map must never be committed or sent to browsers: inverting an image reveals the original Mooniez.
// Locally, IMAGE_MAP_FILE can point at the packed file instead.
//
// Packed format: "v1." + base64(gzip(JSON { host, tokens: [[image, thumbnail], ...] })), where tokens[i]
// belongs to token id i + 1 and paths are relative to host. The order is already shuffled, so no
// Mooniez ids are stored.

import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";

export const SUPPLY = 555;
export const IMAGE_HOST = "https://mooniez-burn-images.henryfinnai.workers.dev/";

let cache;

export function unpack(packed) {
  if (!packed?.startsWith("v1.")) throw new Error("IMAGE_MAP is not in the expected format");
  const { host, tokens } = JSON.parse(gunzipSync(Buffer.from(packed.slice(3), "base64")).toString("utf8"));
  if (host !== IMAGE_HOST) throw new Error("IMAGE_MAP points at an unexpected image host");
  if (!Array.isArray(tokens) || tokens.length !== SUPPLY) throw new Error(`IMAGE_MAP has ${tokens?.length} tokens, expected ${SUPPLY}`);
  return tokens;
}

/** Returns { imageFor(tokenId) } or throws with a message that is safe to show. */
export function loadImages() {
  if (cache) return cache;
  let packed = process.env.IMAGE_MAP;
  if (!packed && process.env.IMAGE_MAP_FILE) {
    try {
      packed = readFileSync(process.env.IMAGE_MAP_FILE, "utf8").trim();
    } catch {}
  }
  if (!packed) throw new Error("The image map has not been set up yet");
  const tokens = unpack(packed);
  cache = {
    imageFor: (tokenId) => {
      const [image, thumbnail] = tokens[tokenId - 1];
      return { image: IMAGE_HOST + image, thumbnail: IMAGE_HOST + thumbnail };
    },
  };
  return cache;
}
