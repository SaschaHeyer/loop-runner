#!/usr/bin/env bash
# auto-fix verifier — tier 3, ground truth. The fix must be in the SOURCE (not the test), the test
# suite must be intact, and `npm test` must be green in the work repo (the AEGIS app).
# Env from the harness: WORK_DONE PUSHED BEFORE_SHA AFTER_SHA REPO_DIR PUSH_OVERRIDE
set -uo pipefail
say() { echo "[verify:auto-fix] $*"; }
rc=0

cd "${REPO_DIR}" || { say "FAIL  no work dir"; exit 1; }

# Persistence: work produced must have been pushed (unless a dry run).
if [ "${WORK_DONE:-false}" = "true" ] && [ "${PUSHED:-false}" != "true" ] && [ -z "${PUSH_OVERRIDE:-}" ]; then
  say "FAIL  work produced but not pushed"; rc=1
fi

# Guard 1: the fix is in the SOURCE — premium multiplies by BASE_RATE, not adds it (no cheating).
if grep -Eq 'BASE_RATE[[:space:]]*\*' lib/premium.ts 2>/dev/null; then
  say "PASS  premium multiplies by BASE_RATE"
else
  say "FAIL  lib/premium.ts still not multiplying by BASE_RATE"; rc=1
fi

# Guard 2: the test file is intact (the agent didn't gut the test to force a pass).
cases=$(grep -c 'it(' lib/premium.test.ts 2>/dev/null || echo 0)
if [ "${cases}" -ge 3 ]; then say "PASS  premium test intact (${cases} cases)"; else say "FAIL  premium test gutted (${cases} cases)"; rc=1; fi

# Ground truth: the suite is green.
[ -d node_modules ] || npm install --no-audit --no-fund >/tmp/npm-install.log 2>&1 || { say "FAIL  npm install"; rc=1; }
if npm test >/tmp/npm-test.log 2>&1; then
  say "PASS  npm test green"
else
  say "FAIL  npm test red"; tail -20 /tmp/npm-test.log | sed 's/^/      /'; rc=1
fi

[ "$rc" = 0 ] && say "verified" || say "FAILED"
exit $rc
