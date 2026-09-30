#!/usr/bin/env bash
# Seals the seedbox FTP login used by the seedbox-proxy sidecar into
# 18-bookorbit/sealed-seedbox-ftp.yaml. Prompts for the password without
# echoing it; run it from the repository root in a terminal:
#
#   bash 18-bookorbit/seal-seedbox-ftp.sh
set -euo pipefail

context="${KUBE_CONTEXT:-admin@k8s.noelmiller.dev}"
out="18-bookorbit/sealed-seedbox-ftp.yaml"

read -r -p "Seedbox FTP username [rapidseedbox91832]: " username
username="${username:-rapidseedbox91832}"
read -r -s -p "Seedbox FTP password: " password
echo
if [[ -z "$password" ]]; then
  echo "Empty password; nothing written." >&2
  exit 1
fi

tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
kubectl create secret generic seedbox-ftp --namespace bookorbit \
  --from-literal=username="$username" \
  --from-literal=password="$password" \
  --dry-run=client -o yaml |
  kubeseal --context "$context" --format yaml \
    --controller-name sealed-secrets --controller-namespace kube-system \
    > "$tmp"
unset password
mv "$tmp" "$out"
trap - EXIT
echo "Wrote $out"
