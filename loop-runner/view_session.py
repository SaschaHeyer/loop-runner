#!/usr/bin/env python3
"""Pretty-print a loop's agent session transcript: reasoning, tool calls, and results.

The Cloud Run Job archives each run's full transcript to GCS as session.jsonl, namespaced by loop
(gs://<bucket>/<loop>/<execution-id>/session.jsonl). That file has the WHOLE story (every thinking
block, tool call, tool result, and message) — Claude Code's `--output-format json` .result only keeps
the final message, which is why a run can look "short".

Usage:
  python3 loop-runner/view_session.py <loop>/<execution-id>     # e.g. ceo/abc123
  LOOP=ceo python3 loop-runner/view_session.py <execution-id>   # loop via env (default ceo)
  python3 loop-runner/view_session.py path/to/session.jsonl     # a local file
  gcloud storage cat gs://.../session.jsonl | python3 loop-runner/view_session.py -

Env: SESSIONS_BUCKET (default: your-gcp-project-loop-sessions), LOOP (default: ceo)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

BUCKET = os.environ.get("SESSIONS_BUCKET", "your-gcp-project-loop-sessions")
LOOP = os.environ.get("LOOP", "ceo")


def load(arg: str) -> str:
    if arg == "-":
        return sys.stdin.read()
    if os.path.exists(arg):
        return open(arg).read()
    # otherwise treat it as "<loop>/<execution-id>" (or a bare id + LOOP env) and pull from GCS
    key = arg if "/" in arg else f"{LOOP}/{arg}"
    uri = f"gs://{BUCKET}/{key}/session.jsonl"
    out = subprocess.run(["gcloud", "storage", "cat", uri], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"could not read {uri}:\n{out.stderr.strip()}")
    return out.stdout


def content_blocks(d: dict) -> list:
    msg = d.get("message")
    if isinstance(msg, dict):
        c = msg.get("content")
        if isinstance(c, list):
            return c
        if isinstance(c, str):
            return [{"type": "text", "text": c}]
    return []


def indent(s: str, pad: str = "     ") -> str:
    return s.strip().replace("\n", "\n" + pad)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    for line in load(sys.argv[1]).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        for b in content_blocks(d):
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "thinking":
                print("\n🧠 THINKING\n   " + indent(b.get("thinking") or ""))
            elif bt == "text":
                who = "👤 USER" if d.get("type") == "user" else "🤖 ASSISTANT"
                print(f"\n{who}\n   " + indent(b.get("text") or ""))
            elif bt == "tool_use":
                inp = b.get("input", {}) or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") or json.dumps(inp)
                print(f"\n🔧 {b.get('name')}: {str(arg)[:1000]}")
            elif bt == "tool_result":
                c = b.get("content")
                txt = "".join(x.get("text", "") for x in c if isinstance(x, dict)) if isinstance(c, list) else str(c)
                print("   ↳ " + indent(txt[:1200]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
