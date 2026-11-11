#!/usr/bin/env bash
# Export all n8n workflows to the host, one JSON file per workflow, named by workflow name.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE="n8n"
OUT="$COMPOSE_DIR/bkp_workflows_docker"
TMP="/tmp/bkp"

command -v jq >/dev/null || { echo "jq missing: sudo apt install jq"; exit 1; }

cd "$COMPOSE_DIR"
mkdir -p "$OUT"
rm -f "$OUT"/*.json

docker compose exec -T "$SERVICE" rm -rf "$TMP"
docker compose exec -T "$SERVICE" n8n export:workflow --backup --output="$TMP/"
docker compose cp "$SERVICE:$TMP/." "$OUT/"
docker compose exec -T "$SERVICE" rm -rf "$TMP"

shopt -s nullglob
for f in "$OUT"/*.json; do
  name=$(jq -r 'if type=="array" then .[0].name else .name end' "$f" | tr '/' '-')
  if [ "$f" != "$OUT/$name.json" ]; then
    mv "$f" "$OUT/$name.json"
  fi
done

count=$(ls "$OUT"/*.json | wc -l)
echo "Backed up $count workflows to $OUT"
