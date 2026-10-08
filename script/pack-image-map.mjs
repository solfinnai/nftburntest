// Turns the handoff's burn-test-urls.json into the IMAGE_MAP value for Vercel.
//
//   SHUFFLE_SECRET=<hex> node script/pack-image-map.mjs private/burn-test-urls.json
//
// Writes, all inside the git-ignored private/ folder:
//   private/image-map.txt          the IMAGE_MAP value (keep it out of git and chat)
//   private/token-to-mooniez.csv   which Mooniez each test token shows, for your records
//   private/shuffle-secret.txt     the secret used (only when one was generated)
//
// The shuffle is keyed by SHUFFLE_SECRET, so the same map + secret always gives the same assignment.
// Once tokens are minted, never re-pack with a different secret.
import { createHmac, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { gzipSync } from "node:zlib";

const SUPPLY = 555;
const HOST = "https://mooniez-burn-images.henryfinnai.workers.dev/";
const input = process.argv[2] || "private/burn-test-urls.json";

const map = JSON.parse(readFileSync(input, "utf8"));
const ids = Object.keys(map);
if (ids.length !== SUPPLY) throw new Error(`${input} has ${ids.length} entries, expected ${SUPPLY}`);
for (const id of ids) {
  const { image, thumbnail } = map[id] ?? {};
  if (!image?.startsWith(HOST) || !thumbnail?.startsWith(HOST)) throw new Error(`Entry ${id} has an unexpected URL`);
  if (!image.endsWith(".png") || !thumbnail.endsWith(".webp")) throw new Error(`Entry ${id} is not a .png/.webp pair`);
}

mkdirSync("private", { recursive: true });
let secret = process.env.SHUFFLE_SECRET;
if (!secret) {
  secret = randomBytes(32).toString("hex");
  writeFileSync("private/shuffle-secret.txt", `${secret}\n`);
}

const order = ids
  .map((id) => [createHmac("sha256", secret).update(id).digest("hex"), id])
  .sort((a, b) => (a[0] < b[0] ? -1 : 1))
  .map(([, id]) => id);

const tokens = order.map((id) => [map[id].image.slice(HOST.length), map[id].thumbnail.slice(HOST.length)]);
const packed = `v1.${gzipSync(JSON.stringify({ host: HOST, tokens }), { level: 9 }).toString("base64")}`;

writeFileSync("private/image-map.txt", `${packed}\n`);
writeFileSync("private/token-to-mooniez.csv", `token_id,mooniez_id\n${order.map((id, i) => `${i + 1},${id}`).join("\n")}\n`);
console.log(`IMAGE_MAP: ${packed.length} characters (Vercel allows 64 KB of env vars in total)`);
console.log("Wrote private/image-map.txt and private/token-to-mooniez.csv");
