// Loads the private image map and assigns one image to each token id (1..555).
//
// private/burn-test-urls.json is the map from the Mooniez handoff: { "<mooniez id>": { image, thumbnail }, ... }.
// It must never be committed or sent to browsers. It is uploaded straight to Vercel and only this
// server code reads it. Token ids are matched to entries by a keyed shuffle (SHUFFLE_SECRET), so a
// token number says nothing about which Mooniez it shows.

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const SUPPLY = 555;
const IMAGE_HOST = "https://mooniez-burn-images.henryfinnai.workers.dev/";

let cache;

/** Returns { imageFor(tokenId) } or throws with a message that is safe to show. */
export function loadImages(secret) {
  if (cache) return cache;
  if (!secret) throw new Error("SHUFFLE_SECRET is not set");

  let raw;
  try {
    raw = JSON.parse(readFileSync(join(process.cwd(), "private", "burn-test-urls.json"), "utf8"));
  } catch {
    throw new Error("The image map has not been uploaded yet");
  }

  const ids = Object.keys(raw);
  if (ids.length !== SUPPLY) throw new Error(`The image map has ${ids.length} entries, expected ${SUPPLY}`);
  for (const id of ids) {
    const { image, thumbnail } = raw[id] ?? {};
    if (!image?.startsWith(IMAGE_HOST) || !thumbnail?.startsWith(IMAGE_HOST)) {
      throw new Error("The image map has an entry with an unexpected URL");
    }
  }

  const order = ids
    .map((id) => [createHmac("sha256", secret).update(id).digest("hex"), id])
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([, id]) => id);

  cache = { imageFor: (tokenId) => raw[order[tokenId - 1]] };
  return cache;
}
