# verify-signed-nightly: &x74

Where: the `verify-signed-nightly` job in `.github/workflows/nightly.yml`, above `- &x74`.

cmux-next: the app's CFBundleShortVersionString and every bundled
CLI's `--version` say the cmux-next version (cmux-tui/Cargo.toml
[workspace.package]); a 0.1.0 `cmux` inside a 1.0.0 app fails here.
