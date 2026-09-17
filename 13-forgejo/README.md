# Forgejo

This application installs [Forgejo](https://forgejo.org/) from the official
`forgejo-helm` chart (pulled by kustomize from the `code.forgejo.org` OCI
registry) with an in-cluster PostgreSQL database. It is reachable at
`https://git.k8s.noelmiller.dev` and, for git over SSH, at
`git@git.k8s.noelmiller.dev` on port 22.

## Components
- `namespace.yaml`: creates the `forgejo` namespace with the `restricted` Pod Security level enforced.
- `sealed-forgejo-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-forgejo-admin.yaml`: sealed Forgejo administrator credentials (`username`, `password`).
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest Coder runs.
- `forgejo-values.yaml`: Forgejo chart values: rootless image, restricted-compatible security contexts, 50Gi data volume on `nvme-2tb`, PostgreSQL connection, metrics + ServiceMonitor, and the `app.ini` settings for the domain, SSH port, and registration policy.
- `forgejo-routes.yaml`: Gateway API `HTTPRoute` (HTTPS) and `TCPRoute` (SSH) attaching to `main-gateway`.

## How traffic reaches Forgejo
HTTPS is routed exactly like every other app: the `HTTPRoute` attaches to
`main-gateway`'s `websecure` listener and inherits the wildcard certificate.

SSH is routed through the same Gateway. Traefik has an `ssh` EntryPoint
(container port `2222`, exposed on the Traefik LoadBalancer as port `22`, see
`01-infrastructure/kustomization.yaml`) and `main-gateway` has a matching
`ssh` TCP listener (`02-configuration/main-gateway.yaml`). The `TCPRoute`
forwards that listener to the `forgejo-ssh` Service, so clone URLs use the
same DNS name as the web UI with no extra MetalLB address. Traefik's
`providers.kubernetesGateway.experimentalChannel` must stay enabled: without
it Traefik ignores `TCPRoute` objects.

Inside the pod the rootless image serves SSH from Forgejo's built-in server on
`2222`; `SSH_PORT: 22` only controls the port advertised in clone URLs.

## First login
The administrator account is created on first start from the sealed
`forgejo-admin` Secret. The password is never stored in plaintext in git;
read it from the unsealed Secret after the first sync:

```sh
kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

The chart's default `passwordMode: keepUpdated` re-applies this password on
every pod start, so change it by resealing the Secret (below), not in the UI.
This local account is the break-glass login; day-to-day sign-in goes through
Keycloak.

## Sign-in with Keycloak
`forgejo-values.yaml` registers Keycloak (`14-keycloak`) as an OpenID Connect
source named `keycloak`, using the `homelab` realm's discovery URL and the
client id/secret from `sealed-forgejo-keycloak-oauth.yaml` (keys `key` and
`secret`; the same secret is sealed for the `keycloak` namespace). The chart
runs `gitea admin auth add-oauth` / `update-oauth` in an init container on
every start, so the source follows the values file.

- The local registration form is closed (`ALLOW_ONLY_EXTERNAL_REGISTRATION`);
  a first Keycloak sign-in creates the Forgejo account (`ENABLE_AUTO_REGISTRATION`)
  with the Keycloak username, and links to an existing local account with the
  same e-mail automatically.
- The `groups` claim is mapped: members of the Keycloak group `forgejo-admins`
  are Forgejo administrators (`adminGroup`).
- Adding the source fetches the discovery document, so Forgejo will not start
  while Keycloak or the realm is unreachable; the init container retries until
  it is.

## Rotating credentials
PostgreSQL (Forgejo reads the `password` key at startup; rotate it in the
database too, or restore from backup, when changing an existing deployment):

```sh
user_password="$(openssl rand -base64 32 | tr -d '=+/\\n' | cut -c1-24)"
admin_password="$(openssl rand -base64 32 | tr -d '=+/\\n' | cut -c1-24)"

kubectl create secret generic forgejo-postgresql \
  --namespace forgejo \
  --from-literal=postgres-password="$admin_password" \
  --from-literal=password="$user_password" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 13-forgejo/sealed-forgejo-postgresql.yaml
```

Administrator account:

```sh
read -rsp "New admin password: " FORGEJO_ADMIN_PASSWORD; echo
kubectl create secret generic forgejo-admin \
  --namespace forgejo \
  --from-literal=username=forgejo_admin \
  --from-literal=password="$FORGEJO_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 13-forgejo/sealed-forgejo-admin.yaml
unset FORGEJO_ADMIN_PASSWORD
```

## Data and secrets on the volume
Repositories, LFS objects, attachments, and `app.ini` live on the
`forgejo-data` PVC. On the very first start the chart generates
`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, and `LFS_JWT_SECRET` into that
`app.ini` and never overwrites them. Losing the volume therefore invalidates
existing sessions, tokens, and LFS locks as well as the repositories, so back
it up together with a `pg_dump` of the database.

## Upgrading PostgreSQL
Same procedure as Coder (see `12-coder/README.md`): look up the current
`latest` digest, update `image.digest` in `postgresql-values.yaml`, and stay
within PostgreSQL 18 unless you have a `pg_dump` and are prepared to run a
major-version upgrade.

## Monitoring and dashboard
- Forgejo's `/metrics` endpoint is scraped through the chart's `ServiceMonitor`.
- Blackbox probes check `forgejo-http:3000/api/healthz`, `forgejo-ssh:22`, and `forgejo-postgresql:5432` (`08-monitoring/probes.yaml`).
- Homepage lists Forgejo in the Cluster group (`05-dashboard/config/services.yaml`).

## Not yet configured
- **Forgejo Actions runner**: no `forgejo-runner` is deployed, so Actions
  workflows will queue forever if enabled. Add a runner Deployment with a
  registration token from Site Administration → Actions → Runners.
- **Coder integration**: to let Coder workspaces clone over HTTPS without
  prompting, create an OAuth2 application in Forgejo and add a
  `CODER_EXTERNAL_AUTH_0_*` block to `12-coder/coder-values.yaml`.
- **Coder sign-in through Keycloak**: Coder currently uses GitHub OAuth; it
  can switch to Keycloak with a second client in `14-keycloak/realm-homelab.json`
  and `CODER_OIDC_*` settings.
- **Argo CD webhooks**: `ALLOWED_HOST_LIST` already permits private targets,
  so a repository webhook to `http://argocd-server.argocd.svc.cluster.local/api/webhook`
  works once Argo CD is pointed at a Forgejo-hosted repository.
