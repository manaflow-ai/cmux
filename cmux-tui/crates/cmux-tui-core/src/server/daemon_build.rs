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
