#!/usr/bin/env bash
# Loop runner — Cloud Run Job harness. Runs ONE loop end to end, task-agnostic.
#
# Pick the loop with LOOP=<name>; the runner reads loops/<name>/loop.yaml for everything that
# differs (model, prompt, verifier, skills, identity). The CEO is just loop #1.
#
# Flow (the agent is a SUBPROCESS, so the harness regains control when it exits):
#   clone repo -> read loop.yaml -> start local auth proxy -> run agent CLI -> agent EXITS
#   -> harness commits anything left behind (the persistence GUARANTEE) -> push
#   -> run the loop's verify.sh -> log cost -> archive transcript -> exit
#
# Because the harness shares the agent's filesystem, "commit + push" is enforced HERE, not
# hoped for in the prompt. That kills the deploy-without-commit and Groundhog-Day failures.
set -uo pipefail

log() { echo "[harness] $*"; }

usage() {
  cat <<'EOF'
loop-runner entrypoint — runs ONE loop end to end (clone → agent → commit/push → verify → record).

Usage:  LOOP=<name> REPO_FULL_NAME=<owner/repo> [env...] entrypoint.sh
        entrypoint.sh --help

Required env:
  LOOP               loop id; reads loops/<LOOP>/loop.yaml for the spec (e.g. ceo, issue-triage)
  REPO_FULL_NAME     library repo to clone, e.g. SaschaHeyer/loop-runner
  GITHUB_PAT         GitHub token (Secret Manager 'github-pat'); injected via --set-secrets

Common optional env:
  AGENT_CLI          claude | agy                         (default: claude)
  MODEL              override the spec's model            (e.g. claude-sonnet-5)
  WORKDIR            scratch root                          (default: /workspace)
  PUSH_OVERRIDE      none | pr — force a safer push mode than the spec declares (M3 dry-run)
  STREAM             1 = stream-json live steps to Cloud Logging (M14; default 0)
  SMOKE              1 = harness-only validation, skip the agent (M1.2 smoke)
  GCP_PROJECT / SECRET_MANAGER_PROJECT   default: your-gcp-project

Per-loop everything else (model, max_turns, prompt, verify, skills, connectors, repo, shared, push)
is read from loops/<LOOP>/loop.yaml AT RUNTIME from the fresh clone — editing a spec needs no rebuild.
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

# ---------- config (env, set on the Cloud Run Job; see .env.example) ----------
AGENT_CLI="${AGENT_CLI:-claude}"                 # claude | agy
LOOP="${LOOP:?set LOOP=<name> (matches loops/<name>/loop.yaml, e.g. ceo)}"
REPO_FULL_NAME="${REPO_FULL_NAME:?set REPO_FULL_NAME, e.g. SaschaHeyer/loop-runner}"
WORKDIR="${WORKDIR:-/workspace}"
REPO_DIR="${WORKDIR}/repo"
COST_LOG_REL="${COST_LOG:-cost_log.yaml}"
PROXY_PORT="${PROXY_PORT:-8081}"
PROXY_SELFTEST_URL="${PROXY_SELFTEST_URL:-https://firestore.googleapis.com/v1/projects/${GCP_PROJECT:-your-gcp-project}/databases/(default)/documents/crm?pageSize=1}"
export SECRET_MANAGER_PROJECT="${SECRET_MANAGER_PROJECT:-your-gcp-project}"
export GCP_PROJECT="${GCP_PROJECT:-your-gcp-project}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "=== loop=${LOOP} cli=${AGENT_CLI} repo=${REPO_FULL_NAME} ts=${TS} ==="

# ---------- 1. git identity (creds only) + clone the repo (direct TLS, BEFORE the proxy) ----------
# One GitHub PAT (Secret Manager 'github-pat') covers this repo (and any same-owner skills repos),
# fed to git by a credential helper. Cloning here, before HTTPS_PROXY is set, keeps the critical
# bootstrap off the TLS-intercepting proxy and its CA. The commit identity is set later from the spec.
export HOME="${HOME:-/root}"
: "${GITHUB_PAT:?GITHUB_PAT must be set (Secret Manager secret 'github-pat')}"
# Strip ALL whitespace from the token. A secret stored with a trailing newline makes GH_TOKEN
# "ghp_…\n"; gh then builds an Authorization header whose value contains a newline, and Go's
# net/http rejects it: `net/http: invalid header field value for "Authorization"`. That failure is
# silent-ish (gh exits non-zero mid-run) and cost a full session of "gh flakiness" to diagnose via a
# run trace. Trim here so the harness is robust to how the secret was stored.
GITHUB_PAT="$(printf '%s' "${GITHUB_PAT}" | tr -d '[:space:]')"
mkdir -p "${WORKDIR}" /usr/local/share/ca-certificates

# Capture EVERYTHING the harness prints (its own [harness] lines AND the verifier's [verify:…] output,
# since verify.sh runs as our subprocess) to run.log, tee'd so it also streams to Cloud Logging. This
# is what makes the verdict + verifier reasoning visible per-run (archived to GCS in §10). Not a Claude
# session — the verifier is a script — so it must be captured separately from the agent transcripts.
RUN_LOG="${WORKDIR}/run.log"
exec > >(tee -a "${RUN_LOG}") 2>&1

# Deterministic session id for the MAKER agent (from the execution), so we can identify its transcript
# among all the .jsonl files a run produces (maker + tier-4 judge + any delegated subagents).
MAKER_SESSION_ID="$(python3 -c 'import uuid,os;print(uuid.uuid5(uuid.NAMESPACE_URL,"loop-"+os.environ.get("CLOUD_RUN_EXECUTION","local")))' 2>/dev/null || true)"
git config --global credential.helper '!f(){ echo "username=x-access-token"; echo "password=${GITHUB_PAT}"; };f'
git config --global safe.directory '*'
# gh CLI needs an explicit token in automation (it refuses to run headless without one). Found in
# error-sweep's first run: the agent reached `gh pr create` and gh had no auth.
export GH_TOKEN="${GITHUB_PAT}"

# Host prefix for every clone. Defaults to public GitHub; overridable for a GH Enterprise host or,
# critically, for LOCAL testing against file:// scratch remotes (see loop-runner/test/).
GIT_HOST_BASE="${GIT_HOST_BASE:-https://github.com/}"

# REPO_DIR is the LIBRARY clone: the source of the spec, prompt, verifier, and shared skills. It is
# read-only during the run — a loop's WORK (commits, pushes) happens in WORK_DIR, resolved in §2b.
rm -rf "${REPO_DIR}"
log "cloning ${REPO_FULL_NAME} (library: spec + prompt + verifier + skills)"
git clone "${GIT_HOST_BASE}${REPO_FULL_NAME}.git" "${REPO_DIR}" || { log "FATAL library clone failed"; exit 1; }
cd "${REPO_DIR}"

# ---------- 2. read the loop spec ----------
SPEC="${REPO_DIR}/loops/${LOOP}/loop.yaml"
[ -f "${SPEC}" ] || { log "FATAL no spec at loops/${LOOP}/loop.yaml"; exit 1; }
eval "$(python3 /harness/parse_spec.py "${SPEC}")"
# env overrides spec (lets a smoke/manual run force a model or turn cap); spec overrides the default.
MODEL="${MODEL:-${LOOP_MODEL:-claude-opus-4-8}}"
MAX_TURNS="${MAX_TURNS:-${LOOP_MAX_TURNS:-80}}"
ALLOWED_TOOLS="${LOOP_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,WebSearch,WebFetch}"
git config --global user.name  "${LOOP_GIT_USER_NAME:-loop-runner}"
git config --global user.email "${LOOP_GIT_USER_EMAIL:-loop@localhost}"
LOOP_PUSH_MODE="${LOOP_PUSH:-main}"                     # what the loop's own spec declares
PUSH_TARGET="${PUSH_OVERRIDE:-${LOOP_PUSH_MODE}}"       # what actually happens this run (a dry run wins)
log "spec: model=${MODEL} max_turns=${MAX_TURNS} tier='${LOOP_TIER:-?}' verify='${LOOP_VERIFY:-none}' push='${LOOP_PUSH_MODE}'${PUSH_OVERRIDE:+ [PUSH_OVERRIDE=${PUSH_OVERRIDE} -> effective push='${PUSH_TARGET}']}"
# The persist Stop hook pushes the current branch for a 'main' loop; a PR-mode loop (or any
# PUSH_OVERRIDE dry run) persists locally and lets section 7 handle the rest.
if [ "${PUSH_TARGET}" = "main" ]; then export PERSIST_PUSH=1; else export PERSIST_PUSH=0; fi

# ---------- 2b. resolve the WORK repo (M8): where the agent operates + commits ----------
# Default: the library IS the work repo (single-repo mode — today's behavior, zero regression).
# If the spec sets `repo:`, clone THAT as a separate work repo: the library stays read-only spec
# source and the agent's cwd + every commit/push happens in the work repo instead. The HARNESS does
# the cloning, never the agent (same as the library clone above). Smoke runs stay in the library —
# they validate the harness/image (writing loop-runner/SMOKE.md), not the work repo.
if [ -n "${LOOP_REPO:-}" ] && [ "${SMOKE:-0}" != "1" ]; then
  WORK_DIR="${WORKDIR}/work"
  rm -rf "${WORK_DIR}"
  log "cloning work repo ${LOOP_REPO} (agent operates + commits HERE; library stays read-only)"
  git clone "${GIT_HOST_BASE}${LOOP_REPO}.git" "${WORK_DIR}" || { log "FATAL work repo clone failed"; exit 1; }
else
  WORK_DIR="${REPO_DIR}"
  [ -n "${LOOP_REPO:-}" ] && log "smoke: ignoring repo:${LOOP_REPO}, validating harness in the library" \
                         || log "single-repo mode: the agent works in the library repo (no repo: in spec)"
fi
BEFORE_SHA="$(git -C "${WORK_DIR}" rev-parse HEAD)"

# ---------- 3. assemble the skill dirs (repo skills/ + per-loop skills/ + external skill repos) ----------
SKILL_DIRS=()
[ -d "${REPO_DIR}/skills" ]                 && SKILL_DIRS+=("${REPO_DIR}/skills")
[ -d "${REPO_DIR}/loops/${LOOP}/skills" ]   && SKILL_DIRS+=("${REPO_DIR}/loops/${LOOP}/skills")
sidx=0
for repo in ${LOOP_SKILLS:-}; do
  d="${WORKDIR}/skills-ext-${sidx}"; sidx=$((sidx + 1)); rm -rf "$d"
  if git clone "${GIT_HOST_BASE}${repo}.git" "$d" 2>/dev/null; then
    SKILL_DIRS+=("$d"); log "skills: cloned ${repo}"
  else
    log "skills: clone skipped (non-fatal): ${repo}"
  fi
done

# ---------- 3c. clone the shared COMMONS repos (M12): fleet-wide memory the loop READS and APPENDS to ----------
# Unlike skills/ (read-only reference), a commons repo is knowledge many loops share: cross-loop
# LEARNINGS, playbooks, research. The agent reads AND writes it; §7 commits + pushes it back with a
# concurrent-writer-safe push (many loops may share one commons). Convention (told to the agent + kept
# conflict-free in practice): append under <commons>/<loop>/ — never rewrite another loop's entries.
SHARED_DIRS=()
cidx=0
for repo in ${LOOP_SHARED:-}; do
  d="${WORKDIR}/shared-${cidx}"; cidx=$((cidx + 1)); rm -rf "$d"
  if git clone "${GIT_HOST_BASE}${repo}.git" "$d" 2>/dev/null; then
    SHARED_DIRS+=("$d"); log "commons: cloned ${repo} -> ${d}"
  else
    log "commons: clone skipped (non-fatal): ${repo}"
  fi
done
COMMONS_NOTE=""
[ "${#SHARED_DIRS[@]}" -gt 0 ] && COMMONS_NOTE="
Shared commons (read AND append — fleet-wide memory across loops): ${SHARED_DIRS[*]}. Read others' learnings for context; append yours under <commons>/${LOOP}/ (create it) and to any append-only shared log. NEVER rewrite or delete another loop's entries. The harness commits + pushes the commons for you after you stop."

# ---------- 3b. assemble runtime Claude config: base+loop hooks, discoverable skills ----------
# We own the container, so the persistence GUARANTEE and the hard boundaries are enforced as
# HOOKS, not merely requested in the prompt. Written to .claude/settings.local.json (a real
# settings layer whose permissions apply without a trust dialog — verified for headless print mode).
# NOTE: the config is injected into WORK_DIR — the agent's cwd — which is the library only in
# single-repo mode. Hooks + skills must live where the agent actually runs, not in the spec source.
mkdir -p "${WORK_DIR}/.claude/skills"
python3 /harness/hooks/merge_settings.py \
  /harness/hooks/base-settings.json \
  "${REPO_DIR}/loops/${LOOP}/hooks/settings.json" \
  > "${WORK_DIR}/.claude/settings.local.json"
log "hooks: assembled .claude/settings.local.json (base persist + guard hooks + any loop hooks)"

# Register skills for auto-discovery: copy every SKILL.md folder (from the library's skills/, the
# loop's skills/, and any external skill repos) under WORK_DIR/.claude/skills/, which cwd-discovery
# loads. Sources are the LIBRARY clone; the copy target is the agent's cwd (WORK_DIR).
skill_count=0
for sd in "${SKILL_DIRS[@]:-}"; do
  [ -d "$sd" ] || continue
  while IFS= read -r skmd; do
    skdir="$(dirname "$skmd")"; name="$(basename "$skdir")"
    rm -rf "${WORK_DIR}/.claude/skills/${name}"
    cp -r "$skdir" "${WORK_DIR}/.claude/skills/${name}" && skill_count=$((skill_count + 1))
  done < <(find "$sd" -name SKILL.md -type f 2>/dev/null)
done
log "skills: registered ${skill_count} skill(s) under .claude/skills/"

# Register the loop's SUBAGENTS for discovery: copy loops/<name>/agents/*.md under WORK_DIR/.claude/agents/.
# Claude Code discovers subagents there (incl. headless -p); a loop's verifier or maker can then delegate
# to them (Task/Agent tool), or verify.sh can run one as a judge via `claude --agent <name> ...`. Each
# .md pins its own model/effort/tools in frontmatter, so a tier-4 judge can run on a different model.
agent_count=0
if [ -d "${REPO_DIR}/loops/${LOOP}/agents" ]; then
  mkdir -p "${WORK_DIR}/.claude/agents"
  while IFS= read -r amd; do
    cp "$amd" "${WORK_DIR}/.claude/agents/$(basename "$amd")" && agent_count=$((agent_count + 1))
  done < <(find "${REPO_DIR}/loops/${LOOP}/agents" -name '*.md' -type f 2>/dev/null)
fi
log "agents: registered ${agent_count} subagent(s) under .claude/agents/"

# ---------- 3c. register the chrome-devtools MCP server IF this loop drives a browser ----------
# A loop opts in with zero config: just list `chrome-devtools` in allowed_tools or in a sub-agent's
# tools:. The MCP server (chrome-devtools-mcp, installed in the image) exposes navigate/click/fill/
# screenshot; Chrome only launches on first tool use, so registering it is cheap for loops that never
# call it. We write .claude/mcp.json and pass it via --mcp-config at invocation (§6). MCP_CONFIG stays
# empty for non-browser loops, so their invocation is byte-identical to before.
MCP_CONFIG=""
if grep -rqs "chrome-devtools" "${REPO_DIR}/loops/${LOOP}" 2>/dev/null \
   || printf '%s' "${ALLOWED_TOOLS}" | grep -q "chrome-devtools"; then
  MCP_CONFIG="${WORK_DIR}/.claude/mcp.json"
  cat > "${MCP_CONFIG}" <<'MCPJSON'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "chrome-devtools-mcp",
      "args": ["--headless", "--isolated", "--executablePath", "/usr/local/bin/chromium-headless"]
    }
  }
}
MCPJSON
  # Allow the whole server's tools for the main agent; sub-agents still gate via their own tools:.
  ALLOWED_TOOLS="${ALLOWED_TOOLS},mcp__chrome-devtools"
  log "mcp: registered chrome-devtools server (this loop drives a browser)"
fi

# The runtime-injected config is the RUNNER's, not the work repo's — never commit it. Exclude it in
# WORK_DIR (where it lives). In single-repo mode WORK_DIR==REPO_DIR, so this is today's behavior.
for p in '.claude/settings.local.json' '.claude/skills/' '.claude/agents/' '.claude/mcp.json'; do
  grep -qxF "$p" "${WORK_DIR}/.git/info/exclude" 2>/dev/null || echo "$p" >> "${WORK_DIR}/.git/info/exclude"
done

# ---------- 4. local auth-injecting egress proxy (mirrors run_loop.py PROXY_API_KEYS) ----------
# Started BEFORE the proxy env is exported so the addon's metadata fetch is never self-proxied.
# M5: hand the addon the loop's declared connectors so it injects ONLY those (least privilege). A
# `connectors: []` loop then reaches no authenticated API (its proxy self-test returns 401/403, not 200).
export LOOP_CONNECTORS="${LOOP_CONNECTORS:-}"
export LOOP_CONNECTORS_ENFORCE=1
log "connectors (proxy will inject only these): [${LOOP_CONNECTORS:-}]"
log "starting egress proxy on 127.0.0.1:${PROXY_PORT}"
mitmdump -s /harness/proxy_addon.py --listen-host 127.0.0.1 -p "${PROXY_PORT}" \
         --set block_global=false --set connection_strategy=lazy \
         >/tmp/mitmproxy.log 2>&1 &
PROXY_PID=$!

CA="${HOME}/.mitmproxy/mitmproxy-ca-cert.pem"
for _ in $(seq 1 40); do [ -f "${CA}" ] && break; sleep 0.5; done
if [ ! -f "${CA}" ]; then log "ERROR: proxy CA not generated"; cat /tmp/mitmproxy.log; exit 1; fi

cp "${CA}" /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates >/dev/null 2>&1 || true
SYS_CA="/etc/ssl/certs/ca-certificates.crt"

export HTTP_PROXY="http://127.0.0.1:${PROXY_PORT}" HTTPS_PROXY="http://127.0.0.1:${PROXY_PORT}"
export http_proxy="${HTTP_PROXY}" https_proxy="${HTTPS_PROXY}"
export NO_PROXY="metadata.google.internal,169.254.169.254,127.0.0.1,localhost"
export no_proxy="${NO_PROXY}"
export REQUESTS_CA_BUNDLE="${SYS_CA}" SSL_CERT_FILE="${SYS_CA}" CURL_CA_BUNDLE="${SYS_CA}" \
       GIT_SSL_CAINFO="${SYS_CA}" NODE_EXTRA_CA_CERTS="${CA}" \
       CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="${SYS_CA}"
log "proxy live, CA trusted"

# Deterministic keystone check: a NO-AUTH call to a googleapis domain must come back 200, proving
# the proxy injected the SA token — exactly what makes a loop's proxy-only tools work. Non-fatal.
PT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${PROXY_SELFTEST_URL}" || echo 000)
if [ "${PT_CODE}" = "200" ]; then
  log "✅ proxy self-test PASSED — HTTP 200 on a no-auth call (token injection works)"
else
  log "⚠️ proxy self-test: HTTP ${PT_CODE} (expected 200; check proxy injection or CA trust)"
fi

# ---------- 5. build the prompt (a generic runtime header + the loop's prompt.md) ----------
SYS_ARG=(); ADD_DIR_ARGS=()
# Guard the expansion: SKILL_DIRS is empty for a loop with no skills, which is unbound under `set -u`.
for d in "${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"}"; do ADD_DIR_ARGS+=(--add-dir "$d"); done
# Commons dirs are mounted read/WRITE (the loop appends learnings there); §7 pushes them back.
for d in "${SHARED_DIRS[@]+"${SHARED_DIRS[@]}"}"; do ADD_DIR_ARGS+=(--add-dir "$d"); done
# MCP config (§3c): only non-empty for a browser loop, so non-browser invocations are unchanged.
MCP_ARGS=(); [ -n "${MCP_CONFIG:-}" ] && MCP_ARGS=(--mcp-config "${MCP_CONFIG}")

if [ "${SMOKE:-0}" = "1" ]; then
  log "SMOKE MODE: harness validation only (no loop actions)"
  SYS_ARG=(--system-prompt "You are validating a deployment harness, NOT doing real work. Do EXACTLY the steps in the user message, in order, then stop.")
  KICKOFF="Harness smoke test (${TS}, loop=${LOOP}, model ${MODEL}). Working dir ${REPO_DIR}. Do these steps in order, then STOP: \
(1) print 'uname -a' and the python3 / node / gcloud versions; \
(2) confirm the working dir is a git clone (run 'git rev-parse HEAD'); \
(3) write the file loop-runner/SMOKE.md with exactly one line: 'harness smoke OK ${TS} loop=${LOOP} model=${MODEL}'; \
(4) stop. Do NOT deploy, do NOT send any email, do NOT modify any other file."
else
  # system prompt from the spec file, if the loop declares one
  if [ -n "${LOOP_SYSTEM_PROMPT:-}" ] && [ -f "${REPO_DIR}/${LOOP_SYSTEM_PROMPT}" ]; then
    SYS_ARG=(--system-prompt "$(cat "${REPO_DIR}/${LOOP_SYSTEM_PROMPT}")")
  fi
  PROMPT_FILE="${REPO_DIR}/${LOOP_PROMPT:-loops/${LOOP}/prompt.md}"
  [ -f "${PROMPT_FILE}" ] || { log "FATAL no prompt file at ${LOOP_PROMPT:-loops/${LOOP}/prompt.md}"; kill "${PROXY_PID}" 2>/dev/null; exit 1; }
  RUNTIME_HEADER="Runtime: loop-runner (Cloud Run Job). loop=${LOOP}, ts=${TS}, model=${MODEL}.
Working dir: ${WORK_DIR} — this git repo is your memory. Edit files here and the harness commits + pushes them for you after you stop. Your deliverable is a PUSHED commit.
Auth: Google APIs (gcloud / Firestore / Vertex) use the job's service account natively (NO token mint). Other connectors (GitHub, Stripe, Resend, Cloudflare) are auth-injected at a local egress proxy — call them with NO Authorization header.
Skills available (read-only reference dirs): ${SKILL_DIRS[*]:-(none)}.${COMMONS_NOTE}
When you have no high-value work left, STOP."
  KICKOFF="${RUNTIME_HEADER}

--- loop task (loops/${LOOP}/prompt.md) ---
$(cat "${PROMPT_FILE}")"
fi

# ---------- 6. run the agent (the maker), headless ----------
# The agent runs with its cwd in WORK_DIR (the library only in single-repo mode). CLAUDE_PROJECT_DIR
# points the persist Stop hook at the same tree, so it commits the work repo, not the library.
cd "${WORK_DIR}"
export CLAUDE_PROJECT_DIR="${WORK_DIR}"
RESULT="${WORKDIR}/result.json"; AGENT_RC=0
case "${AGENT_CLI}" in
  claude)
    if [ "${STREAM:-0}" = "1" ]; then
      # M14 (opt-in): stream-json → live loop_step lines in Cloud Logging via the projector, which also
      # writes the final result event to RESULT (same fields as --output-format json, so log_cost + the
      # excerpt are unchanged). --session-id (a deterministic UUID from the execution) correlates the run
      # to its transcript. Default path (below) is byte-identical to before — STREAM=0 changes nothing.
      log "STREAM=1: live step streaming on (session ${MAKER_SESSION_ID:-?})"
      claude --print --output-format stream-json --verbose \
        --model "${MODEL}" --allowedTools "${ALLOWED_TOOLS}" --max-turns "${MAX_TURNS}" \
        ${MAKER_SESSION_ID:+--session-id "${MAKER_SESSION_ID}"} \
        "${SYS_ARG[@]+"${SYS_ARG[@]}"}" "${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"}" "${MCP_ARGS[@]+"${MCP_ARGS[@]}"}" \
        -p "${KICKOFF}" 2>/tmp/agent.err \
        | LOOP="${LOOP}" EXEC_ID="${CLOUD_RUN_EXECUTION:-${TS}}" python3 /harness/stream_steps.py "${RESULT}"
      AGENT_RC=${PIPESTATUS[0]}
    else
      claude --print --output-format json \
        --model "${MODEL}" \
        --allowedTools "${ALLOWED_TOOLS}" \
        --max-turns "${MAX_TURNS}" \
        ${MAKER_SESSION_ID:+--session-id "${MAKER_SESSION_ID}"} \
        "${SYS_ARG[@]+"${SYS_ARG[@]}"}" "${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"}" "${MCP_ARGS[@]+"${MCP_ARGS[@]}"}" \
        -p "${KICKOFF}" >"${RESULT}" 2>/tmp/agent.err || AGENT_RC=$?
    fi
    ;;
  agy)
    # agy print mode: -p runs one prompt non-interactively; no --output-format json (log_cost
    # handles non-JSON gracefully). agy uses its own model names — override MODEL when AGENT_CLI=agy.
    agy --print --dangerously-skip-permissions --print-timeout "${PRINT_TIMEOUT:-50m}" \
      --model "${MODEL}" "${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"}" \
      -p "${KICKOFF}" >"${RESULT}" 2>/tmp/agent.err || AGENT_RC=$?
    ;;
  *) log "ERROR unknown AGENT_CLI=${AGENT_CLI}"; kill "${PROXY_PID}" 2>/dev/null; exit 2 ;;
esac
cat /tmp/agent.err >&2 || true
log "agent exited rc=${AGENT_RC}"

if [ -f "${RESULT}" ]; then
  python3 -c "import json;d=json.load(open('${RESULT}'));print('[agent-response] '+((d.get('result') or '(no text)')[:4000]))" 2>/dev/null \
    || log "(agent output was not JSON — see the GCS transcript)"
fi

# ---------- 7. THE GUARANTEE: persist whatever the agent left behind ----------
# External skill repos (separate remotes) first.
for d in "${WORKDIR}"/skills-ext-*; do
  [ -d "$d/.git" ] || continue
  if [ -n "$(git -C "$d" status --porcelain)" ]; then
    git -C "$d" add -A
    git -C "$d" commit -m "skills: ${LOOP} loop ${TS}" || true
    git -C "$d" push || log "WARN skills push failed ($d)"
  fi
done

# Shared COMMONS repos (M12): commit + push back what the loop appended. Many loops may push the SAME
# commons around the same time, so a blind push loses the race — pull --rebase --autostash and retry.
# Append-only + per-loop subdirs keep this conflict-free in practice; a genuine conflict logs a WARN
# rather than failing the run (the loop's real deliverable is in WORK_DIR, not the commons).
for d in "${SHARED_DIRS[@]+"${SHARED_DIRS[@]}"}"; do
  [ -d "$d/.git" ] || continue
  [ -n "$(git -C "$d" status --porcelain)" ] || { log "commons: no new learnings to push ($d)"; continue; }
  git -C "$d" add -A
  git -C "$d" commit -m "commons: ${LOOP} loop ${TS}" || true
  pushed_commons=0
  for _attempt in 1 2 3; do
    if git -C "$d" push 2>/dev/null; then pushed_commons=1; break; fi
    git -C "$d" pull --rebase --autostash >/dev/null 2>&1 || { git -C "$d" rebase --abort 2>/dev/null || true; break; }
  done
  [ "${pushed_commons}" = 1 ] && log "commons: pushed learnings back ($d)" || log "WARN commons push failed after retries ($d)"
done

cd "${WORK_DIR}"   # persist the WORK repo (the library only in single-repo mode); never the library from a work-repo loop

# Did the AGENT actually produce work? Judge by ITS OWN output relative to the CURRENT origin/main
# (which already includes any concurrent operator / other-loop pushes) — NOT by whether the shared main
# SHA moved from the clone-time BEFORE_SHA. A pure fast-forward of main (the agent ran `git pull`, or
# someone pushed to main during the run) is NOT agent work. Concurrent writers are NORMAL.
# Fixed 2026-07-10: a concurrent push to main mid-run was mis-read as agent work — it spawned a spurious
# PR branch and failed a run that actually had nothing to do. AGENT_WORKED = uncommitted changes OR local
# commits ahead of origin/main; captured BEFORE any harness safety-net commit / branch move.
git fetch -q origin main 2>/dev/null || true
if [ -n "$(git status --porcelain)" ] \
   || { git rev-parse --verify -q origin/main >/dev/null 2>&1 && [ -n "$(git rev-list origin/main..HEAD 2>/dev/null)" ]; }; then
  AGENT_WORKED=true
else
  AGENT_WORKED=false
fi

# PR-mode must NEVER land work on main: if the agent COMMITTED/left work on main, move it to a branch.
# Keyed on REAL agent work (AGENT_WORKED), not the main SHA — a concurrent push is not our work.
if [ "${LOOP_PUSH_MODE}" != "main" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
   && [ "${AGENT_WORKED}" = "true" ]; then
  SAFE_BRANCH="loop/${LOOP}-$(printf '%s' "${TS}" | tr ':' '-')"
  git switch -c "${SAFE_BRANCH}" 2>/dev/null || git checkout -b "${SAFE_BRANCH}"
  log "PR-mode: moved work to branch ${SAFE_BRANCH} (never main)"
fi

if [ -n "$(git status --porcelain)" ]; then
  log "agent left uncommitted work — harness committing it (safety net)"
  git add -A
  git commit -m "Loop ${LOOP} ${TS}: harness safety-net commit (agent left uncommitted work)" || true
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Push HEAD to origin/main, tolerating CONCURRENT WRITERS (the operator, another loop finishing,
# a mid-run push by the agent itself). Discovered in the first real CEO loop: the agent pushed its
# work mid-run, the operator pushed docs on top, and the blind final push was rejected as a rewind
# — a FALSE "work would be lost" even though every commit was already on origin.
push_main() {
  git push origin HEAD:main 2>/dev/null && return 0
  git fetch -q origin main || return 1
  # (a) origin already CONTAINS our HEAD — the work is safe (someone else moved main forward). OK.
  if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    log "push: origin/main already contains HEAD (concurrent writer moved main forward) — work is safe"
    return 0
  fi
  # (b) genuine divergence (e.g. our safety-net commit vs a concurrent push) — rebase once, retry.
  log "push: origin/main diverged — rebasing our commits on top and retrying"
  git rebase origin/main >/dev/null 2>&1 || { git rebase --abort 2>/dev/null; return 1; }
  git push origin HEAD:main
}

PUSHED=true
case "${PUSH_TARGET}" in
  none)
    if [ -n "${PUSH_OVERRIDE:-}" ]; then
      log "🏜  DRY RUN — nothing pushed (PUSH_OVERRIDE=${PUSH_OVERRIDE}; loop declares push='${LOOP_PUSH_MODE}')"
      log "would-be diffstat (${BEFORE_SHA:0:7}..${BRANCH}):"
      git diff --stat "${BEFORE_SHA}" HEAD | while IFS= read -r line; do log "  ${line}"; done
    else
      log "push target 'none' — committed locally, not pushing"
    fi
    PUSHED=false ;;
  main)
    push_main || { log "ERROR git push failed"; PUSHED=false; } ;;   # no-op push if idle
  *)  # pr / branch mode — push the working branch; the loop's open-pr skill opens/updates the PR
    if [ "${BRANCH}" = "main" ]; then
      log "PR-mode: no changes this loop — nothing to push"; PUSHED=false
    else
      git push origin "HEAD:${BRANCH}" || { log "ERROR git push failed"; PUSHED=false; }
      [ "${PUSHED}" = "true" ] && log "PR-mode: pushed branch ${BRANCH} (open/update the PR from it)"
    fi ;;
esac
AFTER_SHA="$(git rev-parse HEAD)"
WORK_DONE="${AGENT_WORKED}"   # the agent's OWN output vs origin/main — NOT raw main movement (concurrent-writer-safe)
log "work_done=${WORK_DONE} pushed=${PUSHED} target=${PUSH_TARGET} branch=${BRANCH} ${BEFORE_SHA:0:7} -> ${AFTER_SHA:0:7}"

# ---------- 8. verifier: the loop's own verify.sh (exit 0 = pass) ----------
# The verifier SCRIPT is a spec artifact (from the library); it runs with REPO_DIR=WORK_DIR so it
# inspects the tree the agent actually changed. In single-repo mode those are the same directory.
VERDICT="none"
VERIFY_OUT="${WORKDIR}/verify.out"; : > "${VERIFY_OUT}"
if [ -n "${LOOP_VERIFY:-}" ] && [ -f "${REPO_DIR}/${LOOP_VERIFY}" ]; then
  log "running verifier ${LOOP_VERIFY} (tier '${LOOP_TIER:-?}')"
  # Capture the verifier's output to a file (deterministic, for the PR comment in §8b) AND surface it in
  # the run log by cat-ing it after.
  if BEFORE_SHA="${BEFORE_SHA}" AFTER_SHA="${AFTER_SHA}" WORK_DONE="${WORK_DONE}" PUSHED="${PUSHED}" \
     REPO_DIR="${WORK_DIR}" RESULT="${RESULT}" GCP_PROJECT="${GCP_PROJECT}" LOOP="${LOOP}" \
     PROXY_SELFTEST_CODE="${PT_CODE}" REPO_FULL_NAME="${REPO_FULL_NAME}" \
     PUSH_OVERRIDE="${PUSH_OVERRIDE:-}" \
     bash "${REPO_DIR}/${LOOP_VERIFY}" > "${VERIFY_OUT}" 2>&1; then
    VERDICT="pass"
  else
    VERDICT="FAIL"
  fi
  cat "${VERIFY_OUT}"
  log "verifier verdict: ${VERDICT} (tier '${LOOP_TIER:-?}')"
else
  log "no verifier declared for loop ${LOOP} (tier '${LOOP_TIER:-?}')"
fi
[ -z "$(git status --porcelain)" ] || log "WARN tree not clean after push"

# ---------- 8b. surface the verdict ON the PR (push:pr loops) — where the human actually decides ----------
# The verdict otherwise lives only in run.log / the dashboard; post it as a PR comment so a reviewer sees
# the check-by-check result + the tier-4 judge's reasoning before merging. Advisory (a PR goes to a human),
# not a hard gate. Uses gh (authed); parse PR JSON with python3 (gh --jq is flaky in-container).
if [ "${LOOP_PUSH_MODE}" = "pr" ] && [ "${BRANCH}" != "main" ] && command -v gh >/dev/null 2>&1; then
  PR_REPO="${LOOP_REPO:-${REPO_FULL_NAME}}"
  PR_NUM="$(gh pr list --repo "${PR_REPO}" --head "${BRANCH}" --state open --json number 2>/dev/null \
            | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d[0]["number"] if d else "")
except Exception: pass' 2>/dev/null)"
  if [ -n "${PR_NUM}" ]; then
    VEMOJI="✅"; [ "${VERDICT}" = "FAIL" ] && VEMOJI="❌"; [ "${VERDICT}" = "none" ] && VEMOJI="ℹ️"
    VCHECKS="$(grep -E '^\[verify:' "${VERIFY_OUT}" 2>/dev/null | sed 's/^\[verify:[^]]*\] //')"
    [ -n "${VCHECKS}" ] || VCHECKS="(no itemized checks emitted)"
    TRACE_LINE=""
    # Optional: set DASHBOARD_BASE_URL to your own dashboard to add a per-run trace link to the PR comment.
    if [ -n "${CLOUD_RUN_EXECUTION:-}" ] && [ -n "${DASHBOARD_BASE_URL:-}" ]; then
      TRACE_LINE="$(printf '**Trace:** %s/run/%s\n' "${DASHBOARD_BASE_URL}" "${CLOUD_RUN_EXECUTION}")"
    fi
    VBODY="$(printf '<!-- loop-verifier -->\n## %s Loop verifier: **%s**\n\n**Tier:** %s\n**Run:** `%s`\n%s\n```\n%s\n```\n\n_Automated verifier output from the `%s` loop (independent of the PR). Advisory — you decide on merge._' \
      "${VEMOJI}" "${VERDICT}" "${LOOP_TIER:-?}" "${CLOUD_RUN_EXECUTION:-local}" "${TRACE_LINE}" "${VCHECKS}" "${LOOP}")"
    if gh pr comment "${PR_NUM}" --repo "${PR_REPO}" --body "${VBODY}" >/dev/null 2>&1; then
      log "verifier: posted verdict (${VERDICT}) to PR #${PR_NUM} on ${PR_REPO}"
    else
      log "WARN verifier: could not post verdict comment to PR #${PR_NUM} on ${PR_REPO}"
    fi

    # ---------- 8c. autonomous re-trigger on a FAILED verdict — no human needed ----------
    # A FAIL otherwise just sits on the PR waiting for a human /loop comment. Toggle a label instead:
    # GitHub Actions (revise-on-verify-fail.yml) fires on ai:verify-failed being ADDED and re-runs this
    # same loop in REVISE_PR mode, using the verdict comment just posted above as the fix instructions —
    # the maker/checker duo becomes a real retry-until-verified loop, not just maker+checker-then-stop.
    # Cap it (AUTOREVISE_MAX_ATTEMPTS, default 3) by counting commits THIS loop's own git identity made
    # on the branch so far (1 = the initial fix, each revise adds one) — no separate ledger to maintain.
    if [ "${VERDICT}" != "none" ]; then
      ATTEMPTS="$(git log --author="${LOOP_GIT_USER_EMAIL:-loop@localhost}" --oneline 2>/dev/null | wc -l | tr -d ' ')"
      MAX_ATTEMPTS="${AUTOREVISE_MAX_ATTEMPTS:-3}"
      gh label create "ai:verify-failed" --repo "${PR_REPO}" --color 5319e7 2>/dev/null || true
      if [ "${VERDICT}" = "FAIL" ]; then
        if [ "${ATTEMPTS}" -ge "${MAX_ATTEMPTS}" ] 2>/dev/null; then
          log "verifier: FAIL at attempt ${ATTEMPTS}/${MAX_ATTEMPTS} — escalating to a human, not re-triggering"
          gh pr edit "${PR_NUM}" --repo "${PR_REPO}" --remove-label "ai:verify-failed" >/dev/null 2>&1 || true
          gh label create "ai:needs-human" --repo "${PR_REPO}" --color d93f0b 2>/dev/null || true
          gh pr edit "${PR_NUM}" --repo "${PR_REPO}" --add-label "ai:needs-human" >/dev/null 2>&1 || true
          gh pr comment "${PR_NUM}" --repo "${PR_REPO}" --body "$(printf 'Reached %s automatic fix attempts without passing verification. Stopping the autonomous retry so a human can take it from here, the verifier output above has the specifics. Comment `/loop <guidance>` to have the loop try again with your steer.' "${MAX_ATTEMPTS}")" >/dev/null 2>&1 || true
        else
          # Remove-then-add: GitHub only fires the `labeled` event for a label the PR does NOT already
          # have, so a bare re-add on a lingering label would silently fail to re-trigger the workflow.
          gh pr edit "${PR_NUM}" --repo "${PR_REPO}" --remove-label "ai:verify-failed" >/dev/null 2>&1 || true
          if gh pr edit "${PR_NUM}" --repo "${PR_REPO}" --add-label "ai:verify-failed" >/dev/null 2>&1; then
            log "verifier: FAIL (attempt ${ATTEMPTS}/${MAX_ATTEMPTS}) — labelled ai:verify-failed for autonomous retry"
          else
            log "WARN verifier: could not label PR #${PR_NUM} for autonomous retry"
          fi
        fi
      else
        # PASS — clear any stale retry label left over from an earlier failed cycle on this same PR.
        gh pr edit "${PR_NUM}" --repo "${PR_REPO}" --remove-label "ai:verify-failed" >/dev/null 2>&1 || true
      fi
    fi
  else
    log "verifier: no open PR for branch ${BRANCH} on ${PR_REPO} — no comment posted"
  fi
fi

# ---------- 9. cost telemetry -> Cloud Logging (cost_log.yaml is gitignored by design) ----------
LOOP_BUDGET_USD="${LOOP_BUDGET_USD:-}" python3 /harness/log_cost.py "${RESULT}" "${REPO_DIR}/${COST_LOG_REL}" \
        "${AFTER_SHA}" "${PUSHED}" "${WORK_DONE}" "${AGENT_CLI}" "${MODEL}" "${LOOP}" || log "WARN cost log failed"

# ---------- 10. archive the full transcript to GCS (gs://<bucket>/<loop>/<exec>/), then shut down ----------
kill "${PROXY_PID}" 2>/dev/null || true
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy   # uploads go direct via the SA's native ADC
if [ -n "${SESSIONS_BUCKET:-}" ]; then
  EXEC_ID="${CLOUD_RUN_EXECUTION:-${TS}}"
  DEST="gs://${SESSIONS_BUCKET}/${LOOP}/${EXEC_ID}"
  gcloud storage cp "${RESULT}" "${DEST}/result.json" 2>/dev/null && log "transcript -> ${DEST}/result.json" || log "WARN result.json upload failed"
  # run.log = the harness + verifier output (verdict, [verify:…], work_done/pushed). This is the
  # "Verdict & verifier" source the dashboard/get_run.py render. Flush the tee first so it's complete.
  sync 2>/dev/null || true
  [ -f "${RUN_LOG}" ] && gcloud storage cp "${RUN_LOG}" "${DEST}/run.log" 2>/dev/null && log "transcript -> ${DEST}/run.log" || log "WARN run.log upload failed"
  # ALL agent transcripts — maker + tier-4 judge + any delegated subagent each leave a .jsonl here.
  # Archive every one under sessions/ (uniform capture, no per-subagent wiring); also keep the maker's
  # (known session id, else the largest) as session.jsonl for the primary trace / back-compat.
  scount=0
  while IFS= read -r j; do
    [ -f "$j" ] || continue
    gcloud storage cp "$j" "${DEST}/sessions/$(basename "$j")" 2>/dev/null && scount=$((scount + 1))
  done < <(find "${HOME}/.claude/projects" -name '*.jsonl' -type f 2>/dev/null)
  log "sessions: archived ${scount} agent transcript(s) -> ${DEST}/sessions/"
  MAKER_J="$(find "${HOME}/.claude/projects" -name "${MAKER_SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)"
  [ -n "${MAKER_J}" ] || MAKER_J="$(find "${HOME}/.claude/projects" -name '*.jsonl' -type f -print0 2>/dev/null | xargs -0 ls -S 2>/dev/null | head -1)"
  [ -n "${MAKER_J}" ] && gcloud storage cp "${MAKER_J}" "${DEST}/session.jsonl" 2>/dev/null && log "transcript -> ${DEST}/session.jsonl (maker)" || log "WARN session.jsonl upload failed"
fi
log "loop ${LOOP} done (verdict=${VERDICT})."
# Exit on the VERIFIER's verdict, NOT on whether a push happened. PUSHED=false is CORRECT and expected
# for a push:none loop (labels-only triage), an idle run, or a dry run — none of those is a failure.
# The "work produced must be pushed" guarantee lives IN the verifiers (their persistence check sets
# verdict=FAIL), which is the right place for it. (Bug found dogfooding the triage loop: a push:none
# loop passed verification but the container exited 1 because PUSHED was false.)
[ "${VERDICT}" = "FAIL" ] && exit 1 || exit 0
