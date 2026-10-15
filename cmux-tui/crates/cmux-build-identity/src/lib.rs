//! The identity of this cmux-tui build: `CMUX_TUI_BUILD_COMMIT` when the
//! build sets it (release and CI builds), otherwise the HEAD commit, plus
//! `-dirty.<hash>` of the uncommitted cmux-tui sources (build.rs).
//!
//! Daemon skew detection and SSH host re-bootstrap compare this value, so a
//! dev build must change it on every source edit. It lives in this leaf crate,
//! not in cmux-remote, because the build script reruns on every edit in the
//! workspace: only this crate and the crates that read it (cmux-tui) recompile,
//! not cmux-remote and everything between it and the binary. Library crates
//! take the value as an argument (`SshBootstrapConfig::defaults`,
//! `pinned_linux_payload`); do not depend on this crate from a library that
//! the binary does not otherwise rebuild on every edit.

#![forbid(unsafe_code)]

/// This build's identity. See the crate documentation.
pub const BUILD_IDENTITY: &str = env!("CMUX_TUI_BUILD_IDENTITY");
