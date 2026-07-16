#!/usr/bin/env python3
"""M14 stream-json projector (used only when STREAM=1).

Reads Claude Code `--output-format stream-json` NDJSON from stdin and:
  1. emits ONE compact `loop_step` JSON line per meaningful event to STDOUT — in a Cloud Run Job that
     lands in Cloud Logging LIVE, so `get_run.py --watch` / the dashboard can follow a run in progress
     (Claude Code has no external "attach to a live session" API; stdout streaming is the live channel);
  2. writes the final `result` event to argv[1] (RESULT) — it carries the SAME fields as
     `--output-format json` (total_cost_usd, usage, num_turns, session_id, is_error, result), so
     `log_cost.py` and the harness response-excerpt keep working unchanged.

Defensive by design: never crash the run on an unexpected event shape (the stream format is
version-unstable), so STREAM=1 can never fail a loop that would otherwise succeed.
"""
from __future__ import annotations

import json
import os
import sys

RESULT = sys.argv[1] if len(sys.argv) > 1 else "/dev/null"
LOOP = os.environ.get("LOOP", "")
EXEC = os.environ.get("EXEC_ID", "")
_seq = 0


def emit(step_type: str, name: str = "", brief: str = "") -> None:
    global _seq
    _seq += 1
    brief = " ".join((brief or "").split())[:200]
    print(json.dumps({"logType": "loop_step", "loop": LOOP, "exec_id": EXEC, "seq": _seq,
                      "step_type": step_type, "name": name, "brief": brief}, separators=(",", ":")), flush=True)


def _blocks(msg) -> list:
    c = (msg or {}).get("content")
    if isinstance(c, list):
        return c
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return []


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        t = ev.get("type")
        try:
            if t == "result":
                with open(RESULT, "w") as f:
                    f.write(line)
                emit("result", "", f"turns={ev.get('num_turns')} cost={ev.get('total_cost_usd')} error={ev.get('is_error')}")
            elif t == "system":
                emit("system", ev.get("subtype", ""), "")
            else:  # assistant / user / stream_event — dig for content blocks
                msg = ev.get("message") or (ev.get("event") or {}).get("message") or {}
                for b in _blocks(msg):
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "tool_use":
                        inp = b.get("input", {}) or {}
                        arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") or inp.get("url") or ""
                        emit("tool_use", b.get("name", "") or "", str(arg))
                    elif bt == "tool_result":
                        emit("tool_result", "", "")
                    elif bt == "text":
                        emit("text", "", b.get("text", "") or "")
                    elif bt == "thinking":
                        emit("thinking", "", "")
        except Exception:
            pass  # never let a projection error kill the run
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
