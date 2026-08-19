# Testing strategy

The overall cross-repo strategy (environments, the approach to reading Cognito's emails in tests,
and how "vibe coding" shapes all of this) is recorded in
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md).
This document covers what's specific to this repo.

## Purpose

This repo (formerly `mootmaker-e2e`, renamed 2026-08-19 — see [README.md's
History](README.md#history)) owns only the pieces of the testing strategy that are genuinely
shared across more than one frontend, and so can't live inside any single frontend's own repo:

- **Ephemeral-environment lifecycle** — standing up/tearing down a matched
  [mootmaker-api](https://github.com/geoffweatherall/mootmaker-api) +
  [mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp) pair under one
  environment name, and sweeping up anything left behind. See [Ephemeral environment
  scripts](#ephemeral-environment-scripts) below.
- **Real Cognito email reading** — the SES→SNS→SQS pipeline any frontend's tests can long-poll for
  a real verification-code email, when a scenario specifically needs to prove that path works. See
  [Real email reading](#real-email-reading-option-2--sessnssqs) below.

Each frontend owns its *own* `e2e/` (thin, real-infra, curated) and `acceptance/` (broader,
use-case-driven) test suites, in its own repo, using whatever's idiomatic there — TypeScript +
Playwright for [mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp), presumably
Kotlin + Espresso/Compose for `mootmaker-android` later. See
[mootmaker-webapp/testing-strategy.md](https://github.com/geoffweatherall/mootmaker-webapp/blob/main/testing-strategy.md)
for that repo's suites, and [mootmaker/use-cases.md](https://github.com/geoffweatherall/mootmaker/blob/main/use-cases.md)
for the client-agnostic scenario list they draw on.

**Known gap**: `create-ephemeral-env.sh` unconditionally deploys mootmaker-api *and*
mootmaker-webapp together. That's fine for mootmaker-webapp's own suites, but Android's tests will
only need the API half — deploying an unused webapp alongside it would be pure overhead. Not solved
here yet; likely fix is an optional `--api-only` (or similar) flag once Android's acceptance suite
actually exists and this becomes a real cost rather than a hypothetical one.

## Real email reading (Option 2 — SES → SNS → SQS)

This repo owns the receipt rule, SNS topic, and SQS queue (the domain identity and MX record live
in [mootmaker-domain](https://github.com/geoffweatherall/mootmaker-domain) instead — see
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#reading-cognitos-emails-in-tests)
for the full design, including why this is **one persistent, shared pipeline** rather than
something created per ephemeral environment or per frontend). Any frontend's test suite long-polls
the queue and parses the verification code out of the real email body, filtering by a unique
address tag per run. Used only for the small number of tests whose specific purpose is proving
Cognito's email sending actually works — everywhere else, tests use the Cognito Admin-API bypass
instead (`AdminConfirmSignUp` / `AdminSetUserPassword` — see mootmaker/testing-strategy.md's
"Bypassing the code requirement entirely").

**Deployed 2026-08-15, unchanged since**: `deploy/terraform/` here has the receipt rule set/rule,
SNS topic (with a policy letting the SES rule publish to it), and SQS queue (subscribed to the
topic, raw delivery enabled), plus `deploy-email-infra.sh`/`undeploy-email-infra.sh` at the repo
root, matching mootmaker-domain's no-environment-argument pattern (see "No environment argument"
below). The domain identity is referenced via `data "aws_ses_domain_identity"` rather than a
remote-state read, mirroring how mootmaker-api/mootmaker-webapp already find mootmaker-domain's
hosted zone. `mail.mootmaker.com` genuinely receives mail into `sqs_queue_url`, and this pipeline
is exercised end-to-end by mootmaker-webapp's `e2e/sign-up.spec.ts` and `e2e/forgot-password.spec.ts`.

**2026-08-19 repo rename**: this repo moved from `mootmaker-e2e` to `mootmaker-test-infra`, but the
deployed AWS resources, their Terraform-managed names, and the state key they're stored under
(`mootmaker-e2e-email/terraform.tfstate`) were all left exactly as they were — see
`deploy/terraform/backend.hcl`'s comment for why (changing any of them would mean either
re-pointing Terraform at an empty state for already-live resources, or forcing a destroy+recreate
of a pipeline other tests actively depend on — not something to fold silently into a rename).

### No environment argument

Unlike `create-ephemeral-env.sh`'s pipeline, this Terraform takes no environment name — deployed
once and left running, like mootmaker-domain's hosted zone. Reasoning (see also
`deploy/terraform/backend.hcl`'s and `ses.tf`'s comments):

- SES allows only one *active* receipt rule set per region/account, so a fresh rule set per
  ephemeral e2e run would mean concurrent runs fighting over which one is active.
- Concurrency is instead handled at the message level: each e2e run sends to a uniquely-tagged
  address under the shared subdomain and filters the SQS queue for its own tag.
- A fixed backend state key also means `cleanup-stale-envs.sh`'s discovery logic — which groups by
  first path segment and matches only the `<kind>-<YYMMDD>-<rand4>` shape (see [Naming
  convention](#naming-convention) below) — never mistakes this persistent infrastructure for a
  stale ephemeral environment.

## Ephemeral environment scripts

Decided 2026-08-15 (see [mootmaker/testing-strategy.md's Ephemeral environment
lifecycle](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md#ephemeral-environment-lifecycle)
for how this fits the overall policy). **Built and tested against real AWS environments,
2026-08-15**; a fourth script (`list-ephemeral-envs.sh`) added 2026-08-19, alongside real
behavioural changes to the naming convention and `teardown-ephemeral-env.sh` (not just doc
updates) — see [Naming convention](#naming-convention) and the `list-ephemeral-envs.sh` bullet
below.

Four separate bash scripts, matching the one-script-one-job convention already used by
`deploy.sh`/`undeploy.sh`/`authenticate.sh`/`verify.sh` elsewhere in the project. Bash rather than
a Node/TS tool, chiefly for consistency with every other operational script in the project. The
first three mostly need to shell out to mootmaker-api's and mootmaker-webapp's existing
`deploy.sh`/`undeploy.sh` rather than reimplement any deploy mechanics themselves;
`list-ephemeral-envs.sh` is the odd one out - read-only, it talks to Terraform directly instead
(see its own bullet below) since none of `deploy.sh`/`undeploy.sh` offer a read-only mode.

- **`create-ephemeral-env.sh [claude|web-e2e|web-acc|...]`** (default `claude`): generates a name
  (`<kind>-<YYMMDD>-<rand4>` — `claude` for Claude's own interactive dev sessions, or a short
  `<frontend>-<tier>` naming exactly which automated suite created it, e.g. `web-e2e-<YYMMDD>-<rand4>`
  for `mootmaker-webapp/e2e/run.sh` — see the naming convention in the overall strategy doc and
  [Naming convention](#naming-convention) below), then calls `mootmaker-api/deploy.sh <name>` followed by
  `mootmaker-webapp/deploy.sh <name>` (sibling checkouts, resolved relative to this script's own
  location rather than the caller's working directory). Prints the generated name as the last line
  of stdout on success; on failure, prints the (possibly partially-deployed) name and the
  `teardown-ephemeral-env.sh` command to clean it up. Does **not** touch the SES/SNS/SQS pipeline —
  that's a separate, persistent, always-on piece of infrastructure (see above), not something
  created per environment.

- **`teardown-ephemeral-env.sh <name>`**: tears down one specific, already-known environment —
  calls `undeploy.sh <name>` for mootmaker-webapp then mootmaker-api. Refuses to run unless `name`
  matches `^[a-z][a-z0-9-]{0,7}-[0-9]{6}-[a-z0-9]{4}$` exactly — a hard safety rail so a typo can
  never reach `test`/`production`; deliberately strict on shape only, not on which specific `kind`
  values exist (see [Naming convention](#naming-convention) below). Used by any frontend's
  `e2e/run.sh`/`acceptance/run.sh` (see mootmaker-webapp/testing-strategy.md) and by Claude's own
  commit-time cleanup prompt.

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

- **`list-ephemeral-envs.sh`** (added 2026-08-19): read-only report, not a teardown tool. For every
  `<environment>/<project>/terraform.tfstate` object matching the naming convention, downloads it
  and counts the resources actually tracked inside via `jq '.resources | length'`. A count of 0
  means a `terraform destroy` already ran for that project and its state object is a pure leftover
  with nothing left to destroy — safe to `aws s3 rm` directly, no teardown needed.

  For a nonzero count (`mootmaker-api`/`mootmaker-webapp` only — anything else is state-only, see
  the script's own "Known project layouts" comment), also runs a real AWS-check: `terraform plan
  -refresh-only -detailed-exitcode`, a read-only refresh that compares state against actual AWS
  without proposing or persisting any change. **This needed a correction after the first version
  was built and tested against a real, freshly-deployed environment**: a nonzero exit code from
  that command does *not* mean resources were removed — 12 of that environment's 51 resources came
  back "changed" (the ACM certificate finishing async validation, `tags = {}`/`layers = []`
  provider-schema cosmetic defaults, a Cognito pool's genuinely-changing
  `estimated_number_of_users`) with nothing actually missing, which the first version would have
  wrongly reported as "DRIFT - resources may be gone." Terraform's own refresh-only output
  distinguishes the two cases textually — `# X has changed` (attributes differ, resource still
  exists) versus `# X has been deleted` (refresh couldn't find it in AWS at all) — so the script
  greps specifically for the latter. Reports `matches` (no drift), `present (drift)` (drifted but
  nothing missing), or `MISSING` (specific resources confirmed gone from AWS, listed by address)
  accordingly.

  Verified against real AWS the same day it was added, in two parts: (1) all 9 leftover state
  objects from the 2026-08-15 testing session (4 environments, `mootmaker-api`/`mootmaker-webapp`
  each, plus one stray `mootmaker-tools-database-reset` from an ad hoc deploy) correctly classified
  as `0 (empty)`; (2) a fresh `claude-*` environment deployed specifically to test the AWS-check —
  first confirmed both projects correctly reported `present (drift)` (not a false `MISSING`, fixing
  the bug above), then one DynamoDB table was deleted by hand (`aws dynamodb delete-table`, outside
  Terraform) to manufacture a genuine case, and the script correctly reported `MISSING` naming
  exactly that one table and no others out of 51 resources. Environment fully torn down afterward
  (Terraform silently reconciled the manually-deleted table as part of the normal destroy, exactly
  as expected).

  One implementation note worth keeping in mind if this script is ever extended: `check_against_aws`
  is called via command substitution (`aws_check="$(check_against_aws ...)"`) to capture its
  one-line status, and command substitution always forks a subshell — an early draft accumulated
  drift details into a shell array *inside* that function, which silently vanished once each
  subshell exited (the classic bash gotcha). Detail is written to files in a `mktemp -d` directory
  instead, read back after the main loop completes.

### Naming convention

**Changed 2026-08-19**: environment names now identify exactly what created them, not just that
they're ephemeral. Previously every automated test run used a single generic `e2e-*` prefix,
indistinguishable from any other frontend's test runs — a problem the moment a second frontend
(`mootmaker-android`) needs the same pattern. `create-ephemeral-env.sh`'s `kind` argument is no
longer restricted to the literal values `claude`/`e2e`; any lowercase string (letters, digits,
hyphens, starting with a letter, 8 characters or fewer) is accepted, and `teardown-ephemeral-env.sh`/
`cleanup-stale-envs.sh` were loosened to match on shape (`<kind>-<YYMMDD>-<rand4>`) rather than an
exact `claude`/`e2e` enum. In use today:

- `claude` — Claude's own interactive dev-session environments (unchanged), reused for a whole
  session rather than per-task.
- `web-e2e` / `web-acc` — `mootmaker-webapp`'s own `e2e/run.sh` / `acceptance/run.sh`.
- `and-e2e` / `and-acc` — expected once `mootmaker-android` gains the same `e2e`/`acceptance`
  pattern; not built yet.

The `kind` budget is capped at 8 characters (with `web-e2e`/`web-acc` at 7, leaving a little
margin) because `-YYMMDD-<rand4>` is a fixed 12 characters and the overall environment-name ceiling
is 22 (see mootmaker/testing-strategy.md#environments) — `kind` alone could theoretically stretch to
10, but 8 leaves a bit of safety margin below that hard limit. Verified against the real scripts
(not just the regex in isolation): both new-shape rejections (`create-ephemeral-env.sh` with an
invalid `kind`, `teardown-ephemeral-env.sh` against `test`) and acceptances (`web-e2e-<date>-<rand>`
passing the validation gate) behave as intended, with no AWS calls made before an invalid input is
rejected.

### Testing notes (2026-08-15)

All three scripts were exercised repeatedly against real AWS (multiple `claude-*`/`e2e-*`
environments created and torn down; `cleanup-stale-envs.sh` run against a real environment and
correctly discovered/listed it before tearing it down on confirmation).

Two mootmaker-api-side issues turned up during this testing (both are findings *about*
mootmaker-api, not bugs in these scripts) — **both fixed and re-verified the same session**:

1. **`claude-*` names overflowed a Lambda function-name limit.**
   `${environment}-mootmaker-post-confirmation-create-person` was 65 characters for the original
   `claude-<YYMMDD>-<HHmm>-<rand4>` form (Lambda's limit is 64). Fixed by dropping the
   time-of-day component — day-level cleanup granularity doesn't need it anyway.
2. **Every ephemeral environment failed to fully deploy**, because mootmaker-api's (now-removed)
   email verification-code bypass self-enabled purely from the environment name, unconditionally
   trying to create an SCP-blocked KMS key on every `claude-*`/`e2e-*` deploy. Fixed at the time
   with an explicit opt-in variable defaulting off; the whole feature was later dropped entirely
   (cost reasons unrelated to this bug — see mootmaker-api's own `testing-strategy.md`), so this
   specific failure mode no longer exists at all.

**Fixed 2026-08-19** (previously a known gap): `terraform destroy` empties a state file's contents
but doesn't delete the S3 object itself, so a fully-torn-down environment's
`<environment>/<project-name>/terraform.tfstate` key used to keep existing (now empty) after
`teardown-ephemeral-env.sh` ran — `cleanup-stale-envs.sh` would keep listing that environment name
forever, as a "phantom" entry with nothing left to actually tear down. `teardown-ephemeral-env.sh`
now deletes the two state objects it's itself responsible for (`<name>/mootmaker-webapp/...` and
`<name>/mootmaker-api/...`) right after both `undeploy.sh` calls succeed — a best-effort step
(logged as a warning, not a hard failure, if it doesn't work) so a transient S3 error can't make an
already-successful teardown report as failed. Deliberately scoped to only those two known keys,
never a blanket delete of everything under `<environment>/` — some other project's state could in
principle also live under that same environment name (e.g. an ad hoc
`mootmaker-tools/*/deploy.sh` run against it) that this script has no knowledge of and didn't just
destroy; removing that state object without having destroyed its resources first would orphan real
infrastructure with nothing left to track it. Verified against a real already-empty environment
(`claude-260819-ep06`) — re-running teardown against it was confirmed a safe no-op for both
`undeploy.sh` calls, and the two state objects were confirmed removed from the bucket afterward.

Running `teardown-ephemeral-env.sh`/the destroy step again against an environment whose resources
are already gone (but whose state objects haven't been cleaned up yet - e.g. from before this fix)
is still a safe no-op either way.

## Known gaps / future work

- The `--api-only`-style flag noted under [Purpose](#purpose) above, once Android's acceptance
  suite exists and needs it.
- The GitHub-side rename from `mootmaker-e2e` to `mootmaker-test-infra` — deferred deliberately,
  see [README.md's History](README.md#history).
