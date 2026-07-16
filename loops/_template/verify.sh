#!/usr/bin/env bash
# __NAME__ verifier. Make this as strong as the task allows — the verifier is the hard part.
# Verifier tiers (Loop Engineering): 1 the artifact exists · 2 it runs · 3 ground truth
# (tests/compile/reproduce-then-gone) · 4 a second agent judges · 5 a human signs off.
# Tiers 1-3 can gate unattended; 4-5 mean a human is in the loop — declare your tier in loop.yaml.
#
# Env from the harness: WORK_DONE PUSHED BEFORE_SHA AFTER_SHA REPO_DIR PROXY_SELFTEST_CODE PUSH_OVERRIDE
# Exit 0 = pass, non-zero = fail.  Tip: parse GitHub with `gh --json` + python3, NEVER `gh --jq`.
set -uo pipefail
say() { echo "[verify:__NAME__] $*"; }
rc=0

# Persistence is the one universal check: work that was produced must have been pushed.
if [ "${WORK_DONE:-false}" = "true" ] && [ "${PUSHED:-false}" != "true" ] && [ -z "${PUSH_OVERRIDE:-}" ]; then
  say "FAIL  work was produced but not pushed"; rc=1
fi

# --- TIER 1-3: DETERMINISTIC checks (do these first — cheap, and stronger than any LLM opinion) ------
# Prove the deliverable from ground truth: run the tests / compile it / read the result back from the
# API. A passing test can't be argued with; an LLM judge can. Only judge what a test cannot assert.
# e.g.:  ( cd "${REPO_DIR}" && npm test )        || { say "FAIL tests red"; rc=1; }
say "TODO: replace with a REAL, mechanical ground-truth check"
#
# STATE-FILE PATTERN (copy from hello-world): if your loop appends to a git-memory file, assert it
# grew THIS run and the newest line is well-formed — a cheap, honest tier-3 check. Uncomment + adapt:
#
# cd "${REPO_DIR}" || exit 1
# F="loops/__NAME__/state/<your-state-file>"                      # the git-memory file this loop writes
# if [ -f "$F" ]; then say "PASS  $F exists"; else say "FAIL  $F missing"; rc=1; fi
# before="$(git show "${BEFORE_SHA}:$F" 2>/dev/null | wc -l | tr -d ' ')"   # lines at loop start
# after="$(wc -l < "$F" 2>/dev/null | tr -d ' ')"                          # lines now
# if [ "${after:-0}" -gt "${before:-0}" ]; then say "PASS  state grew (${before:-0} -> ${after:-0})"
# else say "FAIL  no new state written (${before:-0} -> ${after:-0})"; rc=1; fi
# tail -n1 "$F" | grep -Eq '<your well-formed-line regex>' \
#   && say "PASS  newest line well-formed" || { say "FAIL  newest line malformed"; rc=1; }

# --- TIER 4 (OPTIONAL): an independent SUBAGENT judges what no test can (scope, idiomaticity, fit) ---
# Uncomment to add an LLM judge on top of the deterministic checks. It runs on a FRESH context and its
# OWN model (pinned in loops/__NAME__/agents/verifier.md frontmatter), independent of the maker. The
# harness mounts loops/__NAME__/agents/ into .claude/agents/, so `--agent verifier` is available here.
#
# GOAL="<one line: what this run was supposed to achieve>"
# EVIDENCE="$(git -C "${REPO_DIR}" diff "${BEFORE_SHA}" "${AFTER_SHA}" | head -c 12000)"
# JUDGE="$(cd "${REPO_DIR}" && claude --agent verifier --output-format json \
#   --json-schema '{"type":"object","properties":{"verdict":{"type":"string","enum":["pass","fail"]},"reasoning":{"type":"string"}},"required":["verdict"]}' \
#   -p "GOAL: ${GOAL}"$'\n\n'"DIFF:"$'\n'"${EVIDENCE}" 2>/tmp/judge.err)"
# VERDICT="$(printf '%s' "$JUDGE" | python3 -c 'import json,sys
# try: print(json.load(sys.stdin).get("structured_output",{}).get("verdict",""))
# except Exception: pass' 2>/dev/null)"
# case "$VERDICT" in
#   pass) say "PASS  tier-4 judge: pass" ;;
#   fail) say "FAIL  tier-4 judge: fail"; rc=1 ;;
#   *)    say "WARN  tier-4 judge inconclusive (could not read a verdict)"; sed 's/^/      /' /tmp/judge.err 2>/dev/null | head -3 ;;
# esac

[ "$rc" = "0" ] && say "verified" || say "FAILED"
exit $rc
