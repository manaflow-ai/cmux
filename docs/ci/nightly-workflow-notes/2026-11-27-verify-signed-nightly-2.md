# 2026-11-27-verify-signed-nightly-2

Above `- &x74` (job `verify-signed-nightly`) in `.github/workflows/nightly.yml`.

cmux-next: the app's CFBundleShortVersionString and every bundled
CLI's `--version` say the cmux-next version (cmux-tui/Cargo.toml
[workspace.package]); a 0.1.0 `cmux` inside a 1.0.0 app fails here.
