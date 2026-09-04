# mootmaker-ephemeral-envs

Ephemeral-environment lifecycle scripts shared by every frontend: stand up/tear down a matched
`mootmaker-api` + `mootmaker-webapp` pair under one environment name.

**Start by reading [README.md](README.md)** and [testing-strategy.md](testing-strategy.md).

Formerly `mootmaker-e2e`, before each frontend gained its own `e2e/` and `acceptance/` suites. Also
used to own a persistent real-email testing pipeline, split out to
[mootmaker-email-testing](https://github.com/geoffweatherall/mootmaker-email-testing) 2026-09-03 —
this repo is itself being renamed to
[mootmaker-ephemeral-envs](https://github.com/geoffweatherall/mootmaker-ephemeral-envs) as part of
that same split, to match its now-single purpose.

## Working here

- **These scripts create and destroy real AWS resources.** Treat them with the care that implies.
- **The name check is a safety rail, not a nicety.** `teardown-ephemeral-env.sh` refuses anything
  that is not `<kind>-<YYMMDD>-<rand4>`, so a typo can never reach `production`. Do not work around
  it; retiring a long-lived environment is a deliberate manual act.
- **Known gap: teardown is incomplete.** The script undeploys `mootmaker-webapp` and `mootmaker-api`
  only, and removes only those two state objects. Its caution is correct — deleting a state object it
  did not itself destroy would orphan live infrastructure — but the effect is that an environment
  with tools deployed is *not* fully torn down by the script named "tear down this environment".
  Undeploy the tools separately first.
- **Ephemeral environments leak.** Four survived a single session in August 2026 and were found the
  next morning still running. Anything older than 24 hours is a leak. Nothing automated catches this
  yet.
- **Verify teardown against live AWS**, not the script's exit code.

---

## Project-wide rules

This repository is part of the **mootmaker** project. The workflow rules that apply everywhere live
in the hub repository, which you should find checked out as a sibling directory:

    ../mootmaker/docs/process/README.md

On GitHub: <https://github.com/geoffweatherall/mootmaker/blob/main/docs/process/README.md>

**Read it before doing any non-trivial work here.** The short version:

- Work of any real size starts with a **design document** (`../mootmaker/designs/`), not with code.
- Bugs and small changes start with a **GitHub issue in this repository**, so `Closes #N` works.
- All work happens on a **branch** and lands via a **pull request**. There is no approval step —
  reading the diff is the review, merging is the approval.
- **A green acceptance run against a real deployed environment** is the definition of working — not
  a passing unit suite, and not a successful deploy.
- **Environments are `production`, `test`, or ephemeral.** `test` and `production` change only
  through `release.yml` in mootmaker-release — never `./deploy.sh` by hand. Everything else is
  ephemeral: tear down any you create, as part of finishing rather than as a tidy-up afterwards.
- **If your change makes a document wrong, fixing it is part of the change.**
- **Verify against reality, not your own output.** A script exiting zero is not evidence that the
  thing it was meant to do happened.
- **Say what actually happened.** Failing tests get reported with their output; skipped steps get
  named.

Also useful: [`../mootmaker/docs/roles/`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/roles/)
for which kind of work you are doing, and
[`../mootmaker/tools/workstation/check.sh`](https://github.com/geoffweatherall/mootmaker/blob/main/tools/workstation/check.sh)
if something is not installed.

`CLAUDE.md` in this repository is a symlink to this file.
