#!/usr/bin/env bash
# Registers the Discord slash commands (/tasks, /add, /done) in one server and
# seals what the workflows need from the Discord application, as
# sealed-n8n-discord-interactions.yaml: the public key and server ID that
# verify Discord's requests, and the bot token the relay posts with so that
# its messages can carry a Done button. Safe to re-run: the command list is
# replaced as a whole.
#
# Run under bash in a real terminal: ./16-n8n/setup-discord-command.sh
set -euo pipefail

CTX=admin@k8s.noelmiller.dev
NAME=n8n-discord-interactions
OUT="$(cd "$(dirname "$0")" && pwd)/sealed-$NAME.yaml"

echo "From https://discord.com/developers/applications > your application:"
read -rp "Application ID (General Information): " app_id
read -rp "Server ID (Discord > right-click the server > Copy Server ID; needs Developer Mode): " guild_id
read -rsp "Bot token (Bot > Reset Token; hidden): " bot_token; echo

[[ "$app_id" =~ ^[0-9]{17,20}$ ]] || { echo "the application ID should be 17-20 digits" >&2; exit 1; }
[[ "$guild_id" =~ ^[0-9]{17,20}$ ]] || { echo "the server ID should be 17-20 digits" >&2; exit 1; }
[[ -n "$bot_token" ]] || { echo "empty bot token" >&2; exit 1; }

# Option types: 3 = string, 4 = integer. Autocomplete options are answered by
# the workflow as the user types.
commands='[
  {
    "name": "tasks", "type": 1,
    "description": "List the open Todoist tasks of a project",
    "options": [
      {"type": 3, "name": "project", "description": "Project name; defaults to the project this channel is mapped to", "required": false}
    ]
  },
  {
    "name": "add", "type": 1,
    "description": "Add a task to this channel'"'"'s Todoist project",
    "options": [
      {"type": 3, "name": "task", "description": "What needs doing", "required": true, "max_length": 500},
      {"type": 3, "name": "due", "description": "When, in plain words: tomorrow, fri 5pm, every monday", "required": false},
      {"type": 4, "name": "priority", "description": "p1 is the most urgent", "required": false,
       "choices": [{"name": "p1", "value": 1}, {"name": "p2", "value": 2}, {"name": "p3", "value": 3}, {"name": "p4", "value": 4}]},
      {"type": 3, "name": "assignee", "description": "Who should do it (shared projects only)", "required": false, "autocomplete": true}
    ]
  },
  {
    "name": "done", "type": 1,
    "description": "Complete a task in this channel'"'"'s Todoist project",
    "options": [
      {"type": 3, "name": "task", "description": "Start typing and pick the task", "required": true, "autocomplete": true}
    ]
  }
]'

# The token goes in through stdin so it never appears in the process list.
resp=$(curl -sS -X PUT "https://discord.com/api/v10/applications/$app_id/guilds/$guild_id/commands" \
  -H 'content-type: application/json' -H @- --data "$commands" <<<"Authorization: Bot $bot_token")
if [[ "$(jq -r 'if type == "array" then length else 0 end' <<<"$resp")" != "3" ]]; then
  echo "Discord refused the commands: $(jq -c 'if type == "object" then {code, message, errors} else . end' <<<"$resp" 2>/dev/null || echo "$resp")" >&2
  echo "A 'Missing Access' error means the application is not installed in that server with the applications.commands scope." >&2
  unset bot_token
  exit 1
fi
echo "registered in server $guild_id: $(jq -r '[.[].name | "/" + .] | join(" ")' <<<"$resp")"

# Posting as the bot needs the bot to be a member of the server, which the
# applications.commands install alone does not make it. 68608 = View Channel,
# Send Messages, Read Message History. Private channels also need the bot (or
# its role) added to them; where it cannot post, the relay uses the webhook.
echo
echo "For the Done button, add the bot to the server once, if you have not:"
echo "  https://discord.com/oauth2/authorize?client_id=$app_id&scope=bot+applications.commands&permissions=68608"
echo

if [[ -f "$OUT" ]]; then
  read -rp "Seal the public key, server ID, and this bot token again? Needed the first time the token is stored, and after a token reset. [Y/n] " again
  [[ "$again" == [nN]* ]] && { unset bot_token; exit 0; }
fi
read -rp "Public Key (General Information): " public_key
[[ "$public_key" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "the public key should be 64 hex characters" >&2; exit 1; }

kubectl create secret generic "$NAME" --namespace n8n \
  --from-literal=public-key="$public_key" --from-literal=guild-id="$guild_id" \
  --from-literal=bot-token="$bot_token" --dry-run=client -o yaml |
  kubeseal --context "$CTX" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system > "$OUT.tmp"
unset bot_token
grep -q '^kind: SealedSecret' "$OUT.tmp" || { echo "sealing failed" >&2; rm -f "$OUT.tmp"; exit 1; }
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT"
