//! cmux remote browser host (plans/cmux-next/remote-tab-r2.md).
//!
//! The host process drives the CEF fork's remote presentation (`cmux_rp_*`)
//! through a C++ shim (`csrc/rb_shim.h`) and serves remote tabs over
//! `cmux.rd/1` (service `rb/1`). This crate's pure core, [`tab::HostTab`],
//! turns viewer control and input into calls on a [`tab::Presentation`] (the
//! shim behind a trait, faked in tests) using the shared reducers of
//! `cmux-remote-browser`. The shim binding (`ffi`) and the binary are macOS
//! only; encoding and transport plug in through lane 17's `cmux-encode` and
//! `cmux-rd-engine` (remote-tab-r2.md section 5).

pub mod tab;

#[cfg(target_os = "macos")]
pub mod ffi;
