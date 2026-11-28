# cmux-next.yml: job `release-compile-fast`, step "Check out the fleet compile reader"

Moved out of `.github/workflows/cmux-next.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Why: one compile per head. The tip check already compiles this head on the fleet; read its verdict
Why: 2026-11-24-swift-canary-fleet-1.md
