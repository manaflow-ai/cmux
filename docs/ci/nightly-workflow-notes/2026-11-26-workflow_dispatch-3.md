# 2026-11-26-workflow_dispatch-3

Above `NIGHTLY_NEXT_R2_BUCKET: cmux-nightly-next` (job `workflow_dispatch`) in `.github/workflows/nightly.yml`.

cmux-next's own version line (CFBundleShortVersionString
<V>-nightly.<build>) comes from cmux-tui/Cargo.toml [workspace.package]
(`scripts/ci/nightly_version.py next-base`), the version the bundled CLIs
print too; main's nightly and RC keep the project version.
