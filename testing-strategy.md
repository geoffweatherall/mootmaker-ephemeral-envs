# Testing strategy

The overall cross-repo strategy (environments, the approach to reading Cognito's emails in tests,
and how "vibe coding" shapes all of this) is recorded in
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md).
This document covers what's specific to this repo. The ephemeral-environment scripts are built and
tested, and the SES/SNS/SQS email-reading pipeline is deployed; the full-stack test suite itself is
still the plan.

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
  `e2e-<YYMMDD>-<rand4>` convention (see
  [mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#environments)).
- **Full-stack test suite**: see [below](#full-stack-test-suite).
- **Real email reading (Option 2 — SES → SNS → SQS)**: see
  [below](#real-email-reading-option-2--sessnssqs).
- **Ephemeral environment scripts**: see [below](#ephemeral-environment-scripts). Built and tested
  2026-08-15.

## Full-stack test suite

Built 2026-08-15. Node/TypeScript (`package.json`, `tsconfig.json`), Playwright, three scenarios in
`tests/` — deliberately a small, curated set, not a re-run of anything the mocked-API layer in
mootmaker-webapp already covers (see this repo's own README's ["Purpose"](README.md#purpose) and
[mootmaker/testing-strategy.md's "How vibe coding shapes this
strategy"](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#how-vibe-coding-shapes-this-strategy)
for why this layer stays thin):

- **`sign-up.spec.ts`**: a real sign-up through the real deployed webapp, against the real
  deployed Cognito pool, receiving a real emailed verification code via the SES→SNS→SQS pipeline
  and completing with it. Proves Cognito + SES + the webapp actually work together end to end.
- **`forgot-password.spec.ts`**: same proof, for the password-reset code path. Its precondition
  (an existing confirmed account) is created directly via the Cognito Admin API
  (`tests/support/cognitoAdmin.ts` — `SignUp` + `AdminConfirmSignUp`, no code involved, see
  [mootmaker/testing-strategy.md's "Bypassing the code requirement
  entirely"](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#reading-cognitos-emails-in-tests))
  rather than through the sign-up UI — that's `sign-up.spec.ts`'s job, not this test's; this test's
  own real UI interaction is only the forgot-password flow it's actually testing.
- **`smoke.spec.ts`**: the deployed home page actually loads (DNS, TLS certificate, CloudFront/S3
  serving) — the one thing that isn't auth- or business-logic-shaped but still only exists once
  everything is genuinely deployed together.

`tests/support/email.ts` is the email-reading logic itself: generates a `e2e-<uuid>@mail.mootmaker.com`
address per test (never reused, so concurrent/sequential runs can't cross-talk on the shared
queue — see "No environment argument" above for why the pipeline itself is shared), long-polls
`SQS_QUEUE_URL`, and parses the code out of the matching message with `mailparser` (proper
MIME/transfer-encoding decoding, rather than regexing the raw SES notification body and hoping the
message happens to be plain ASCII).

`run-full-stack-tests.sh` is the "Deploy pipeline" component above: with no argument, creates a
fresh `e2e-*` environment (via `create-ephemeral-env.sh e2e`), reads `WEBAPP_URL` and the
`COGNITO_*` variables from that environment's own Terraform outputs (`authenticate.sh` for the
API's, a direct `terraform output` for the webapp's, since only mootmaker-api has its own
`authenticate.sh`) plus `SQS_QUEUE_URL` from this repo's own persistent state, runs `npm test`, and
tears the environment down afterward regardless of the result (pass, fail, or a script error) via
a `trap`. Given an existing environment name instead, it runs against that one without creating or
tearing anything down — useful for iterating without paying a fresh deploy every run.

**Verification status**: verified 2026-08-15 — all three specs pass together via
`run-full-stack-tests.sh` against a real deployed environment (real Cognito sign-up and
forgot-password flows, real emailed codes read back off the live SES→SNS→SQS pipeline, real
deployed home page). One real bug was caught and fixed along the way: `SignUpCommand`
unconditionally sends its own sign-up confirmation-code email as a side effect, even when the
caller bypasses that code via `AdminConfirmSignUp` — left alone, that straggler landed in the
shared queue and could be picked up by a later, unrelated `waitForVerificationCode` call for the
same address (the queue is a standard, unordered SQS queue). `cognitoAdmin.ts`'s
`createConfirmedTestAccount` now drains any such stragglers immediately after creating the account,
before the caller can request a real code. Separately, this suite also caught a real production bug
in the webapp itself — see `mootmaker-webapp`'s `auth/cognito.ts`.

## Real email reading (Option 2 — SES → SNS → SQS)

This repo owns the receipt rule, SNS topic, and SQS queue (the domain identity and MX record live
in [mootmaker-domain](https://github.com/geoffweatherall/mootmaker-domain) instead — see
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#reading-cognitos-emails-in-tests)
for the full design, including why this is **one persistent, shared pipeline** rather than
something created per ephemeral environment). The test suite long-polls the queue and parses the
verification code out of the real email body, filtering by a unique address tag per run. Used
only for the small number of tests whose specific purpose is proving Cognito's email sending
actually works — everywhere else, tests use the DynamoDB-bypass approach from mootmaker-api
instead.

**Deployed 2026-08-15**: `deploy/terraform/` here has the receipt rule set/rule, SNS topic (with a
policy letting the SES rule publish to it), and SQS queue (subscribed to the topic, raw delivery
enabled), plus `deploy-email-infra.sh`/`undeploy-email-infra.sh` at the repo root, matching
mootmaker-domain's no-environment-argument pattern (see "No environment argument" below). The
domain identity is referenced via `data "aws_ses_domain_identity"` rather than a remote-state
read, mirroring how mootmaker-api/mootmaker-webapp already find mootmaker-domain's hosted zone.

The account's SCP allow-list was updated to include `ses`/`sns`/`sqs` (2026-08-15), mootmaker-domain's
SES domain identity for `mail.mootmaker.com` was deployed and verified first, then this pipeline
was deployed on top of it — `aws_ses_active_receipt_rule_set.e2e` is live, so `mail.mootmaker.com`
genuinely receives mail into `sqs_queue_url` now. Not yet exercised end-to-end with a real message
(that's the next piece of work — the full-stack test suite's own email-reading logic, see below).

### No environment argument

Unlike `create-ephemeral-env.sh`'s pipeline, this Terraform takes no environment name — deployed
once and left running, like mootmaker-domain's hosted zone. Reasoning (see also
`deploy/terraform/backend.hcl`'s and `ses.tf`'s comments):

- SES allows only one *active* receipt rule set per region/account, so a fresh rule set per
  ephemeral e2e run would mean concurrent runs fighting over which one is active.
- Concurrency is instead handled at the message level: each e2e run sends to a uniquely-tagged
  address under the shared subdomain and filters the SQS queue for its own tag.
- A fixed backend state key (`mootmaker-e2e-email/terraform.tfstate`, not
  `<environment>/mootmaker-e2e/terraform.tfstate`) also means `cleanup-stale-envs.sh`'s discovery
  logic — which groups by first path segment and matches only `claude-*`/`e2e-*` — never mistakes
  this persistent infrastructure for a stale ephemeral environment.

## Ephemeral environment scripts

Decided 2026-08-15 (see [mootmaker/testing-strategy.md's Ephemeral environment
lifecycle](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#ephemeral-environment-lifecycle)
for how this fits the overall policy). **Built and tested against real AWS environments,
2026-08-15.**

Three separate bash scripts, matching the one-script-one-job convention already used by
`deploy.sh`/`undeploy.sh`/`authenticate.sh`/`verify.sh` elsewhere in the project. Bash rather than
a Node/TS tool, chiefly for consistency with every other operational script in the project, and
because all three mostly need to shell out to mootmaker-api's and mootmaker-webapp's existing
`deploy.sh`/`undeploy.sh` rather than reimplement any deploy mechanics themselves.

- **`create-ephemeral-env.sh [claude|e2e]`** (default `claude`): generates a name
  (`claude-<YYMMDD>-<rand4>` or `e2e-<YYMMDD>-<rand4>`, see the naming convention in
  the overall strategy doc), then calls `mootmaker-api/deploy.sh <name>` followed by
  `mootmaker-webapp/deploy.sh <name>` (sibling checkouts, resolved relative to this script's own
  location rather than the caller's working directory). Prints the generated name as the last line
  of stdout on success; on failure, prints the (possibly partially-deployed) name and the
  `teardown-ephemeral-env.sh` command to clean it up. Does **not** touch the SES/SNS/SQS pipeline —
  that's a separate, persistent, always-on piece of infrastructure (see above), not something
  created per environment.

- **`teardown-ephemeral-env.sh <name>`**: tears down one specific, already-known environment —
  calls `undeploy.sh <name>` for mootmaker-webapp then mootmaker-api. Refuses to run unless `name`
  matches `^(claude|e2e)-[0-9]{6}-[0-9]{4}-[a-z0-9]{4}$` exactly — a hard safety rail so a typo can
  never reach `test`/`production`. This is what Claude's commit-time cleanup prompt (see the
  overall strategy doc) uses once the user confirms.

- **`cleanup-stale-envs.sh`**: the batch sweep, for anything left behind by an interrupted session
  or a failed run. Computes the shared state bucket name as `remote-state-<account-id>` (via `aws
  sts get-caller-identity`, matching mootmaker-bootstrap-terraform's own naming convention — no
  dependency on any sibling repo's `backend.hcl`), lists its object keys, and groups by the first
  path segment of `<environment>/<project-name>/terraform.tfstate` — no separate environment
  registry needed. Lists everything it finds and asks for confirmation before tearing down each
  one (via `teardown-ephemeral-env.sh`, so the same name-format safety rail applies), matching
  `undeploy.sh`'s own always-interactive, no-`-auto-approve` safety pattern — rather than an age
  threshold or a pick-list menu, since this script can destroy multiple environments in one run
  and explicit per-environment confirmation felt like the safer default than any automatic
  selection rule. Runnable by Geoff directly, or by Claude.

### Testing notes (2026-08-15)

All three scripts were exercised repeatedly against real AWS (multiple `claude-*`/`e2e-*`
environments created and torn down; `cleanup-stale-envs.sh` run against a real environment and
correctly discovered/listed it before tearing it down on confirmation). See the session's own
report for exact command output and current status of the two findings below.

Two mootmaker-api-side issues turned up during this testing (both are findings *about*
mootmaker-api, not bugs in these scripts) — **both fixed and re-verified the same session**, after
this testing surfaced them:

1. **`claude-*` names overflowed a Lambda function-name limit.**
   `${environment}-mootmaker-post-confirmation-create-person` was 65 characters for the original
   `claude-<YYMMDD>-<HHmm>-<rand4>` form (Lambda's limit is 64). Fixed here by dropping the
   time-of-day component — `create-ephemeral-env.sh`/`teardown-ephemeral-env.sh`/
   `cleanup-stale-envs.sh` now all generate/accept `claude-<YYMMDD>-<rand4>` (18 characters, 4 to
   spare against the 22-character ceiling that constraint implies), which day-level cleanup
   granularity doesn't need anyway.
2. **Every ephemeral environment failed to fully deploy**, because mootmaker-api's (now-removed)
   email verification-code bypass self-enabled purely from the environment name, unconditionally
   trying to create an SCP-blocked KMS key on every `claude-*`/`e2e-*` deploy. Fixed at the time
   with an explicit opt-in variable defaulting off; the whole feature was later dropped entirely
   (2026-08-15, cost reasons unrelated to this bug — see mootmaker-api's own `testing-strategy.md`),
   so this specific failure mode no longer exists at all.

Net effect: these scripts' own mechanics (name generation, calling `deploy.sh`/`undeploy.sh` in the
right order and directories, the safety-rail regex, partial-failure cleanup messaging, and
`cleanup-stale-envs.sh`'s discovery/listing) were verified working via multiple real create/fail/
teardown cycles even before the two fixes above, including teardown correctly cleaning up
partially-created resources. After both fixes, a fresh `claude-<date>-<rand>` environment deploys
mootmaker-api cleanly end to end (44 resources) and tears down cleanly — re-verify the full
`create-ephemeral-env.sh` path (API + webapp together) next time either script gets touched, since
that specific combination wasn't re-run after the fixes landed.

One more behaviour worth knowing about `cleanup-stale-envs.sh`: `terraform destroy` empties a
state file's contents but doesn't delete the S3 object itself, so a fully-torn-down environment's
`<environment>/<project-name>/terraform.tfstate` key can still exist (now empty) after
`teardown-ephemeral-env.sh` has run - `cleanup-stale-envs.sh` will keep listing that environment
name until the object itself is deleted from the state bucket (`aws s3api delete-object`). Running
`teardown-ephemeral-env.sh`/the destroy step again against an already-empty state is a safe no-op
(Terraform reports "No changes. No objects need to be destroyed." and exits without a
confirmation prompt), so re-confirming a phantom entry costs nothing beyond the prompt itself.
