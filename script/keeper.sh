#!/usr/bin/env bash
# Reveals pending mints and swaps automatically, so holders don't have to press "Reveal".
# Any wallet with a little ETH for gas works; it needs no special permissions.
# Run from the repo root (it uses the RPC aliases in foundry.toml):
#
#   NFT=0xYourContract KEEPER_PRIVATE_KEY=0x... RPC=robinhood ./script/keeper.sh
set -uo pipefail
: "${NFT:?set NFT to the contract address}"
: "${KEEPER_PRIVATE_KEY:?set KEEPER_PRIVATE_KEY to a wallet with a little ETH for gas}"
RPC="${RPC:-robinhood}"
INTERVAL="${INTERVAL:-3}"

while true; do
  next=$(cast call "$NFT" "nextToReveal()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  ready=$(cast call "$NFT" "isRevealReady(uint256)(bool)" "$next" --rpc-url "$RPC")
  if [ "$ready" = "true" ]; then
    if cast send "$NFT" "reveal(uint256)" 10 --rpc-url "$RPC" --private-key "$KEEPER_PRIVATE_KEY" >/dev/null; then
      echo "$(date -u +%H:%M:%S) revealed from request $next"
    else
      echo "$(date -u +%H:%M:%S) reveal failed, will retry" >&2
    fi
  fi
  sleep "$INTERVAL"
done
