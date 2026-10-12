# mootmaker-ephemeral-envs

Scripts and workflows that create, keep, tear down and sweep ephemeral environments: throwaway copies of
the system named `<kind>-<YYMMDD>-<rand4>`.

**Read [README.md](README.md) first**, and [testing-strategy.md](testing-strategy.md) before changing a
script. Keep both true in the same pull request as any change that affects them.

## Working here

- **These scripts create and destroy real AWS resources.** Treat them with the care that implies, and
  state the cost before creating anything.
- **Use `create-ephemeral-env.sh` to make an environment**, never a hand-rolled name. Reuse one environment
  for a whole session, and tear it down when the work is finished, or keep it with
  `./keep-env.sh <name> "<reason>"` if it must outlast the 48-hour sweep.
- **The name check is a safety rail.** Teardown refuses anything that is not `<kind>-<YYMMDD>-<rand4>`, so
  a typo can never reach `test` or `production`. Never work around it.
- **Teardown discovers components and refuses ones it does not know.** A component missing from
  `component_dirs` in `teardown-ephemeral-env.sh` stops it. Add the component there; never delete its
  state by hand, which would orphan live infrastructure.
- **The sweep destroys unattended.** Any change to `sweep-stale-envs.sh` keeps all four guards (name shape,
  no lock, 48 hours idle, no KEEP marker), and is tried without `--destroy` first.
- **Verify teardown against AWS**, not the script's exit code.

---

## Project-wide rules

This repository is part of **Mootmaker**. The hub repository, checked out as a sibling at
`../mootmaker`, holds what applies everywhere:

- How work is done: [`../mootmaker/docs/process/README.md`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/process/README.md).
  Read it before any non-trivial work.
- How the system fits together: [`../mootmaker/docs/overview/`](https://github.com/geoffweatherall/mootmaker/tree/main/docs/overview).
- What to do when something is wrong: [`../mootmaker/docs/runbooks/`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/runbooks/README.md).

The short version:

- Work of any real size starts with a **design** (`../mootmaker/designs/`); a bug or small change starts
  with a **GitHub issue in this repository**, so `Closes #N` works.
- Everything lands on a **branch** through a **pull request**. Reading the diff is the review; merging is
  the approval.
- **A green acceptance run against a real deployed environment** is the definition of working.
- **`test` and `production` change only through a release** (`release.yml` in mootmaker-release). Use an
  ephemeral environment for your own work, and tear it down when you finish.
- **Say what something costs in AWS before creating it.** Under NZ$1 one-off, go ahead and state it;
  more, or anything recurring, ask first.
- **Keep documentation and comments true and current.** If a change makes a document wrong, fixing it is
  part of the change. Describe what is, not how it got here; a comment says what and why.
- **Verify against reality, not your own output**, and **say what actually happened**, including
  failures and skipped steps.

Something not installed? [`../mootmaker/tools/workstation/check.sh`](https://github.com/geoffweatherall/mootmaker/blob/main/tools/workstation/check.sh).

`CLAUDE.md` in this repository is a symlink to this file.
