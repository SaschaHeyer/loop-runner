---
name: loop-new
description: Interview-driven authoring of a new loop in this Loop Library. Use when the user wants to create, add, build, or scaffold a new loop ("new loop", "create a loop", "add a loop for X", "build a loop that..."), or invokes /loop-new. Asks the six decision questions, then scaffolds, fills, validates, registers, and commits the loop end to end.
---

# /loop-new — author a new loop from an interview

You are creating a new loop in this Loop Library. `./new-loop.sh` scaffolds the FILES; your job is
to scaffold the DECISIONS and turn the answers into a finished, validated loop. Gold-standard
examples to imitate: `loops/hello-world/` (minimal) and `loops/error-sweep/` (PR mode; its history taught the turn-budget and
gh-token lessons). The runner must NEVER need changes for a new loop — if it seems to, stop and
flag it.

## Phase 1 — the interview

Ask these six questions (use AskUserQuestion where it helps; accept a prose brief and extract the
answers, confirming what you inferred). Each answer maps to a concrete artifact:

1. **Name** — lowercase kebab-case, named for the FUNCTION, not the machinery (it doubles as the
   bot name if the loop ever gets a Slack/service identity; 1:1 loop↔bot↔token convention).
   → folder + `name:`
2. **What does it do, and what does "done" look like, in one sentence?** → `description:`
3. **Data sources.** Public or credentialed? Which APIs? → `connectors:`. CHECK each against the
   `_API` map in `loop-runner/proxy_addon.py` (plus googleapis/github which are built in). If a
   connector is missing, STOP and walk `loop-runner/connectors/README.md` first (secret →
   `--set-secrets` → one `_API` line); the human creates the credential/secret themselves — never
   accept a credential pasted into chat.
4. **The deliverable, and how can it be checked MECHANICALLY?** → `verify.sh` + honest `tier:`.
   Push hard for tier 3: deliverable READBACK (a PR that exists via the API, an email id confirmed
   by Resend, a record read back) plus the BLAST-RADIUS check (only the loop's declared paths may
   change: `git diff --name-only $BEFORE_SHA HEAD` filtered against the memory dir). If quality genuinely needs a human, declare tier 5 honestly
   — never fake tier 3 with a placeholder.
5. **Stop conditions.** What does a correct EMPTY run look like? (For notification loops: silence
   on a no-news day is a feature; every run must still record its check in the ledger.) Also:
   `max_turns` (estimate expected tool calls + slack — error-sweep taught that find+fix+prove+PR
   needs ~60) and `budget_usd`. → prompt stop clause + spec caps
6. **Trigger intent, cadence, model, memory.** `trigger: schedule|manual` + `schedule:` (note in a
   comment if cron wiring is deferred — check the plan's M6 status), model
   (`claude-sonnet-4-6` for mechanical work, `claude-opus-4-8` for judgement), `memory:` (default
   `loops/<name>/state` with a seeded `ledger.json`), `push:` (`main` only if it touches nothing
   but its own state; `pr` when a human should review; `none` for read-only).

## Phase 2 — execute (commit after each step, imperative messages)

1. `./new-loop.sh <name>` — never hand-create the folder.
2. Fill `loop.yaml` from the answers. Annotate non-obvious choices with `# DECISION:` comments.
   Delete `system.md` (and its spec line) unless the loop truly needs a durable role brief.
3. Write `prompt.md` as the orient → act → prove → record → STOP workflow. Include: read the
   ledger first; the exact deliverable format; the no-auth-header rule for proxy-injected APIs;
   the stop condition in its own sentence; "touch nothing outside <memory dir>" when applicable.
   Customer-facing/outbound copy must never use an em-dash as a connector.
4. Write `verify.sh` per question 4. Then TEST it in a scratch git repo across at least: the happy
   path, the clean-empty-run path, ledger-did-not-advance, out-of-scope file change, and (if
   readback applies) claimed-deliverable-missing. Every case must return the expected exit code.
5. Seed `state/ledger.json` (e.g. `{"seen": [], "runs": []}`) and remove `.gitkeep`.
6. Validation battery — all must pass:
   - `diff <(python3 loop-runner/parse_spec.py loops/<name>/loop.yaml) <(SPEC_PARSER_FORCE_MINI=1 python3 loop-runner/parse_spec.py loops/<name>/loop.yaml)`
   - `bash -n loops/<name>/verify.sh`
   - the scenario tests from step 4
7. Register: a row in `LOOPS.md` (with the honest tier) and the loop line in the root `README.md`
   layout block. Verify every loop appears in both.
8. Push, then offer the deploy: `cd loop-runner && LOOP=<name> BUILD=0 CREATE_CRON=0 ./deploy.sh`
   (BUILD=0 — the image is loop-agnostic; CREATE_CRON per the M6 status in the plan). The first
   LIVE execution is the operator's call — it may cost money or send something; ask before running.

## Hard rules
- Never touch `loop-runner/` for a new loop; if the loop seems to need it, that is a milestone
  discussion, not a quiet edit.
- Never place operator skills in `skills/` (that dir is mounted into loop containers for the loop
  AGENTS). This skill's own home, `.claude/skills/`, is for the humans/assistants working the repo.
- Tier honesty over tier vanity. A declared tier 5 with a human is better than a fake tier 3.
