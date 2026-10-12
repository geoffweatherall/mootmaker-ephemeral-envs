# Testing strategy

This repository has no automated test suite. Its scripts create and destroy real AWS resources, and the
only meaningful test of them is a run against real AWS. The layers across the whole system are in the
hub's [testing overview](https://github.com/geoffweatherall/mootmaker/blob/main/docs/overview/testing.md).

## How the scripts are exercised anyway

Every release and every webapp or Android acceptance run creates and tears down environments with these
scripts or the same naming convention, and the sweep runs daily. A broken script therefore shows up
quickly in normal work. That is not a substitute for testing a change before merging it.

## Before merging a change to a script

1. **Bash checks:** `bash -n <script>` and, if installed, `shellcheck <script>`.
2. **Reject what must be rejected, with no AWS call made first:** an invalid `kind` for
   `create-ephemeral-env.sh`, and `test`, `production` or a malformed name for
   `teardown-ephemeral-env.sh`.
3. **A real round trip** in a `claude` environment: create (with `--with-demo-data` if the change touches
   it), `list-ephemeral-envs.sh` to see it reported as present, teardown, then
   `aws s3 ls s3://remote-state-<account>/<name>/` to confirm nothing is left.
4. **Sweep changes:** run `sweep-stale-envs.sh` without `--destroy` first, and read the report before any
   destroying run. To exercise the age guard, pass a small `--max-age-hours` against an environment
   you own.

**Check teardown against AWS, not the script's exit code.** Look for leftover state objects and log
groups, and for resources named after the environment.

## Things that are easy to get wrong

- **A refresh-only plan's exit code 2 does not mean resources are gone.** Attributes that drift
  harmlessly, such as an ACM certificate finishing validation or a Cognito pool's user estimate, also
  produce it. `list-ephemeral-envs.sh` looks for Terraform's "has been deleted" lines instead.
- **Command substitution runs in a subshell.** Anything a function called as `$(...)` accumulates in a
  shell variable is lost when the subshell exits, so the report scripts write detail to temporary files.
- **Teardown deletes only the state objects of components it actually destroyed.** Deleting state for
  something still running would orphan real infrastructure with nothing left to track it.
