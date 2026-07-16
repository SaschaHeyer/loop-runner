#!/usr/bin/env python3
"""Shared step-trace parser for loop-runner agent transcripts (M14).

Single source of truth for "what a step is". Parses Claude Code's session JSONL (the transcript the
harness archives to gs://<bucket>/<loop>/<exec>/session.jsonl) into a flat list of typed steps that
BOTH the CLI (view_session.py / get_run.py) and the dashboard render. Claude Code's transcript format
is "internal and changes between versions" (per the docs), so this is the ONE place to adapt on an
upgrade.

Step dict: {"kind": thinking|text|tool_use|tool_result, "role": user|assistant, "name": <tool>,
            "text": <str>, "brief": <short one-liner>}
"""
from __future__ import annotations

import json


def _blocks(d: dict) -> list:
    msg = d.get("message")
    if isinstance(msg, dict):
        c = msg.get("content")
        if isinstance(c, list):
            return c
        if isinstance(c, str):
            return [{"type": "text", "text": c}]
    return []


def parse(text: str) -> list[dict]:
    """Parse session JSONL text into a flat list of step dicts (in order)."""
    steps: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        role = d.get("type")
        for b in _blocks(d):
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "thinking":
                t = (b.get("thinking") or "").strip()
                steps.append(dict(kind="thinking", role=role, name="", text=t, brief=_oneline(t)))
            elif bt == "text":
                t = (b.get("text") or "").strip()
                if t:
                    steps.append(dict(kind="text", role=role, name="", text=t, brief=_oneline(t)))
            elif bt == "tool_use":
                inp = b.get("input", {}) or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") or inp.get("url") or ""
                if not arg:
                    try:
                        arg = json.dumps(inp)[:200]
                    except Exception:
                        arg = ""
                steps.append(dict(kind="tool_use", role=role, name=b.get("name", "") or "", text=str(arg), brief=_oneline(str(arg))))
            elif bt == "tool_result":
                c = b.get("content")
                if isinstance(c, list):
                    t = "".join(x.get("text", "") for x in c if isinstance(x, dict))
                else:
                    t = str(c or "")
                steps.append(dict(kind="tool_result", role=role, name="", text=t.strip(), brief=_oneline(t)))
    return steps


def _oneline(s: str, n: int = 120) -> str:
    s = " ".join((s or "").split())
    return s[:n] + ("…" if len(s) > n else "")


def maker_session_id(exec_name: str) -> str:
    """The deterministic session id the entrypoint assigns the MAKER agent (uuid5 of the execution).
    Lets a reader identify the maker transcript by filename among the several .jsonl a run produces."""
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "loop-" + (exec_name or "local")))


def role_of(text: str, *, session_id: str = "", maker_id: str = "") -> str:
    """Classify an archived transcript as maker / verifier-judge / subagent.
    Primary signal (deterministic): the maker's filename IS maker_session_id(exec) — a uuid5 — while the
    tier-4 judge (`claude --agent`) and delegated subagents get random uuid4s. Content heuristics are the
    fallback for old single-session runs where we don't have the ids. NB the verifier.md SYSTEM prompt is
    NOT in the transcript, so we match the judge's actual -p prompt ('Judge whether this fix…' / GOAL+DIFF)."""
    if session_id and maker_id and session_id == maker_id:
        return "maker"
    low = text[:20000].lower()
    if '"issidechain":true' in low or '"issidechain": true' in low:
        return "subagent"
    if ("adversarial" in low or "return only the structured verdict" in low
            or "judge whether this fix" in low
            or ("goal (issue #" in low and "diff (" in low)):
        return "verifier-judge"
    return "maker"


ICON = {"thinking": "🧠", "text": "🤖", "tool_use": "🔧", "tool_result": "↳"}


def render_text(steps: list[dict], full: bool = False) -> str:
    """Human-readable replay for the terminal (mirrors view_session.py's style)."""
    out = []
    for s in steps:
        icon = ICON.get(s["kind"], "•")
        if s["kind"] == "tool_use":
            out.append(f"\n🔧 {s['name']}: {s['text'][:1000] if full else s['brief']}")
        elif s["kind"] == "tool_result":
            body = s["text"][:1200] if full else s["brief"]
            out.append("   ↳ " + body.replace("\n", "\n     "))
        elif s["kind"] == "thinking":
            body = s["text"] if full else s["brief"]
            out.append("\n🧠 THINKING\n   " + body.replace("\n", "\n   "))
        else:  # text
            who = "👤 USER" if s["role"] == "user" else "🤖 ASSISTANT"
            body = s["text"] if full else s["brief"]
            out.append(f"\n{who}\n   " + body.replace("\n", "\n   "))
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    src = sys.stdin.read() if len(sys.argv) < 2 or sys.argv[1] == "-" else open(sys.argv[1]).read()
    print(render_text(parse(src), full=True))
