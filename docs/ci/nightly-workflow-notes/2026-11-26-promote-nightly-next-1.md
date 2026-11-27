# 2026-11-26-promote-nightly-next-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_SIGN_RUNNER || github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && vars.CI_NIGHTLY_SIGN_RUNNER || 'glaeda-nightly-std-xcode-26.6' }}` (job `promote-nightly-next`) in `.github/workflows/nightly.yml`.

Ends on the nightly slot's label as a literal, never vars.CI_NIGHTLY_NEXT_BUILD_RUNNER: main's
repository-variable check (scripts/ci/signing_runner_variables.py) holds a variable a signing job
reads to blacksmith-*/ubuntu-*, and that variable names an owned Mac (#26450).
