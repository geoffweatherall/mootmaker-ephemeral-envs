# mootmaker-e2e

A project that is part of my [Claude Code exploration](https://github.com/geoffweatherall/mootmaker).

## Purpose

Full-stack end-to-end testing for the [mootmaker](https://github.com/geoffweatherall/mootmaker)
project: tests that exercise a genuinely deployed
[mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp) against a genuinely
deployed [mootmaker-api](https://github.com/geoffweatherall/mootmaker-api), including real Amazon
Cognito authentication and real email delivery for the sign-up/forgot-password verification-code
flows — the things neither repo's own test suite can see on its own. See
[testing-strategy.md](testing-strategy.md) for the detail, and
[mootmaker/testing-strategy.md](https://github.com/geoffweatherall/mootmaker/blob/main/testing-strategy.md)
for how this fits the wider strategy across all three repos.

This repo also owns the supporting infrastructure that exists purely for testing purposes and
doesn't belong in the API's or webapp's own deployments — currently, the SES→SNS→SQS email-reading
path described in [testing-strategy.md](testing-strategy.md).

See [use-cases.md](use-cases.md) for the starting list of user-focused scenarios these tests are
expected to eventually cover.

## Status

The three ephemeral-environment lifecycle scripts (`create-ephemeral-env.sh`,
`teardown-ephemeral-env.sh`, `cleanup-stale-envs.sh`) are built and tested
against real AWS environments — see
[testing-strategy.md](testing-strategy.md#ephemeral-environment-scripts) for
detail.

The real-email SES→SNS→SQS pipeline (`deploy/terraform/`, plus the matching
domain identity in [mootmaker-domain](https://github.com/geoffweatherall/mootmaker-domain))
is deployed and live — `mail.mootmaker.com` genuinely receives mail into this
project's SQS queue. See
[testing-strategy.md](testing-strategy.md#real-email-reading-option-2--sessnssqs)
for detail.

The Playwright full-stack test suite (`tests/`, run via
`./run-full-stack-tests.sh`) covers a real sign-up, a real password reset
(both with a real emailed code), and a deployed-site smoke check — see
[testing-strategy.md](testing-strategy.md#full-stack-test-suite) for detail
and current verification status.
