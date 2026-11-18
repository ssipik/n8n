#!/usr/bin/env bash
# Export all n8n workflows to the host, one JSON file per workflow, named by workflow name.
# Personal values (read from .env) are replaced with placeholders so the files can go into git.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE="n8n"
OUT="$COMPOSE_DIR/bkp_workflows_docker"
TMP="/tmp/bkp"

command -v jq >/dev/null || { echo "jq missing: sudo apt install jq"; exit 1; }

# Read one KEY=value from .env (no sourcing, so the file is not executed as shell code)
env_get() {
  local v
  v=$(grep -E "^$1=" "$COMPOSE_DIR/.env" | tail -n1 | cut -d= -f2- || true)
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  [ -n "$v" ] || { echo "$1 missing in .env"; exit 1; }
  printf '%s' "$v"
}

OWNER_EMAIL=$(env_get N8N_OWNER_EMAIL)
OWNER_NAME=$(env_get N8N_OWNER_NAME)
TIMEZONE=$(env_get GENERIC_TIMEZONE)

cd "$COMPOSE_DIR"
mkdir -p "$OUT"
rm -f "$OUT"/*.json

docker compose exec -T "$SERVICE" rm -rf "$TMP"
docker compose exec -T "$SERVICE" n8n export:workflow --backup --output="$TMP/"
docker compose cp "$SERVICE:$TMP/." "$OUT/"
docker compose exec -T "$SERVICE" rm -rf "$TMP"

# - delete: test data (pinData), instance id, and fields that change on every export (noisy diffs)
# - replace: personal values with placeholders (literal match, no regex)
CLEAN='
def lit($from; $to): if type == "string" then split($from) | join($to) else . end;
def clean:
  del(.pinData, .meta.instanceId, .updatedAt, .versionId, .activeVersionId,
      .versionCounter, .triggerCount, .shared[]?.updatedAt, .shared[]?.project.updatedAt)
  | (.shared[]?.project.name |= lit($name; "__OWNER_NAME__"))
  | walk(lit($email; "__OWNER_EMAIL__") | lit($tz; "__TIMEZONE__"));
if type == "array" then map(clean) else clean end
'

shopt -s nullglob
for f in "$OUT"/*.json; do
  name=$(jq -r 'if type=="array" then .[0].name else .name end' "$f" | tr '/' '-')
  jq --arg email "$OWNER_EMAIL" --arg name "$OWNER_NAME" --arg tz "$TIMEZONE" "$CLEAN" "$f" > "$f.tmp"
  rm "$f"
  mv "$f.tmp" "$OUT/$name.json"
done

# Safety net: refuse to finish if a personal value survived
if grep -lF -e "$OWNER_EMAIL" -e "$TIMEZONE" "$OUT"/*.json; then
  echo "ERROR: personal data still present in the files above"; exit 1
fi

count=$(ls "$OUT"/*.json | wc -l)
echo "Backed up $count workflows to $OUT"
