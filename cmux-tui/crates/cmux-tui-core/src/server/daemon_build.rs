//! The daemon's build identity in `identify` (`daemon-build-v1`,
//! plans/cmux-next/version-skew.md step 2).
//!
//! `build_id` names the exact build of the binary that serves the socket
//! (the source commit, with a hash of uncommitted changes for a dirty
//! build). `cli_path` is the absolute path of that binary: the daemon and
//! the `cmux` CLI are one binary, so it is the CLI that matches this daemon.
//! A CLI that meets a daemon of another build uses both to find the
//! matching CLI (version-skew.md step 3, which also checks the path before
//! it runs anything). The daemon's entry point installs them once at start;
//! a mux that runs without them (tests, embedders) reports `null`.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Advertises `build_id` and `cli_path` in `identify`.
pub const DAEMON_BUILD_CAPABILITY: &str = "daemon-build-v1";

/// The build identity of the process that serves the socket.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonBuild {
    build_id: String,
    cli_path: Option<PathBuf>,
}

impl DaemonBuild {
    /// A path that is not absolute is dropped: a client must never resolve
    /// a daemon's CLI against its own working directory or PATH.
    pub fn new(build_id: impl Into<String>, cli_path: PathBuf) -> Self {
        let cli_path = cli_path.is_absolute().then_some(cli_path);
        Self { build_id: build_id.into(), cli_path }
    }

    pub fn build_id(&self) -> &str {
        &self.build_id
    }

    pub fn cli_path(&self) -> Option<&Path> {
        self.cli_path.as_deref()
    }
}

static DAEMON_BUILD: OnceLock<DaemonBuild> = OnceLock::new();

/// Records this process's build identity. The first call wins: the identity
/// of a running daemon never changes.
pub fn install_daemon_build(build: DaemonBuild) {
    let _ = DAEMON_BUILD.set(build);
}

/// True once the entry point installed this process's build identity.
pub(super) fn installed() -> bool {
    DAEMON_BUILD.get().is_some()
}

/// `(build_id, cli_path)` for `identify`; both `null` when not installed.
pub(super) fn identify_build_fields() -> (Option<String>, Option<String>) {
    let Some(build) = DAEMON_BUILD.get() else {
        return (None, None);
    };
    let cli_path = build.cli_path().and_then(Path::to_str).map(str::to_owned);
    (Some(build.build_id.clone()), cli_path)
}

/// The source stamps of a packaged build (`build_commit` and
/// `ghostty_commit` in `identify` and `ping`). The binary reads them at
/// compile time (`CMUX_TUI_BUILD_COMMIT`, else `CMUX_MUX_BUILD_COMMIT`;
/// `CMUX_TUI_GHOSTTY_COMMIT`) and installs them at start. This crate never
/// reads them itself: a compile-time read here made every new stamp
/// recompile the whole crate. An empty stamp counts as no stamp.
///
/// `build_time` (`with_build_time`): unix seconds of the source commit
/// (`cmux_build_identity::BUILD_TIME`), in `identify {revisions: true}`, so
/// a client that updates machines can tell an older build from a newer one
/// (`cmux link machine update --if-older`). Zero counts as unknown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BuildStamp {
    build_commit: Option<&'static str>,
    ghostty_commit: Option<&'static str>,
    build_time: Option<u64>,
}

impl BuildStamp {
    pub fn new(build_commit: Option<&'static str>, ghostty_commit: Option<&'static str>) -> Self {
        Self {
            build_commit: build_commit.filter(|commit| !commit.is_empty()),
            ghostty_commit: ghostty_commit.filter(|commit| !commit.is_empty()),
            build_time: None,
        }
    }

    /// The stamp with its source commit's time (unix seconds; 0: unknown).
    #[must_use]
    pub fn with_build_time(mut self, time: u64) -> Self {
        self.build_time = (time != 0).then_some(time);
        self
    }

    pub fn build_time(&self) -> Option<u64> {
        self.build_time
    }

    pub fn build_commit(&self) -> Option<&'static str> {
        self.build_commit
    }

    pub fn ghostty_commit(&self) -> Option<&'static str> {
        self.ghostty_commit
    }
}

static BUILD_STAMP: OnceLock<BuildStamp> = OnceLock::new();

/// Records this process's source stamps. The first call wins. A mux that
/// runs without them (tests, embedders) reports `null` for both, as an
/// unstamped build does. Every entry point that serves `identify` or `ping`
/// must call it before it serves (the cmux-tui binary does it first in
/// `main`); a future embedder that serves them (for example an FFI daemon)
/// and does not call it reports `build_commit: null`, and the app's daemon
/// handoff then does not occur.
pub fn install_build_stamp(stamp: BuildStamp) {
    let _ = BUILD_STAMP.set(stamp);
}

pub(super) fn stamped_build_commit() -> Option<&'static str> {
    BUILD_STAMP.get().and_then(BuildStamp::build_commit)
}

pub(super) fn stamped_build_time() -> Option<u64> {
    BUILD_STAMP.get().and_then(BuildStamp::build_time)
}

pub(super) fn stamped_ghostty_commit() -> Option<&'static str> {
    BUILD_STAMP.get().and_then(BuildStamp::ghostty_commit)
}
