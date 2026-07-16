Run one auto-fix loop against the AEGIS app (this work repo is the AEGIS "AI Apocalypse Insurance"
Next.js app).

The app ships with an intentional bug that has a failing test. Your job: fix the ONE failing test at
its root cause in the source, prove the suite is green, and open a pull request. Minimal change only,
and NEVER edit the test to make it pass.

1. Orient. Install and run the tests to see what is red:
       npm install
       npm test
   Read the failing test and the source it exercises. Find the ROOT CAUSE in the source (under lib/),
   not in the test.

2. Fix. Make the smallest correct change in the source, nothing unrelated. Re-run:
       npm test
   Do not continue until every test is green. If you cannot get it green, stop and say why.

3. Open a PR. Create a branch, commit only your source fix, push it, and open a pull request:
       git switch -c fix/premium-calc
       git add -A && git commit -m "<clear message: what was wrong, and the fix>"
       git push -u origin HEAD
       gh pr create --fill --title "<short title>" --body "<what was broken, the one-line fix, and: npm test is green>"
   After you stop, the harness runs an independent verifier and posts its verdict on this PR.

Stop condition: if npm test is already green (nothing to fix), say so plainly and STOP without opening
a PR. A loop that correctly does nothing beats a loop that invents work.
