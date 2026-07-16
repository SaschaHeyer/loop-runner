---
name: loop-runner
description: The full Loop Runner lifecycle, interactively — GCP infra setup, first canary run, authoring new loops (interview-driven), local dry-runs, deploys and triggers (cron / GitHub event / manual), cost tracking, and querying past runs. Use when the user wants to set up or get started with loop-runner, run agents headless/unattended/on a schedule in the cloud, create/add/scaffold a new loop, deploy or dry-run a loop, wire a trigger, check what a run cost, or inspect/debug/replay a loop run.
---

# Loop Runner — the whole lifecycle, one skill

Loop Runner runs any repeatable agent workflow (a "loop") headless in a Cloud Run Job:
**TRIGGER → EXECUTE → VERIFY → RECORD → STOP.** The harness owns what the agent can't be trusted
with: a Stop hook commits + pushes whatever the agent leaves behind, a PreToolUse guard blocks
footguns, `verify.sh` runs in the harness (not the agent), and a local egress proxy injects API
credentials on the wire — the agent never holds a key. The agent forgets; the repo doesn't.

## How to drive this skill

Work **phase by phase, interactively** — and never open with a command.

**Your first reply runs nothing.** Introduce, bound, then ask:

1. One breath of orientation: Loop Runner runs agentic loops headless in Cloud Run Jobs, and the
   harness guarantees commit → push → verify → record on every run — the agent can't forget its
   own work.
2. The boundary, stated up front: **the supported runtime today is Google Cloud** (Cloud Run Jobs
   + Cloud Scheduler) with Claude on Vertex AI — it isn't cloud-agnostic yet. A GCP project with
   billing is required, and a fresh project enables the Claude models in Vertex Model Garden once.
   If they don't have or want GCP, say so honestly and stop here.
3. The road in one line — foundation → canary → author a loop → deploy → operate — then ask where
   to go (AskUserQuestion): fresh setup · create a loop · deploy/trigger · costs & runs · debug.
   If their invocation already named a clear goal, confirm it in a sentence instead of re-asking.

Only after that answer, run the Phase 0 probe. Per phase: gather the decisions with
AskUserQuestion (one round, few questions), act, then show the user what changed and what's next.
**Confirm before anything that costs money or leaves the machine** (builds, live executions,
pushes, sending anything). Never accept a credential pasted into chat — secrets go into GCP Secret
Manager by the user's own hand.

## Phase 0 · Where are we? (read-only probe — only after the intro)

```bash
gcloud config get-value project 2>/dev/null && gcloud auth list --filter=status:ACTIVE --format='value(account)'
git remote -v | head -2                      # inside a loop-runner fork/clone?
ls loop-runner/.env 2>/dev/null              # configured?
gcloud run jobs list --region=<region> --format='value(name)' 2>/dev/null | grep ^loop-  # deployed loops
gcloud storage ls gs://<project>-loop-sessions/ 2>/dev/null | head -3                    # past runs
```

No repo → Phase 1. Repo but no `.env`/project → Phase 2. No `loop-hello-world` job or no
successful run yet → Phase 3. Otherwise ask what they want: new loop (4), deploy/trigger (5),
costs or run inspection (6), debugging (7).

## Phase 1 · Get the harness

The loop library is a repo the loops push work back into, so the user needs their own copy:
`gh repo fork SaschaHeyer/loop-runner --clone` (or use their existing fork). Full walkthrough
lives at `loop-runner/get-started.md` — prefer it when the user wants to read along.

## Phase 2 · GCP foundation (once per project)

Ask for: project id, region (default `us-central1`). Then set up, showing each command first:

1. `gcloud auth login && gcloud config set project <project>` (plus
   `gcloud auth application-default login` for local dry-runs).
2. Enable services: `run artifactregistry cloudbuild secretmanager cloudscheduler aiplatform storage`
   (`gcloud services enable <svc>.googleapis.com …`).
3. **Vertex Model Garden, once**: enable the Claude models (accept the EULA) — without this the
   agent's first model call fails.
4. Runner service account `loop-runner@<project>.iam.gserviceaccount.com`; typical roles:
   `roles/aiplatform.user`, `roles/secretmanager.secretAccessor`, storage objectAdmin on the
   sessions bucket (deploy.sh creates `gs://<project>-loop-sessions` idempotently).
5. GitHub PAT (repo scope, user creates it themselves) → Secret Manager secret `github-pat`.
   Other connectors each map to one secret via `loop-runner/connectors/registry.json`.
6. `cp loop-runner/.env.example loop-runner/.env` and fill: `GCP_PROJECT`, `DEPLOY_SA`,
   `REPO_FULL_NAME=<their-fork>`, `SESSIONS_BUCKET`. Model auth is the Job's service account
   (Vertex ADC) — there is **no Anthropic API key anywhere**.

## Phase 3 · Prove the spine (canary)

```bash
cd loop-runner
LOOP=hello-world REPO_FULL_NAME=<owner>/loop-runner ./deploy.sh      # first time: builds the image
gcloud run jobs execute loop-hello-world --region=<region> --project=<project> --wait
```

Healthy run: logs show `proxy live, CA trusted` then `work_done=… pushed=true`, and a commit lands
on `origin/main`. Optional pre-flight without loop actions: `LOOP=hello-world SMOKE=1 ./deploy.sh`.
Live executions cost real money — always confirm before executing.

## Phase 4 · Author a new loop (the interview)

Never modify `loop-runner/` for a new loop — a loop is only ever a `loops/<name>/` folder. Gold
examples to imitate: `loops/hello-world/` (minimal) and `loops/issue-fix/` (event-driven PR loop).
Ask the six questions (AskUserQuestion; accept a prose brief and confirm what you inferred):

1. **Name** — kebab-case, named for the function → folder + `name:`.
2. **What does it do, and what is "done", in one sentence?** → `description:`.
3. **Data sources** — which APIs, public or credentialed? → `connectors:` (least privilege; `[]`
   = no authenticated egress; github + Google APIs are built in; a new API = one entry in
   `connectors/registry.json` + one Secret Manager secret).
4. **The deliverable, and how is it checked MECHANICALLY?** → `verify.sh` + honest `tier:`. Push
   for ground-truth readback (PR exists via `gh`, tests green, record read back) — never a model
   grading its own work. In Two-Repo Mode the work repo is the loop's memory; prefer platform-side
   ledgers (e.g. issue-fix's one-branch-per-issue) over library state files.
5. **Stop conditions** — what does a correct EMPTY run look like (silence is a feature)? Plus
   `max_turns` (find+fix+prove+PR ≈ 60) and `budget_usd`.
6. **Trigger, cadence, model, memory, push** — `trigger: schedule` (+cron) or manual/event;
   `claude-sonnet-4-6` for mechanical work, opus for judgement; `push: main` only if it touches
   nothing but its own state, `pr` when a human reviews, `none` read-only; `repo:` for Two-Repo
   Mode. Browser-driving loops opt in by naming `mcp__chrome-devtools__*` tools (docs/browser.md).

Then execute: `./new-loop.sh <name>` (never hand-create), fill the four artifacts (`loop.yaml`
with `# DECISION:` comments, `prompt.md` as orient → act → prove → record → STOP, `verify.sh`,
optional `agents/*.md`), delete unused scaffold files, and validate — all must pass:

```bash
diff <(python3 loop-runner/parse_spec.py loops/<name>/loop.yaml) \
     <(SPEC_PARSER_FORCE_MINI=1 python3 loop-runner/parse_spec.py loops/<name>/loop.yaml)
bash -n loops/<name>/verify.sh
# scenario-test verify.sh in a scratch git repo: happy path, clean-empty-run,
# out-of-scope change, claimed-deliverable-missing — assert the exit codes
```

Register the loop in the root `README.md` layout block, commit, push.

## Phase 5 · Test, deploy, trigger

- **Dry-run locally** (nothing reaches origin): `docker build -t loop-runner loop-runner/` then
  `docker run --rm -e LOOP=<name> -e REPO_FULL_NAME=… -e GITHUB_PAT="$(gcloud secrets versions
  access latest --secret=github-pat)" -e GCP_ACCESS_TOKEN="$(gcloud auth print-access-token)"
  -e GCP_PROJECT=<project> -e PUSH_OVERRIDE=none loop-runner`.
- **Deploy**: `cd loop-runner && LOOP=<name> BUILD=0 ./deploy.sh` (the image is loop-agnostic;
  spec edits need no rebuild). A `trigger: schedule` loop gets its Cloud Scheduler cron from
  `schedule:` automatically; `CREATE_CRON=0` skips it.
- **Triggers**: cron (above) · manual `gcloud run jobs execute loop-<name> --region=<region>
  --wait` · GitHub event via an Action + Workload Identity Federation — copy
  `loops/issue-fix/github-trigger.example.yml` into the work repo and fill the WIF ids.
- The first live execution is the operator's call — it may cost money or send something. Ask.

## Phase 6 · Costs and querying runs

- **Evidence per run** (auto-archived): `gs://<project>-loop-sessions/<loop>/<execution-id>/` —
  `result.json` (the CLI's own cost/duration/token JSON, verbatim), `run.log` (harness narration +
  the verify verdict), `sessions/*.jsonl` (every agent transcript, sub-agents included).
- **Cost**: `log_cost.py` appends one row per run (from `result.json`) to the shared cost log
  (`COST_LOG`, default `cost_log.yaml`); a `budget_usd` breach is flagged loudly there. Quick
  per-run answer: `gcloud storage cat gs://…/<loop>/<exec>/result.json | python3 -c "import json,sys;
  d=json.load(sys.stdin); print(d.get('total_cost_usd'), d.get('duration_ms'))"`.
- **Replay / inspect**: `python3 loop-runner/get_run.py <loop>/<exec-id>` reconnects to a run;
  `python3 loop-runner/view_session.py <loop>/<exec-id>` renders its transcript readable.
- **List runs**: `gcloud storage ls gs://<project>-loop-sessions/<loop>/`. **Live** runs stream to
  Cloud Logging: filter `resource.type="cloud_run_job" resource.labels.job_name="loop-<name>"`.
- When a verdict looks suspicious, read the transcript, not the summary (docs/sessions.md).

## Phase 7 · Debug quick hits

- Model call fails on a fresh project → Model Garden EULA not accepted (Phase 2.3).
- Connector 401s → the agent must call proxied APIs **without** an Authorization header
  (docs/proxy.md); check the connector is declared in `loop.yaml` and registered.
- Verifier failed on a PR loop → the harness labels the PR `ai:verify-failed` and can retry;
  read `run.log` first, then the transcript.
- Browser loop "used curl instead" → the `mcp__chrome-devtools__*` tools weren't named exactly
  (a bare `chrome-devtools` grants nothing) — docs/browser.md.

## Hard rules

- Never touch `loop-runner/` to make a loop work — that's a harness change, discuss it.
- Tier honesty over tier vanity; least-privilege connectors; secrets only in Secret Manager.
- Confirm anything that spends money or sends anything. Empty runs are a feature, not a bug.
