# Coder

This application installs Coder with an in-cluster PostgreSQL database and
exposes it at `https://coder.k8s.noelmiller.dev`.

## Components
- `namespace.yaml`: creates the `coder` namespace.
- `sealed-coder-postgresql.yaml`: sealed credentials for the PostgreSQL instance (`password`, `postgres-password`, `connection-url`).
- `sealed-coder-github-oauth.yaml`: sealed GitHub OAuth App client secret (`client-secret`).
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (20Gi persistent volume on `nvme-2tb`).
- `coder-values.yaml`: Coder Helm chart values configured for cluster-internal PostgreSQL, GitHub OAuth, and `https://coder.k8s.noelmiller.dev` access URL.
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
Sign-in uses a dedicated GitHub OAuth App (not the default Coder-managed app,
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
