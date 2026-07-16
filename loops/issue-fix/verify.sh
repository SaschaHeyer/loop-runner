#!/usr/bin/env bash
# issue-fix verifier — tier 3, ground-truth readback. Runs in the harness, not the agent.
# Pass = (a) a clean empty run (no work claimed, none produced), or (b) an OPEN PR exists on a
# branch named issue-fix/<n> that references issue <n>, and the work tree's suite is green.
# Env from the harness: WORK_DONE PUSHED BEFORE_SHA AFTER_SHA REPO_DIR PUSH_OVERRIDE (gh is authed).
set -uo pipefail
say() { echo "[verify:issue-fix] $*"; }
rc=0

cd "${REPO_DIR}" || { say "FAIL  no work dir"; exit 1; }

# Case A: clean empty run — no agent-ready issue to claim is a correct outcome.
if [ "${WORK_DONE:-false}" != "true" ]; then
  say "PASS  clean empty run (no matching issue — silence is a feature)"
  exit 0
fi

# Persistence: work produced must have been pushed (unless a dry run).
if [ "${PUSHED:-false}" != "true" ] && [ -z "${PUSH_OVERRIDE:-}" ]; then
  say "FAIL  work produced but not pushed"; rc=1
fi

# Readback 1: we are on a branch named for exactly one issue.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
ISSUE=""
case "${BRANCH}" in
  issue-fix/[0-9]*) ISSUE="${BRANCH#issue-fix/}"; say "PASS  branch ${BRANCH} names issue #${ISSUE}" ;;
  *) say "FAIL  branch '${BRANCH}' is not issue-fix/<number>"; rc=1 ;;
esac

# Readback 2: an OPEN PR for that branch exists and references the issue. (Dry runs push
# nothing, so there is no PR to read back — skip.)
if [ -n "${ISSUE}" ] && [ -z "${PUSH_OVERRIDE:-}" ]; then
  PR_JSON="$(gh pr list --state open --head "${BRANCH}" --json number,title,body 2>/dev/null || echo '[]')"
  if [ -n "${PR_JSON}" ] && [ "${PR_JSON}" != "[]" ]; then
    if printf '%s' "${PR_JSON}" | grep -q "#${ISSUE}"; then
      say "PASS  open PR on ${BRANCH} references #${ISSUE}"
    else
      say "FAIL  PR on ${BRANCH} never mentions #${ISSUE}"; rc=1
    fi
  else
    say "FAIL  no open PR for ${BRANCH}"; rc=1
  fi
fi

# Ground truth: the work repo's suite is green. Adapt this block to YOUR repo's test command —
# a verifier that runs nothing is a verifier in name only.
if [ -f package.json ] && grep -q '"test"' package.json; then
  [ -d node_modules ] || npm install --no-audit --no-fund >/tmp/npm-install.log 2>&1 || { say "FAIL  npm install"; rc=1; }
  if npm test >/tmp/npm-test.log 2>&1; then
    say "PASS  npm test green"
  else
    say "FAIL  npm test red"; tail -20 /tmp/npm-test.log | sed 's/^/      /'; rc=1
  fi
else
  say "WARN  no npm test script found — wire your suite here for real ground truth"
fi

[ "$rc" = 0 ] && say "verified" || say "FAILED"
exit $rc
