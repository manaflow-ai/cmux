# env: BASH_ENV: '$({ w="${GITHUB_WORKSPACE:-/nonexistent}/scripts/ci/api_call_log/env.

Where: the `env` job in `.github/workflows/nightly.yml`, above `BASH_ENV: '$({ w="${GITHUB_WORKSPACE:-/nonexistent}/scripts/ci/api_call_log/env.sh"; t="${RUNNER_TEM…`.

Temporary REST budget attribution: one gh-call line per GitHub API call (scripts/ci/api_call_log/env.sh, fetched at a fixed commit when the checkout has no copy).
