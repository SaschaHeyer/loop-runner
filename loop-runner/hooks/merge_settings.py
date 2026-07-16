#!/usr/bin/env python3
"""Merge Claude Code settings JSON files (base first, then overrides).

Hook arrays are CONCATENATED per event (so a loop adds hooks without dropping the base ones);
any other key from a later file overrides an earlier one. The runner uses this to assemble
.claude/settings.local.json = base hooks + this loop's hooks. Missing files are skipped.

    merge_settings.py base-settings.json loops/<name>/hooks/settings.json > .claude/settings.local.json
"""
from __future__ import annotations

import json
import sys


def merge(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in b.items():
        if k == "hooks" and isinstance(v, dict) and isinstance(out.get("hooks"), dict):
            h = dict(out["hooks"])
            for event, groups in v.items():
                h[event] = (h.get(event, []) or []) + (groups or [])
            out["hooks"] = h
        elif isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = v
    return out


def main() -> int:
    result: dict = {}
    for path in sys.argv[1:]:
        try:
            with open(path) as f:
                result = merge(result, json.load(f))
        except FileNotFoundError:
            continue
    json.dump(result, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
