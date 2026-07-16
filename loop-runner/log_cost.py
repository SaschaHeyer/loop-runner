#!/usr/bin/env python3
"""Append one per-loop cost record to COST_LOG in the SAME YAML schema as the reference runner.

This makes Cloud Run Job loops show up in the existing runner/cost_dashboard.html next to
managed-runtime loops (it reads the same YAML sequence). Claude Code's --output-format json
gives a real total_cost_usd, so est_cost here is exact, not estimated.

Usage:
  log_cost.py <result.json> <cost_log_path> <after_sha> <pushed> <work_done> <cli> <model> [loop]
"""
from __future__ import annotations

import datetime
import json
import os
import sys


def main() -> int:
    result, logpath, after, pushed, work, cli, model = sys.argv[1:8]
    loop = sys.argv[8] if len(sys.argv) > 8 else ""
    try:
        d = json.load(open(result))
    except Exception:
        d = {}

    u = d.get("usage", {}) or {}
    inp = int(u.get("input_tokens", 0) or 0) + int(u.get("cache_creation_input_tokens", 0) or 0)
    out = int(u.get("output_tokens", 0) or 0)
    cached = int(u.get("cache_read_input_tokens", 0) or 0)

    rec = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "interaction_id": d.get("session_id", "") or "",
        "status": "error" if d.get("is_error") else "completed",
        "runner": "cloud-run-job",
        "loop": loop,
        "cli": cli,
        "model": model,
        "total_tokens": inp + out,
        "input_tokens": inp,
        "output_tokens": out,
        "thought_tokens": 0,
        "tool_tokens": 0,
        "cached_tokens": cached,
        "pushed": pushed == "true",
        "steps": int(d.get("num_turns", 0) or 0),
        "after_sha": (after or "")[:12],
        "work_done": work == "true",
    }
    cost = d.get("total_cost_usd")
    if cost is not None:
        rec["est_cost"] = round(float(cost), 4)

    # M4 — enforce budget_usd (option a: post-hoc, visible). Compare the real cost to the loop's
    # declared budget and flag a breach loudly in the log + the structured record, so a log-based
    # alert can fire and the dashboard/BQ can surface it. (Advisory: does not change loop behaviour;
    # max_turns remains the hard in-loop stop. An in-loop PostToolUse budget-stop is option b, later.)
    budget = os.environ.get("LOOP_BUDGET_USD", "").strip()
    try:
        budget_f = float(budget) if budget else None
    except ValueError:
        budget_f = None
    if budget_f is not None:
        rec["budget_usd"] = budget_f
        over = cost is not None and float(cost) > budget_f
        rec["budget_exceeded"] = bool(over)
        if over:
            print(f"[harness] ⚠️  BUDGET EXCEEDED — est_cost=${float(cost):.4f} > budget_usd=${budget_f:.4f} "
                  f"(loop={loop or '?'})")

    os.makedirs(os.path.dirname(logpath) or ".", exist_ok=True)
    new = not os.path.exists(logpath)
    with open(logpath, "a") as f:
        if new:
            f.write("# per-loop cost log — a YAML sequence. Load with yaml.safe_load(open(this_file)).\n")
        f.write("- " + "\n  ".join(f"{k}: {json.dumps(v)}" for k, v in rec.items()) + "\n")
    print(f"[harness] logged cost to {logpath} (steps={rec['steps']} est_cost={rec.get('est_cost')})")

    # M10 — durable telemetry: emit the record as ONE structured JSON line. In a Cloud Run Job that
    # line lands in Cloud Logging as a parsed jsonPayload (the YAML file above is ephemeral/gitignored),
    # so cost is queryable by loop/day/model in Logs Explorer and a one-time log sink routes it to
    # BigQuery for SQL. The `logType` marker is the stable filter: jsonPayload.logType="loop_cost".
    print(json.dumps({"logType": "loop_cost", **rec}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
