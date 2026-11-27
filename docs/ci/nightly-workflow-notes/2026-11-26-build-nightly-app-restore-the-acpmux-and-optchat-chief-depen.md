# nightly.yml: job `build-nightly-app`, step "Restore the acpmux and OptChat Chief dependency builds (cmux-next)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The cmux-next Rust helpers below (acpmux, the OptChat Chief) compiled
every dependency from scratch on each nightly: about 150 s of the
serial build path (2026-10-09). Their target dirs keep the dependency
builds between nightly-next runs; cargo still rebuilds what changed.
