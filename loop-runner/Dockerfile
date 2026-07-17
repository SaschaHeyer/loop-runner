# Loop runner — Cloud Run Job image (in-process, task-agnostic loop harness).
# The agent CLI runs as a subprocess of entrypoint.sh, so the harness can deterministically
# commit/push/verify after it exits. This image is LOOP-AGNOSTIC: which loop runs is the LOOP
# env var, and the repo (with loops/<name>/loop.yaml) is CLONED at runtime — only the harness
# lives in the image.
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl unzip jq ca-certificates gnupg \
      python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Google Cloud SDK (gcloud; auth is native via the Job's service account / metadata server).
RUN curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz \
      | tar -xz -C /opt \
    && /opt/google-cloud-sdk/install.sh --quiet --path-update=true
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# Firestore emulator (+ the headless JRE it needs). Lets a loop's verifier run the app's test suite
# against REAL Firestore semantics locally, catching backend-shape bugs (ordering on an unstored field,
# document-id parsing) that an in-memory test fake silently hides — before they reach the deploy check.
# Pre-installed so there's no run-time download; a loop that doesn't use Firestore simply never starts it.
RUN apt-get update && apt-get install -y --no-install-recommends default-jre-headless \
    && rm -rf /var/lib/apt/lists/* \
    && gcloud components install cloud-firestore-emulator --quiet

# GitHub CLI (some CEO tools shell `gh`).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Agent CLIs.
#   Claude Code (default maker; runs on Vertex via CLAUDE_CODE_USE_VERTEX=1).
RUN npm install -g @anthropic-ai/claude-code@latest firebase-tools@latest

# Headless browser support (for loops that must drive a real browser, e.g. a verifier walking the
# deployed UI instead of curling the API). Chromium from Debian + Google's chrome-devtools MCP server,
# which exposes navigate/click/fill/screenshot tools. entrypoint.sh registers the MCP server per-run
# (see §3c) so a loop or sub-agent that lists chrome-devtools in its tools gets a real browser.
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
# Container runs as root and has no /dev/shm to speak of; wrap chromium so every launch is headless,
# sandbox-off, and shm-disabled. chrome-devtools-mcp points at this wrapper via --executablePath.
# --ignore-certificate-errors: the run's mitmproxy intercepts HTTPS, but Chromium trusts its own cert
# store, not the system one where the proxy CA is installed — so it would reject every intercepted cert.
# Acceptable here: the browser only ever hits throwaway test previews, never anything sensitive.
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage --headless=new --ignore-certificate-errors "$@"\n' \
      > /usr/local/bin/chromium-headless \
    && chmod +x /usr/local/bin/chromium-headless
ENV CHROME_BIN=/usr/local/bin/chromium-headless \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/chromium-headless
RUN npm install -g chrome-devtools-mcp@latest puppeteer-core@latest
# Make globally-installed modules (puppeteer-core) resolvable by loop helper scripts run from any cwd
# (e.g. a loop's tools/*.js that drives Chromium with an injected session -- see zendesk_shot.js).
ENV NODE_PATH=/usr/local/lib/node_modules
#   Antigravity CLI (`agy`) — OPTIONAL alternative backend. Install per the official method at
#   https://github.com/google-antigravity/antigravity-cli, then set AGENT_CLI=agy on the Job.
#   (Left commented so the build doesn't depend on an unverified install command.)
# RUN curl -fsSL https://raw.githubusercontent.com/google-antigravity/antigravity-cli/main/install.sh | sh

# Local egress proxy (reproduces the managed runtime's credential injection) in its own venv.
RUN python3 -m venv /opt/mitm && /opt/mitm/bin/pip install --no-cache-dir mitmproxy \
    && ln -s /opt/mitm/bin/mitmdump /usr/local/bin/mitmdump

# Let the agent pip-install extra deps at runtime on Debian's managed python; pre-seed common ones.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN pip3 install --no-cache-dir --break-system-packages requests pyyaml google-auth

# Harness.
WORKDIR /harness
COPY entrypoint.sh proxy_addon.py log_cost.py parse_spec.py stream_steps.py /harness/
COPY hooks/ /harness/hooks/
# Connector registry (M11b): proxy_addon.py reads /harness/connectors/registry.json at startup to build
# its auth-injection map. Ship it in the image (harness data, not runtime-cloned) — without it the proxy
# silently falls back to the built-in resend/stripe/cloudflare map and a registry-only connector (slack)
# would not inject.
COPY connectors/registry.json /harness/connectors/registry.json
RUN chmod +x /harness/entrypoint.sh /harness/hooks/*.sh

# Runs as root so the entrypoint can install the proxy CA into the system trust store at runtime.
# The real security boundary is the Job's scoped service account + Cloud Run isolation.
ENTRYPOINT ["/harness/entrypoint.sh"]
