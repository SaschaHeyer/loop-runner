"""mitmproxy addon: inject auth credentials on egress.

A local mitmproxy sits in front of the agent's outbound HTTP(S). A tool calls an API with NO
Authorization header; this addon injects the right credential on the wire, so the secret never
enters the agent's context, prompt, or filesystem. Tools keep calling *.googleapis.com /
api.stripe.com / api.resend.com / api.cloudflare.com with no auth of their own. Full design and
security properties: docs/proxy.md.

Rule: inject ONLY when the request has no Authorization header. That way the agent CLI's own
model auth (Claude Code on Vertex, or an Anthropic/Gemini key) is never doubled — it sets its
own header, so we leave it alone; a tool that sends none gets the credential filled in.

Credentials:
  * *.googleapis.com   -> Bearer <token from the metadata server> (the Job's service account)
  * github.com         -> Basic base64("x-access-token:<GITHUB_PAT>")
  * api.stripe.com     -> Bearer <STRIPE_SECRET_KEY>      (Secret Manager -> env)
  * api.resend.com     -> Bearer <RESEND_API_KEY>
  * api.cloudflare.com -> Bearer <CLOUDFLARE_API_TOKEN>
"""
from __future__ import annotations

import base64
import json
import os
import time
import urllib.request

from mitmproxy import http

GCP_PROJECT = os.environ.get("GCP_PROJECT", "your-gcp-project")

# Third-party APIs: domain -> (connector name, env var, header template). Loaded from the connector
# registry (connectors/registry.json) so adding a connector is DATA, not code (M11b) — the same file
# deploy.sh reads to wire --set-secrets. Value pulled from env (the Job sets these via --set-secrets
# from Secret Manager). Connector name gates injection (M5). gcp + github are NOT env-bearer (SA token /
# Basic PAT) and stay special-cased below, intentionally absent from the registry.
_BUILTIN_API = {
    "api.resend.com": ("resend", "RESEND_API_KEY", "Bearer {}"),
    "api.stripe.com": ("stripe", "STRIPE_SECRET_KEY", "Bearer {}"),
    "api.cloudflare.com": ("cloudflare", "CLOUDFLARE_API_TOKEN", "Bearer {}"),
}


def _load_registry() -> dict:
    """Build the domain -> (connector, env, header) map from connectors/registry.json. Falls back to
    the built-in map if the file is missing or unparseable, so a bad/absent registry never fails the
    proxy closed (it just injects the known built-ins). Override the path with LOOP_CONNECTOR_REGISTRY."""
    path = os.environ.get("LOOP_CONNECTOR_REGISTRY") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "connectors", "registry.json")
    try:
        with open(path) as f:
            reg = json.load(f)
        api = {}
        for name, c in reg.items():
            if name.startswith("_") or not isinstance(c, dict):
                continue  # skip _comment and any non-connector keys
            dom, env, hdr = c.get("domain"), c.get("env"), c.get("header", "Bearer {}")
            if dom and env:
                api[dom] = (name, env, hdr)
        return api or _BUILTIN_API
    except Exception:
        return _BUILTIN_API


_API = _load_registry()

# M5 — scope injection to the loop's declared `connectors:`. The entrypoint exports LOOP_CONNECTORS
# (space-separated) + LOOP_CONNECTORS_ENFORCE=1. When enforcing, inject ONLY for declared connectors,
# so a `connectors: []` loop physically cannot reach an authenticated API (least privilege). Running
# the proxy standalone (no enforce flag) injects everything, preserving the prior behavior.
_ENFORCE = os.environ.get("LOOP_CONNECTORS_ENFORCE") == "1"
_ALLOWED = set(os.environ.get("LOOP_CONNECTORS", "").split())


def _allowed(connector: str) -> bool:
    return (not _ENFORCE) or (connector in _ALLOWED)

# A token cache for the metadata-server (service account) token.
_gcp = {"token": None, "exp": 0.0}
# An opener that NEVER goes through the proxy (the metadata fetch must not self-loop).
_direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _gcp_token() -> str | None:
    now = time.time()
    if _gcp["token"] and now < _gcp["exp"] - 60:
        return _gcp["token"]
    # Cloud Run / GCE metadata server -> the Job's service account access token.
    try:
        req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/"
            "service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"},
        )
        with _direct.open(req, timeout=5) as r:
            d = json.load(r)
        _gcp["token"] = d["access_token"]
        _gcp["exp"] = now + int(d.get("expires_in", 3000))
        return _gcp["token"]
    except Exception:
        # Local testing fallback: a token handed in via env.
        tok = os.environ.get("GCP_ACCESS_TOKEN")
        if tok:
            _gcp["token"] = tok
            _gcp["exp"] = now + 300
        return tok


def _has_auth(flow: http.HTTPFlow) -> bool:
    return any(k.lower() == "authorization" for k in flow.request.headers.keys())


def request(flow: http.HTTPFlow) -> None:
    if _has_auth(flow):
        return  # never double-inject — protects the agent CLI's own auth
    host = flow.request.pretty_host

    # Google APIs (Firestore, Secret Manager, IAM Credentials, Vertex, ...) — connector "gcp"
    if host == "googleapis.com" or host.endswith(".googleapis.com"):
        if _allowed("gcp"):
            tok = _gcp_token()
            if tok:
                flow.request.headers["Authorization"] = f"Bearer {tok}"
                flow.request.headers.setdefault("X-Goog-User-Project", GCP_PROJECT)
        return  # not declared -> no injection; the request goes out unauthenticated (401/403)

    # GitHub (git-over-https + api.github.com), Basic with the PAT — connector "github"
    if host == "github.com" or host.endswith(".github.com"):
        if _allowed("github"):
            pat = os.environ.get("GITHUB_PAT", "")
            if pat:
                basic = base64.b64encode(f"x-access-token:{pat}".encode()).decode()
                flow.request.headers["Authorization"] = f"Basic {basic}"
        return

    # Third-party APIs — each gated by its connector name
    for dom, (conn, env_name, tmpl) in _API.items():
        if host == dom or host.endswith("." + dom):
            if _allowed(conn):
                val = os.environ.get(env_name, "")
                if val:
                    flow.request.headers["Authorization"] = tmpl.format(val)
            return
