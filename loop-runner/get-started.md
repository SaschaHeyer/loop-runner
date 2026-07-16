# Getting Started with the Loop Runner

Welcome to the **Loop Runner**! This guide is a friendly, step-by-step tutorial designed to help you set up, run, deploy, and extend your own automated agent workflows (known as **Loops**).

---

## What is a Loop?

A **Loop** is any repeatable agent workflow that runs **completely headless and unattended in the cloud** under a standard lifecycle:
$$\text{TRIGGER} \longrightarrow \text{EXECUTE} \longrightarrow \text{VERIFY} \longrightarrow \text{RECORD} \longrightarrow \text{STOP}$$

This design allows you to run powerful AI agents in the background (such as overnight or on cron schedules) without requiring a human operator, an active terminal session, or manual input.

Examples of loops include:
*   An autonomous **AI CEO** running a live business.
*   An **Error Sweep** loop that scans logs, identifies bugs, and proposes pull requests with fixes in the background.
*   A **Slack-to-Issues** triage bot that auto-responds to customer queries.

The **Loop Runner** is the invariant "harness" (or engine) that hosts and executes these loops headless inside a **Google Cloud Run Job**. It manages auth proxying, state persistence, git commits/pushes, runbook verification, and cost logging.


---

## Quick Setup

Before creating or running loops, make sure your local environment is configured:

1.  **GCP Authentication**: Authenticate with your Google Cloud account:
    ```bash
    gcloud auth login
    gcloud auth application-default login
    ```
2.  **Target GCP Project**: Ensure you are pointing to the correct GCP project:
    ```bash
    gcloud config set project your-gcp-project
    ```
3.  **Docker**: Ensure Docker is installed and running locally for dry-run testing.

---

## Step 1: Create a New Loop

We provide an automatic scaffolding script to create a new loop from a template. Run it from the repository root:

```bash
./new-loop.sh <your-loop-name>
```
*Note: Use lowercase kebab-case (e.g., `link-checker` or `slack-issue-bot`).*

This creates a new folder under `loops/<your-loop-name>/` containing the following core files:

| File | Purpose | What to do with it |
| :--- | :--- | :--- |
| **`loop.yaml`** | The loop specification and config. | Edit models, schedules, and connectors here. |
| **`prompt.md`** | The kickoff instruction file for the agent. | Write the specific goal and instructions for your agent here. |
| **`system.md`** | Optional per-loop system prompt overrides. | Fine-tune the agent's core identity or constraints if needed. |
| **`verify.sh`** | Bash script executed at the end of the run. | Write assertions to verify the agent successfully completed its task (exit `0` = pass). |
| **`skills/`** | Optional custom per-loop skills. | Add any loop-specific runbooks or custom scripts here. |

---

## Step 2: Configure Your Spec (`loop.yaml`)

Open `loops/<your-loop-name>/loop.yaml`. Here are the key fields to configure, including how to connect external target repositories, manage memory, and load external skills or shared databases:

```yaml
model: "claude-sonnet-4-6"      # Choose the AI model (e.g. claude-sonnet-4-6, claude-opus-4-8)
turns: 40                       # Maximum turn cap before stopping to avoid runaways
budget_usd: 5.00                # Set an honest budget check
push: pr                        # pr (create pull request) | main (direct ship) | none (read-only)

# Scoped API credentials (Least Privilege - strictly enforced)
connectors:
  - gcp
  - github

# Schedule (Optional: deploys a Cloud Scheduler cron)
schedule: "0 05 * * *"          # Standard cron expression
timezone: "Europe/Berlin"       # Optional: DST-safe IANA timezone

# --- Memory, Repositories, & Shared Commons ---

# Memory / Persistence directory (git-backed state)
memory: loops/__NAME__/state     # Where this loop remembers (repo-relative)

# Work Repository (Two-Repo Mode)
# repo: "your-org/your-work-repo" # Optional: target repository where agent operates

# External Skill Repositories (Git)
# skills:
#   - "SaschaHeyer/shared-agent-skills"     # Optional: external skills to clone and mount

# Shared Commons Repositories (Fleet-wide read/append learnings)
# shared:
#   - "SaschaHeyer/shared-fleet-learnings"  # Optional: cross-loop shared databases/learnings

# Loop Quality Tier
tier: "2"                       # 1 (exists) | 2 (runs) | 3 (ground-truth) | 4 (self-judge) | 5 (human)
```

### 1. Connecting Target Repositories (Two-Repo Mode vs. Single-Repo)
By default, the Loop Runner operates in **Single-Repo Mode**, meaning the cloned loop library is both the *source of the specification* and the *workspace where the agent writes code and commits*.

For real-world use, you will want **Two-Repo Mode** to connect your loop to any other repository (like a business application or a target website):
*   **How to Enable**: Set the `repo:` field to your target repository:
    ```yaml
    repo: "your-org/your-work-repo"
    ```
*   **How it Works**: At runtime, the Loop Runner clones **both** repositories. The library repo (containing your specifications, prompts, verifier) remains completely **read-only** so it is never polluted, while the agent runs, makes changes, and raises pull requests **entirely inside the connected target repository**.

### 2. Declaring External Skill Repositories
If you have a shared suite of skills (e.g., standard debugging runbooks or generic tools) that multiple loops should share:
*   Add the repository names (in `owner/repo` format) to the `skills:` list:
    ```yaml
    skills:
      - "SaschaHeyer/shared-agent-skills"
    ```
*   The harness will automatically clone these repositories from GitHub using your stored credentials and mount them into the agent's workspace alongside your local skills.

### 3. Memory & State Persistence (`memory:`)
Loops are built to be robust against "Groundhog Day" syndrome (the agent forgetting everything it did in previous runs).
*   **The State Folder**: The spec reserves a repository-relative path under `memory:` (typically `loops/<your-loop-name>/state/`).
*   **Persistence Guarantee**: When the agent finishes, the Loop Runner commits and pushes any state files (such as history files, execution trackers, or intermediate databases) back to Git automatically. On the next trigger/run, the agent starts with its memory intact.

### 4. Shared Fleet-wide Commons (`shared:`)
While skills are read-only references, **Shared Commons Repositories** represent **shared writeable databases** that multiple distinct loops can append to:
*   **How to use**: List any shared repositories in your `shared:` block.
*   **The Rule**: Loops can read other loops' learnings or database rows, and append their own entries (typically under `<commons-repo>/<your-loop-name>/`).
*   **Safe Push**: Since multiple separate running jobs can push to the same commons repo simultaneously, the harness manages conflict-free pulls and rebases automatically on completion.

### 5. Loop Quality Tiers (`tier:`)
Quality tiers represent the honesty and maturity of your loop development:
*   `1 (exists)`: Initial scaffold is present.
*   `2 (runs)`: Runs end-to-end but is not yet fully validated or correct.
*   `3 (ground-truth)`: Output is validated against real ground-truth data.
*   `4 (self-judge)`: The agent can evaluate and judge its own output.
*   `5 (human)`: Production-grade quality worthy of shipping live to human customers.

### 6. Where Should Durable Information Live?
As a loop's workload grows — especially a backlog-draining pattern, where the loop works through a
queue of GitHub issues one at a time — you'll accumulate facts that don't belong copy-pasted into
every single task. There are four distinct places information can live, each with a different scope:

| Lives in | Scope | Read by | Best for |
| :--- | :--- | :--- | :--- |
| `system.md` (this loop's spec, library repo) | This **loop's** durable persona, across every run | Every invocation of this specific loop | The agent's identity and constraints — "you are a strict, adversarial verifier" — independent of whatever the work repo contains |
| `prompt.md` (this loop's spec, library repo) | This **run's** kickoff instructions | Every invocation of this specific loop | The generic task description — "pick the next ready issue and build it" |
| The work repo's own `CLAUDE.md` (repo root, set via `repo:` in Two-Repo Mode) | Facts about the **project being built**, independent of which loop or task touches it | Any agent whose cwd is that repo — Claude Code auto-loads `CLAUDE.md` with zero config | Architecture decisions, coding conventions, "always/never do X in this codebase" — config every future task needs |
| An individual task or issue body | **One** unit of work | Whichever run picks up that specific task | Acceptance criteria and reference links specific to that one feature |

**The signal to watch for**: if you catch yourself pasting the same background fact into every new
issue a backlog-draining loop works through, that's a sign it belongs in the work repo's `CLAUDE.md`
instead. Write it once there, and every future task's agent picks it up automatically — because
Claude Code loads `CLAUDE.md` from its working directory on every run, not because someone remembered
to repeat it.

> [!IMPORTANT]
> **Least Privilege for Connectors**: The auth proxy only injects credentials for APIs declared under the `connectors:` list. If you keep this empty (`[]`), the loop will run in an offline/read-only sandbox and cannot access authenticated web APIs.



---

## Step 3: Run and Test Locally (Dry-Run Mode)

Always test your loop locally before deploying it to Google Cloud. You can run a **dry-run** that executes the entire loop in Docker but **never pushes changes to production**:

1.  **Build the Loop Runner Docker Image**:
    ```bash
    docker build -t loop-runner loop-runner/
    ```
2.  **Execute the Dry Run**:
    ```bash
    docker run --rm \
      -e LOOP=<your-loop-name> \
      -e REPO_FULL_NAME=SaschaHeyer/loop-runner \
      -e GITHUB_PAT="$(gcloud secrets versions access latest --secret=github-pat --project=your-gcp-project)" \
      -e GCP_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
      -e GCP_PROJECT=your-gcp-project \
      -e PUSH_OVERRIDE=none \
      loop-runner
    ```

In dry-run mode, the harness clones the repository, lets the agent work, records its changes locally, executes your `verify.sh`, and prints a detailed diffstat — all without affecting your remote `main` branch.

---

## Step 4: Deploy and Run on Google Cloud

Once your local dry runs are successful, deploy the loop to Cloud Run:

1.  **Deploy the Loop**:
    ```bash
    cd loop-runner
    LOOP=<your-loop-name> ./deploy.sh
    ```
    This command packages your loop spec, registers the GCP Cloud Run Job, and provisions a Cloud Scheduler cron if `schedule:` is configured in `loop.yaml`.

2.  **Manually Trigger a GCP Run**:
    If you don't want to wait for the cron schedule, you can trigger a headless run on GCP manually:
    ```bash
    gcloud run jobs execute loop-<your-loop-name> --region=us-central1 --project=your-gcp-project --wait
    ```

---

## Step 5: Extend Your Loop with Skills, Connectors, & Agents

### 1. Customizing & Extending Your Agent
You can fully customize the agent's persona, tool access, swappable execution engine, and safety boundaries:

#### A. Durable Persona & Persona Brief (`system.md`)
To establish a persistent identity, coding guidelines, or rules the agent must always respect:
1. Uncomment the `system_prompt` line in your `loops/<your-loop-name>/loop.yaml`:
   ```yaml
   system_prompt: loops/<your-loop-name>/system.md
   ```
2. Create and write your rules inside `loops/<your-loop-name>/system.md`. This is excellent for defining who the agent is (e.g., "You are an autonomous PR reviewer...") and keeping it separated from the active task kickoff in `prompt.md`.

#### B. Restricting Agent Tools (`allowed_tools`)
To enforce safety, you can constrain what tools the agent is permitted to call by editing the comma-separated string in `loop.yaml`:
```yaml
allowed_tools: "Read,Write,Edit,Glob,Grep,WebFetch"  # (Safely block arbitrary terminal commands!)
```
This is ideal for securing a loop: if `Bash` is not listed, the agent will have no terminal access and can only perform safe file edits or read documentation.

#### C. Swapping the Agent Engine (`AGENT_CLI`)
The runner container executes the agent CLI as a swappable subprocess of `entrypoint.sh`:
*   **Claude Code (`AGENT_CLI=claude`)**: The default, production-proven engine.
*   **Google Antigravity CLI (`AGENT_CLI=agy`)**: Swaps the execution over to Google Gemini models using the `agy` CLI. 
    *(Note: Headless auth for `agy` is currently pending upstream support; stick to `AGENT_CLI=claude` for unattended Cloud Run jobs).*

#### D. Hard Boundary Enforcement (`hooks/`)
A prompt can *request* a boundary, but a hook *enforces* it. You can define loop-specific Pre/Post tool-use hooks that block or monitor actions:
1. Create a `loops/<your-loop-name>/hooks/` folder.
2. Add a `settings.json` specifying your matcher hooks:
   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             { "type": "command", "command": "bash /workspace/repo/loops/<your-loop-name>/hooks/guard.sh" }
           ]
         }
       ]
     }
   }
   ```
3. Add your executable shell script `loops/<your-loop-name>/hooks/guard.sh`. The script can inspect proposed commands: exit `2` to block execution (returning the script's stderr as a message to the agent), or exit `0` to allow it.

---

### 2. Adding Per-Loop & Shared Skills
If your agent needs a specialized playbook, custom scripts, or dedicated reference instructions, you can add them either locally or via a shared Git repository:

#### A. Local Per-Loop Skills
*   **Best for**: Custom instructions or scripts that are specific to *this loop only*.
*   **How to add**:
    1. Create a directory: `loops/<your-loop-name>/skills/<skill-name>/`
    2. Create a `SKILL.md` inside it containing your instructions and examples.
    3. The Loop Runner will automatically discover and mount this skill at runtime inside the agent's environment under `.claude/skills/<skill-name>/` with no manual configuration.

#### B. External Shared Skills (Loaded via Repository)
*   **Best for**: Generic or shared capabilities (like error analysis or code review checklists) that are used across multiple loops.
*   **How to add**:
    1. Create a separate Git repository (e.g. `SaschaHeyer/shared-agent-skills`) containing folders with `SKILL.md` files (e.g. `shared-agent-skills/code-reviewer/SKILL.md`).
    2. List the repository in your loop's `loop.yaml` under `skills:`:
       ```yaml
       skills:
         - "SaschaHeyer/shared-agent-skills"
       ```
    3. The Loop Runner will automatically clone this repository at runtime and register all its skill definitions under the agent's `.claude/skills/` directory alongside any local skills.


---

### 3. Adding Custom API Connectors
Need your loop to call an external API (e.g. Slack, Jira, HubSpot)?
1. Store the API credentials securely in GCP Secret Manager.
2. Add a `--set-secrets` entry in `loop-runner/deploy.sh` to inject the secret into the container environment.
3. Add a single line to the `_API` mapping inside `loop-runner/proxy_addon.py` instructing the local mitmproxy to intercept requests and inject your token:
   ```python
   "api.hubspot.com": ("HUBSPOT_ACCESS_TOKEN", "Bearer {}")
   ```
4. Declare the connector in your `loop.yaml` under `connectors:`:
   ```yaml
   connectors:
     - hubspot
   ```
   Now, the agent can call `api.hubspot.com` with zero authentication headers in its code, and the proxy will automatically inject the token!

---

### 4. Registering Loop-Specific Subagents
For complex loops, a single main agent might get bogged down or waste context. You can extend your loop with **specialized subagents** that the main agent can delegate tasks to:

*   **Where to place them**: Add markdown configuration files under `loops/<your-loop-name>/agents/` (e.g., `loops/<your-loop-name>/agents/reviewer.md`).
*   **Automatic Registration**: At runtime, the Loop Runner automatically copies these agent definition files into the agent's discovery folder (`.claude/agents/`).
*   **How to define a subagent**: Inside your `<agent-name>.md` file, you can specify its unique system prompt, preferred model, and allowed tools:
    ```markdown
    ---
    name: CodeReviewer
    model: claude-sonnet-4-6
    allowed_tools: Read,Glob,Grep
    ---
    You are a specialized code reviewer. Your only job is to analyze the proposed changes in the workspace and output a markdown table of feedback...
    ```
*   **How the main agent uses them**: During execution, the main agent will discover these registered subagents and can spawn them to execute isolated background sub-tasks (e.g., calling them via its internal agent tools), conserving its own context and budget.


