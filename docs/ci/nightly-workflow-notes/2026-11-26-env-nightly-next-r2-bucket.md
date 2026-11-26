# env: NIGHTLY_NEXT_R2_BUCKET: cmux-nightly-next

Where: the `env` job in `.github/workflows/nightly.yml`, above `NIGHTLY_NEXT_R2_BUCKET: cmux-nightly-next`.

cmux-next's own version line (CFBundleShortVersionString
<V>-nightly.<build>) comes from cmux-tui/Cargo.toml [workspace.package]
(`scripts/ci/nightly_version.py next-base`), the version the bundled CLIs
print too; main's nightly and RC keep the project version.
