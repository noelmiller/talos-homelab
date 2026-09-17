#!/usr/bin/env bash
# Remove leftover server-side-apply field managers from objects that Argo CD
# server-side-applies.
#
# Why: with server-side apply a field is only deleted once its LAST manager
# drops it. A hand-run `kubectl apply --server-side` (the bootstrap command in
# README.md, a one-off test) leaves a `kubectl` manager co-owning every field
# it touched. When a later commit removes such a field, Argo CD drops it, the
# stale manager still owns it, the field stays live, and the Application still
# reports Synced. Client-side-applied Applications are not affected.
#
# What: for every object that has BOTH `argocd-controller` and one of the
# stale managers as Apply managers, apply an identity-only manifest as the
# stale manager, which makes it relinquish everything. Fields that some other
# manager also owns are untouched, so this is metadata-only and restarts
# nothing. Objects where a stale manager is the ONLY owner of some field are
# listed and skipped, because relinquishing would delete those fields; review
# them, then pass --prune-orphans to converge them to git as well.
#
# Usage:
#   scripts/prune-stale-field-managers.sh                  # dry run (default)
#   scripts/prune-stale-field-managers.sh --apply
#   scripts/prune-stale-field-managers.sh --apply --prune-orphans
#   STALE_MANAGERS="kubectl,my-test" scripts/prune-stale-field-managers.sh
set -euo pipefail

STALE_MANAGERS="${STALE_MANAGERS:-kubectl,copilot-precommit-test}"
KEEP_MANAGER="argocd-controller"
apply=false
prune_orphans=false
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --prune-orphans) prune_orphans=true ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "$bin is required" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Scanning every listable resource type (takes a minute or two)..." >&2
kubectl api-resources --verbs=list,patch -o name |
  grep -v -E '^(events|events\.events\.k8s\.io|componentstatuses)$' |
  while read -r resource; do
    kubectl get "$resource" --all-namespaces -o json --show-managed-fields 2>/dev/null |
      jq -c --arg stale "$STALE_MANAGERS" --arg keep "$KEEP_MANAGER" '
        # Leaf paths of a fieldsV1 tree, e.g. spec.template...limits.cpu
        def leaves: [paths(type == "object" and length == 0)]
          | map(map(sub("^[fkv]:"; "")) | join("."));
        ($stale | split(",")) as $stale_names
        | .items[]?
        | (.metadata.managedFields // []) as $mf
        | [$mf[] | select(.operation == "Apply") | .manager] as $appliers
        | select($appliers | index($keep))
        | ($appliers | map(select(. as $m | $stale_names | index($m)))) as $found
        | select($found | length > 0)
        | ([$mf[] | select(.operation == "Apply" and (.manager as $m | $stale_names | index($m)))
            | .fieldsV1 | leaves] | add | unique) as $stale_fields
        | ([$mf[] | select((.operation == "Apply" and (.manager as $m | $stale_names | index($m))) | not)
            | .fieldsV1 // {} | leaves] | add // []) as $other_fields
        | { apiVersion, kind,
            name: .metadata.name,
            namespace: (.metadata.namespace // ""),
            managers: $found,
            orphans: ($stale_fields - $other_fields) }' || true
  done > "$work/objects.jsonl"

total="$(wc -l < "$work/objects.jsonl" | tr -d ' ')"
clean="$(jq -c 'select(.orphans | length == 0)' "$work/objects.jsonl" | wc -l | tr -d ' ')"
orphaned=$((total - clean))

echo
echo "Objects with a stale manager next to $KEEP_MANAGER: $total"
jq -r '"\(.namespace | if . == "" then "(cluster)" else . end)"' "$work/objects.jsonl" |
  sort | uniq -c | sort -rn | sed 's/^/  /'
echo "  metadata-only (no field changes): $clean"
echo "  would lose fields (stale-only):   $orphaned"
if [ "$orphaned" -gt 0 ]; then
  echo
  echo "Fields owned ONLY by a stale manager:"
  jq -r 'select(.orphans | length > 0)
    | "  \(.kind) \(.namespace)/\(.name)\n" + (.orphans | map("      " + .) | join("\n"))' \
    "$work/objects.jsonl"
fi

if ! $apply; then
  echo
  echo "Dry run. Re-run with --apply to relinquish the stale managers."
  exit 0
fi

echo
failed=0
done_count=0
while read -r obj; do
  if [ "$(jq -r '.orphans | length' <<<"$obj")" -gt 0 ] && ! $prune_orphans; then
    echo "skipped (has stale-only fields): $(jq -r '"\(.kind) \(.namespace)/\(.name)"' <<<"$obj")"
    continue
  fi
  manifest="$(jq '{apiVersion, kind, metadata: ({name} + (if .namespace == "" then {} else {namespace} end))}' <<<"$obj")"
  for manager in $(jq -r '.managers[]' <<<"$obj"); do
    if ! kubectl apply --server-side --field-manager="$manager" -f - <<<"$manifest" >/dev/null; then
      echo "FAILED: $(jq -r '"\(.kind) \(.namespace)/\(.name)"' <<<"$obj") as $manager" >&2
      failed=$((failed + 1))
    fi
  done
  done_count=$((done_count + 1))
done < "$work/objects.jsonl"

echo "Relinquished stale managers on $done_count objects, $failed failures."
[ "$failed" -eq 0 ]
