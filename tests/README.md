# On-demand smoke tests

Manifests here are **not** part of any kustomization and are never applied by
ArgoCD. Apply one by hand to check a piece of the cluster, then delete it.

| File | Checks | Apply / clean up |
|---|---|---|
| `gateway-api.yaml` | Traefik + Gateway API routing and the wildcard cert | `kubectl apply -f tests/gateway-api.yaml`, open `https://whoami.k8s.noelmiller.dev`, then `kubectl delete -f tests/gateway-api.yaml` |
| `storage-classes.yaml` | All three local-path StorageClasses provision and bind | `kubectl apply -f tests/storage-classes.yaml`, `kubectl get pvc`, then `kubectl delete -f tests/storage-classes.yaml` (PVs are `Retain`; delete them too) |
| `kubevirt-web-vm.yaml` | KubeVirt boots a VM with both a pod and a `lan` Multus interface | `kubectl apply -f tests/kubevirt-web-vm.yaml`, open `https://vm-test.k8s.noelmiller.dev`, then `kubectl delete -f tests/kubevirt-web-vm.yaml` |

The images in these files are intentionally not tracked by Renovate.
