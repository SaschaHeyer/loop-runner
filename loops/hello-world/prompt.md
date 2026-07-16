Run one hello-world loop. This is the smallest possible loop: it exists only to prove the whole spine
(clone, model, task, verify, commit, push) works end to end, without touching any real work repo.

Do exactly this, then STOP:

1. Read `loops/hello-world/state/greetings.md` (it already exists). Count the greeting lines already
   there — the ones that start with `[`. Call that count N.
2. Append ONE new line to that file, in EXACTLY this format (the current UTC time, and run number N+1):

   `[<UTC ISO-8601, e.g. 2026-07-06T09:00:00Z>] hello from the hello-world loop (run <N+1>)`

   Use `date -u +%Y-%m-%dT%H:%M:%SZ` for the timestamp.
3. Stop. Do nothing else: do not modify any other file, do not deploy, do not call any API.

That is the entire job. The harness commits and pushes your line for you — the repo is the memory, so
the next run sees your greeting and counts one higher.
