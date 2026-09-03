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

The real-email SES→SNS→SQS pipeline this repo used to also own moved to its own repo,
[mootmaker-email-testing](https://github.com/geoffweatherall/mootmaker-email-testing), 2026-09-03 —
see [History](#history) below. It was never really related to the scripts above; the two were only
ever combined because both were the "genuinely cross-repo" leftovers of the original
`mootmaker-e2e` split.

See [mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/docs/reference/testing-strategy.md)
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
  [mootmaker](https://github.com/geoffweatherall/mootmaker/blob/main/docs/reference/use-cases.md) — a
  client-agnostic list of scenarios, not owned by any one frontend.
- This repo was renamed (on GitHub too, since — this note used to say that rename was still
  deferred; it has since happened) and kept only the genuinely cross-repo pieces described above.

**2026-09-03**: those "genuinely cross-repo pieces" turned out to still be two unrelated things
combined by circumstance rather than by relationship — the ephemeral-environment scripts above, and
the real-email SES→SNS→SQS pipeline. The pipeline moved to its own repo,
[mootmaker-email-testing](https://github.com/geoffweatherall/mootmaker-email-testing); this repo
kept only the ephemeral-environment scripts and is being renamed again, to
[mootmaker-ephemeral-envs](https://github.com/geoffweatherall/mootmaker-ephemeral-envs), to match.

## Status

The ephemeral-environment lifecycle scripts were built and verified working against real AWS
2026-08-15 (back when this repo was still `mootmaker-e2e`) — see [testing-strategy.md](testing-strategy.md)
for detail. The real-email SES→SNS→SQS pipeline that was also verified that day now lives in
[mootmaker-email-testing](https://github.com/geoffweatherall/mootmaker-email-testing) — see that
repo's own README for its status, unchanged by the move.

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
