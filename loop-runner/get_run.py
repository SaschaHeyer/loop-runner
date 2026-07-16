#!/usr/bin/env python3
"""Reconnect to / replay a loop run. Understand and debug what an agent did.

Claude Code has NO external "attach to a live session" API; the live channel is the run's stdout
(stream-json → Cloud Logging, once STREAM=1 ships), and the durable trace is the archived
session.jsonl. So this tool:
  - polls the Cloud Run execution status;
  - while RUNNING: tails the harness log lines (and `logType=loop_step` lines when present) live;
  - when DONE: replays the full step trace from gs://<bucket>/<loop>/<exec>/session.jsonl and prints
    the run summary (status, cost, turns) from result.json.

Usage:
  python3 loop-runner/get_run.py <loop>/<exec-id> [--project your-gcp-project] [--full] [--watch]
  python3 loop-runner/get_run.py ceo-greenfield/loop-ceo-greenfield-tx6dp --full
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

import trace as tracelib  # noqa: A004  (local shared parser)

REGION = os.environ.get("DASH_REGION", "us-central1")


def sh(args, timeout=60):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def exec_status(execution: str, project: str):
    rc, out, _ = sh(["gcloud", "run", "jobs", "executions", "describe", execution,
                     "--region", REGION, "--project", project, "--format",
                     "value(status.succeededCount,status.failedCount,status.runningCount)"])
    if rc != 0 or not out.strip():
        return None
    parts = (out.split() + ["0", "0", "0"])[:3]
    suc, fail, run = (int(x or 0) for x in parts)
    return "success" if suc else ("failed" if fail else ("running" if run else "unknown"))


def tail_logs(execution: str, project: str, minutes: int = 60):
    rc, out, _ = sh(["gcloud", "logging", "read",
                     f'resource.type="cloud_run_job" AND labels."run.googleapis.com/execution_name"="{execution}"',
                     "--project", project, "--freshness", f"{minutes}m", "--order", "asc",
                     "--format", "value(textPayload,jsonPayload.logType,jsonPayload.step_type,jsonPayload.brief)"], timeout=90)
    return out if rc == 0 else ""


def main() -> int:
    argv = sys.argv[1:]
    flags = {a for a in argv if a.startswith("--")}
    project = os.environ.get("DASH_PROJECT", "your-gcp-project")
    skip = -1
    if "--project" in argv:
        i = argv.index("--project")
        skip = i + 1
        if i + 1 < len(argv):
            project = argv[i + 1]
    positional = [a for j, a in enumerate(argv) if not a.startswith("--") and j != skip]
    if not positional:
        print(__doc__)
        return 1
    ref = positional[0]
    full = "--full" in flags
    loop, _, execution = ref.partition("/")
    if not execution:
        execution, loop = loop, os.environ.get("LOOP", "")
    bucket = f"{project}-loop-sessions"

    # 1. status (poll if --watch and still running)
    st = exec_status(execution, project)
    if st is None:
        print(f"could not find execution {execution} in {project}", file=sys.stderr)
        return 2
    print(f"status: {st}  (loop={loop or '?'}, project={project}, exec={execution})")
    if st == "running" and "--watch" in flags:
        while st == "running":
            time.sleep(10)
            st = exec_status(execution, project)
            print(f"  … {st}")

    # 2. running -> live tail; done -> full replay from the archive
    if st == "running":
        print("\n--- live log tail (running) ---")
        print(tail_logs(execution, project) or "(no log lines yet)")
        print("\n(run is still in progress — re-run with --watch, or again after it finishes for the full trace)")
        return 0

    base = f"gs://{bucket}/{loop}/{execution}"

    # summary from result.json
    rc, rj, _ = sh(["gcloud", "storage", "cat", f"{base}/result.json"])
    if rc == 0 and rj:
        try:
            d = json.loads(rj)
            print(f"summary: turns={d.get('num_turns')} cost=${d.get('total_cost_usd')} "
                  f"error={d.get('is_error')} session={d.get('session_id','')[:12]}")
        except Exception:
            pass

    # VERDICT & VERIFIER — from run.log (the harness + verify.sh output): the [verify:…] checks, the
    # tier-4 judge's verdict line, and work_done/pushed/verdict.
    rc, runlog, _ = sh(["gcloud", "storage", "cat", f"{base}/run.log"])
    if rc == 0 and runlog:
        lines = [ln for ln in runlog.splitlines()
                 if ("[verify:" in ln) or ("verifier verdict" in ln) or ("work_done=" in ln)
                 or ("BUDGET EXCEEDED" in ln)]
        if lines:
            print("\n--- verdict & verifier ---")
            for ln in lines:
                print("  " + ln.split("] ", 1)[-1] if "] " in ln else "  " + ln)

    # AGENT TRANSCRIPTS — one per session: maker + tier-4 judge + any delegated subagent.
    rc, lsout, _ = sh(["gcloud", "storage", "ls", f"{base}/sessions/"])
    sess_uris = [u.strip() for u in lsout.splitlines() if u.strip().endswith(".jsonl")] if rc == 0 else []
    if not sess_uris:
        # fallback: the primary session.jsonl only
        rc, _s, _ = sh(["gcloud", "storage", "cat", f"{base}/session.jsonl"])
        if rc == 0:
            sess_uris = [f"{base}/session.jsonl"]
    if not sess_uris:
        print(f"\nno agent transcripts archived for this run ({base}/).", file=sys.stderr)
        return 0

    maker_id = tracelib.maker_session_id(execution)
    parsed = []
    for uri in sess_uris:
        rc, txt, _ = sh(["gcloud", "storage", "cat", uri])
        if rc != 0 or not txt:
            continue
        sid = uri.rsplit("/", 1)[-1][:-6] if uri.endswith(".jsonl") else ""
        parsed.append((tracelib.role_of(txt, session_id=sid, maker_id=maker_id), tracelib.parse(txt), uri))
    # maker first, then judge, then subagents
    order = {"maker": 0, "verifier-judge": 1, "subagent": 2}
    parsed.sort(key=lambda p: order.get(p[0], 3))
    print(f"\n--- agent transcripts: {len(parsed)} session(s) ---")
    for role, steps, uri in parsed:
        print(f"  · {role:<14} {len(steps):>3} steps   {uri.rsplit('/',1)[-1]}")
    for role, steps, uri in parsed:
        # replay the maker fully by default; others only with --full (keeps output focused)
        if role == "maker" or full:
            print(f"\n=== {role} ({len(steps)} steps){' · full' if full else ' · briefs (--full for all sessions)'} ===")
            print(tracelib.render_text(steps, full=full))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
