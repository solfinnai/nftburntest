// Local stand-in for Vercel: serves web/ and runs the api/ functions.
//
//   NETWORK=local CONTRACT_ADDRESS=0x... SHUFFLE_SECRET=dev RPC_URL=http://127.0.0.1:8545 node script/dev-server.mjs
//
// The image map is read from private/burn-test-urls.json, exactly like on Vercel.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { GET as config } from "../api/config.js";
import { GET as metadata } from "../api/metadata/[id].js";

const root = join(process.cwd(), "web");
const port = Number(process.env.PORT || 3000);
const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

async function staticFile(pathname) {
  const clean = normalize(pathname).replace(/^(\.\.[/\\])+/, "");
  const base = join(root, clean.endsWith("/") ? `${clean}index.html` : clean);
  if (!base.startsWith(root)) return null;
  for (const file of [base, `${base}.html`]) {
    try {
      return { body: await readFile(file), type: types[extname(file)] || "application/octet-stream" };
    } catch {}
  }
  return null;
}

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  let response;
  if (url.pathname === "/api/config") response = await config(new Request(url));
  else if (url.pathname.startsWith("/api/metadata/")) response = await metadata(new Request(url));

  if (response) {
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
    return;
  }
  const file = await staticFile(url.pathname);
  if (!file) {
    res.writeHead(404, { "content-type": "text/plain" }).end("Not found");
    return;
  }
  res.writeHead(200, { "content-type": file.type }).end(file.body);
}).listen(port, "127.0.0.1", () => console.log(`Dev server on http://127.0.0.1:${port}`));
