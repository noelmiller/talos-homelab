# AGENTS.md

Guidance for coding agents working in this repository. [README.md](README.md) is the full runbook; this file covers what you need before changing anything.

## What this repo is

GitOps source for a single-node bare-metal Talos Linux cluster (`k8s.noelmiller.dev`, node `10.42.0.2`). Omni manages the node and its Talos/Kubernetes versions; Argo CD deploys everything on Kubernetes from `main`.

**Merging to `main` is a production deploy.** The `root` app-of-apps (`04-gitops/root-app.yaml`) creates one child Application per layer, all with automated sync, `prune: true` and `selfHeal: true`. There is no staging cluster.

## Layout

- `NN-<name>/`: one layer per directory, each a kustomize root with a matching Argo CD Application in `04-gitops/apps/NN-<name>.yaml`. Numbers are ordering only, and gaps are fine (06 is unused).
- `01-infrastructure/` is bootstrapped by hand once, then Argo CD manages it, including Argo CD itself.
- `10-linode-relay/` is Terraform (the public WireGuard game relay), not Kubernetes. It is not deployed by Argo CD.
- `omni/`: Omni ConfigPatches, which are the live Talos machine config. The SideroLink join token is replaced by `<SIDEROLINK_JOIN_TOKEN>`; keep it that way.
- Top-level `*-patch.yaml` files are pre-Omni Talos patches kept for reference. Their content now lives in the Omni import patch.
- `tests/`: hand-applied smoke-test manifests. They are never in a kustomization.
- Several layers have their own `README.md` with layer-specific setup and gotchas. Read it before changing that layer.

## Validate locally

CI (`.github/workflows/validate.yaml`) runs two checks on every PR, and both must pass:

```bash
kubectl kustomize --enable-helm <layer>                  # render one layer
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  <rendered.yaml>
cd 10-linode-relay && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
```

Helm charts are pulled into `<layer>/charts/` by `--enable-helm`. That directory is gitignored, so never commit it.

## Conventions

- **Helm charts** are declared under `helmCharts:` in the layer's `kustomization.yaml` with a pinned `version` and a `valuesFile`, never with `helm install`.
- **Images in raw manifests** are pinned by tag and digest (`image:tag@sha256:...`). Renovate maintains them. If you add a layer with raw manifests, add its path to `kubernetes.managerFilePatterns` in `renovate.json`.
- **Secrets** are only ever committed as `SealedSecret`s named `sealed-*.yaml`, sealed with the in-cluster controller (`--controller-name sealed-secrets --controller-namespace kube-system`). Plaintext secrets, `talosconfig`, `controlplane.yaml`, `worker.yaml`, `cloudflare-secret.yaml` and `*.tfvars` must never be committed.
- **Routing** goes through Gateway API: an `HTTPRoute` with parent `main-gateway` in namespace `default`, `sectionName: websecure`, and hostname `<app>.k8s.noelmiller.dev`. The wildcard cert and Traefik handle TLS. The MetalLB pool is LAN-only.
- **Storage** uses the StorageClasses `nvme-2tb`, `sata-8tb` and `sata-1tb`, all `reclaimPolicy: Retain`. Every layer that has PVCs carries the kustomize patch that annotates them `argocd.argoproj.io/sync-options: Prune=false,Delete=false`. Copy it into any new layer with PVCs.
- **Namespaces** carry Pod Security Admission labels. Default to `restricted`, and add a comment in `namespace.yaml` explaining any looser level.
- **PodDisruptionBudgets**: never add one whose `minAvailable` is at least its replica count. On a single node it blocks Omni's drain, and every Talos upgrade along with it.
- **SSO**: apps sign in through Keycloak. Clients are defined in `14-keycloak/realm-homelab.json`, and their secrets are sealed in both `14-keycloak/` and the app's layer.
- **Dashboard**: user-facing services get an entry in `05-dashboard/config/services.yaml`.

### Adding a layer

1. Create `NN-<name>/` with `kustomization.yaml`, `namespace.yaml` (with PSA labels) and the PVC patch if needed.
2. Add `04-gitops/apps/NN-<name>.yaml`, modelled on an existing app. Use `ServerSideApply=true` and `SkipDryRunOnMissingResource=true` for Helm-heavy or CRD-heavy layers.
3. Add the directory to the `for dir in ...` loop in `.github/workflows/validate.yaml`.
4. Add it to the README's repository layout and section list, and to `renovate.json` if needed.

## Pitfalls

- **Server-side-apply apps** (`monitoring`, `coder`, `forgejo`, `keycloak`, `velero`, `n8n`, `outline` and `bookorbit`) can keep a field that was *removed* in git if a stale field manager still owns it, and the app still reports `Synced`. After such a change, check the live object. Never `kubectl apply --server-side` over an Argo-managed layer. Use `kubectl diff` or `--dry-run=server` instead. The fix is described in the README's GitOps section.
- **Secret-only changes** do not restart pods that read the Secret as env vars. Restart the workload after the sync.
- **`kubectl rollout restart`** writes an annotation into the pod template, which Argo CD reports as drift. Delete pods instead when you only need fresh ones.
- **Talos/Kubernetes upgrades** go through Omni, not `talosctl upgrade`. Follow the README's "Upgrading via Omni" runbook, which starts with taking backups first.
- **Backups**: Velero backs up to Backblaze B2 daily at 04:00 America/Chicago and skips the media library. A bare `velero backup create` tries to upload that library, so use `--from-schedule velero-daily`.

## Working against the live cluster

- Never assume the current kubectl context is the homelab. Pass the Omni-issued kubeconfig (`~/.talos/omni-k8s-noelmiller-dev/kubeconfig`, from `omnictl kubeconfig -c k8s-noelmiller-dev`) explicitly to `kubectl` *and* `kubeseal`. A secret sealed against the wrong cluster is silently undecryptable. The old `admin@k8s.noelmiller.dev` context and the pre-Omni `talosconfig` were revoked on 2026-10-15. The `seal-*.sh` and `setup-*.sh` helpers use that kubeconfig by default, and `HOMELAB_KUBECONFIG` overrides it.
- Prefer read-only commands. Mutations belong in git. Hand-applied changes get reverted by self-heal, or they leave stale field managers behind.
- Scripts that prompt for secrets must run under `bash` in a real terminal and refuse to write empty values.

## Change workflow

1. Branch `noelmiller-<topic>` off `main`. Do not stack PRs, because deleting a merged base branch closes the PR on top of it.
2. Commit with a short imperative subject that matches the history, for example "Add Omni to the Homepage dashboard". Open a PR against `main`.
3. Wait for both Validate checks to register and pass. GitHub auto-merge is disabled, and a merge is a deploy, so get explicit approval before merging. Merge with a merge commit (`gh pr merge --merge --delete-branch`).
4. After merging, hard-refresh Argo CD (`kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`, starting with `root` for new apps). Then verify that the workload actually rolled out, not just that the app shows `Synced`.

Renovate opens dependency PRs on weekends and never auto-merges. Review Helm chart bumps by diffing `kubectl kustomize --enable-helm` output between the merge-base and the PR head.
