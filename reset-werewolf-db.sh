#!/usr/bin/env bash
# Delete the werewolf game's sqlite database on the server, wiping all game
# state (active games, players, history). The service is stopped first since
# it holds the db open in WAL mode, then restarted with a fresh database.
#
# Usage: reset-werewolf-db.sh [--yes]
#   --yes  skip the confirmation prompt
set -euo pipefail

SERVER="admin@178.104.5.193"
DB_DIR="/var/lib/werewolf"
DB_FILES=(
  "$DB_DIR/werewolf.db"
  "$DB_DIR/werewolf.db-wal"
  "$DB_DIR/werewolf.db-shm"
  "$DB_DIR/werewolf.db-journal"
)

CONFIRMED=false
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRMED=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if ! $CONFIRMED; then
  read -r -p "This permanently deletes all werewolf game data on $SERVER. Continue? [y/N] " reply
  case "$reply" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo "==> Stopping werewolf service..."
ssh "$SERVER" "sudo systemctl stop werewolf"

echo "==> Deleting database files..."
ssh "$SERVER" "sudo rm -fv ${DB_FILES[*]}"

echo "==> Starting werewolf service..."
ssh "$SERVER" "sudo systemctl start werewolf"

echo "==> Done."
