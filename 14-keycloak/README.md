# Keycloak

Single sign-on for the cluster, currently used by Forgejo and Coder. Keycloak runs from
the official `quay.io/keycloak/keycloak` image in production mode with an
in-cluster PostgreSQL database and is reachable at
`https://auth.k8s.noelmiller.dev`.

## Components
- `namespace.yaml`: `keycloak` namespace, `restricted` Pod Security.
- `sealed-keycloak-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-keycloak-admin.yaml`: sealed bootstrap admin (`username`, `password`), also used by the realm import Job.
- `sealed-keycloak-forgejo-client.yaml`: sealed OIDC client secret for Forgejo (`client-secret`). The same value is sealed for the `forgejo` namespace in `13-forgejo/sealed-forgejo-keycloak-oauth.yaml`.
- `sealed-keycloak-coder-client.yaml`: sealed OIDC client secret for Coder (`client-secret`). The same value is sealed for the `coder` namespace in `12-coder/sealed-coder-keycloak-oidc.yaml`.
- `sealed-keycloak-github-idp.yaml`: sealed GitHub OAuth App credentials for the `github` identity provider (`client-id`, `client-secret`).
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
- identity provider `github` and its first-login flow `github link existing` (see "Sign in with GitHub" below);
- group `forgejo-admins`;
- client scope `groups` with a group-membership mapper (claim `groups`);
- confidential client `forgejo` with redirect URI `https://git.k8s.noelmiller.dev/user/oauth2/keycloak/callback` and the `groups` scope by default;
- confidential client `coder` with redirect URI `https://coder.k8s.noelmiller.dev/api/v2/users/oidc/callback` and `offline_access` as an optional scope (Coder requests it to get a long-lived refresh token).

`realm-import-job.yaml` runs [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli)
as an Argo CD PostSync hook after every successful sync. The client secret
placeholders `$(env:FORGEJO_OAUTH_CLIENT_SECRET)`,
`$(env:CODER_OIDC_CLIENT_SECRET)`, and `$(env:GITHUB_IDP_CLIENT_ID)` /
`$(env:GITHUB_IDP_CLIENT_SECRET)` are resolved from the sealed Secrets at
import time, so the secrets never appear in git. The Job creates
and updates the declared objects but is configured with `no-delete` for
clients, client scopes, groups, authentication flows, and identity providers,
so anything created by hand in the admin console survives. Edit the JSON and push to change the realm; kustomize hashes
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
5. For Coder, switch **Email verified** on for the user (Coder refuses
   unverified addresses), then open `https://coder.k8s.noelmiller.dev` and
   choose **Sign in with Keycloak**. Keycloak is Coder's only sign-in
   provider; see `12-coder/README.md` for break-glass access.

## Sign in with GitHub
The login page offers a **GitHub** button, which Forgejo and Coder inherit
because they only ever see Keycloak. GitHub is a second way into an
*existing* Keycloak user, not a way to get one:

- `registrationAllowed: false` does not apply to brokered logins, and the
  built-in `first broker login` flow would create a Keycloak user (and with
  it a Coder and Forgejo account) for any GitHub user. The provider therefore
  uses the custom flow `github link existing`.
- Step 1, *Detect existing broker user*: the GitHub account's primary e-mail
  (or login name) must match a user you already created in the realm;
  everyone else is rejected and nothing is created.
- Step 2, *Username password form for re-authentication*: on the first GitHub
  sign-in the matched user proves their Keycloak password once, which links
  the GitHub account. Later GitHub sign-ins go straight through. Automatic
  linking is deliberately not used: the match falls back to the login name,
  so a GitHub user named like one of your Keycloak users could otherwise take
  that account over.
- Links are listed under Users → the user → **Identity provider links**, and
  can be added or removed by the user at
  `https://auth.k8s.noelmiller.dev/realms/homelab/account` → Account security
  → Linked accounts.
- Password sign-in to Keycloak keeps working when GitHub is unavailable.

The GitHub OAuth App (GitHub → Settings → Developer settings → OAuth Apps):
- **Homepage URL**: `https://auth.k8s.noelmiller.dev`
- **Authorization callback URL**: `https://auth.k8s.noelmiller.dev/realms/homelab/broker/github/endpoint`

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

Coder client secret (same pattern; the next sync updates the Keycloak client
and the `coder-keycloak-oidc` Secret, but Coder reads it as an environment
variable, so finish with `kubectl -n coder rollout restart deploy/coder`):

```sh
client_secret="$(openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-40)"
kubectl create secret generic keycloak-coder-client --namespace keycloak \
  --from-literal=client-secret="$client_secret" --dry-run=client -o yaml |
  kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > 14-keycloak/sealed-keycloak-coder-client.yaml
kubectl create secret generic coder-keycloak-oidc --namespace coder \
  --from-literal=client-secret="$client_secret" --dry-run=client -o yaml |
  kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > 12-coder/sealed-coder-keycloak-oidc.yaml
unset client_secret
```

GitHub identity provider (client ID from the OAuth App page, then generate a
new client secret there; the next sync updates the provider):

```sh
# zsh syntax; in bash use `read -rp "prompt" var` / `read -rsp "prompt" var`.
read -r "gh_id?GitHub client ID: "
read -rs "gh_secret?GitHub client secret: "; echo
if [ -n "$gh_id" ] && [ -n "$gh_secret" ]; then
  kubectl create secret generic keycloak-github-idp --namespace keycloak \
    --from-literal=client-id="$gh_id" --from-literal=client-secret="$gh_secret" \
    --dry-run=client -o yaml |
    kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
    > 14-keycloak/sealed-keycloak-github-idp.yaml
else
  echo "empty value, nothing written" >&2
fi
unset gh_id gh_secret
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

## Coupling with Coder
Coder fetches the same discovery document once at startup and exits if it
cannot, so a Coder pod that (re)starts while Keycloak is unavailable
crash-loops until Keycloak answers. A Coder pod that is already running keeps
serving workspaces and existing sessions, but Keycloak is its only sign-in
provider, so nobody can sign in until Keycloak is back (break-glass procedure
in `12-coder/README.md`).

## Adding another application
Add a client to `realm-homelab.json` with its redirect URI, seal its secret
for the `keycloak` namespace, pass it to the Job as an environment variable,
and reference it with `$(env:NAME)` in the JSON.
