# Talos Homelab — Single-Node Kubernetes Cluster

A single-node [Talos Linux](https://www.talos.dev/) Kubernetes cluster running on bare metal, managed declaratively via `kustomize` and [ArgoCD](https://argo-cd.readthedocs.io/). Hosts a Traefik ingress gateway with automatic Let's Encrypt certs, a GPU-accelerated media stack (Jellyfin, Ombi, Sonarr, Radarr, Prowlarr, SABnzbd), and game servers.

## Hardware

- AMD Ryzen (Zen2/Zen3, "Matisse/Vermeer") CPU, no integrated GPU
- AMD Radeon RX 6950 XT (Navi 21 / RDNA2) discrete GPU — used for Jellyfin hardware transcoding
- 3 disks: an NVMe boot disk, plus a 2TB NVMe, an 8TB SATA SSD, and a 1TB SATA SSD dedicated to workloads
- Single NIC networking on a home LAN (`10.42.0.0/24`)

## Repository layout

```
controlplane.yaml, worker.yaml   Talos machine configs (gitignored — contain cluster PKI secrets)
talosconfig                      talosctl client config (gitignored — contains admin credentials)
local-storage-patch.yaml         Talos UserVolumeConfig patch for the 3 data disks
01-infrastructure/                Helm-chart-based cluster bootstrap (see below)
02-configuration/                 Cluster-wide config: storage classes, Gateway, MetalLB pool, ClusterIssuer
03-media/                         Media app stack (Jellyfin/Ombi/Sonarr/Radarr/Prowlarr/SABnzbd)
04-gitops/                        ArgoCD app-of-apps definitions
05-dashboard/                     Homepage cluster dashboard
06-virtualization/                KubeVirt, CDI, Multus, and kubevirt-manager
07-minecraft/                     Paper Minecraft server with Bedrock cross-play
08-monitoring/                    Prometheus, Grafana, exporters, probes, and alerts
09-palworld/                      Palworld dedicated server and persistent storage
10-linode-relay/                  Terraform for the public WireGuard game relay
```

## Prerequisites

- `talosctl`, `kubectl`, `kustomize` (or a `kubectl` recent enough to support `--enable-helm` in `kubectl kustomize`)
- `kubeseal` CLI (for sealing new secrets against the in-cluster sealed-secrets controller)
- A Cloudflare account + API token with DNS edit permission for your domain (used for ACME DNS-01 challenges)

## 1. Provision the node with Talos

1. Boot the target machine from the [Talos ISO](https://www.talos.dev/latest/talos-guides/install/bare-metal-platforms/iso/).
2. Generate machine configs for a single-node control-plane cluster:
   ```bash
   talosctl gen config k8s.<your-domain> https://<node-ip>:6443
   ```
   This produces `controlplane.yaml`, `worker.yaml` (unused here — single node), and `talosconfig`. **These three files contain cluster PKI secrets and must never be committed to git** (already covered by `.gitignore`).
3. Apply the config to the node and bootstrap etcd:
   ```bash
   talosctl apply-config --insecure -n <node-ip> --file controlplane.yaml
   talosctl bootstrap --talosconfig talosconfig -n <node-ip>
   talosctl kubeconfig --talosconfig talosconfig -n <node-ip>
   ```
4. Since this is a single-node cluster, the control-plane taint needs to allow workloads — confirm with `kubectl get nodes` and `kubectl describe node` that there's no `NoSchedule` taint blocking regular pods (Talos does not taint single control-plane nodes by default).

## 2. Provision the data disks

The node has 3 additional disks beyond the boot disk, each dedicated to a `UserVolumeConfig` in [local-storage-patch.yaml](local-storage-patch.yaml), matched by disk WWID:

| Volume name | Disk | Approx. usable size |
|---|---|---|
| `nvme-2tb` | 2TB NVMe | ~1850 GiB |
| `sata-8tb` | 8TB SATA SSD | ~7400 GiB |
| `sata-1tb` | 1TB SATA SSD | ~925 GiB |

**Important**: disk vendors market capacity in decimal TB, but Talos `minSize`/`maxSize` are binary (GiB/TiB) — a "2TB" drive is only ~1863 GiB, not 2048 GiB. Always check the real byte size first:

```bash
talosctl --talosconfig talosconfig -n <node> get disks -o yaml   # look at spec.size / spec.pretty_size
```

Apply the patch and reboot to let the volume manager provision the partitions:

```bash
talosctl --talosconfig talosconfig -n <node> patch mc -p @local-storage-patch.yaml
talosctl --talosconfig talosconfig -n <node> reboot
```

Verify all three volumes reach `ready`:

```bash
talosctl --talosconfig talosconfig -n <node> get volumestatus | grep ^u-
```

If a disk has pre-existing partitions from another OS, it will fail with "not enough space" — `talosctl get discoveredvolumes` shows what's occupying it, and `talosctl wipe disk <dev>` clears it (destructive, back up first).

## 3. Bootstrap cluster infrastructure (`01-infrastructure`)

This layer installs, via a mix of raw upstream manifests and Helm charts declared in [01-infrastructure/kustomization.yaml](01-infrastructure/kustomization.yaml):

- **local-path-provisioner** — dynamic PVC provisioning backed by the 3 data disks, mapped to storage classes by node path (see the `local-path-config` patch)
- **MetalLB** (L2 mode) — LoadBalancer IPs for bare metal, pool defined in `02-configuration`
- **Gateway API CRDs** (v1.6.1, standard + experimental channel — Traefik needs both, even for features you don't use, or its provider will never sync)
- **Traefik** — ingress gateway via the Kubernetes Gateway API provider, with automatic Let's Encrypt via Cloudflare DNS-01
- **sealed-secrets** — encrypts secrets so they're safe to commit to a public git repo
- **cert-manager** — issues the wildcard TLS cert used by the Gateway
- **ArgoCD** — once installed, manages every layer (including itself) going forward

Apply it (first time only — after this, ArgoCD takes over):

```bash
cd 01-infrastructure
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -   # first run only, if not present
kubectl kustomize . --enable-helm | kubectl apply --server-side --force-conflicts -f -
```

`--server-side` is required — some CRDs (Gateway API `HTTPRoute`, ArgoCD `ApplicationSet`) are too large for client-side apply's `last-applied-configuration` annotation.

### Cloudflare API token secret

Traefik and cert-manager both need a Cloudflare API token (DNS edit scope) to complete ACME DNS-01 challenges. It's stored as a `SealedSecret` (safe to commit) in `02-configuration/sealed-cloudflare-secret*.yaml`. To (re)generate for a fresh cluster (the sealed-secrets controller's key is per-cluster, so old sealed secrets from another cluster won't decrypt):

```bash
kubectl create secret generic cloudflare-api-token -n traefik \
  --from-literal=CF_DNS_API_TOKEN=<your-token> --dry-run=client -o json | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
  > 02-configuration/sealed-cloudflare-secret.yaml
```

Repeat for the `cert-manager` namespace copy.

### GPU passthrough (AMD)

The RX 6950 XT needs the `amdgpu` Talos system extension, which isn't part of the stock installer image. Build a custom schematic and upgrade to it:

```bash
curl -s -X POST https://factory.talos.dev/schematics -H "Content-Type: application/yaml" -d '
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/amdgpu
      - siderolabs/amd-ucode
'
# returns {"id": "<schematic-id>"}
talosctl --talosconfig talosconfig -n <node> upgrade \
  --image factory.talos.dev/installer/<schematic-id>:v1.13.7
```

**Known gotcha**: AMD Navi 2x GPUs' PSP (security co-processor) can get stuck after a `kexec`-based warm reboot (which is what Talos upgrades use by default), failing with `PSP firmware loading failed`. If `/dev/dri` doesn't appear or dmesg shows PSP errors, force a true power cycle instead:

```bash
talosctl --talosconfig talosconfig -n <node> reboot --mode powercycle
```

Verify with `talosctl ls /dev/dri` (expect `card0` + `renderD128`) and `vainfo` from inside a pod with the device mounted.

## 4. Cluster-wide configuration (`02-configuration`)

- `storage-classes.yaml` — `nvme-2tb`, `sata-8tb`, `sata-1tb` StorageClasses (`WaitForFirstConsumer`, backed by local-path-provisioner)
- `metallb-pool.yaml` — `IPAddressPool` + `L2Advertisement` for the LAN
- `main-gateway.yaml` — the shared `Gateway` (HTTP + HTTPS listeners on `*.<your-domain>`); listener ports must match Traefik's actual EntryPoint ports (`8000`/`8443`), not the externally-exposed Service ports (`80`/`443`)
- `cluster-issuer.yaml` — cert-manager `ClusterIssuer` (ACME + Cloudflare DNS-01) and a wildcard `Certificate`
- `argocd-route.yaml` — exposes the ArgoCD UI through the Gateway

Every app's `HTTPRoute` attaches to `main-gateway`'s `websecure` listener and inherits the wildcard cert automatically — no per-app TLS config needed.

## 5. Media stack (`03-media`)

Jellyfin, Ombi, SABnzbd, Sonarr, Radarr, and Prowlarr. The download and library apps share one bulk `sata-8tb` PVC mounted at `/data` (same filesystem, so completed downloads move instead of copy into the library). Jellyfin additionally mounts `/dev/dri` (`securityContext.privileged: true` — required, hostPath alone doesn't bypass Kubernetes' device cgroup) for VAAPI hardware transcoding. Ombi uses a dedicated MySQL 8.4 database on NVMe storage and communicates with the other apps over their cluster Services.

A one-shot [bootstrap Job](03-media/bootstrap-job.yaml) wires the apps together after first deploy (SABnzbd categories/paths, Sonarr/Radarr download client + root folder, Prowlarr → Sonarr/Radarr application sync) by reading each app's auto-generated API key from its config PVC. It's idempotent but **Jobs are immutable** — if you change `03-media/bootstrap-script.sh`, you must delete the old Job before ArgoCD/kubectl can recreate it:

```bash
kubectl delete job media-bootstrap -n media --ignore-not-found
```

Manual, one-time setup still required per app (can't be scripted without your own accounts/credentials):
- SABnzbd: add your usenet provider (Settings → Servers)
- Prowlarr: add your indexer(s) — syncs to Sonarr/Radarr automatically
- Jellyfin: finish the setup wizard, add libraries pointing at `/data/media/{tv,movies}`, then enable VAAPI hardware acceleration (Dashboard → Playback → `/dev/dri/renderD128`, H264 + HEVC only — this GPU generation cannot **encode** AV1, only decode it)
- Ombi: open `https://ombi.k8s.noelmiller.dev` and configure its MySQL database with host `ombi-mysql`, port `3306`, database/user `ombi`, and the `mysql-password` value from the `ombi-mysql` Secret. The wizard writes `database.json` to the persistent Ombi config volume. Create the administrator account, then connect Jellyfin (`http://jellyfin.media.svc.cluster.local:8096`), Sonarr (`http://sonarr.media.svc.cluster.local:8989`), and Radarr (`http://radarr.media.svc.cluster.local:7878`) in Settings. Use each app's API key and enable Jellyfin user authentication so users can sign in and submit requests.

Ombi's three logical databases share the MySQL instance because their table names do not overlap. The database and user are created automatically with `utf8mb4`, as recommended by Ombi. Database credentials are stored in `sealed-ombi-mysql-secret.yaml`, encrypted for this cluster. Moving from the default SQLite database does not migrate existing Ombi data; if Ombi was configured before MySQL was deployed, repeat the setup wizard or follow Ombi's database migration guide.

## 6. GitOps (`04-gitops`)

Once ArgoCD is running (from step 3), bootstrap the app-of-apps pattern **once**:

```bash
kubectl apply -f 04-gitops/root-app.yaml
```

This creates the `root` Application, which watches `04-gitops/apps/` and creates one child `Application` per layer (`infrastructure`, `configuration`, `media`, `dashboard`, `virtualization`, `minecraft`, `monitoring`, and `palworld`) — including one pointing back at `01-infrastructure`, so ArgoCD manages its own upgrades too.

From here on, the workflow is just:

```bash
git add -A && git commit -m "..." && git push
```

ArgoCD polls the repo and auto-syncs + self-heals drift. Force an immediate sync with `argocd app sync <name>` or the UI at `https://argocd.<your-domain>`.

## 7. Minecraft

The `minecraft` namespace runs separate survival and creative Paper servers with Geyser and Floodgate, allowing both Java and Bedrock clients to connect. Each world uses `nvme-2tb` storage, and a sidecar creates coordinated backups every 12 hours on a separate `sata-1tb` PVC. The most recent 14 backups per server are retained.

MetalLB exposes the servers on dedicated LAN addresses:

| Server | Address | Java Edition | Bedrock Edition |
|---|---|---|---|
| Survival | `10.42.0.12` | `25565/TCP` | `19132/UDP` |
| Creative | `10.42.0.13` | `25566/TCP` | `19133/UDP` |

Both servers enforce an explicit player whitelist. Keep `WHITELIST` in `server.yaml` and `creative.yaml` limited to known Java or Floodgate player names.

For public access, the Linode relay forwards game traffic through WireGuard to pfSense instead of exposing the home address. The LoadBalancer Services accept game traffic only from the LAN and the relay's `10.99.0.1` tunnel address. Create DNS-only Cloudflare records pointing at the relay IP; Cloudflare Tunnel cannot proxy the Bedrock UDP ports.

## 8. Monitoring

The `monitoring` namespace runs the `kube-prometheus-stack` and Prometheus Blackbox Exporter. Prometheus retains up to 15 days or 25 GB of metrics on a 30 GiB `sata-1tb` PVC. It collects Kubernetes API, kubelet/cAdvisor, node-exporter, and kube-state-metrics data, providing cluster, node, namespace, pod, container, and persistent-volume telemetry. Native metrics from ArgoCD, Traefik, cert-manager, sealed-secrets, and all metrics-capable components installed by the stack are discovered through PodMonitor and ServiceMonitor resources.

Blackbox probes cover every application-facing HTTP or TCP service in this repository, including the media stack, Homepage, ArgoCD, KubeVirt Manager, the test VM, MySQL, both Minecraft servers, Palworld's cluster-internal REST endpoint, Grafana, and the Kubernetes API. The `ApplicationServiceUnavailable` alert fires after a probe has failed for five minutes, while `ApplicationServiceSlow` detects HTTP endpoints taking longer than five seconds.

Grafana is available at `https://grafana.k8s.noelmiller.dev`. It is configured for anonymous Viewer access on the trusted LAN with administrative login disabled. The built-in Kubernetes dashboards are supplemented by **Cluster Service Overview**, which shows service health and latency, node utilization, namespace resource usage, and PVC utilization.

## 9. Palworld server

The Palworld dedicated server is available on the LAN at `10.42.0.14:8211` over UDP. MetalLB assigns the stable LAN address, while the server world, game installation, and built-in daily backups persist on a 50 GiB `nvme-2tb` PVC. The server and administrator passwords are stored in a namespace-scoped `SealedSecret`.

The server is not exposed directly through the router or Cloudflare. The Linode relay is intended to forward the game and query UDP ports over WireGuard without publishing the home IP. Community-browser listing remains disabled until that tunnel and forwarding path are complete.

## Networking notes

- The cluster's MetalLB pool (`10.42.0.11-10.42.0.48`) is **private/LAN-only** — reachable from your home network, not the public internet. For external access you'd additionally need a public DNS record and port-forwarding/tunnel (e.g. Cloudflare Tunnel) — not currently configured.
- Point any local DNS override (e.g. a router's custom DNS zone) at the **Gateway/Traefik Service's external IP** (`kubectl -n traefik get svc traefik`), not the node's own IP — they're not the same thing, and only the Service IP has anything actually listening on 80/443.
- KubeVirt Manager is available at `https://kubevirt.k8s.noelmiller.dev` and is intended only for the trusted LAN. It has broad VM-management permissions and does not enable authentication by default.
- KubeVirt VMs use the Talos-managed `br0` bridge and the `lan` Multus network to join the physical LAN. Apply [talos-kubevirt-network-patch.yaml](talos-kubevirt-network-patch.yaml) to move the node address and default route from `enp6s0` to `br0`:
  ```bash
  talosctl machineconfig patch controlplane.yaml \
    --patch @talos-kubevirt-network-patch.yaml \
    --output controlplane-kubevirt.yaml
  yq eval -i \
    '(. | select(.kind == "HostnameConfig")) |= (del(.auto) | .hostname = "k8s.noelmiller.dev")' \
    controlplane-kubevirt.yaml
  talosctl validate --config controlplane-kubevirt.yaml --mode metal --strict
  talosctl --talosconfig talosconfig -n 10.42.0.2 apply-config \
    --mode try --timeout 5m --file controlplane-kubevirt.yaml
  ```
  Verify `br0`, node health, and Kubernetes access before the timeout. Talos automatically rolls the change back if connectivity is lost. The node's original bare-metal network configuration may also exist in META key `0x0a`; back it up with `talosctl get meta 0x0a -o yaml`, then remove it with `talosctl meta delete 0x0a` to prevent the node IP from being assigned to both `enp6s0` and `br0`. Once only `br0` owns the address and the cluster is healthy, persist the full generated config with `apply-config --mode auto`.

## Security notes

- `talosconfig`, `controlplane.yaml`, `worker.yaml`, and `cloudflare-secret.yaml` are gitignored — they contain cluster PKI private keys, join tokens, and a plaintext API token. Never commit them.
- All in-repo secrets are `SealedSecret`s, decryptable only by the sealed-secrets controller running in this specific cluster.
