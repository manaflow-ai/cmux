//! cmux-tui's integration tests, as one test binary (#56677).
//!
//! Each file in `tests/` used to be its own test binary, and every one of them linked the whole
//! daemon: an edit to a crate below cmux-tui relinked about 200 binaries before one test ran.
//! Here they are modules of one binary instead. The list is written by `modules/build.rs` from
//! the files in `tests/`, so adding a test is still adding a file there. A test's full name
//! starts with its file's name: `cargo test -p cmux-tui --test it -- cli::`, or in nextest
//! `binary_id(cmux-tui::it) & test(/^cli::/)`.
//!
//! A file whose tests need a process of their own (it sets the environment of the whole
//! process, or installs the hermetic environment of `acpmux/tests/support/daemon_env.rs` before
//! `main`) keeps its own `[[test]]` in `Cargo.toml`, and so do the two Windows-only files the
//! Windows CI job builds alone; the build script leaves every file named there out.
//!
//! The support modules several test files share are compiled once, here; a test file names
//! one with `use crate::journey_support;`. Each allows its own dead code (a file uses some of
//! it); the two without that attribute get it here.

#[cfg(unix)]
#[path = "../journey_support/mod.rs"]
mod journey_support;

#[cfg(target_os = "linux")]
#[path = "../carrier_support/mod.rs"]
mod carrier_support;

#[cfg(unix)]
#[path = "../fault_support/mod.rs"]
mod fault_support;

#[allow(dead_code)]
#[path = "../support/private_state.rs"]
mod private_state;

#[cfg(unix)]
#[path = "../agent_message_policy/harness.rs"]
mod harness;

#[cfg(unix)]
#[allow(dead_code)]
#[path = "../../../../bindings/examples/rust-agent-screen-detection/src/wake_kinds.rs"]
mod detector_wake_kinds;

cmux_tui_test_modules::modules!();
