#!/usr/bin/env bash
# Scaffold a new loop from loops/_template/.
#
#   ./new-loop.sh <name>       # name: lowercase kebab-case, e.g. link-checker
#
# Creates loops/<name>/ with a filled-in loop.yaml, prompt.md, system.md, verify.sh and state/.
# Then edit those and deploy:  cd loop-runner && LOOP=<name> ./deploy.sh
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME="${1:?usage: ./new-loop.sh <name>   (lowercase kebab-case, e.g. link-checker)}"
echo "$NAME" | grep -Eq '^[a-z][a-z0-9-]*$' \
  || { echo "ERROR: name must be lowercase kebab-case: ^[a-z][a-z0-9-]*$"; exit 1; }
[ "$NAME" = "_template" ] && { echo "ERROR: '_template' is reserved"; exit 1; }

DEST="loops/${NAME}"
[ -e "$DEST" ] && { echo "ERROR: ${DEST} already exists"; exit 1; }

cp -r loops/_template "$DEST"
# Fill the __NAME__ placeholder in every file (portable in-place edit for macOS + Linux).
find "$DEST" -type f -print0 | while IFS= read -r -d '' f; do
  sed "s/__NAME__/${NAME}/g" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
done
chmod +x "$DEST/verify.sh"

echo "created ${DEST}/ from the template:"
find "$DEST" -type f | sort | sed 's/^/  /'
cat <<EOF

next:
  1. edit ${DEST}/loop.yaml       (schedule, model, push mode, and an HONEST tier)
     - set connectors: CONSCIOUSLY — it is ENFORCED (M5). List only what the loop uses
       (gcp/github/stripe/resend/cloudflare); [] means it reaches NO authenticated API.
     - set budget_usd — it is checked (M4): a breach is flagged loudly in the cost log.
  2. write ${DEST}/prompt.md      (the task) and make ${DEST}/verify.sh a REAL check
  3. (optional) register it in your own loop index
  4. smoke, then run:
       cd loop-runner && LOOP=${NAME} SMOKE=1 ./deploy.sh
       gcloud run jobs execute loop-${NAME} --region=us-central1 --project=<your-project> --wait
EOF
