# build-nightly-app: git show "$WORKFLOW_SHA:scripts/ci/git_fetch_retry.py" > "$fetch_retry" 2>/dev/n

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `git show "$WORKFLOW_SHA:scripts/ci/git_fetch_retry.py" > "$fetch_retry" 2>/dev/null \`.

The helper comes from local objects (the slot's, the borrowed mirror's, the mirror itself), never from
raw.githubusercontent.com: that anonymous read is what answered 429.
