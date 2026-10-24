#!/usr/bin/env bash
# Seals the SMTP relay login and From address into sealed-outline-smtp.yaml.
# Run it in a real terminal (it prompts), then commit the file. Outline reads
# the Secret as environment variables, so after the change has synced:
#   kubectl -n outline rollout restart deploy/outline
set -euo pipefail

# The Omni-issued kubeconfig, passed explicitly: the current kubectl context may
# be another cluster, whose controller would seal values the homelab cannot read.
kubeconfig="${HOMELAB_KUBECONFIG:-$HOME/.talos/omni-k8s-noelmiller-dev/kubeconfig}"
out="$(cd "$(dirname "$0")" && pwd)/sealed-outline-smtp.yaml"

if [ ! -f "$kubeconfig" ]; then
  echo "No kubeconfig at $kubeconfig; get one with: omnictl kubeconfig -c k8s-noelmiller-dev $kubeconfig" >&2
  exit 1
fi

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
  kubeseal --kubeconfig "$kubeconfig" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system \
    > "$out.tmp"
mv "$out.tmp" "$out"
unset password
echo "Wrote $out"
