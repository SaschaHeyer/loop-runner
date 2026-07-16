# Headless browser support — when a loop must drive a real UI, not just an API

Some loops need to interact with a web page the way a person would: click a button, fill a form,
submit it, read what rendered back. An HTTP client (`curl`, `WebFetch`) can hit an endpoint, but it
cannot tell you whether a button is wired to the right handler, whether a form actually submits,
whether the page threw a JavaScript error, or whether what rendered matches what the API returned. A
loop that verifies a deployed UI, reproduces a browser-only bug, or walks a multi-step web flow needs
a **real browser**.

The runner ships one: headless Chromium plus Google's
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) server, exposed to the
agent as MCP tools (`navigate_page`, `click`, `fill`, `take_snapshot`, `take_screenshot`, `wait_for`,
`evaluate_script`, …). Chrome only launches on first tool use, so the cost is paid only by loops that
actually drive a browser.

## Opting in — one line, zero extra config

A loop declares it wants a browser simply by naming the `chrome-devtools` tools somewhere it already
configures tools. There is no separate flag or spec field. The runner detects the intent and wires
everything up per run.

Two equivalent ways to opt in:

- **Main agent** — list it in the loop's `allowed_tools` in `loop.yaml`:
  ```yaml
  allowed_tools: "Bash,Read,mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__click,..."
  ```
- **A sub-agent** — list the tools in the sub-agent's `tools:` frontmatter (e.g. an independent
  verifier that walks the deployed app). The runner scans the loop's `agents/*.md` too:
  ```markdown
  ---
  name: my-checker
  tools: Bash, Read, mcp__chrome-devtools__navigate_page, mcp__chrome-devtools__click, mcp__chrome-devtools__fill, mcp__chrome-devtools__take_snapshot, mcp__chrome-devtools__wait_for
  ---
  ```

**Use the real tool names.** MCP tools are named `mcp__<server>__<tool>` — here the server is
`chrome-devtools`, so the tools are `mcp__chrome-devtools__navigate_page`, `mcp__chrome-devtools__click`,
and so on. A bare `chrome-devtools` in a tools list refers to nothing and silently grants no browser —
the agent will just fall back to an HTTP client without telling you. List the specific tools you need.

If a loop mentions none of these, nothing changes: the MCP server is never registered and the loop's
agent invocation is byte-identical to a non-browser loop.

## What the runner does per run

When [`entrypoint.sh`](../loop-runner/entrypoint.sh) sees a browser opt-in, it:

1. writes an MCP config to `<work-dir>/.claude/mcp.json` registering the `chrome-devtools` server,
   pointed at the in-image Chromium wrapper;
2. passes `--mcp-config <that file>` to the agent (`claude`) so the tools are live for the session;
3. adds `mcp__chrome-devtools` to the main agent's allowed tools (sub-agents still gate on their own
   `tools:`);
4. git-excludes `.claude/mcp.json` from the work tree so the runtime config is never committed.

The MCP server itself and Chromium are baked into the image (see
[`loop-runner/Dockerfile`](../loop-runner/Dockerfile)); nothing is downloaded at run time.

## How Chromium is launched (and why)

The image installs Debian's `chromium` and wraps it in a small launcher that every browser session
uses. The wrapper's flags exist for the container environment:

| Flag | Why |
|------|-----|
| `--headless=new` | no display in a Cloud Run container |
| `--no-sandbox` | the container runs as root; Chromium's sandbox refuses to start as root |
| `--disable-dev-shm-usage` | containers have a tiny `/dev/shm`; without this Chromium crashes on larger pages |
| `--disable-gpu` | no GPU in the sandbox |
| `--ignore-certificate-errors` | see below |

**The certificate flag matters.** The runner routes egress through a local
[TLS-intercepting proxy](proxy.md) so it can inject credentials on the wire. Chromium, unlike the
system tools, trusts its **own** certificate store — not the system store where the proxy's CA is
installed — so it would reject every intercepted HTTPS response. `--ignore-certificate-errors` lets
the browser work through the proxy. Treat the in-container browser as a tool for reaching **test and
preview targets**, not for handling anything where certificate validation is a security requirement.

## Cost and limits — budget your turns

Driving a browser is **turn-expensive**. A single flow — navigate, snapshot, click, fill, submit,
snapshot again — can be dozens of agent turns, because the agent re-snapshots the page between actions
to find current element handles. A realistic end-to-end walk plus any follow-on work easily runs past
a small turn cap. Set `max_turns` in the loop's `loop.yaml` accordingly (a browser-driving verifier
typically wants roughly double a non-browser loop's budget). If the agent runs out of turns mid-walk,
that is a budget problem, not a browser failure.

Other notes:

- **Element handles are snapshot-scoped.** After the page changes, handles from an earlier snapshot go
  stale and a `click`/`fill` against them errors; the agent is expected to re-`take_snapshot` and retry
  with fresh handles. Occasional stale-handle errors in a transcript are normal, not a defect.
- **One browser per run.** The MCP server manages a single Chromium instance for the agent session.
- **Verify from the transcript, not the summary.** As with everything else (see [sessions.md](sessions.md)),
  the ground-truth check that a loop *actually* used the browser is its archived transcript — grep it
  for `mcp__chrome-devtools__` tool calls. An agent that claims it "opened the browser" but whose
  transcript shows only HTTP calls did not.
