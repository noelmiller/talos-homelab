# BookOrbit

This application runs [BookOrbit](https://bookorbit.app), a library and
reader for ebooks, PDFs, comics, and audiobooks, from the official
`ghcr.io/bookorbit/bookorbit` image with an in-cluster PostgreSQL database,
following the upstream `docker-compose.yml`. It is reachable at
`https://bookorbit.k8s.noelmiller.dev` from the LAN, and users can sign in
through Keycloak (`14-keycloak`) once the provider is added in the app (see
below).

## Components
- `namespace.yaml`: `bookorbit` namespace, `restricted` Pod Security.
- `sealed-bookorbit-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-bookorbit-secrets.yaml`: sealed application secrets, all random: `jwt-secret`, `podcast-encryption-key`, `email-encryption-key`, `migration-encryption-key`, `book-request-encryption-key` (32 random bytes as hex each), and `setup-bootstrap-token`.
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest as the other layers (it ships pgvector), an init script that creates the extensions, and the Velero `pg_dump` pre-backup hook.
- `bookorbit.yaml`: the `bookorbit-data` PVC (20Gi on `nvme-2tb`, mounted at `/data`), the `bookorbit-books` PVC (500Gi nominal on `sata-8tb`, mounted at `/books`), the Deployment (1 replica, `Recreate`), and the Service (`3000`).
- `bookorbit-route.yaml`: `HTTPRoute` for `bookorbit.k8s.noelmiller.dev` on `main-gateway`.
- `seedbox-proxy/seedbox_proxy.py`: the `seedbox-proxy` sidecar (see "Book requests through the seedbox"), shipped as a generated ConfigMap.
- `sealed-seedbox-ftp.yaml`: sealed seedbox FTP login (`username`, `password`), written by `seal-seedbox-ftp.sh`.

## Runtime configuration
Everything is passed as environment variables in `bookorbit.yaml`:

- `APP_URL` is the public address. It is used in e-mailed links, Kobo and
  OPDS endpoints, and as the OIDC redirect URI (`<APP_URL>/oauth2-callback`).
  TLS terminates at Traefik.
- The entrypoint builds `DATABASE_URL` from `POSTGRES_HOST`, `POSTGRES_PORT`,
  `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` (from the sealed
  Secret), percent-encoding the password.
- The pod runs as the image's `node` user (1000) with a read-only root
  filesystem and an emptyDir at `/tmp`, like upstream's compose file (which
  sets `read_only` and a `/tmp` tmpfs). Started as non-root, the entrypoint
  skips its `chown`/`su-exec` step; `fsGroup: 1000` makes both volumes
  writable instead.
- `LIBRARY_BROWSE_ROOT=/books`: the folder picker for a new library starts at
  the books volume.
- `OIDC_ALLOW_LOCAL_ISSUERS=true`: `auth.k8s.noelmiller.dev` resolves to the
  LAN Traefik address, which BookOrbit's SSRF guard otherwise refuses for OIDC
  discovery.
- `NODE_MAX_OLD_SPACE_SIZE=auto`: the Node.js heap is sized from the 2Gi
  memory limit (1536 MB). Raise the limit for a very large library.
- The image runs pending database migrations on every start, so an upgrade is
  just the image bump. Take a backup first for a new minor version (see
  `15-velero/README.md`); migrations are not reversible by rolling the image
  back. The first start after PostgreSQL is created restarts once or twice on
  `ECONNREFUSED` until the database is up; that is harmless.

Not deployed: the optional Kokoro text-to-speech container from upstream's
`tts` compose profile.

## PostgreSQL extensions
Before every migration run BookOrbit executes `CREATE EXTENSION IF NOT EXISTS`
for `uuid-ossp`, `pg_trgm`, `unaccent`, and `vector`. The first three are
trusted extensions the database owner may create, but pgvector is not, so the
`bookorbit` user cannot and the pod would crash-loop with `permission denied
to create extension "vector"`. The chart's `primary.initdb.scripts` creates
all four as `postgres` when the data directory is first initialised.

It is a `.sh` script rather than `.sql` because the Bitnami image runs `.sql`
init files as the application user. The setup sources the script after it
has read the `*_FILE` secrets into `POSTGRESQL_*` variables, and `exit 1` on
failure makes the container fail loudly. It runs until it has succeeded once
on a volume and never again, so a database restored into an existing volume
must already contain the extensions (a `pg_dump` does).

## First start and sign-in
1. Read the one-time setup token:
   ```sh
   kubectl -n bookorbit get secret bookorbit-secrets \
     -o jsonpath='{.data.setup-bootstrap-token}' | base64 -d; echo
   ```
2. Open `https://bookorbit.k8s.noelmiller.dev`, enter the token, and create
   the first administrator (a local account).
3. Add Keycloak as a provider under the OIDC settings:
   - issuer URI `https://auth.k8s.noelmiller.dev/realms/homelab`
   - client ID `bookorbit`
   - client secret: the value Keycloak holds for the `bookorbit` client:
     ```sh
     kubectl -n keycloak get secret keycloak-bookorbit-client \
       -o jsonpath='{.data.client-secret}' | base64 -d; echo
     ```
   - scopes `openid profile email`, username claim `preferred_username`.

   Provider settings live in BookOrbit's database, not in git. The client
   secret is stored there too, which is why it is only sealed for the
   `keycloak` namespace.
4. Link your administrator to Keycloak from your account settings, then
   decide whether other realm users are auto-provisioned on first sign-in and
   with which permissions (the provider's auto-provision settings).

The `bookorbit` client in `14-keycloak/realm-homelab.json` allows two redirect
URIs, `https://bookorbit.k8s.noelmiller.dev/oauth2-callback` for the web app
and `bookorbit://oauth2-callback` for the iPhone app, requires PKCE (S256),
and registers the back-channel logout URL
`https://bookorbit.k8s.noelmiller.dev/api/v1/auth/oidc/backchannel-logout`, so
ending a Keycloak session also ends the BookOrbit sessions from that login.

Keep local sign-in enabled (`DISABLE_LOCAL_AUTH` is unset, so it defaults to
`false`) as break-glass access while Keycloak is down.

## Adding books
The library lives on the `bookorbit-books` volume at `/books`. Create a
library pointing at a folder there, then upload through the browser, or copy
files in with `kubectl cp` (into the library folder, or into the Book Dock
drop folder under `/data` for automatic import).

## Book requests through the seedbox
Book requests download through Transmission on the RapidSeedbox
(`rapidseedbox91832-tr.basic-003.seedbox.vip`). BookOrbit imports a download
from a local path as soon as Transmission reports it finished, and an import
that finds nothing there fails the attempt, so the files have to be home
*before* BookOrbit hears "finished". The `seedbox-proxy` container in the
BookOrbit pod does that:

- It listens on `localhost:9091` and forwards every Transmission RPC call to
  the seedbox's RPC endpoint (`/rpc` on this seedbox, not the standard
  `/transmission/rpc`, which answers POST with 405; `UPSTREAM_RPC_PATH`), including BookOrbit's own Transmission login (basic
  auth) and the `X-Transmission-Session-Id` handshake. It never stores that
  login.
- In `torrent-get` answers, a finished torrent in the `bookorbit` category
  folder is reported as still downloading (status 4, 99%) until the proxy has
  copied its files over FTPS into `/data/seedbox/<name>`. After that the real
  status passes through and BookOrbit imports the local copy.
- BookOrbit keeps a category's torrents in `<download-dir>/<category>` and
  asks Transmission for `download-dir` before every add; the proxy learns the
  folder from that answer and keeps it in `/data/seedbox/.proxy/download-dir`,
  so no seedbox path is configured here. The FTP login is chrooted into that
  download directory (`FTP_ROOT=/`).
- A copy lands in a staging folder and is renamed into place, and
  `/data/seedbox/.proxy/done/<hash>` is written only after that, so a restart
  simply starts an unfinished copy again. Failures are retried every minute.
- `/data/seedbox` is on the same volume as the Book Dock, so the import
  hardlinks instead of copying. Local copies are deleted seven days after they
  land (`RETENTION_DAYS`); the done markers stay so a torrent BookOrbit still
  watches for seeding is never fetched again. Seeding stays on the seedbox.
- FTPS uses explicit TLS with certificate verification, capped at TLS 1.2
  because vsftpd requires data connections to resume the control connection's
  TLS session, which Python can only offer immediately on 1.2.

Settings in BookOrbit (Settings > System > Requests):

1. Download client **Transmission**: URL `http://localhost:9091`, the
   seedbox's Transmission username and password, category `bookorbit`, and
   allow private addresses (the proxy is on `localhost`, which BookOrbit
   otherwise refuses).
2. Path mapping for that client: remote path `<download-dir>/bookorbit`, local
   path `/data/seedbox`. "Test connection" asks Transmission for its session,
   so after one test the proxy logs `learned download-dir=...` with the value
   to use: `kubectl -n bookorbit logs deploy/bookorbit -c seedbox-proxy`.
3. Indexers: add them directly or through Prowlarr.

Only torrents in the `bookorbit` folder are touched; anything else on the
seedbox (added by hand, other categories) passes through untouched.

To change the FTP login, run `bash 18-bookorbit/seal-seedbox-ftp.sh` in a
terminal (it prompts without echoing), commit, and delete the BookOrbit pod
once Argo CD has synced.

## Rotating credentials
PostgreSQL (BookOrbit reads the password at startup; rotate it in the
database too, or restore from backup, when changing an existing deployment):

```sh
user_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
admin_password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

kubectl create secret generic bookorbit-postgresql \
  --namespace bookorbit \
  --from-literal=postgres-password="$admin_password" \
  --from-literal=password="$user_password" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 18-bookorbit/sealed-bookorbit-postgresql.yaml
unset user_password admin_password
```

`jwt-secret` can be rotated at any time; everyone is signed out. Do **not**
rotate the four `*-encryption-key` values on a running deployment: they
encrypt podcast feed URLs, SMTP settings, migration-source credentials, and
download-client and indexer credentials stored in the database, which become
unreadable. They are in `sealed-bookorbit-secrets.yaml` and in every Velero
backup of the namespace.

The Keycloak client secret is covered in "Rotating credentials" in
`14-keycloak/README.md`. After rotating it, paste the new value into
BookOrbit's provider settings.

## Backups
The daily Velero schedule (`15-velero`) covers the namespace: both volumes,
and the PostgreSQL volume with a consistent `pg_dump` at
`/bitnami/postgresql/backup/bookorbit.sql` written by the pre-backup hook.
The books volume is not labelled out of backups, since books are not
re-downloadable the way the media library is; add
`k8s.noelmiller.dev/backup-volume-data: "false"` to it if it grows too large
for the B2 upload.

The dump is taken with `--clean --if-exists`, so it drops and recreates
`vector` and must be restored as `postgres`, not as `bookorbit`.

## Monitoring and dashboard
- Blackbox probes check `bookorbit:3000/api/v1/health` (which also reports the database connection) and `bookorbit-postgresql:5432` (`08-monitoring/probes.yaml`). BookOrbit has no Prometheus endpoint.
- Homepage lists BookOrbit in the Media group (`05-dashboard/config/services.yaml`).

## Not yet configured
- **SMTP** (Send-to-Kindle, password resets): configured in the app;
  `EMAIL_ENCRYPTION_KEY` is already set, so the credentials are stored
  encrypted.
- **Public access**: the hostname resolves to the LAN-only Traefik address,
  so Kobo sync, OPDS, KOReader, and the iPhone app only work on the home
  network (or over a VPN).
