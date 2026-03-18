#!/usr/bin/env bash
# Deploy the werewolf server to Hetzner.
# Usage: deploy.sh [--no-update]
#   --no-update  skip `nix flake update werewolf` (use locked version as-is)
set -euo pipefail

SERVER="admin@178.104.5.193"
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UPDATE=true
for arg in "$@"; do
  case "$arg" in
    --no-update) UPDATE=false ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if $UPDATE; then
  echo "==> Updating werewolf input in flake.lock..."
  (cd "$SERVER_DIR" && nix flake update werewolf)
fi

echo "==> Copying server config to $SERVER:/etc/nixos/..."
scp "$SERVER_DIR"/*.nix "$SERVER_DIR/flake.lock" "$SERVER":/etc/nixos/

echo "==> Running nixos-rebuild switch on $SERVER..."
ssh "$SERVER" "sudo nixos-rebuild switch --flake /etc/nixos#server-1"

echo "==> Done."
