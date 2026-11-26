# promote-nightly-next: runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.

Where: the `promote-nightly-next` job in `.github/workflows/nightly.yml`, above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '…`.

Ends on the nightly slot's label as a literal, never vars.CI_NIGHTLY_NEXT_BUILD_RUNNER: main's
repository-variable check (scripts/ci/signing_runner_variables.py) holds a variable a signing job
reads to blacksmith-*/ubuntu-*, and that variable names an owned Mac (#26450).
