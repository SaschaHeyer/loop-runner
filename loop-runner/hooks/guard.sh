#!/usr/bin/env bash
# PreToolUse(Bash) hook — enforce the hard boundaries the prompt only asks for.
#
# A prompt can REQUEST "never touch project X"; a hook ENFORCES it, because we own the
# container. This blocks a small, high-confidence set of clearly-forbidden commands and lets
# everything else through (a guard that over-blocks would break real loops).
#
# Contract: exit 2 = block the tool call and feed the stderr reason back to the model; exit 0 = allow.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print((json.load(sys.stdin).get("tool_input") or {}).get("command",""))
except Exception:
    print("")' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

deny() { echo "BLOCKED by loop-runner guard: $1" >&2; exit 2; }

# Hard boundary: block any project you declare off-limits. Set GUARD_BLOCKED_PROJECTS to a
# comma-separated list (e.g. "prod-project,billing-project") and the guard denies any command that
# references one. Empty by default — configure it per deployment.
if [ -n "${GUARD_BLOCKED_PROJECTS:-}" ]; then
  IFS=',' read -ra _blocked <<< "${GUARD_BLOCKED_PROJECTS}"
  for _p in "${_blocked[@]}"; do
    _p="$(printf '%s' "$_p" | tr -d '[:space:]')"; [ -z "$_p" ] && continue
    printf '%s' "$cmd" | grep -Fq "$_p" \
      && deny "the command references '$_p', a project this loop must never touch (GUARD_BLOCKED_PROJECTS)."
  done
fi

# Irreversible footguns.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[fF]?[a-zA-Z]*[[:space:]]+/([[:space:]]|$)' \
  && deny "'rm -rf /' (or equivalent) is not allowed."   # incl. uppercase -Rf (bypass found by error-sweep run 1)
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[[:space:]].*(--force([[:space:]=]|$)|[[:space:]]-f([[:space:]]|$))' \
  && deny "force-push is not allowed — git history is this loop's memory."
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+.*reset[[:space:]]+--hard[[:space:]]+(origin|HEAD~|[0-9a-f]{7,})' \
  && deny "'git reset --hard' to a prior/remote ref would discard the loop's work."

# Dry run (M3): PUSH_OVERRIDE means "nothing reaches origin, full stop" — the harness's own push
# calls already honor this, but the agent can call `git push` directly via Bash (it has before: the
# CEO pushed mid-run in M1.3). Block it here so the dry run is an actual guarantee, not a request.
if [ -n "${PUSH_OVERRIDE:-}" ]; then
  printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push([[:space:]]|$)' \
    && deny "PUSH_OVERRIDE=${PUSH_OVERRIDE} is set (dry run) — no git push is allowed this run, by the agent or the harness."
fi

exit 0
