Run one __NAME__ loop.

Describe the task as an ordered checklist the agent can follow and finish in a single loop:

1. Orient — read the inputs / state this loop depends on.
2. Do the single highest-value thing this loop can complete. One real thing shipped beats five
   half-started.
3. Prove it worked — the concrete evidence your verify.sh will check (a status code, a passing test,
   a record read back). Do not claim success you did not observe.
4. Record — write to loops/__NAME__/state what you did and what the next loop should pick up.

Stop condition: if there is nothing high-value to do, say so plainly and STOP. A loop that correctly
does nothing beats a loop that invents work.
