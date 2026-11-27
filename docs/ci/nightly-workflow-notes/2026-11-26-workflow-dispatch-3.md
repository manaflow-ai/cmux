# nightly.yml: job `workflow_dispatch`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

cmux-next's own version line (CFBundleShortVersionString
<V>-nightly.<build>) comes from cmux-tui/Cargo.toml [workspace.package]
(`scripts/ci/nightly_version.py next-base`), the version the bundled CLIs
print too; main's nightly and RC keep the project version.
