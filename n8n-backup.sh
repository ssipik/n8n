#!/usr/bin/env bash
# Export all n8n workflows to the host, one JSON file per workflow, named by workflow name.
# Personal values (read from .env) are replaced with placeholders so the files can go into git.

# Must be executed, not sourced: set -e / exit would kill the calling shell (and an SSH session).
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Run this script, don't source it: ./n8n-backup.sh" >&2
  return 1
fi

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="n8n"
OUT="$COMPOSE_DIR/bkp_workflows_docker"
TMP="/tmp/bkp"

command -v jq >/dev/null || { echo "jq missing: sudo apt install jq"; exit 1; }

# Read one KEY=value from .env (no sourcing, so the file is not executed as shell code)
env_get() {
  local v
  v=$(grep -E "^$1=" "$COMPOSE_DIR/.env" | tail -n1 | cut -d= -f2- || true)
  v="${v%$'\r'}"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  [ -n "$v" ] || [ "${2:-}" = optional ] || { echo "ERROR: $1 missing in .env" >&2; exit 1; }
  printf '%s' "$v"
}

csv_json() { jq -cn --arg s "$1" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'; }

OWNER_NAME=$(env_get N8N_OWNER_NAME)
TIMEZONE=$(env_get GENERIC_TIMEZONE)
# Comma-separated email addresses used in workflows -> __EMAIL_1__, __EMAIL_2__, ... (keep the order stable)
EMAILS_JSON=$(csv_json "$(env_get N8N_EMAILS)")
# Optional, comma-separated: other private text (e.g. account names) -> __PRIVATE_1__, __PRIVATE_2__, ...
# Replaced everywhere, literally - avoid short values that also occur inside normal words.
PRIVATE_JSON=$(csv_json "$(env_get N8N_EXTRA_STRINGS optional)")

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
  | walk(lit($tz; "__TIMEZONE__")
         | reduce ($emails | to_entries[]) as $e (.; lit($e.value; "__EMAIL_\($e.key + 1)__"))
         | reduce ($private | to_entries[]) as $e (.; lit($e.value; "__PRIVATE_\($e.key + 1)__")));
if type == "array" then map(clean) else clean end
'

shopt -s nullglob
for f in "$OUT"/*.json; do
  name=$(jq -r 'if type=="array" then .[0].name else .name end' "$f" | tr '/' '-')
  jq --arg name "$OWNER_NAME" --arg tz "$TIMEZONE" \
     --argjson emails "$EMAILS_JSON" --argjson private "$PRIVATE_JSON" "$CLEAN" "$f" > "$f.tmp"
  rm "$f"
  mv "$f.tmp" "$OUT/$name.json"
done

# Safety net: refuse to finish if a personal value survived
while IFS= read -r s; do
  if grep -nF -e "$s" "$OUT"/*.json; then
    echo "ERROR: personal data still present in the files above"; exit 1
  fi
done < <(jq -r --arg tz "$TIMEZONE" '.[], $tz' <<<"$PRIVATE_JSON")
# ...and if any email address survived (owner's, or one missing from N8N_EMAILS)
if grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' "$OUT"/*.json; then
  echo "ERROR: email addresses above are not anonymized - add them to N8N_EMAILS in .env"; exit 1
fi

count=$(ls "$OUT"/*.json | wc -l)
echo "Backed up $count workflows to $OUT"
