# mootmaker-test-infra

A project that is part of my [Claude Code exploration](https://github.com/geoffweatherall/mootmaker).

## Purpose

Shared testing infrastructure used by more than one frontend of the
[mootmaker](https://github.com/geoffweatherall/mootmaker) project — currently
[mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp), with
[mootmaker-android](https://github.com/geoffweatherall/mootmaker-android) expected to depend on
the same pieces later. Nothing here is a test suite itself; each frontend owns its own `e2e/` and
`acceptance/` tests (see [mootmaker-webapp/testing-strategy.md](https://github.com/geoffweatherall/mootmaker-webapp/blob/main/testing-strategy.md)),
against its own real deployed environment, using whatever's idiomatic for that platform. This repo
only owns the things that are genuinely cross-repo:

- **Ephemeral-environment lifecycle scripts** (`create-ephemeral-env.sh`,
  `teardown-ephemeral-env.sh`, `cleanup-stale-envs.sh`, `list-ephemeral-envs.sh`) — these
  deploy/undeploy [mootmaker-api](https://github.com/geoffweatherall/mootmaker-api) and
  [mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp) *together*, so they
  can't live inside either one on their own.
- **The real-email SES→SNS→SQS pipeline** (`deploy/terraform/`, `deploy-email-infra.sh`,
  `undeploy-email-infra.sh`) — one persistent, shared queue any frontend's tests can long-poll for
  a real Cognito verification-code email. Deployed once, not per environment, not per frontend.

See [mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md)
for how this fits the wider cross-repo strategy, and
[testing-strategy.md](testing-strategy.md) for the detail specific to this repo.

## History

This repo used to be `mootmaker-e2e` and also owned a full-stack Playwright suite
(`sign-up.spec.ts`, `forgot-password.spec.ts`, `smoke.spec.ts`) plus `use-cases.md`. Both moved out
2026-08-19, once a second frontend (Android) meant "e2e tests" needed to become "each frontend's
own e2e/acceptance tests" rather than one shared suite:

- The Playwright suite and its support helpers (`cognitoAdmin.ts`, `email.ts`, `testAccount.ts`)
  moved into [mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp)'s new `e2e/`
  directory, unchanged in behaviour.
- `use-cases.md` moved into
  [mootmaker](https://github.com/geoffweatherall/mootmaker/blob/main/use-cases.md) — a
  client-agnostic list of scenarios, not owned by any one frontend.
- This repo was renamed and kept only the genuinely cross-repo pieces described above.

GitHub still has this checked out under the old remote name (`mootmaker-e2e`) — the local rename
happened first, deliberately, and the GitHub-side rename is deferred to a later, separate step.

## Status

The ephemeral-environment lifecycle scripts and the SES→SNS→SQS pipeline were both built and
verified working against real AWS 2026-08-15 (back when this repo was still `mootmaker-e2e`) — see
[testing-strategy.md](testing-strategy.md) for detail. The deployed AWS resources themselves — SQS
queue, SNS topic, SES receipt rule, and the Terraform state key they're stored under — were left
exactly as they were through the 2026-08-19 rename, to avoid forcing a destroy/recreate of a
pipeline other tests depend on. See `deploy/terraform/backend.hcl`'s comment.

Also 2026-08-19: environment names now identify exactly what created them (e.g. `web-e2e-*`/
`web-acc-*` for `mootmaker-webapp`'s own suites, not a single generic `e2e-*` for everything —
see [testing-strategy.md#naming-convention](testing-strategy.md#naming-convention));
`teardown-ephemeral-env.sh` now removes its own environment's state files from the shared bucket
once torn down; and `list-ephemeral-envs.sh` was added as a read-only report on every ephemeral
environment's state files, flagging which are empty (nothing left to destroy, safe to delete
directly) and, for any that aren't, cross-checking against real AWS (`terraform plan -refresh-only`)
to tell "still genuinely deployed" apart from "resources are actually gone but state doesn't know
it yet." All verified against real AWS the same day, including a deliberate live test (deploy a
real environment, manually delete one resource outside Terraform, confirm the script correctly
named exactly that one as missing) — see testing-strategy.md for detail.
