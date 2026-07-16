#!/usr/bin/env bash
# hello-world verifier — TIER 3 (ground truth). Even the smallest loop earns a real check: a new,
# well-formed greeting line must have been appended to the state file this run, and pushed.
# Env from the harness: WORK_DONE PUSHED BEFORE_SHA AFTER_SHA REPO_DIR
set -uo pipefail
say() { echo "[verify:hello-world] $*"; }
cd "${REPO_DIR:-.}" || exit 1
F="loops/hello-world/state/greetings.md"
rc=0

# 1. the greeting file exists
if [ -f "$F" ]; then say "PASS  $F exists"; else say "FAIL  $F missing"; exit 1; fi

# 2. a new greeting line was appended this loop (count of '[' lines grew vs the start of the loop)
before="$(git show "${BEFORE_SHA}:$F" 2>/dev/null | grep -c '^\[' || true)"
after="$(grep -c '^\[' "$F" || true)"
if [ "${after:-0}" -gt "${before:-0}" ]; then
  say "PASS  greeting appended (${before:-0} -> ${after:-0})"
else
  say "FAIL  no new greeting appended (${before:-0} -> ${after:-0})"; rc=1
fi

# 3. the newest line is a well-formed greeting
if tail -n1 "$F" | grep -Eq '^\[.*\] hello from the hello-world loop \(run [0-9]+\)$'; then
  say "PASS  newest line is well-formed"
else
  say "FAIL  newest line is not in the expected format"; rc=1
fi

# 4. it was pushed (the persistence guarantee actually happened) — skip in a PUSH_OVERRIDE dry run,
#    where PUSHED=false is expected and correct, not a failure.
if [ -n "${PUSH_OVERRIDE:-}" ]; then
  say "SKIP  push check (PUSH_OVERRIDE=${PUSH_OVERRIDE} dry run — not pushing is expected)"
elif [ "${PUSHED:-false}" = "true" ]; then
  say "PASS  pushed"
else
  say "FAIL  not pushed"; rc=1
fi

if [ "$rc" = "0" ]; then say "TIER 3 verified: greeting appended, well-formed, and pushed"; else say "TIER 3 FAILED"; fi
exit $rc
