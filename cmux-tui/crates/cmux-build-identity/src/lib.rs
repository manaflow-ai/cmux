//! The exact build of this cmux-tui binary: the source commit, plus a hash
//! of uncommitted source changes for a dirty build (`build.rs`), or
//! `CMUX_TUI_BUILD_COMMIT` when the release sets it. No dependencies, so it
//! builds on every target: the daemon reports it in `identify` (`build_id`,
//! version skew) and the SSH bootstrap compares it with a remote binary.

/// This build's identity.
pub const BUILD_IDENTITY: &str = env!("CMUX_TUI_BUILD_IDENTITY");
