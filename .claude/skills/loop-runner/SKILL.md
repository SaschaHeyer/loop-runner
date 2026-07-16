---
name: loop-runner
description: Set up and operate Loop Runner — a task-agnostic harness that runs agentic loops (Claude Code) headless in Google Cloud Run Jobs with guaranteed commit → push → verify → record. Use when the user wants agents that run unattended, overnight, or on a cron; wants to install or set up loop-runner; wants to add, deploy, dry-run, or debug a loop; or asks how to run Claude Code headless in the cloud.
---

# Loop Runner — operator runbook

Loop Runner runs any repeatable agent workflow (a "loop") headless in a Cloud Run Job under one
lifecycle: **TRIGGER → EXECUTE → VERIFY → RECORD → STOP**. The harness runs the agent as a
subprocess and owns the guarantees the agent can't be trusted with: a Stop hook commits + pushes
whatever the agent leaves behind, a PreToolUse guard blocks footguns (`rm -rf /`, force-push,
`reset --hard`), `verify.sh` runs in the harness (not the agent), and a local egress proxy injects
API credentials on the wire so the agent never holds a key.

Mantra: **the agent forgets; the repo doesn't.** The repo is the loop's memory.

## 1 · Get the harness (first time only)

The loop library is a repo the loops push state back into, so the user needs their own copy with
write access:

```bash
gh repo fork SaschaHeyer/loop-runner --clone   # or clone their existing fork
cd loop-runner
```

If already inside a loop-runner checkout, skip this step.

## 2 · Configure once

1. `cp loop-runner/.env.example loop-runner/.env`, then fill in: GCP project, region, runtime
   service account. Never paste credentials into chat — secrets (e.g. `github-pat`) go into GCP
   Secret Manager; the deploy script wires them with `--set-secrets`.
2. `gcloud auth login && gcloud config set project <project>`.
3. One-time on a fresh GCP project: enable the Claude models in Vertex AI Model Garden (accept the
   EULA).

## 3 · Prove the spine with the canary

```bash
cd loop-runner
LOOP=hello-world REPO_FULL_NAME=<owner>/loop-runner ./deploy.sh
gcloud run jobs execute loop-hello-world --region=<region> --project=<project> --wait
```

A healthy run logs `proxy live, CA trusted`, then `work_done=… pushed=true`, and lands a commit on
`origin/main`. If the canary passes, the whole spine works: clone → model → task → verify → commit
→ push. Full walkthrough: `loop-runner/get-started.md`.

## 4 · Add a loop

Never hand-create the folder and never modify `loop-runner/` for a new loop — the runner is
task-agnostic; a new loop is only ever a new `loops/<name>/` folder:

```bash
./new-loop.sh <kebab-case-name>    # scaffolds loops/<name>/ from loops/_template
```

Then fill in four artifacts (in a loop-runner checkout, prefer the `/loop-new` interview skill,
which walks the decisions and validates the result):

| File | Purpose |
|------|---------|
| `loop.yaml` | model, `max_turns`, `budget_usd`, trigger/schedule, connectors, memory, push mode, tier |
| `prompt.md` | the brief: orient → act → prove → record → STOP (state the stop condition explicitly) |
| `verify.sh` | exit 0 = pass; runs in the harness — make it a real check, not vibes |
| `agents/*.md` | optional subagents (e.g. an independent verifier) |

Key `loop.yaml` decisions:

- **`push:`** — `main` (ship; only if the loop touches nothing but its own state), `pr` (propose;
  can never land on main), `none` (read-only).
- **`connectors:`** — least privilege. Only listed APIs get credentials injected by the proxy;
  `[]` means the loop runs with no authenticated egress. GitHub and Google APIs are built in;
  new APIs need one `_API` line in `loop-runner/proxy_addon.py` plus a Secret Manager entry.
- **`memory:`** — a git-backed state dir (default `loops/<name>/state`); the harness commits and
  pushes it after every run, which is what defeats Groundhog Day.
- **`repo:`** — Two-Repo Mode: set it to a work repo and the agent operates + opens PRs there
  while the library stays read-only.
- **`tier:`** — be honest: 1 exists · 2 runs · 3 ground-truth · 4 self-judge · 5 human. A verifier
  that reads back ground truth (tests green, PR exists) beats a model grading its own work.

## 5 · Dry-run locally, then deploy

Dry-run in Docker (never pushes):

```bash
docker build -t loop-runner loop-runner/
docker run --rm -e LOOP=<name> -e REPO_FULL_NAME=<owner>/loop-runner \
  -e GITHUB_PAT="$(gcloud secrets versions access latest --secret=github-pat)" \
  -e GCP_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  -e GCP_PROJECT=<project> -e PUSH_OVERRIDE=none loop-runner
```

Deploy + trigger (the image is loop-agnostic — after the first build, deploy specs with `BUILD=0`):

```bash
cd loop-runner && LOOP=<name> ./deploy.sh        # creates the Cloud Run Job (+ cron if scheduled)
gcloud run jobs execute loop-<name> --region=<region> --project=<project> --wait
```

The first live execution is the operator's call — it may cost money or send something; ask before
running it.

## 6 · Debug a run

- Cloud Run Job logs show the harness stages: clone → `proxy live, CA trusted` → agent → verify →
  `work_done=… pushed=…`.
- Transcripts and a per-run cost record are archived to Cloud Storage; inspect sessions with
  `loop-runner/view_session.py` (see `docs/sessions.md`).
- Connector/auth issues: the agent must call APIs **without** auth headers (the proxy injects
  them); see `docs/proxy.md`. Browser-driving loops: see `docs/browser.md`.

## Hard rules

- Never touch `loop-runner/` to make a loop work; that's a harness change, not a loop.
- Tier honesty over tier vanity — a declared tier 5 with a human beats a fake tier 3.
- Least-privilege connectors; secrets live in Secret Manager, never in specs, prompts, or chat.
