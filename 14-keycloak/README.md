# Keycloak

Single sign-on for the cluster, currently used by Forgejo. Keycloak runs from
the official `quay.io/keycloak/keycloak` image in production mode with an
in-cluster PostgreSQL database and is reachable at
`https://auth.k8s.noelmiller.dev`.

## Components
- `namespace.yaml`: `keycloak` namespace, `restricted` Pod Security.
- `sealed-keycloak-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-keycloak-admin.yaml`: sealed bootstrap admin (`username`, `password`), also used by the realm import Job.
- `sealed-keycloak-forgejo-client.yaml`: sealed OIDC client secret for Forgejo (`client-secret`). The same value is sealed for the `forgejo` namespace in `13-forgejo/sealed-forgejo-keycloak-oauth.yaml`.
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest as Coder and Forgejo.
- `keycloak.yaml`: Deployment (1 replica, `Recreate`), Service (`8080` http, `9000` management), and a ServiceMonitor for `/metrics`.
- `keycloak-route.yaml`: `HTTPRoute` for `auth.k8s.noelmiller.dev` on `main-gateway`.
- `realm-homelab.json`: the `homelab` realm, applied by `realm-import-job.yaml` (see below).

## Runtime configuration
Everything is passed as `KC_*` environment variables: PostgreSQL connection,
`KC_HOSTNAME=https://auth.k8s.noelmiller.dev`, plain HTTP behind Traefik with
`KC_PROXY_HEADERS=xforwarded`, and health/metrics on the management port.
Because `KC_DB` differs from the image's build-time default, every start
re-augments the Quarkus build (roughly a minute); the startup probe allows
five minutes.

## Realm as code
`realm-homelab.json` declares:
- realm `homelab`: no self-registration, e-mail login, brute-force protection;
- group `forgejo-admins`;
- client scope `groups` with a group-membership mapper (claim `groups`);
- confidential client `forgejo` with redirect URI `https://git.k8s.noelmiller.dev/user/oauth2/keycloak/callback` and the `groups` scope by default.

`realm-import-job.yaml` runs [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli)
as an Argo CD PostSync hook after every successful sync. The client secret
placeholder `$(env:FORGEJO_OAUTH_CLIENT_SECRET)` is resolved from the sealed
Secret at import time, so the secret never appears in git. The Job creates
and updates the declared objects but is configured with `no-delete` for
clients, client scopes, and groups, so anything created by hand in the admin
console survives. Edit the JSON and push to change the realm; kustomize hashes
the file into the ConfigMap name, which re-creates the Job.

The CLI image tag suffix (`26.5.5`) is the Keycloak version it was built
against; it works with Keycloak 26.7 because the admin API is stable within a
major version. Bump both together when a new CLI release appears.

## First login and users
1. Read the bootstrap admin credentials:
   ```sh
   kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d; echo
   kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
   ```
2. Open `https://auth.k8s.noelmiller.dev/admin/`, sign in, and in the
   `master` realm create a permanent administrator (Users → Add user, set a
   password, assign the `admin` realm role). Keycloak flags the bootstrap
   account as temporary until this is done. The import Job keeps using the
   bootstrap account; if you delete it, reseal `keycloak-admin` with the new
   administrator's credentials.
3. Switch to the `homelab` realm and create your user (Users → Add user,
   Credentials → set password). Add it to the `forgejo-admins` group to be a
   Forgejo administrator.
4. Open `https://git.k8s.noelmiller.dev`, choose **Sign in with keycloak**.
   The Forgejo account is created on first sign-in with the Keycloak username.

## Rotating credentials
Bootstrap admin (only takes effect on an empty database; afterwards change
the password in the admin console and reseal so the import Job can log in):

```sh
read -rsp "Keycloak admin password: " KC_ADMIN_PASSWORD; echo
kubectl create secret generic keycloak-admin --namespace keycloak \
  --from-literal=username=admin --from-literal=password="$KC_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > 14-keycloak/sealed-keycloak-admin.yaml
unset KC_ADMIN_PASSWORD
```

Forgejo client secret (seal the same value for both namespaces; the next
sync updates the Keycloak client and Forgejo's auth source together):

```sh
client_secret="$(openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-40)"
kubectl create secret generic keycloak-forgejo-client --namespace keycloak \
  --from-literal=client-secret="$client_secret" --dry-run=client -o yaml |
  kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > 14-keycloak/sealed-keycloak-forgejo-client.yaml
kubectl create secret generic forgejo-keycloak-oauth --namespace forgejo \
  --from-literal=key=forgejo --from-literal=secret="$client_secret" --dry-run=client -o yaml |
  kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > 13-forgejo/sealed-forgejo-keycloak-oauth.yaml
unset client_secret
```

PostgreSQL: same procedure and caveats as `13-forgejo/README.md`.

## Coupling with Forgejo
Forgejo's chart adds the OIDC source with `gitea admin auth add-oauth` in an
init container on every start, which fetches
`https://auth.k8s.noelmiller.dev/realms/homelab/.well-known/openid-configuration`.
While Keycloak is down or the realm has not been imported yet, that init
container fails and Kubernetes retries it; Forgejo comes up on its own once
Keycloak answers. Expect this on the first deployment and after a full
cluster restart.

## Adding another application
Add a client to `realm-homelab.json` with its redirect URI, seal its secret
for the `keycloak` namespace, pass it to the Job as an environment variable,
and reference it with `$(env:NAME)` in the JSON.
