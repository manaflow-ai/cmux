# CMUX-570 shared Rust packaging experiment

Leo: "decreasing bundle size". Keep the browser engine bundled and every
existing app and CLI entry point available.

The current app links `cmux-app-ffi` while `Resources/bin/cmux` links the CLI
and daemon independently. This crate puts both dependency graphs into one
fat-LTO link. Its lock starts from the CLI workspace's lock: no third-party
dependency identity is changed. The five added identities are this crate,
the app FFI, and its three FFI wrappers.

`scripts/measure/shared-rust-core.sh` is the initial fleet link proof. It
checks every C export listed by the existing app FFI packaging headers and
runs a thin executable's `cmux --help` with a 30-second deadline. The output
explicitly measures link payloads, not an installed app. No shipping build
selects this crate.

The full comparison still requires two app artifacts from the same source,
architecture and nightly configuration:

- A: one `libcmux_core.dylib` in `Contents/Frameworks`, used by the app and a
  thin executable at `Contents/Resources/bin/cmux`. Keeping that executable
  preserves `current_exe()` and sibling helper paths.
- B: the combined static archive linked into the app executable, with the
  existing CLI symlinks dispatching into its Rust entry point before GUI
  initialization. Canonical `current_exe()` changes to `Contents/MacOS/cmux`;
  helper lookup and daemon re-exec must be verified before this can ship.

For each arm, `bundle-size.py report` must measure the complete app after
packaging and signing. Fleet launch smoke, browser page load, `cmux --help`,
`acpmux ls`, and `cmux-tui start` must pass. Select the smaller passing arm;
archive sizes and matching code bytes are not substitutes for that result.
Stop the experiment at a passing installed comparison or the task's eight
hour deadline. Chief and mobile-host consolidation follow that decision.
