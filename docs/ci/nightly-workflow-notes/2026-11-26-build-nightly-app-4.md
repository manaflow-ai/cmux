# 2026-11-26-build-nightly-app-4

Above `- name: Restore the acpmux and OptChat Chief dependency builds (cmux-next)` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The cmux-next Rust helpers below (acpmux, the OptChat Chief) compiled
every dependency from scratch on each nightly: about 150 s of the
serial build path (2026-10-09). Their target dirs keep the dependency
builds between nightly-next runs; cargo still rebuilds what changed.

## nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Jobs publish-nightly needs that run beside this one; derived from the
needs graph by tests/test_nightly_stop_if_publish_doomed.py.
