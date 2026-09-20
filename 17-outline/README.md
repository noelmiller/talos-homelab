# Outline

This application runs the [Outline](https://www.getoutline.com/) wiki from the
official `outlinewiki/outline` image with an in-cluster PostgreSQL database
and Redis, following the
[self-hosting guide](https://docs.getoutline.com/s/hosting). It is reachable
at `https://outline.k8s.noelmiller.dev` from the LAN, and sign-in goes through
Keycloak (`14-keycloak`).

## Components
- `namespace.yaml`: `outline` namespace, `restricted` Pod Security.
- `sealed-outline-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-outline-secrets.yaml`: sealed `secret-key` (`SECRET_KEY`, 32 random bytes as hex) and `utils-secret` (`UTILS_SECRET`).
- `sealed-outline-keycloak-oidc.yaml`: sealed OIDC client secret (`client-secret`). The same value is sealed for the `keycloak` namespace in `14-keycloak/sealed-keycloak-outline-client.yaml`.
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest as the other layers, with the Velero `pg_dump` pre-backup hook.
- `redis.yaml`: Redis Deployment and Service, no persistence (see below).
- `outline.yaml`: the `outline-data` PVC (20Gi on `nvme-2tb`), Deployment (1 replica, `Recreate`), and Service (`3000`).
- `outline-route.yaml`: `HTTPRoute` for `outline.k8s.noelmiller.dev` on `main-gateway`. Real-time collaboration uses WebSockets on the same host, which Traefik passes through.

## Runtime configuration
Everything is passed as environment variables in `outline.yaml`:

- `URL` is the public address; TLS terminates at Traefik, so `FORCE_HTTPS` is
  off (Traefik already redirects port 80, and with it on the kubelet and
  blackbox probes of `/_health` would get a redirect instead of an answer).
- The database is configured with `DATABASE_HOST`, `DATABASE_NAME`,
  `DATABASE_USER`, and `DATABASE_PASSWORD` (from the sealed Secret) rather
  than `DATABASE_URL`; Outline refuses to start with a mix of the two.
  `PGSSLMODE=disable` because the in-cluster PostgreSQL speaks plain TCP.
- `FILE_STORAGE=local`: images, attachments, avatars, and import/export
  archives are written to the `outline-data` volume at
  `/var/lib/outline/data`. Documents themselves live in PostgreSQL.
- `ENABLE_UPDATES=false`: no version check or anonymised statistics; Renovate
  tracks the image.
- The image runs pending database migrations on every start, so an upgrade is
  just the image bump. Take a backup first for a new minor version (see
  `15-velero/README.md`); migrations are not reversible by rolling the image
  back.

## Redis
Outline uses Redis for its background job queues, rate-limiter counters, and
collaboration presence. None of that is a source of truth, so Redis runs
without a volume (`--save "" --appendonly no`) and with `noeviction`, which
the job queues require. Restarting it drops jobs that were queued at that
moment (a pending export, for example); start the action again.

## Sign-in with Keycloak
`outline.yaml` sets `OIDC_ISSUER_URL` to the `homelab` realm, and Outline
reads the authorization, token, userinfo, and end-session endpoints and PKCE
support from the realm's discovery document. The `outline` client is declared
in `14-keycloak/realm-homelab.json`:

- redirect URI `https://outline.k8s.noelmiller.dev/auth/oidc.callback`;
- post-logout redirect URI `https://outline.k8s.noelmiller.dev`: signing out
  of Outline ends the Keycloak session for that login (RP-initiated logout
  with `id_token_hint`) and returns to Outline's login page.

Things to know:

- Discovery happens at startup and Outline exits if it fails, so the pod
  restarts until Keycloak and the realm answer.
- The **first user to sign in creates the workspace and is its
  administrator.** Sign in yourself before telling anyone else the address.
  Later realm users join the same workspace with the default role set under
  Settings → Security; roles are managed in Outline, as the community edition
  does not map OIDC groups.
- Outline rejects a sign-in without an `email` claim, so the Keycloak user
  needs an e-mail address. The username comes from `preferred_username`.
- Keycloak is the only provider and there is no local account, so there is no
  break-glass login: while Keycloak is down, nobody new can sign in (existing
  sessions keep working). E-mail magic links would need SMTP, which is not
  configured.

## Rotating credentials
PostgreSQL (Outline reads the password at startup; rotate it in the database
too, or restore from backup, when changing an existing deployment):

```sh
user_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
admin_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

kubectl create secret generic outline-postgresql \
  --namespace outline \
  --from-literal=postgres-password="$admin_password" \
  --from-literal=password="$user_password" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 17-outline/sealed-outline-postgresql.yaml
unset user_password admin_password
```

The OIDC client secret is sealed for two namespaces; see "Rotating
credentials" in `14-keycloak/README.md`.

Do **not** rotate `secret-key` on a running deployment: it encrypts sessions
and the stored tokens of integrations, which become unreadable. It is in
`sealed-outline-secrets.yaml` and in every Velero backup of the namespace.

## Backups
The daily Velero schedule (`15-velero`) covers the namespace: the
`outline-data` volume, and the PostgreSQL volume with a consistent `pg_dump`
at `/bitnami/postgresql/backup/outline.sql` written by the pre-backup hook.
Both are needed for a restore; attachments are referenced from the database.
Outline can also export a collection or the whole workspace as Markdown or
JSON under Settings → Export.

## Monitoring and dashboard
- Blackbox probes check `outline:3000/_health`, `outline-postgresql:5432`, and `outline-redis:6379` (`08-monitoring/probes.yaml`). Outline has no Prometheus endpoint.
- Homepage lists Outline in the Cluster group (`05-dashboard/config/services.yaml`).

## Not yet configured
- **SMTP**: without `SMTP_*` settings Outline sends no invitations or
  notification e-mails. Invite people by creating their Keycloak user instead.
- **Integrations** (Slack, GitHub previews, Iframely, ...): see the
  [configuration docs](https://docs.getoutline.com/s/hosting/doc/configuration-509J4lAzjo).
- **Public access**: the hostname resolves to the LAN-only Traefik address, so
  public share links only work on the home network.
