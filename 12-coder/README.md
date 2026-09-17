# Coder

This application installs Coder with an in-cluster PostgreSQL database and
exposes it at `https://coder.k8s.noelmiller.dev`.

## Components
- `namespace.yaml`: creates the `coder` namespace.
- `sealed-coder-postgresql.yaml`: sealed credentials for the PostgreSQL instance (`password`, `postgres-password`, `connection-url`).
- `sealed-coder-github-oauth.yaml`: sealed GitHub OAuth App client secret (`client-secret`).
- `sealed-coder-keycloak-oidc.yaml`: sealed Keycloak OIDC client secret (`client-secret`). The same value is sealed for the `keycloak` namespace in `14-keycloak/sealed-keycloak-coder-client.yaml`.
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (20Gi persistent volume on `nvme-2tb`). The image is pinned by digest because the chart's default tag is the floating `latest`, which would pull a new PostgreSQL major on any pod restart and fail to start on the existing data directory.
- `coder-values.yaml`: Coder Helm chart values configured for cluster-internal PostgreSQL, GitHub OAuth, Keycloak OIDC, and `https://coder.k8s.noelmiller.dev` access URL.
- `coder-route.yaml`: Gateway API `HTTPRoute` attaching `coder.k8s.noelmiller.dev` to `main-gateway`.

## Rotating PostgreSQL Credentials
To regenerate the sealed PostgreSQL secret:

```sh
user_password="$(openssl rand -base64 32 | tr -d '=+/\\n' | cut -c1-24)"
admin_password="$(openssl rand -base64 32 | tr -d '=+/\\n' | cut -c1-24)"
connection_url="postgresql://coder:${user_password}@coder-postgresql:5432/coder?sslmode=disable"

kubectl create secret generic coder-postgresql \
  --namespace coder \
  --from-literal=postgres-password="$admin_password" \
  --from-literal=password="$user_password" \
  --from-literal=connection-url="$connection_url" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 12-coder/sealed-coder-postgresql.yaml
```

## Authentication
The login page offers two providers: **Sign in with Keycloak** (OpenID
Connect against the `homelab` realm in `14-keycloak`) and GitHub.

### Keycloak
- **Issuer**: `https://auth.k8s.noelmiller.dev/realms/homelab`, client `coder`, declared in `14-keycloak/realm-homelab.json` with redirect URI `https://coder.k8s.noelmiller.dev/api/v2/users/oidc/callback`.
- Any user of the `homelab` realm can sign in; the Coder account is created on first sign-in with the Keycloak username and the `member` role. The realm has no self-registration, so that is whoever you created in Keycloak.
- Coder rejects an `email_verified: false` claim. For users created in the admin console, switch **Email verified** on (Users → the user → Details).
- The `offline_access` scope gives Coder a refresh token that outlives the Keycloak SSO session, so sessions are not cut off when the access token expires. Revoke one from the user's **Sessions** tab in Keycloak.
- Coder fetches the OIDC discovery document at startup and exits if that fails, so while Keycloak is down or the realm has not been imported, a *restarting* Coder pod crash-loops until Keycloak answers. A running pod is unaffected, and GitHub sign-in is independent of Keycloak.
- To rotate the client secret, see "Rotating credentials" in `14-keycloak/README.md`.

A Coder account is bound to one login type. An account that was created
through GitHub cannot sign in through Keycloak with the same e-mail address
(`Incorrect login type`), and Coder only offers self-service conversion for
password accounts. To move an existing GitHub account to Keycloak, switch its
login type in the database, then sign in with Keycloak using the same e-mail:

```sh
kubectl -n coder exec -it coder-postgresql-0 -- bash -c \
  'PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" psql -U coder coder'
```
```sql
DELETE FROM user_links WHERE user_id = (SELECT id FROM users WHERE email = '<email>');
UPDATE users SET login_type = 'oidc' WHERE email = '<email>';
```

Once every account is on Keycloak, GitHub sign-in can be removed by deleting
the `CODER_OAUTH2_GITHUB_*` variables (keep
`CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE: "false"`) and
`sealed-coder-github-oauth.yaml`.

### GitHub
GitHub sign-in uses a dedicated GitHub OAuth App (not the default Coder-managed app,
which is explicitly disabled via `CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE: "false"`).

- **Homepage URL / Authorization callback URL**: `https://coder.k8s.noelmiller.dev`
- **Allowed org**: `henry-miller-frazier` (`CODER_OAUTH2_GITHUB_ALLOWED_ORGS`)
- Client ID is stored in plaintext in `coder-values.yaml` (not sensitive on its own).
- Client secret is stored in `sealed-coder-github-oauth.yaml`.

To rotate the GitHub OAuth client secret, generate a new one from the GitHub
OAuth App settings page, then reseal it:

```sh
kubectl create secret generic coder-github-oauth \
  --namespace coder \
  --from-literal=client-secret="<new-client-secret>" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 12-coder/sealed-coder-github-oauth.yaml
```

## Upgrading PostgreSQL
The pinned digest corresponds to PostgreSQL 18.6.0. To move to a newer image, look up the
current `latest` digest and its version label, then update `image.digest` in
`postgresql-values.yaml`. Stay within the same major version unless you have a
`pg_dump` backup and are prepared to run a major-version upgrade.

```sh
curl -s https://hub.docker.com/v2/repositories/bitnami/postgresql/tags/latest | jq -r .digest
```

