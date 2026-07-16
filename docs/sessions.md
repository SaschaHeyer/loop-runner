# Session archive — where every run's evidence actually lives

A loop's git repo is its memory for *work* (commits, PRs, issues) — but a run also produces
*evidence*: what the agent actually saw, said, and did, turn by turn. That evidence is what lets you
answer "did this really happen the way the summary claims?" instead of trusting the loop's own
self-report. `entrypoint.sh` archives it automatically, at the end of every run, to Cloud Storage.

This matters more than it sounds: a loop's own PR comment or Cloud Logging output is the loop
*describing* what it did. The session archive is the closest thing to ground truth — the actual
transcript, unedited. When a verdict looks suspicious, read the transcript, not the summary.

## Where — one bucket, shared by every loop in the project

Controlled by the `SESSIONS_BUCKET` env var, which `deploy.sh` defaults to `<project>-loop-sessions`
and creates automatically (`gcloud storage buckets create`, idempotent) if it doesn't exist yet.

**This bucket is shared across every loop in the project — not scoped per loop.** If you've deployed
several loops into the same GCP project, they all archive into the same bucket, namespaced by loop
name underneath it. Nothing about the archiving step is loop-specific config; it's pure harness
behavior driven entirely by the `LOOP` and `CLOUD_RUN_EXECUTION` env vars already present on the Job.

There is **no lifecycle/retention policy** set on this bucket by the harness — nothing is ever
deleted automatically. Every run's transcripts accumulate indefinitely unless you add your own
cleanup policy.

## Structure — one folder per loop, one per execution

```
gs://<project>-loop-sessions/
├── my-loop/                          ← one folder per LOOP NAME
│   ├── loop-my-loop-ab12c/           ← one folder per EXECUTION ID
│   └── loop-my-loop-xy34z/
└── another-loop/
    └── loop-another-loop-qw56e/
```

The execution ID is Cloud Run's own execution name (`CLOUD_RUN_EXECUTION`, e.g.
`loop-my-loop-ab12c`) when running as a Cloud Run Job — or a UTC timestamp when running locally
(`docker run`), since there's no Cloud Run execution to name it after.

## What's inside one execution's folder

```
my-loop/loop-my-loop-ab12c/
├── result.json      Claude Code's own final JSON result for the maker's invocation
├── run.log           everything the harness printed — its own [harness] lines, tee'd
│                      together with the loop's verify.sh output ([verify:…], the verdict)
├── session.jsonl      a convenience copy of the maker's own session transcript
└── sessions/          EVERY agent transcript this run produced, no exceptions
    ├── <uuid>.jsonl            ← could be the maker, an orchestrator, whichever ran first
    ├── agent-<id>.jsonl        ← a Task-spawned sub-agent
    └── agent-<id>.jsonl        ← another one, if the loop spawned more than one
```

- **`result.json`** — the raw JSON `claude -p` itself returns on exit: final result text, cost,
  duration, token usage. This is also what `log_cost.py` reads to append a row to the shared cost
  log — it isn't a harness-authored summary, it's the CLI's own structured output, verbatim.
- **`run.log`** — the harness's own narration (`[harness] ...` lines) interleaved with whatever the
  loop's `verify.sh` printed (`[verify:...] PASS/FAIL ...`). This is the fastest way to see *what the
  harness itself concluded* about a run — pushed, work_done, the verdict — without reading a single
  transcript.
- **`session.jsonl`** — a **copy** of one specific transcript, promoted to the top level for
  convenience: the maker's own session (identified by a deterministic session ID derived from the
  execution ID, falling back to the largest transcript found if that ID can't be matched). It also
  exists inside `sessions/` — this is not a different file, just an easier-to-find duplicate of it.
- **`sessions/`** — **every** `.jsonl` transcript Claude Code left behind this run, archived
  uniformly with no per-loop or per-subagent wiring needed. A simple orchestrator/maker loop produces
  one file here. A loop that uses the `Task` tool to spawn sub-agents (an orchestrator plus one or
  more independent judges, say) produces one file per agent that ran — the orchestrator's own
  session, plus one transcript per sub-agent it spawned. **This is where you find ground truth**: if
  a loop's summary claims a sub-agent did something specific, its actual transcript here is
  what to check — search it for the tool names you'd expect (did it really call the tool it claims
  to have used?), not just its final text response.

## How to read them

- **`loop-runner/get_run.py <loop>/<exec-id>`** — reconnect to / replay a specific run without
  hand-rolling `gcloud storage`/`jq` commands.
- **`loop-runner/view_session.py <loop>/<exec-id>`** — render a session transcript for reading.
- Raw access always works too: `gcloud storage ls gs://<bucket>/<loop>/<exec-id>/` and
  `gcloud storage cat` / `cp` any file directly. For a still-*running* execution, the harness's own
  progress streams to Cloud Logging in real time (filter on `resource.type="cloud_run_job"` and
  `resource.labels.job_name="loop-<name>"`) — the GCS archive only appears once the run finishes.
