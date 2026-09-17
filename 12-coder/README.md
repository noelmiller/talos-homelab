# Coder

This application installs Coder with an in-cluster PostgreSQL database and
exposes it at `https://coder.k8s.noelmiller.dev`.

## Components
- `namespace.yaml`: creates the `coder` namespace.
- `sealed-coder-postgresql.yaml`: sealed credentials for the PostgreSQL instance (`password`, `postgres-password`, `connection-url`).
- `sealed-coder-keycloak-oidc.yaml`: sealed Keycloak OIDC client secret (`client-secret`). The same value is sealed for the `keycloak` namespace in `14-keycloak/sealed-keycloak-coder-client.yaml`.
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (20Gi persistent volume on `nvme-2tb`). The image is pinned by digest because the chart's default tag is the floating `latest`, which would pull a new PostgreSQL major on any pod restart and fail to start on the existing data directory.
- `coder-values.yaml`: Coder Helm chart values configured for cluster-internal PostgreSQL, Keycloak OIDC, and `https://coder.k8s.noelmiller.dev` access URL.
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
Sign-in goes through Keycloak only: the login page offers **Sign in with
Keycloak** (OpenID Connect against the `homelab` realm in `14-keycloak`).
GitHub sign-in is not configured, and Coder's built-in GitHub OAuth app is
explicitly disabled with `CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE: "false"`.

- **Issuer**: `https://auth.k8s.noelmiller.dev/realms/homelab`, client `coder`, declared in `14-keycloak/realm-homelab.json` with redirect URI `https://coder.k8s.noelmiller.dev/api/v2/users/oidc/callback`.
- Any user of the `homelab` realm can sign in; the Coder account is created on first sign-in with the Keycloak username and the `member` role. The realm has no self-registration, so that is whoever you created in Keycloak.
- Coder matches accounts by e-mail address and rejects an `email_verified: false` claim. For users created in the admin console, switch **Email verified** on (Users → the user → Details).
- The `offline_access` scope gives Coder a refresh token that outlives the Keycloak SSO session, so sessions are not cut off when the access token expires. Revoke one from the user's **Sessions** tab in Keycloak.
- Coder fetches the OIDC discovery document at startup and exits if that fails, so while Keycloak is down or the realm has not been imported, a *restarting* Coder pod crash-loops until Keycloak answers. A running pod keeps serving workspaces and existing sessions, but nobody can sign in until Keycloak is back.
- To rotate the client secret, see "Rotating credentials" in `14-keycloak/README.md`.

### Break-glass access
If Keycloak is unavailable or the owner account is lost, create a local
owner with a password from inside the Coder pod (password sign-in stays
enabled for this purpose), then sign in with e-mail and password:

```sh
kubectl -n coder exec -it deploy/coder -- coder server create-admin-user \
  --username breakglass --email <email>
```

It reads the database URL from the pod's environment and prompts for the
password. Delete the user again once Keycloak sign-in works.

### Accounts created before Keycloak
A Coder account is bound to one login type, and Coder only offers
self-service conversion for password accounts. The original `noelmiller`
owner account was created through GitHub and was switched to OIDC in the
database before GitHub sign-in was removed:

```sh
kubectl -n coder exec -it coder-postgresql-0 -- bash -c \
  'PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")" psql -U coder coder'
```
```sql
DELETE FROM user_links WHERE user_id = (SELECT id FROM users WHERE username = '<username>');
UPDATE users SET login_type = 'oidc' WHERE username = '<username>';
```

The next Keycloak sign-in with the same e-mail address links the account.

## Upgrading PostgreSQL
The pinned digest corresponds to PostgreSQL 18.6.0. To move to a newer image, look up the
current `latest` digest and its version label, then update `image.digest` in
`postgresql-values.yaml`. Stay within the same major version unless you have a
`pg_dump` backup and are prepared to run a major-version upgrade.

```sh
curl -s https://hub.docker.com/v2/repositories/bitnami/postgresql/tags/latest | jq -r .digest
```

