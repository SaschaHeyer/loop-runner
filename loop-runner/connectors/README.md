# connectors/ — how a loop reaches the outside world

A **connector** is any HTTPS API a loop uses. Credentials are injected at the local egress proxy
(`../proxy_addon.py`) — the agent calls the API with **no Authorization header** and the proxy adds
it on the wire, so the credential never enters the agent's sandbox. A loop declares what it uses in
its spec (`connectors: [slack, github]`); that list is **scoped** (M5 — a loop reaches only the
connectors it declares) and **config-driven** (M11b — the domain→secret map is data, below).

## Add a connector (2 steps — data, not code, since M11b)

1. **Secret Manager** — the human puts the credential in themselves (never through chat):
   ```bash
   printf '%s' '<credential>' | gcloud secrets create <secret-name> --data-file=- --project=<proj>
   ```
2. **One entry** in the connector registry [`registry.json`](registry.json) — this single file is read
   by BOTH the proxy (`../proxy_addon.py`, for auth injection) AND `../deploy.sh` (for `--set-secrets`
   wiring), so there is **no code to edit**:
   ```json
   "myapi": { "domain": "api.example.com", "secret": "<secret-name>", "env": "MY_TOKEN", "header": "Bearer {}" }
   ```
   `domain` is the host (its subdomains match too); `env` is the var the proxy reads; `header` is the
   `Authorization` template (`{}` = the credential — use `"Basic {}"` for base64 schemes). Then declare
   `connectors: [myapi]` in the loop's `loop.yaml`. A declared connector missing from the registry is a
   hard error at deploy (fail fast), never a silent unauthenticated deploy.

Already wired via the registry: `api.stripe.com`, `api.resend.com`, `api.cloudflare.com`, `slack.com`.
The two **non-env-bearer** connectors stay special-cased in `../proxy_addon.py` (and absent from the
registry): `*.googleapis.com` (Job SA token from the metadata server) and `github.com` (Basic base64 of
the PAT; `gh` CLI in the image, always injected).

## Slack

Files: [`slack/app-manifest.yaml`](slack/app-manifest.yaml) — paste-ready app manifest (read-only
bot: `channels:history` + `channels:read`).

**Naming convention:** name the bot after the LOOP (its function), never the machinery — teammates
seeing `@slack-digest` in the member list know exactly what it reads and why; `@loop-runner` would
be opaque. Keep it 1:1: loop `loops/<name>/` ↔ bot `@<name>` ↔ its own token, so audit and
revocation stay per-loop.

Setup: api.slack.com/apps → **Create New App → From a manifest** → workspace → paste the manifest →
Create → **OAuth & Permissions → Install to Workspace** → copy the `xoxb-…` bot token → step 1
above as `slack-bot-token` → `/invite @slack-digest` in each channel the loop should read
(bots need channel membership for history, even in public channels).
⚠️ **Managed/enterprise workspaces**: installing requires ADMIN APPROVAL — the button
reads "Request to Workspace Install" and the `xoxb` token only generates after approval. Include a
justification note with the request (read-only, two scopes, invite-only, no posting, token in
Secret Manager) — least-privilege manifests get approved fastest. Registry entry (already present):
```json
"slack": { "domain": "slack.com", "secret": "slack-bot-token", "env": "SLACK_BOT_TOKEN", "header": "Bearer {}" }
```
Usage from a loop (no auth header — the proxy injects the bot token):
```bash
curl -s "https://slack.com/api/users.conversations?types=public_channel"          # channels the bot is in
curl -s "https://slack.com/api/conversations.history?channel=C0123&limit=50"       # recent messages
```
Live example: the [`slack-to-issues`](../../loops/slack-to-issues/) loop — reads the channel(s) the bot was
invited to and opens a GitHub issue on its own repo per actionable message. It was the first connector
added as pure config (registry entry + secret, no `proxy_addon.py`/`deploy.sh` edit).

**Bot vs user token vs MCP:** a bot is not the only way — a user token (`xoxp`, what Claude
Desktop's Slack connector uses) reads everything the human can read with zero invites, but acts AS
the human, leaks their entire Slack view if compromised, and dies with their account. Decision for
unattended loops: **bot token** (machine identity, least privilege, clean audit).

## Jira (recipe, not yet wired)

Jira Cloud uses Basic auth: store `base64(email:api_token)` as secret `jira-basic-b64`, then add one
registry entry (note `"header": "Basic {}"`):
```json
"jira": { "domain": "<site>.atlassian.net", "secret": "jira-basic-b64", "env": "JIRA_BASIC_B64", "header": "Basic {}" }
```
Agent POSTs to `/rest/api/3/issue` with no auth header.
