# n8n

Workflow automation for the homelab. [n8n](https://n8n.io/) runs from the
official `n8nio/n8n` image with an in-cluster PostgreSQL database. The editor
is reachable on the LAN at `https://n8n.k8s.noelmiller.dev`; production
webhooks are published to the internet at
`https://hooks.noelmiller.dev/webhook/...` through a Cloudflare Tunnel.

## Components
- `namespace.yaml`: `n8n` namespace, `restricted` Pod Security.
- `sealed-n8n-postgresql.yaml`: sealed PostgreSQL credentials (`password`, `postgres-password`).
- `sealed-n8n-encryption-key.yaml`: sealed `N8N_ENCRYPTION_KEY` (`encryption-key`), which encrypts the credentials saved in n8n.
- `sealed-n8n-todoist-discord.yaml`: sealed inputs of the Todoist workflow (`todoist-client-secret`, `discord-webhook-url`, `todoist-api-token`).
- `sealed-n8n-discord-project-webhooks.yaml`: sealed map of Todoist project name to Discord webhook URL (`project-webhooks`, one JSON object), written by `seal-project-webhook.sh`. Optional.
- `seal-project-webhook.sh`: adds, replaces, or removes entries in that map and reseals it.
- `sealed-n8n-discord-interactions.yaml`: sealed Discord application public key and server ID for the `/tasks` command (`public-key`, `guild-id`), written by `setup-discord-command.sh`. Optional.
- `setup-discord-command.sh`: registers the `/tasks` slash command in one server and writes that file.
- `sealed-cloudflared-credentials.yaml`: sealed tunnel credentials (`credentials.json`, `tunnel-id`).
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest as Coder, Forgejo, and Keycloak, with the Velero `pg_dump` hook.
- `n8n.yaml`: data PVC (5Gi on `nvme-2tb`), Deployment (1 replica, `Recreate`), Service (`5678`), and a ServiceMonitor for `/metrics`.
- `n8n-route.yaml`: `HTTPRoute` for `n8n.k8s.noelmiller.dev` on `main-gateway`.
- `cloudflared.yaml`: `cloudflared` Deployment for the webhook tunnel and a PodMonitor for its metrics.
- `cloudflared-config.yaml`: the tunnel's ingress rules, mounted through a hashed ConfigMap.
- `workflows/todoist-discord.json`: the Todoist to Discord workflow, imported by hand (see below). Not applied by Argo CD.
- `workflows/discord-tasks.json`: the `/tasks` slash command workflow, imported the same way.

## Runtime configuration
Everything is passed as environment variables: the PostgreSQL connection,
`N8N_EDITOR_BASE_URL=https://n8n.k8s.noelmiller.dev` behind one proxy hop, and
`WEBHOOK_URL=https://hooks.noelmiller.dev/` so the editor displays the public
address for production webhooks. `enableServiceLinks` is off because a Service
named `n8n` would otherwise inject `N8N_PORT=tcp://...`, which n8n reads as
its listen port.

Sign-in is n8n's own owner account, created in the browser on the first
visit. The community edition has no OIDC, so Keycloak is not involved.

`NODE_FUNCTION_ALLOW_BUILTIN=crypto` and `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`
relax two n8n 2.x defaults so the Todoist workflow's Code node can compute an
HMAC with a secret from the environment. The second one lets any workflow
read the pod's environment, including the database password and the
encryption key. That is acceptable while the instance has one user; revisit
it before inviting anyone else.

## Public webhooks
`cloudflared` runs a locally-managed tunnel: the ingress rules are in
`cloudflared-config.yaml`, not in the Cloudflare dashboard, so what is
published is reviewed in git. It forwards `hooks.noelmiller.dev` paths
matching `^/webhook/` to the n8n Service and answers 404 for anything else.
The editor, the REST API, `/metrics`, and the editor's `/webhook-test/` URLs
are never published. The tunnel dials out to Cloudflare, so nothing is
port-forwarded and Traefik is not in the path.

The hostname is a first-level subdomain because Cloudflare's Universal SSL
certificate covers `*.noelmiller.dev` but not `*.k8s.noelmiller.dev`.

A production webhook only answers while its workflow is published. To test
from the editor with "Listen for test event", send the request to the LAN
address (`https://n8n.k8s.noelmiller.dev/webhook-test/...`).

### Creating the tunnel
Once, from a workstation:

```sh
brew install cloudflared
cloudflared tunnel login                  # browser; pick the noelmiller.dev zone
cloudflared tunnel create n8n-webhooks    # writes ~/.cloudflared/<tunnel-id>.json
cloudflared tunnel route dns n8n-webhooks hooks.noelmiller.dev
```

Seal the credentials file together with the tunnel ID, which the Deployment
passes to `cloudflared tunnel run`:

```sh
creds=$(ls ~/.cloudflared/*.json)   # exactly one file; otherwise name it
kubectl create secret generic cloudflared-credentials \
  --namespace n8n \
  --from-file=credentials.json="$creds" \
  --from-literal=tunnel-id="$(jq -r .TunnelID "$creds")" \
  --dry-run=client -o yaml |
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    > 16-n8n/sealed-cloudflared-credentials.yaml
```

`~/.cloudflared/cert.pem` can create and delete tunnels in the zone; it is not
needed by the cluster. Delete it, and the credentials file, once the sealed
Secret is committed.

## Todoist to Discord
`workflows/todoist-discord.json` posts an embed to a Discord channel when a
Todoist task is added, updated, completed, or deleted, with who it is
assigned to:

Webhook (`POST /webhook/todoist`, raw body) -> Code node that verifies
`X-Todoist-Hmac-SHA256` and parses the event -> HTTP Request that lists the
projects from the Todoist API -> Code node that builds the embed and picks
the channel -> HTTP Request to that Discord webhook -> `200 sent`. A bad or missing signature gets
`401`; anything not relayed gets `200 ignored: <reason>`.

`item:updated` is the noisy one, so it is filtered. Todoist also sends it when
a task is completed or uncompleted and for every occurrence of a recurring
task (`update_intent` other than `item_updated`); those are dropped because
they have their own events. For a real edit the payload carries the previous
version of the task, and the embed lists what changed (content, due date,
priority, labels, description, project, assignee) as `old → new`. An update with none of
those, such as a drag to reorder, is dropped.

The project lookup uses `TODOIST_API_TOKEN`, the `data:read` OAuth token from
the authorization in step 6. One request lists every project, which gives the
names, and the parents that channel routing walks up. If the token is missing
or the lookup fails, the message is posted to the default channel.

An assigned task shows an "Assigned to" field; unassigned tasks show nothing.
The name comes from the project's collaborators, fetched only when a task has
an assignee, which only happens in shared projects. If that lookup fails the
field says "someone". The Project field (`Work / Clients / Acme`) appears only
in the default channel, where several projects mix; in a project's own channel
it would be redundant.

### A channel per project
A Discord webhook belongs to one channel, so routing is a map of project name
to webhook URL in `DISCORD_PROJECT_WEBHOOKS`. The nearest mapped project wins:
a task in `Work / Clients / Acme` goes to Acme's channel if Acme is mapped,
otherwise Clients', otherwise Work's. Names match without regard to case.
Anything unmapped, Inbox and new projects included, goes to the default
`DISCORD_WEBHOOK_URL`, so nothing is dropped. Renaming a project in Todoist
sends it to the default channel until the map is updated.

To add, replace, or remove a project, create the webhook in the target
channel (Edit Channel > Integrations > Webhooks), then:

```sh
./16-n8n/seal-project-webhook.sh
```

It reads the current map from the live Secret (a SealedSecret cannot be
decrypted locally), prompts for project names and hidden URLs, and rewrites
`sealed-n8n-discord-project-webhooks.yaml`. Merge one run before starting the
next. n8n reads the map at start-up, so after the merge:

```sh
kubectl -n n8n rollout restart deploy/n8n
```

The workflow itself does not change when the map does.

Todoist signs the raw request body with the app's client secret, which is why
the Webhook node keeps the raw body and the Code node parses it itself.
Completions of recurring tasks are posted like any other; Todoist sends
`item:completed` for every occurrence.

### Setup
1. In the [Todoist app console](https://developer.todoist.com/appconsole.html),
   create an app. The OAuth redirect URL can be `https://localhost/callback`.
2. In the Discord channel: Edit Channel > Integrations > Webhooks > New
   Webhook, and copy its URL. Treat the URL as a secret; it is the whole
   posting credential.
3. Seal both values:
   ```sh
   read -rs "todoist_secret?Todoist client secret: "; echo
   read -rs "discord_url?Discord webhook URL: "; echo
   kubectl create secret generic n8n-todoist-discord \
     --namespace n8n \
     --from-literal=todoist-client-secret="$todoist_secret" \
     --from-literal=discord-webhook-url="$discord_url" \
     --dry-run=client -o yaml |
     kubeseal --format yaml \
       --controller-name sealed-secrets \
       --controller-namespace kube-system \
       > 16-n8n/sealed-n8n-todoist-discord.yaml
   unset todoist_secret discord_url
   ```
4. After the sync, open `https://n8n.k8s.noelmiller.dev`, create the owner
   account, then Workflows > Import from File > `todoist-discord.json`, and
   publish the workflow.
5. Back in the Todoist app console, under Webhooks, set the callback URL to
   `https://hooks.noelmiller.dev/webhook/todoist`, select `item:added`,
   `item:updated`, `item:completed`, and `item:deleted`, and activate the
   webhook.
6. Todoist only delivers webhooks for users who authorized the app through
   OAuth; the console's test token does not count. Authorize once: open

   ```
   https://todoist.com/oauth/authorize?client_id=CLIENT_ID&scope=data:read&state=x
   ```

   approve, copy `code` from the redirect URL, and exchange it:

   ```sh
   curl -X POST https://todoist.com/oauth/access_token \
     -d client_id=CLIENT_ID -d client_secret=CLIENT_SECRET -d code=CODE
   ```

   The authorization is what makes Todoist deliver webhooks. The returned
   `access_token` is read-only and is what the workflow uses to look up
   project names; add it to the existing SealedSecret without re-entering the
   other values, then commit the file:

   ```sh
   read -rs "todoist_token?Todoist access token: "; echo
   kubectl create secret generic n8n-todoist-discord \
     --namespace n8n \
     --from-literal=todoist-api-token="$todoist_token" \
     --dry-run=client -o yaml |
     kubeseal --format yaml \
       --controller-name sealed-secrets \
       --controller-namespace kube-system \
       --merge-into 16-n8n/sealed-n8n-todoist-discord.yaml
   unset todoist_token
   ```

## Listing tasks from Discord
`workflows/discord-tasks.json` answers a `/tasks` slash command with the open
tasks of a Todoist project, as a message everyone in the channel can see.
Discord delivers slash commands over HTTPS to an Interactions Endpoint URL,
here `https://hooks.noelmiller.dev/webhook/discord`, so there is no bot
process and no gateway connection.

Webhook (`POST /webhook/discord`, raw body) -> Code node that verifies the
request -> reply -> Code node that finds the project and lists its tasks ->
HTTP Request that edits the reply.

- Discord signs `timestamp + body` with the application's Ed25519 key. A bad
  signature, or a timestamp more than five minutes off, gets `401`; Discord
  probes for exactly that before it accepts the endpoint URL. Commands from
  any server other than `DISCORD_GUILD_ID` are refused.
- The first reply is "thinking..." (a deferred response) and the list is sent
  as an edit of it, which lifts Discord's three-second limit on replies.
- `/tasks` with no argument lists the project the channel is mapped to. A
  webhook URL answers an unauthenticated `GET` with its channel ID, so the
  project -> webhook map from the section above is also the channel ->
  project map. `/tasks project:<name>` lists any project from any channel;
  a path such as `Family / Trips` picks between sub-projects with the same
  name.
- Tasks are sorted by due date, then priority, and show their assignee. A list
  longer than an embed holds ends with "and N more". Sub-projects are not
  included. The title names the project only when it was asked for with
  `project:`; in the project's own channel it is just the count.
- It reads Todoist with the same `data:read` token, so it cannot change tasks.

### Setup
1. In the [Discord developer portal](https://discord.com/developers/applications),
   create an application. Under Installation, keep only "Guild Install" and
   the `applications.commands` scope, open the install link, and add it to
   your server. No bot permissions are needed.
2. Register the command and seal the public key and server ID. The bot token
   (Bot > Reset Token) is used once for the registration call and not stored:
   ```sh
   ./16-n8n/setup-discord-command.sh
   ```
3. Commit `sealed-n8n-discord-interactions.yaml`, merge, and let the pod roll.
4. In the n8n editor, import `workflows/discord-tasks.json` as a new workflow
   and publish it.
5. Only then set General Information > Interactions Endpoint URL to
   `https://hooks.noelmiller.dev/webhook/discord`. Discord verifies the URL
   when you save, so the workflow has to be live first.

## Workflows in git
The workflows in git are the source of truth only by convention: n8n stores
the live copy in PostgreSQL. After editing one in the browser, download it
(Workflow menu > Download) over its file here.

## Rotating credentials
The Todoist client secret and the Discord webhook URL are rotated by
repeating step 3 (then step 6 again, since sealing from scratch drops the API
token) and restarting n8n (`kubectl -n n8n rollout restart
deploy/n8n`), since both are read from the environment.

Do not rotate `n8n-encryption-key`: credentials saved in n8n are encrypted
with it and become unreadable. The PostgreSQL passwords are only applied when
the database is first initialised; changing them later means `ALTER ROLE` in
the database first, as for the other PostgreSQL instances.

## Monitoring and dashboard
- `ServiceMonitor` `n8n` scrapes `/metrics` on the n8n Service; `PodMonitor` `cloudflared` scrapes the tunnel's metrics port (`2000`).
- `cloudflared`'s liveness probe is `/ready`, which fails once no edge connection is left, so a dead tunnel restarts on its own.
- Blackbox probes in `08-monitoring/probes.yaml`: HTTP `n8n.n8n.svc:5678/healthz/readiness` (which includes the database connection) and TCP `n8n-postgresql.n8n.svc:5432`.
- Homepage entry under `Cluster` in `05-dashboard/config/services.yaml`.

## Backups
Velero backs up both volumes daily. PostgreSQL holds the workflows,
credentials, and executions; its pre-backup hook leaves a consistent dump at
`/bitnami/postgresql/backup/n8n.sql` (see
[15-velero/README.md](../15-velero/README.md)). A restored database is only
useful with the same `n8n-encryption-key`, which comes back with the
SealedSecret as long as the cluster's sealing key is restored too.

## Upgrading PostgreSQL
Same procedure as the other instances; see
[13-forgejo/README.md](../13-forgejo/README.md#upgrading-postgresql).

## Not yet configured
- No alert on the tunnel itself beyond the liveness restart; a webhook that stops arriving is silent.
- Workflows are imported by hand rather than reconciled from git.
