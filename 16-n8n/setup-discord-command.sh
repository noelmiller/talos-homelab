#!/usr/bin/env bash
# Registers the /tasks slash command in one Discord server and seals what the
# "Discord tasks command" workflow needs to verify Discord's requests, as
# sealed-n8n-discord-interactions.yaml. Safe to re-run: registering a command
# with the same name replaces it. The bot token is used once and not stored.
#
# Run under bash in a real terminal: ./16-n8n/setup-discord-command.sh
set -euo pipefail

CTX=admin@k8s.noelmiller.dev
NAME=n8n-discord-interactions
OUT="$(cd "$(dirname "$0")" && pwd)/sealed-$NAME.yaml"

echo "From https://discord.com/developers/applications > your application:"
read -rp "Application ID (General Information): " app_id
read -rp "Public Key (General Information): " public_key
read -rp "Server ID (Discord > right-click the server > Copy Server ID; needs Developer Mode): " guild_id
read -rsp "Bot token (Bot > Reset Token; hidden, not stored): " bot_token; echo

[[ "$app_id" =~ ^[0-9]{17,20}$ ]] || { echo "the application ID should be 17-20 digits" >&2; exit 1; }
[[ "$guild_id" =~ ^[0-9]{17,20}$ ]] || { echo "the server ID should be 17-20 digits" >&2; exit 1; }
[[ "$public_key" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "the public key should be 64 hex characters" >&2; exit 1; }
[[ -n "$bot_token" ]] || { echo "empty bot token" >&2; exit 1; }

command='{
  "name": "tasks",
  "type": 1,
  "description": "List the open Todoist tasks of a project",
  "options": [{
    "type": 3,
    "name": "project",
    "description": "Project name; defaults to the project this channel is mapped to",
    "required": false
  }]
}'

# The token goes in through stdin so it never appears in the process list.
resp=$(curl -sS -X POST "https://discord.com/api/v10/applications/$app_id/guilds/$guild_id/commands" \
  -H 'content-type: application/json' -H @- --data "$command" <<<"Authorization: Bot $bot_token")
unset bot_token
if [[ "$(jq -r '.name // empty' <<<"$resp")" != "tasks" ]]; then
  echo "Discord refused the command: $(jq -c '{code, message}' <<<"$resp" 2>/dev/null || echo "$resp")" >&2
  echo "A 'Missing Access' error means the application is not installed in that server with the applications.commands scope." >&2
  exit 1
fi
echo "registered /tasks in server $guild_id"

kubectl create secret generic "$NAME" --namespace n8n \
  --from-literal=public-key="$public_key" --from-literal=guild-id="$guild_id" --dry-run=client -o yaml |
  kubeseal --context "$CTX" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system > "$OUT.tmp"
grep -q '^kind: SealedSecret' "$OUT.tmp" || { echo "sealing failed" >&2; rm -f "$OUT.tmp"; exit 1; }
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT"
