#!/usr/bin/env bash
# Deploy ONE loop: build the (loop-agnostic) harness image, deploy a Cloud Run Job named
# loop-<name>, and — if the loop is scheduled — wire a Cloud Scheduler cron from its loop.yaml.
#
# The image is the SAME for every loop; which loop runs is the LOOP env var on the Job, and the
# per-loop settings (model, turns, prompt, verifier) are read from loops/<name>/loop.yaml at
# runtime. So editing a spec takes effect on the next run with NO redeploy.
#
# Secrets: only github-pat is always injected (the harness needs it to clone + push). Every other
# secret is wired ONLY when the loop declares that connector, from connectors/registry.json. So a
# loop reaches exactly the credentials it asked for and nothing more.
#
# Usage:  LOOP=hello-world ./deploy.sh          # build + deploy + cron (from schedule:)
#         LOOP=my-loop BUILD=0 ./deploy.sh       # reuse the built image, just deploy the Job
set -euo pipefail

# M9: a real usage stub so a misconfigured invocation fails with guidance, not a set -u error.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
deploy.sh — build the loop-runner image + deploy Cloud Run Job loop-<name> (+ cron if scheduled).

  LOOP=<name> ./deploy.sh                 build + deploy Job loop-<name> (+ Scheduler cron from schedule:)
  LOOP=<name> BUILD=0 ./deploy.sh         reuse the existing image, just (re)deploy the Job
  LOOP=<name> SMOKE=1 ./deploy.sh         constrained harness validation (no loop actions)
  LOOP=<name> CREATE_CRON=0 ./deploy.sh   deploy the Job without a scheduler cron
  LOOPS_ROOT=/path/to/repo LOOP=<name> ./deploy.sh   deploy a loop whose spec lives in ANOTHER repo

Env overrides: PROJECT (default your-gcp-project), REGION (us-central1), AGENT_CLI (claude|agy),
  REPO_FULL_NAME (this engine repo), SCHEDULE + TIMEZONE (from the spec). Secrets injected
  match the loop's connectors: list. LOOP must match a loops/<name>/loop.yaml.

  LOOPS_ROOT (default: this repo's root) — the engine is loop-agnostic and its Docker image never
  contains your loops; they are cloned at runtime from REPO_FULL_NAME. Point LOOPS_ROOT at a local
  checkout of that loops repo when your loop specs live in a DIFFERENT repo than this engine, so
  deploy can read loops/<name>/loop.yaml to configure the Job. Also set REPO_FULL_NAME to that same
  loops repo (what the Job clones at runtime).
USAGE
  exit 0
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # loop-runner/ (the engine; also the build context)
REPO_ROOT="$(cd .. && pwd)"
# Where the loop SPECS live. Defaults to this repo (engine + loops together). Override to deploy loops
# that live in a separate repo — the engine image is the same regardless, only the spec source moves.
LOOPS_ROOT="${LOOPS_ROOT:-${REPO_ROOT}}"

# ---------- which loop ----------
LOOP="${LOOP:?set LOOP=<name>, e.g. LOOP=ceo ./deploy.sh  (matches loops/<name>/loop.yaml)}"
SPEC="${LOOPS_ROOT}/loops/${LOOP}/loop.yaml"
[ -f "${SPEC}" ] || { echo "ERROR: no spec at ${LOOPS_ROOT}/loops/${LOOP}/loop.yaml (set LOOPS_ROOT if your loops live in another repo)"; exit 1; }
eval "$(python3 ./parse_spec.py "${SPEC}")"           # -> LOOP_MODEL, LOOP_SCHEDULE, LOOP_TRIGGER, ...

# ---------- config (override via env) ----------
PROJECT="${PROJECT:-your-gcp-project}"
REGION="${REGION:-us-central1}"
VERTEX_REGION="${VERTEX_REGION:-global}"              # Claude 4.6/4.8 serve from the GLOBAL endpoint
JOB="${JOB:-loop-${LOOP}}"
AR_REPO="${AR_REPO:-ceo-agent}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/loop-runner:latest"
SA="${SA:-loop-runner@${PROJECT}.iam.gserviceaccount.com}"   # scoped runner identity
REPO_FULL_NAME="${REPO_FULL_NAME:-SaschaHeyer/loop-runner}"
AGENT_CLI="${AGENT_CLI:-claude}"
SMOKE="${SMOKE:-0}"                                   # 1 = constrained harness validation (no loop actions)
BUILD="${BUILD:-1}"                                   # 0 = reuse the existing image (skip the rebuild)
SCHEDULE="${SCHEDULE:-${LOOP_SCHEDULE:-0 * * * *}}"   # from the spec; override with SCHEDULE=...
TIMEZONE="${TIMEZONE:-${LOOP_TIMEZONE:-Etc/UTC}}"     # IANA zone for the cron (spec timezone:); Scheduler handles DST
SESSIONS_BUCKET="${SESSIONS_BUCKET:-${PROJECT}-loop-sessions}"   # per-run transcript archive (namespaced by loop)
# A 'schedule' loop gets a cron; a 'manual' loop deploys the Job only.
if [ "${LOOP_TRIGGER:-schedule}" = "schedule" ]; then CREATE_CRON="${CREATE_CRON:-1}"; else CREATE_CRON="${CREATE_CRON:-0}"; fi

echo ">> loop=${LOOP} model=${LOOP_MODEL:-?} trigger=${LOOP_TRIGGER:-?} project=${PROJECT} region=${REGION} job=${JOB} smoke=${SMOKE} cron=${CREATE_CRON} build=${BUILD}"

# ---------- secrets: inject only what the loop's connectors: declare (least privilege) ----------
# github-pat is ALWAYS injected (the harness needs it to clone + push, regardless of connectors).
# Each other connector maps to one Secret Manager secret via the connector registry
# (connectors/registry.json — the SAME file proxy_addon.py reads, M11b), so adding a connector is a
# registry entry + a secret, no deploy.sh edit. gcp (SA-native, no secret) and github (always injected
# above) are the two non-env-bearer exceptions and are skipped here. A declared connector missing from
# the registry is a hard error (fail fast, don't silently deploy without its credential). The secret
# must exist in THIS project (${PROJECT}) — an isolated CEO has only what it owns.
REGISTRY="$(dirname "$0")/connectors/registry.json"
# A loop may declare its OWN connectors in loops/<name>/connectors.json (in the loops repo), merged over
# the generic engine registry below. This keeps loop-specific connector names out of this task-agnostic
# engine repo -- a loop that talks to some product defines that connector alongside its own spec.
LOOP_REGISTRY="${LOOPS_ROOT}/loops/${LOOP}/connectors.json"
SECRETS="GITHUB_PAT=github-pat:latest"
for c in ${LOOP_CONNECTORS:-}; do
  case "$c" in
    gcp|github) continue ;;   # gcp = SA native (no secret); github = always injected above
  esac
  # Look up env + secret for connector $c in the engine registry, then the per-loop one (per-loop wins).
  frag="$(python3 -c "import json,os
reg={}
for p in ['${REGISTRY}', '${LOOP_REGISTRY}']:
    if os.path.exists(p):
        try: reg.update({k:v for k,v in json.load(open(p)).items() if not k.startswith('_')})
        except Exception: pass
c=reg.get('$c')
print(f\"{c['env']}={c['secret']}:latest\" if isinstance(c,dict) and c.get('env') and c.get('secret') else '')" 2>/dev/null)"
  if [ -z "${frag}" ]; then
    echo "ERROR: connector '$c' is declared by loop '${LOOP}' but not defined in ${REGISTRY} or ${LOOP_REGISTRY}" >&2
    echo "       add an entry (secret/env, plus domain/header if proxy-injected) to loops/${LOOP}/connectors.json, or remove it from connectors:." >&2
    exit 1
  fi
  SECRETS="${SECRETS},${frag}"
done
echo ">> connectors=[${LOOP_CONNECTORS:-}] -> secrets: ${SECRETS}"

# ---------- enable APIs ----------
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com aiplatform.googleapis.com \
  --project="${PROJECT}"

# ---------- Artifact Registry + transcript bucket ----------
gcloud artifacts repositories create "${AR_REPO}" --repository-format=docker \
  --location="${REGION}" --project="${PROJECT}" 2>/dev/null || true
gcloud storage buckets create "gs://${SESSIONS_BUCKET}" --location="${REGION}" --project="${PROJECT}" 2>/dev/null || true

# ---------- build (once; the image is loop-agnostic) ----------
if [ "${BUILD}" = "1" ]; then
  echo ">> building ${IMAGE}  (one harness image serves every loop)"
  gcloud builds submit --tag "${IMAGE}" --project="${PROJECT}" .
else
  echo ">> BUILD=0 — reusing existing image ${IMAGE}"
fi

# ---------- IAM the agent needs (Vertex) ----------
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" --role="roles/aiplatform.user" --condition=None >/dev/null

# ---------- deploy the Job ----------
# NOTE: model / max_turns are deliberately NOT set as env — they come from loop.yaml at runtime,
# so the spec is the single source of truth. LOOP selects which spec the harness reads.
echo ">> deploying job ${JOB}"
gcloud run jobs deploy "${JOB}" \
  --image="${IMAGE}" --region="${REGION}" --project="${PROJECT}" \
  --service-account="${SA}" \
  --cpu=4 --memory=8Gi --task-timeout=3600 --max-retries=0 --tasks=1 \
  --set-env-vars="AGENT_CLI=${AGENT_CLI},LOOP=${LOOP},REPO_FULL_NAME=${REPO_FULL_NAME},GCP_PROJECT=${PROJECT},SECRET_MANAGER_PROJECT=${PROJECT},DEPLOY_SA=${SA},COST_LOG=cost_log.yaml,CLAUDE_CODE_USE_VERTEX=1,ANTHROPIC_VERTEX_PROJECT_ID=${PROJECT},CLOUD_ML_REGION=${VERTEX_REGION},SMOKE=${SMOKE},SESSIONS_BUCKET=${SESSIONS_BUCKET}" \
  --set-secrets="${SECRETS}"

# ---------- Cloud Scheduler -> run the Job (OAuth as the runner SA; needs run.invoker on the job) ----------
if [ "${CREATE_CRON}" = "1" ]; then
  gcloud run jobs add-iam-policy-binding "${JOB}" --region="${REGION}" --project="${PROJECT}" \
    --member="serviceAccount:${SA}" --role="roles/run.invoker" >/dev/null 2>&1 || true

  RUN_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"
  if gcloud scheduler jobs describe "${JOB}-cron" --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
    CMD=update
  else
    CMD=create
  fi
  echo ">> ${CMD} scheduler ${JOB}-cron (${SCHEDULE} ${TIMEZONE})"
  gcloud scheduler jobs ${CMD} http "${JOB}-cron" \
    --location="${REGION}" --project="${PROJECT}" \
    --schedule="${SCHEDULE}" --time-zone="${TIMEZONE}" \
    --uri="${RUN_URI}" --http-method=POST \
    --oauth-service-account-email="${SA}"
elif [ "${LOOP_TRIGGER:-}" = "event" ]; then
  echo ">> trigger=event — no cron. This Job is fired by an external event source that calls"
  echo "   'gcloud run jobs execute ${JOB}' (e.g. a GitHub Actions workflow via Workload Identity"
  echo "   Federation — see .github/workflows/ and README 'Triggers & events'). Test it directly with:"
  echo "   gcloud run jobs execute ${JOB} --region=${REGION} --project=${PROJECT}"
else
  echo ">> skipping Cloud Scheduler (trigger=${LOOP_TRIGGER:-manual} / CREATE_CRON=0). Run manually:"
  echo "   gcloud run jobs execute ${JOB} --region=${REGION} --project=${PROJECT}"
fi

echo ">> done."
echo "   Run once now:  gcloud run jobs execute ${JOB} --region=${REGION} --project=${PROJECT}"
echo "   Tail logs:     gcloud beta run jobs executions logs read --job=${JOB} --region=${REGION} --project=${PROJECT}"
