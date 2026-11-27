# nightly.yml: job `verify-signed-nightly`, step "Download signed app"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

cmux-next: the app's CFBundleShortVersionString and every bundled
CLI's `--version` say the cmux-next version (cmux-tui/Cargo.toml
[workspace.package]); a 0.1.0 `cmux` inside a 1.0.0 app fails here.
