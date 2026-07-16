#!/usr/bin/env bash
# Stop hook — the persistence guarantee, IN-PROCESS.
#
# When the agent stops, commit + push anything it left uncommitted, so no work has to be
# re-derived next loop (the "Groundhog Day" failure from the Loop Engineering talk). The shell
# entrypoint also does this as a backstop; doing it here makes persistence part of the agent's
# own loop — the whole point of owning the container ("can a hook fix it?").
#
# Contract: exit 0 always (allow the stop to proceed). We never block the stop.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$DIR" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
[ -z "$(git status --porcelain)" ] && exit 0        # nothing to persist

git add -A
git commit -m "loop: persist work via Stop hook ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >/dev/null 2>&1 || exit 0
# Push the CURRENT branch (a 'main' loop stays on main; a PR loop is on its own branch). PR-mode
# loops set PERSIST_PUSH=0 so nothing lands remotely from the hook — the entrypoint pushes the
# branch after enforcing that it is not main.
if [ "${PERSIST_PUSH:-1}" = "1" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  git push origin "HEAD:${branch}" >/dev/null 2>&1 || echo "[persist-hook] push failed (entrypoint backstop will retry)" >&2
fi
exit 0
