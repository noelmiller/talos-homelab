#!/usr/bin/env bash
# Seals the SMTP relay login and From address into sealed-outline-smtp.yaml.
# Run it in a real terminal (it prompts), then commit the file. Outline reads
# the Secret as environment variables, so after the change has synced:
#   kubectl -n outline rollout restart deploy/outline
set -euo pipefail

context="${KUBE_CONTEXT:-admin@k8s.noelmiller.dev}"
out="$(cd "$(dirname "$0")" && pwd)/sealed-outline-smtp.yaml"

read -rp "SMTP username (smtp.midco.net): " username
read -rsp "SMTP password: " password; echo
read -rp "From address [${username}]: " from_email
from_email="${from_email:-$username}"

if [ -z "$username" ] || [ -z "$password" ]; then
  echo "Username and password must not be empty; nothing written." >&2
  exit 1
fi
case "$from_email" in
  *@*.*) ;;
  *) echo "From address '$from_email' is not an e-mail address; nothing written." >&2; exit 1 ;;
esac

kubectl create secret generic outline-smtp --namespace outline \
  --from-literal=username="$username" \
  --from-literal=password="$password" \
  --from-literal=from-email="$from_email" \
  --dry-run=client -o yaml |
  kubeseal --context "$context" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system \
    > "$out.tmp"
mv "$out.tmp" "$out"
unset password
echo "Wrote $out"
