# runner-preflight: set -euo pipefail

Where: the `runner-preflight` job in `.github/workflows/nightly.yml`, above `set -euo pipefail`.

The Macs get 403 from github.com on anonymous requests. Every checkout here sets
persist-credentials: false, so actions/checkout's clean of a reused partial clone (a lazy
promisor fetch, before it sets up auth) and every later git fetch went out with no credential.
One header job-wide: the empty entry clears any header in .git/config (two make GitHub answer
400); a step that sets its own GIT_CONFIG_COUNT still sends only its own.
