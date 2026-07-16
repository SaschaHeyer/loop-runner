#!/usr/bin/env python3
"""Parse a loops/<name>/loop.yaml spec into shell variable assignments for `eval`.

Both entrypoint.sh (in the image) and deploy.sh (on your machine) read the spec through this,
so there is exactly ONE parser and the two can never drift.

    eval "$(python3 parse_spec.py loops/ceo/loop.yaml)"
    echo "$LOOP_MODEL $LOOP_SCHEDULE"

Exports (empty string when the field is absent, so shell `${LOOP_X:-default}` still falls back):
  scalars -> LOOP_NAME MODEL MAX_TURNS BUDGET_USD SYSTEM_PROMPT PROMPT VERIFY ALLOWED_TOOLS
             SCHEDULE TIMEZONE TRIGGER MEMORY TIER RUNTIME REPO GIT_USER_NAME GIT_USER_EMAIL
  lists   -> LOOP_SKILLS LOOP_CONNECTORS LOOP_SHARED   (space-separated)

Prefers PyYAML (always present in the image); falls back to a minimal parser for the flat
subset this schema uses, so deploy.sh works on a machine without PyYAML installed.
"""
from __future__ import annotations

import os
import shlex
import sys

SCALARS = {
    "name": "LOOP_NAME", "model": "LOOP_MODEL", "max_turns": "LOOP_MAX_TURNS",
    "budget_usd": "LOOP_BUDGET_USD", "system_prompt": "LOOP_SYSTEM_PROMPT", "prompt": "LOOP_PROMPT",
    "verify": "LOOP_VERIFY", "allowed_tools": "LOOP_ALLOWED_TOOLS", "schedule": "LOOP_SCHEDULE",
    "timezone": "LOOP_TIMEZONE",   # IANA zone for the Scheduler cron (default Etc/UTC in deploy.sh)
    "trigger": "LOOP_TRIGGER", "push": "LOOP_PUSH", "memory": "LOOP_MEMORY", "tier": "LOOP_TIER", "runtime": "LOOP_RUNTIME",
    "repo": "LOOP_REPO",   # optional WORK repo (M8); absent -> the agent works in the library repo
    "git_user_name": "LOOP_GIT_USER_NAME", "git_user_email": "LOOP_GIT_USER_EMAIL",
}
LISTS = {"skills": "LOOP_SKILLS", "connectors": "LOOP_CONNECTORS", "shared": "LOOP_SHARED"}


def _deq(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def _strip_inline_comment(s: str) -> str:
    """Drop a trailing ` # comment`, but not a # inside quotes or [ ] brackets."""
    q = None
    depth = 0
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c == "[":
            depth += 1
        elif c == "]":
            depth = max(0, depth - 1)
        elif c == "#" and depth == 0 and (i == 0 or s[i - 1] in " \t"):
            return s[:i]
    return s


def _mini_load(text: str) -> dict:
    """Minimal YAML-subset loader: flat top-level keys, quoted/plain scalars, folded/literal
    blocks (> and |, skipped since we never export them), block lists (- item) and inline
    lists ([a, b]). Sufficient for loop.yaml; used only when PyYAML is unavailable."""
    data: dict = {}
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        raw = lines[i]
        i += 1
        if not raw.strip() or raw.lstrip().startswith("#") or raw[0] in " \t" or ":" not in raw:
            continue
        key, _, rest = raw.partition(":")
        key = key.strip()
        rest = _strip_inline_comment(rest).strip()
        if rest in (">", "|", ""):                       # a block follows
            items = []
            while i < n and (not lines[i].strip() or lines[i][:1] in " \t"):
                s = _strip_inline_comment(lines[i].strip()).strip()
                if s.startswith("- "):
                    items.append(_deq(s[2:]))
                i += 1
            if items:
                data[key] = items
            elif rest == "":
                data[key] = ""
            # folded/literal scalars are skipped (never exported)
        elif rest.startswith("[") and rest.endswith("]"):
            inner = rest[1:-1].strip()
            data[key] = [_deq(x) for x in inner.split(",")] if inner else []
        else:
            data[key] = _deq(rest)
    return data


def load(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    if os.environ.get("SPEC_PARSER_FORCE_MINI") != "1":
        try:
            import yaml
            return yaml.safe_load(text) or {}
        except ImportError:
            pass
    return _mini_load(text)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: parse_spec.py <loop.yaml>", file=sys.stderr)
        return 2
    d = load(sys.argv[1])
    out = []
    for k, var in SCALARS.items():
        v = d.get(k, "")
        out.append(f"{var}={shlex.quote('' if v is None else str(v))}")
    for k, var in LISTS.items():
        v = d.get(k, []) or []
        if isinstance(v, str):
            v = [v]
        out.append(f"{var}={shlex.quote(' '.join(str(x) for x in v))}")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
