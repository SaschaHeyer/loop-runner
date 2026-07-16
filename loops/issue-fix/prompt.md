Fix ONE GitHub issue in this work repo (your cwd), prove the fix, and propose it as a PR.

1. Orient — pick the issue. List the candidates:
       gh issue list --label agent-ready --state open --json number,title,createdAt
   Skip any issue that already has a fix branch or an open PR (the branch IS the dedupe ledger):
       git ls-remote --heads origin 'issue-fix/*'
       gh pr list --state open --json headRefName,body
   Pick the NEWEST remaining issue. If none remain, say "no agent-ready issues — nothing to do"
   and STOP. A loop that correctly does nothing beats a loop that invents work.

2. Reproduce. Read the issue (`gh issue view <n>`), find the code it points at, and reproduce
   the problem. A failing test is the best reproduction — add one if the suite supports it.

3. Fix the ROOT CAUSE in the source. Smallest correct change, nothing unrelated. NEVER edit an
   existing test just to make it pass. Prove it:
       npm test        # or this repo's test command — everything green before you continue
   If you cannot get it green within budget, stop and say exactly why.

4. Propose. One branch per issue — the branch name is the record:
       git switch -c issue-fix/<n>
       git add -A && git commit -m "fix: <what was wrong> (#<n>)"
       git push -u origin HEAD
       gh pr create --title "fix: <short title> (#<n>)" \
         --body "Closes #<n>. <what was broken, the one-line fix, and: the suite is green>"
   Comment a one-line status + PR link on the issue, then STOP.

Touch nothing outside the fix — no drive-by refactors, no dependency bumps. The harness
commits, pushes, verifies, and archives the transcript after you stop.
