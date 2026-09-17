# Velero

This application installs [Velero](https://velero.io/) from the official
`vmware-tanzu/velero` chart and backs the cluster up to a
[Backblaze B2](https://www.backblaze.com/cloud-storage) bucket through B2's
S3-compatible API. It is the cluster's only off-node backup.

## Components
- `namespace.yaml`: creates the `velero` namespace at Pod Security level `privileged`; the node-agent runs as root and mounts the kubelet's pod directory from the host.
- `velero-values.yaml`: chart values: the `velero-plugin-for-aws` object-store plugin, the B2 `BackupStorageLocation`, the node-agent DaemonSet for file-system backup (kopia), the `daily` Schedule, and the ServiceMonitor/PodMonitor.
- `sealed-velero-b2-credentials.yaml`: sealed B2 application key (key `cloud`, AWS credentials-file format).
- `sealed-velero-repo-credentials.yaml`: sealed kopia repository password (key `repository-password`) that encrypts volume data before it leaves the node.
- `volume-policy.yaml`: Velero volume policy that skips `emptyDir` volumes and the data of any PVC labelled `k8s.noelmiller.dev/backup-volume-data: "false"`; only `media/media-library` carries it.
- `backup-alerts.yaml`: `PrometheusRule` for stale or failed backups and for volumes Velero cannot back up.

Both SealedSecrets sync in Argo CD wave `-1`. The Velero server creates
`velero-repo-credentials` with a publicly known default password if it starts
before the Secret exists, and sealed-secrets will not overwrite a Secret it
does not own.

## What is backed up
The `velero-daily` Schedule runs at 04:00 Central and keeps backups for 30
days. Each backup holds:

- every Kubernetes object in every namespace, plus all cluster-scoped
  objects. This includes the sealed-secrets controller's
  private key in `kube-system`, which is what makes the SealedSecrets in git
  decryptable on a rebuilt cluster.
- the contents of every pod-mounted volume except `media-library`, read from the
  live filesystem by the node-agent, deduplicated and encrypted by kopia.
  Later runs upload only changed blocks.

Not backed up:

- the contents of `media/media-library`, ~6.5 TiB of re-downloadable media,
  skipped by the volume policy. The media apps' config volumes and the Ombi
  database *are* backed up. The policy is attached to the Schedule, so a
  backup made with a bare `velero backup create <name>` ignores it and tries
  to upload the library; use `--from-schedule velero-daily` or pass
  `--resource-policies-configmap velero-volume-policy`.
- any volume still on a **hostPath PV** (see below). Velero skips these with
  only a log warning and still reports the backup `Completed`.

File-system backup copies files while the application is running, so a
restored PostgreSQL or MongoDB data directory is crash-consistent at best.
The databases normally recover through their write-ahead logs, but this is
not a substitute for a logical dump; Velero
[backup hooks](https://velero.io/docs/main/backup-hooks/) running `pg_dump`
into the volume are the usual fix.

## hostPath volumes must be converted
Velero reads volume data from the kubelet's per-pod directory
(`/var/lib/kubelet/pods/<uid>/volumes/`). The kubelet binds a hostPath PV
straight into the container and never creates an entry there, so
[hostPath volumes are not supported](https://velero.io/docs/main/file-system-backup/#limitations);
`local` PVs are. local-path-provisioner creates hostPath PVs unless told
otherwise, which is what it did for every volume provisioned before the
StorageClasses in `02-configuration/storage-classes.yaml` gained
`defaultVolumeType: local`.

The `VeleroVolumeNotBackupCapable` alert lists each affected volume. To list
them by hand:

```sh
kubectl get pv -o custom-columns='PV:.metadata.name,NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,HOSTPATH:.spec.hostPath.path' | grep -v '<none>$'
```

A PV's source is immutable, so conversion replaces the PV *object* with a
`local` twin that has the same name, directory, and `claimRef`. With
`reclaimPolicy: Retain` deleting the object never touches the directory, and
the PVC, the workload, and git are unchanged. The pod keeps running through
the swap and needs one restart afterwards, which is the only downtime.

```sh
PV=pvc-...            # the PV to convert
kubectl get pv $PV -o yaml > $PV.hostpath.yaml        # keep: this is the rollback
yq 'del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
        .metadata.managedFields, .spec.claimRef.resourceVersion)
    | .spec.local.path = .spec.hostPath.path | del(.spec.hostPath)' \
  $PV.hostpath.yaml > $PV.local.yaml

kubectl delete pv $PV --wait=false                     # delete first ...
kubectl patch pv $PV --type=merge -p '{"metadata":{"finalizers":null}}'   # ... then the finalizer
kubectl create -f $PV.local.yaml
kubectl get pvc -A | grep $PV                          # Lost for a few seconds, then Bound
```

Then restart the pod that mounts it (`kubectl rollout restart`, or delete the
pod) and check the application.

- The order matters. While the PV is `Bound`, the pv-protection controller
  puts the finalizer straight back, and the delete then hangs in
  `Terminating`. Deleting first sets a deletion timestamp, after which the
  finalizer stays removed.
- The PVC goes `Lost` with the event `Data on the volume is lost!`. That
  message is about the API object; the directory is untouched, and the claim
  rebinds because the new PV's `claimRef.uid` matches it.
- The kubelet applies `fsGroup` to `local` volumes, which it never did on
  hostPath: at the next pod start the group of every file becomes the pod's
  `fsGroup`, with `g+rw` and setgid on directories. Pods with
  `fsGroupChangePolicy: OnRootMismatch` only pay for that once.
- To roll back, do the same swap with `$PV.hostpath.yaml` (after the same
  `yq del(...)` clean-up).

## Backblaze setup
1. Create a **private** bucket. Under Lifecycle Settings choose *Keep only
   the last version of the file*, or add a custom rule for the
   `talos-homelab/` prefix if the bucket is shared. B2 keeps every version of
   every object by default, so without this nothing Velero or kopia deletes
   ever frees space.
2. Create an application key restricted to that bucket with *Read and Write*
   access and *Allow List All Bucket Names* ticked (S3 clients call
   `ListBuckets`). Note the `keyID` and `applicationKey`; the latter is shown
   once.
3. Set `bucket`, `region`, and `s3Url` in `velero-values.yaml` to match the
   bucket's Endpoint (`s3.<region>.backblazeb2.com`).

## Credentials
Generate the repository password in a password manager and **store it, the
B2 key, and the bucket name there**. The sealed copies in git can only be
opened by this cluster; after losing the cluster, those three things are all
that stands between you and the backups.

```zsh
read "B2_KEY_ID?B2 keyID: "
read -s "B2_APP_KEY?B2 applicationKey: "; echo
read -s "REPO_PASSWORD?Repository password: "; echo

printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$B2_KEY_ID" "$B2_APP_KEY" | \
kubectl create secret generic velero-b2-credentials -n velero \
  --from-file=cloud=/dev/stdin --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
  > 15-velero/sealed-velero-b2-credentials.yaml

kubectl create secret generic velero-repo-credentials -n velero \
  --from-literal=repository-password="$REPO_PASSWORD" --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
  > 15-velero/sealed-velero-repo-credentials.yaml
unset B2_KEY_ID B2_APP_KEY REPO_PASSWORD
```

Rotating the B2 key is a reseal. The repository password cannot be changed
once the first backup has initialised the kopia repositories; changing it
means starting again under a new `prefix`.

## Operating it
Install the [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli)
(`brew install velero`).

```sh
velero backup-location get                         # PHASE must be Available
velero backup create --from-schedule velero-daily  # run one now
velero backup get
velero backup describe <name> --details            # lists every pod volume backed up
velero backup logs <name> | grep -i hostpath       # volumes that were skipped
```

A running backup reports little through `velero backup get`. Object counts
are on the Backup, and each volume is its own `PodVolumeBackup` with byte
progress, carried out by a short-lived pod next to the node-agent:

```sh
velero backup describe <name> --details            # items done/total, per-volume status
kubectl -n velero get backup <name> -o jsonpath='{.status.phase} {.status.progress}{"\n"}'
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<name> -w \
  -o custom-columns='NS:.spec.pod.namespace,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,DONE:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes'
kubectl -n velero logs deploy/velero -f | grep <name>
```

Grafana has the longer view: `velero_backup_last_status`,
`velero_backup_duration_seconds`, and `velero_pod_volume_*` are scraped.

Run a backup by hand right after the first sync rather than waiting for
04:00 to learn whether Backblaze accepts it.

## Restoring
A namespace, into the running cluster (existing objects are left alone, so
delete what should be replaced first; with `Retain`, also remove the old PV
and its directory if the volume should come back from the backup):

```sh
velero restore create --from-backup <name> --include-namespaces forgejo
```

After losing the cluster:

1. Rebuild the node and bootstrap `01-infrastructure` (README steps 1 to 3),
   but do not apply `04-gitops/root-app.yaml` yet.
2. Install Velero by hand from this directory, with plain Secrets made from
   the password manager instead of the SealedSecrets, which the new
   controller cannot open:
   ```sh
   kubectl create namespace velero
   kubectl label namespace velero pod-security.kubernetes.io/enforce=privileged
   kubectl -n velero create secret generic velero-b2-credentials --from-file=cloud=<credentials file>
   kubectl -n velero create secret generic velero-repo-credentials --from-literal=repository-password=<password>
   kubectl kustomize --enable-helm 15-velero | yq 'select(.kind != "SealedSecret")' | \
     kubectl apply -f -
   ```
   Client-side apply on purpose: the `velero` Application syncs with
   `ServerSideApply=true`, and a server-side `kubectl` field manager would
   linger as described in the top-level README's GitOps section.
3. Wait for `velero backup get` to list the backups from the bucket, then
   restore the sealed-secrets key first and restart the controller so the
   SealedSecrets in git decrypt again:
   ```sh
   velero restore create --from-backup <name> --include-namespaces kube-system \
     --include-resources secrets --selector sealedsecrets.bitnami.com/sealed-secrets-key
   kubectl -n kube-system rollout restart deploy/sealed-secrets
   ```
4. Restore the application namespaces, then apply `04-gitops/root-app.yaml`
   and let Argo CD reconcile everything back to git.

The plugin image in `velero-values.yaml` and the chart are bumped separately
by Renovate; check the
[plugin compatibility table](https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility)
when a Velero minor version changes.
