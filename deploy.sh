#!/usr/bin/env bash
# Deploy the werewolf server to Hetzner.
# Builds the NixOS closure locally (fast laptop), copies it to the server,
# and runs only the activation script there.
#
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

echo "==> Building and deploying to $SERVER (build runs locally)..."
nixos-rebuild switch \
  --flake "$SERVER_DIR#server-1" \
  --target-host "$SERVER" \
  --build-host localhost \
  --ask-sudo-password
echo "==> Done."
