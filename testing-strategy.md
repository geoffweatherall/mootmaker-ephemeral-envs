# Testing strategy

The overall cross-repo strategy (environments, the approach to reading Cognito's emails in tests,
and how "vibe coding" shapes all of this) is recorded in
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md).
This document covers what's specific to this repo. Nothing here is built yet — this is the plan.

## Purpose

Everything neither [mootmaker-api](https://github.com/geoffweatherall/mootmaker-api)'s nor
[mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp)'s own test suites can see
on their own:

- a genuinely deployed webapp build talking to a genuinely deployed API (not a local dev server,
  not mocks),
- real Cognito authentication end-to-end, including the sign-up and forgot-password
  verification-code flows with a real emailed code,
- cross-service integration failures (DNS, certificates, CloudFront/S3 serving) that only exist
  once everything is actually deployed together.

This is deliberately the thinnest, least-frequently-run layer of the overall strategy — see [How
"vibe coding" shapes this
strategy](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#how-vibe-coding-shapes-this-strategy)
for why real infrastructure and real email are kept out of the fast inner loop.

See [use-cases.md](use-cases.md) for a starting list of user-focused scenarios to draw on when
deciding what actually belongs in this layer versus the faster ones elsewhere.

## Planned components

- **Deploy pipeline**: stand up a fresh ephemeral environment (API + webapp together, same
  environment name so they're wired to each other per the [multi-environment
  convention](https://github.com/geoffweatherall/mootmaker#multi-environment-deployments)), run
  the full-stack suite against it, then tear it down. Environment names follow the
  `e2e-<YYMMDD>-<HHmm>-<rand4>` convention (see
  [mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#environments)).
- **Full-stack test suite**: Playwright, driving a real browser against the deployed webapp's real
  URL — likely a small, curated set of scenarios (not a re-run of everything the mocked-API layer
  in mootmaker-webapp already covers), focused on what only this layer can catch.
- **Real email reading (Option 2 — SES → SQS)**: a subdomain's MX record points at Amazon SES; an
  SES receipt rule delivers incoming mail to an SQS queue; the test suite long-polls the queue and
  parses the verification code out of the real email body. Used only for the small number of tests
  whose specific purpose is proving Cognito's email sending actually works — everywhere else,
  tests use the DynamoDB-bypass approach from mootmaker-api instead (see
  [mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#reading-cognitos-emails-in-tests)).
  This infrastructure is stood up only alongside the ephemeral environments used for e2e runs —
  never for `test` or `production`.
- **Ephemeral environment scripts**: see [below](#ephemeral-environment-scripts).

## Ephemeral environment scripts

Decided 2026-08-15 (see [mootmaker/testing-strategy.md's Ephemeral environment
lifecycle](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#ephemeral-environment-lifecycle)
for how this fits the overall policy). Not yet built — this is the design.

Three separate bash scripts, matching the one-script-one-job convention already used by
`deploy.sh`/`undeploy.sh`/`authenticate.sh`/`verify.sh` elsewhere in the project. Bash rather than
a Node/TS tool, chiefly for consistency with every other operational script in the project, and
because all three mostly need to shell out to mootmaker-api's and mootmaker-webapp's existing
`deploy.sh`/`undeploy.sh` rather than reimplement any deploy mechanics themselves.

- **`create-ephemeral-env.sh [claude|e2e]`**: generates a name
  (`claude-<YYMMDD>-<HHmm>-<rand4>` or `e2e-<YYMMDD>-<HHmm>-<rand4>`, see the naming convention in
  the overall strategy doc), then calls `mootmaker-api/deploy.sh <name>` followed by
  `mootmaker-webapp/deploy.sh <name>`, and — for `e2e`-flavoured environments — this repo's own
  SES/SQS infrastructure apply. Prints the generated name.

  This script does **not** need to pass any flag for the Option 1 email bypass: `mootmaker-api/deploy.sh`
  determines that entirely from the environment name it's given — `claude-*`/`e2e-*` self-enables
  the bypass, anything else (`test`, `production`, a developer's own personal-sandbox name) leaves
  it off. See [mootmaker-api/testing-strategy.md](https://github.com/geoffweatherall/mootmaker-api/blob/main/testing-strategy.md#whats-changing)
  for where that detection lives.

- **`teardown-ephemeral-env.sh <name>`**: tears down one specific, already-known environment —
  calls `undeploy.sh <name>` for mootmaker-webapp and mootmaker-api (and this repo's own infra, if
  present for that name). This is what Claude's commit-time cleanup prompt (see the overall
  strategy doc) uses once the user confirms.

- **`cleanup-stale-envs.sh`**: the batch sweep, for anything left behind by an interrupted session
  or a failed run. Discovers every `claude-*`/`e2e-*` environment across all projects by listing
  the shared Terraform state bucket's object keys and grouping by the first path segment of
  `<environment>/<project-name>/terraform.tfstate` — no separate environment registry needed.
  Lists everything it finds and asks for confirmation before tearing down each one, matching
  `undeploy.sh`'s own always-interactive, no-`-auto-approve` safety pattern — rather than an age
  threshold or a pick-list menu, since this script can destroy multiple environments in one run
  and explicit per-environment confirmation felt like the safer default than any automatic
  selection rule. Runnable by Geoff directly, or by Claude.
