// GET /api/config: tells the pages which network and contract this deployment serves.

import { json, settings } from "./_lib/settings.js";

export function GET() {
  const { network, contract } = settings();
  return json(200, { network, contractAddress: contract }, 30);
}
