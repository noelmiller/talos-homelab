#!/usr/bin/env bash
# Adds, replaces, or removes entries in the Todoist project -> Discord webhook
# map and reseals it as sealed-n8n-discord-project-webhooks.yaml.
#
# A SealedSecret cannot be decrypted locally, so the current map is read from
# the live Secret. Merge one run before starting the next, or the second run
# will not see the first one's entries. Webhook URLs are never printed.
#
# Run under bash in a real terminal: ./16-n8n/seal-project-webhook.sh
set -euo pipefail

CTX=admin@k8s.noelmiller.dev
NAME=n8n-discord-project-webhooks
KEY=project-webhooks
OUT="$(cd "$(dirname "$0")" && pwd)/sealed-$NAME.yaml"

map=$(kubectl --context "$CTX" -n n8n get secret "$NAME" -o "jsonpath={.data.$KEY}" 2>/dev/null | base64 -d || true)
[[ -n "$map" ]] || map='{}'
jq -e 'type == "object"' >/dev/null <<<"$map" || { echo "the live map is not a JSON object" >&2; exit 1; }

echo "Currently mapped: $(jq -r 'keys | if length == 0 then "(none)" else join(", ") end' <<<"$map")"
echo "Enter a Todoist project name exactly as it appears (case does not matter)."
echo "A sub-project without an entry uses its nearest mapped parent. Blank name to finish."

changed=0
while true; do
  read -rp "Project name: " project
  [[ -n "$project" ]] || break
  read -rsp "Discord webhook URL for '$project' (hidden; '-' removes the entry): " url; echo
  if [[ "$url" == "-" ]]; then
    map=$(jq --arg p "$project" 'with_entries(select((.key | ascii_downcase) != ($p | ascii_downcase)))' <<<"$map")
    echo "  removed $project"
  elif [[ "$url" == https://discord.com/api/webhooks/* || "$url" == https://discordapp.com/api/webhooks/* ]]; then
    map=$(jq --arg p "$project" --arg u "$url" 'with_entries(select((.key | ascii_downcase) != ($p | ascii_downcase))) + {($p): $u}' <<<"$map")
    echo "  mapped $project"
  else
    echo "  that does not look like a Discord webhook URL; skipped" >&2
    continue
  fi
  changed=1
done
unset url

[[ "$changed" == 1 ]] || { echo "nothing changed"; exit 0; }

kubectl create secret generic "$NAME" --namespace n8n \
  --from-literal="$KEY=$(jq -c . <<<"$map")" --dry-run=client -o yaml |
  kubeseal --context "$CTX" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system > "$OUT.tmp"
grep -q '^kind: SealedSecret' "$OUT.tmp" || { echo "sealing failed" >&2; rm -f "$OUT.tmp"; exit 1; }
mv "$OUT.tmp" "$OUT"

echo "wrote $OUT"
echo "Now mapped: $(jq -r 'keys | if length == 0 then "(none)" else join(", ") end' <<<"$map")"
echo "Commit it, merge, then: kubectl -n n8n rollout restart deploy/n8n"
