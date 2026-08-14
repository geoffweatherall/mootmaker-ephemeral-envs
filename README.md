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
doesn't belong in the API's or webapp's own deployments — currently, the SES→SQS email-reading
path described in [testing-strategy.md](testing-strategy.md).

See [use-cases.md](use-cases.md) for the starting list of user-focused scenarios these tests are
expected to eventually cover.

## Status

This repo is newly created and doesn't contain any code yet — see
[testing-strategy.md](testing-strategy.md) for what's planned.
