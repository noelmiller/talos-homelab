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
- `sealed-n8n-todoist-discord.yaml`: sealed inputs of the Todoist workflow (`todoist-client-secret`, `discord-webhook-url`).
- `sealed-n8n-discord-project-webhooks.yaml`: sealed map of Todoist project name to Discord webhook URL (`project-webhooks`, one JSON object), written by `seal-project-webhook.sh`. Optional.
- `seal-project-webhook.sh`: adds, replaces, or removes entries in that map and reseals it.
- `sealed-n8n-discord-interactions.yaml`: sealed Discord application public key and server ID for the slash commands (`public-key`, `guild-id`), written by `setup-discord-command.sh`. Optional.
- `setup-discord-command.sh`: registers the `/tasks`, `/add`, and `/done` slash commands in one server and writes that file.
- `sealed-cloudflared-credentials.yaml`: sealed tunnel credentials (`credentials.json`, `tunnel-id`).
- `postgresql-values.yaml`: Bitnami PostgreSQL chart values (10Gi on `nvme-2tb`), image pinned to the same PostgreSQL 18 digest as Coder, Forgejo, and Keycloak, with the Velero `pg_dump` hook.
- `n8n.yaml`: data PVC (5Gi on `nvme-2tb`), Deployment (1 replica, `Recreate`), Service (`5678`), and a ServiceMonitor for `/metrics`.
- `n8n-route.yaml`: `HTTPRoute` for `n8n.k8s.noelmiller.dev` on `main-gateway`.
- `cloudflared.yaml`: `cloudflared` Deployment for the webhook tunnel and a PodMonitor for its metrics.
- `cloudflared-config.yaml`: the tunnel's ingress rules, mounted through a hashed ConfigMap.
- `credentials/todoist-oauth2.json`: the n8n OAuth2 credential for the Todoist API with every field but the client ID and secret filled in (see below). No secrets.
- `workflows/todoist-discord.json`: the Todoist to Discord workflow, imported by hand (see below). Not applied by Argo CD.
- `workflows/discord-tasks.json`: the Discord slash command workflow, imported the same way.

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
priority, labels, description, project, assignee) as `old → new`. An update
with none of those, such as a drag to reorder, is dropped.

The Todoist API calls are HTTP Request nodes that use the `Todoist`
OAuth2 credential (see "Todoist API access" below). One request lists every
project, which gives the names, and the parents that channel routing walks
up. If the credential is not connected or the lookup fails, the message is
posted to the default channel.

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
   create an app. Set the OAuth redirect URL to
   `https://n8n.k8s.noelmiller.dev/rest/oauth2-credential/callback`.
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
6. Connect the Todoist credential (next section). Todoist only delivers
   webhooks for users who authorized the app through OAuth, and the console's
   test token does not count; connecting the credential is that authorization.

## Todoist API access
Apps created in the Todoist console today get one-hour access tokens and a
refresh token that is replaced on every use, and that cannot be turned off.
A token sealed into a Secret therefore stops working within the hour. Both
workflows instead use an n8n OAuth2 credential, `Todoist`: n8n
refreshes the access token when Todoist answers 401, stores the rotated
refresh token, and keeps both encrypted with `N8N_ENCRYPTION_KEY` in
PostgreSQL. The scope is `data:read_write`, which the Discord commands that
add and complete tasks need; it does not include `data:delete`, so nothing in
n8n can delete a task or a project.

`credentials/todoist-oauth2.json` holds everything but the client ID and
secret, under a fixed ID that the workflow files refer to, so importing a
workflow needs no credential to be re-selected. Create it once:

```sh
kubectl -n n8n exec -i deploy/n8n -- sh -c \
  'cat > /tmp/c.json && n8n import:credentials --input=/tmp/c.json; rm -f /tmp/c.json' \
  < 16-n8n/credentials/todoist-oauth2.json
```

Then in the editor: Overview > Credentials tab > `Todoist` (or
`/home/credentials/TodoistOAuth2001`) > paste the app's Client ID and Client
Secret > Connect my account > Agree, and close the dialog once it says
"Account connected". Do not press Save afterwards: on n8n 2.39 that wrote the
form back without the token that Connect had just stored, leaving a credential
that looks connected and answers nothing. The redirect goes to
`n8n.k8s.noelmiller.dev`, so do this from the LAN. Running the import
again resets the credential to its unconnected state.

If the credential ever needs reconnecting (messages arrive in the default
channel without a Project field, `/tasks` answers "Could not reach Todoist"),
open it and press Reconnect. A refresh token presented twice more than a
minute apart makes Todoist revoke every token of the app; two executions
racing to refresh at the same moment are within that minute.

## Discord commands
`workflows/discord-tasks.json` answers three slash commands:

| Command | Does | Who sees the reply |
|---|---|---|
| `/tasks [project]` | lists a project's open tasks | the channel |
| `/add task [due] [priority] [assignee]` | adds a task to the channel's project | the caller |
| `/done task` | completes a task in the channel's project | the caller |

Discord delivers slash commands over HTTPS to an Interactions Endpoint URL,
here `https://hooks.noelmiller.dev/webhook/discord`, so there is no bot
process and no gateway connection.

Webhook (`POST /webhook/discord`, raw body) -> Code node that verifies the
request -> a Switch on ping, command, or autocomplete -> the project is
resolved -> a Switch per command, each branch being Todoist HTTP Request
nodes and a Code node that words the answer -> HTTP Request that edits the
reply.

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
- `/add` and `/done` change Todoist, so they are narrower than `/tasks`: they
  work only in a channel that is mapped to a project, only on that project,
  and take no `project:` argument. Anyone in the server may use them there.
  `/done` looks the task up among that project's open tasks, so a task ID
  from elsewhere in the account is refused, and there is no delete: the
  credential lacks `data:delete`, and a completed task can be restored in
  Todoist.
- Todoist attributes everything done through the API to the account that
  connected the credential, so `/add` writes "Added from Discord by <name>"
  into the task's description.
- `due` is passed to Todoist as typed (`tomorrow`, `fri 5pm`, `every monday`);
  if Todoist cannot parse it the task is not created and the reply says so.
- `task` in `/done` and `assignee` in `/add` autocomplete: Discord asks the
  workflow for suggestions on every keystroke and wants an answer within
  three seconds, with no deferral. To keep that fast, which channel each
  mapped webhook posts to is remembered for a day in the workflow's static
  data, keyed by a hash of the URL. Typed text also works: a unique match is
  accepted, an ambiguous one is refused with the candidates.
- Confirmations are shown to the caller only, because the relay workflow
  announces the new or completed task to the channel anyway.
- All Todoist access goes through the same credential as the relay.

### Setup
1. In the [Discord developer portal](https://discord.com/developers/applications),
   create an application. Under Installation, keep only "Guild Install" and
   the `applications.commands` scope, open the install link, and add it to
   your server. No bot permissions are needed.
2. Register the commands and seal the public key and server ID. The bot token
   (Bot > Reset Token) is used once for the registration call and not stored:
   ```sh
   ./16-n8n/setup-discord-command.sh
   ```
   Run it again whenever the commands or their options change; it replaces
   the server's command list and offers to skip the sealing.
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
repeating step 3 and restarting n8n (`kubectl -n n8n rollout restart
deploy/n8n`), since both are read from the environment. A new client secret
also goes into the `Todoist` credential, followed by Reconnect.

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
