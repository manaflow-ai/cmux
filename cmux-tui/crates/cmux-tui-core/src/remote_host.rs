//! cmux Remote (docs/cmux-remote.md): the daemon's one signed host for
//! Computer Use and Screen Sharing, the process that holds macOS's
//! Accessibility and Screen Recording grants.
//!
//! The daemon starts the host from a verified copy of the app's embedded
//! `cmux Remote.app` outside the app bundle (macOS 26 checks Screen Recording
//! for a process inside an app bundle as the outermost app), with macOS
//! responsibility disclaimed, so the grants belong to cmux Remote and never
//! to cmux, the daemon, shells or agents. The host serves its supervisor
//! socket; the daemon is a client of it, which is what lets a new daemon
//! adopt a running host after a handoff (docs/cloud-guest-upgrades.md):
//!
//! - start: a recorded host (`host.json`: pid, start time, secret, bundle
//!   digest) that is alive and answers the hello is adopted; otherwise one is
//!   started when Computer Use or Screen Sharing is on.
//! - crash or exit: started again with [`Backoff`] while wanted.
//! - another embedded build: an idle host is drained and replaced at once; a
//!   busy one (a Screen Sharing session) keeps running until it reports idle.
//! - daemon handoff: the host keeps serving; it exits by itself when no
//!   daemon adopts it within its grace.
//!
//! The supervisor secret is 32 random bytes per host, given to the host on
//! an inherited pipe (fd 3) and kept in the 0600 record for the next daemon.
//! Same-user processes can read that record; the host's sensitive answers
//! (the app socket's secret) go only to the verified app
//! (`server/remote_host_command.rs`), and raising access needs the app or the
//! person (the command's origin rule).
//!
//! Windows and Linux run the same lifecycle with the Rust host
//! (`crates/cmux-remote-host`, docs/cmux-remote.md "Windows and Linux"): a
//! sha256-verified copy of `cmux-remote-host` beside the daemon, started in the
//! person's desktop session (a systemd user unit on Linux, an interactive-session
//! task on Windows), the same `remote-host-v1` wire.


/// Advertised by `identify` once `remote-host-status` and `remote-host-call` exist.
pub(crate) const REMOTE_HOST_CAPABILITY: &str = "remote-host-v1";

#[cfg(any(unix, windows))]
use std::path::{Path, PathBuf};

/// The folder where the cmux Remote host of the daemon on `daemon_socket`
/// writes the Computer Use worker's `endpoint.json` (acpmux reads it from
/// `CMUX_NEXT_CUA_V2_DIR`): `<runtime>/cu`, where the runtime folder is the one
/// the daemon passes the host as `--layout-dir`. It depends only on the daemon
/// socket path, so a process that knows that socket names the same folder. On
/// macOS the app names the folder itself; Windows and Linux use this.
#[cfg(any(unix, windows))]
pub fn computer_use_endpoint_dir(daemon_socket: &Path) -> PathBuf {
    runtime_dir_for(daemon_socket).join("cu")
}

#[cfg(any(unix, windows))]
#[path = "remote_host/supervisor.rs"]
mod imp;
#[cfg(any(unix, windows))]
pub(crate) use imp::*;

#[cfg(not(any(unix, windows)))]
mod imp {
    use serde_json::{Value, json};

    /// cmux Remote runs on macOS, Windows and Linux; elsewhere the commands answer that.
    #[derive(Default)]
    pub(crate) struct RemoteHostSupervisor;

    impl RemoteHostSupervisor {
        pub(crate) fn status(&self) -> Value {
            json!({"state": "off", "reason": "cmux Remote runs on macOS, Windows and Linux"})
        }
        pub(crate) fn call(&self, _method: &str, _params: Value) -> Result<Value, String> {
            Err("cmux Remote runs on macOS, Windows and Linux".into())
        }
        pub(crate) fn set_config(&self, _update: &Value) -> Result<Value, String> {
            Err("cmux Remote runs on macOS, Windows and Linux".into())
        }
        pub(crate) fn set_acpmux_socket(&self, _socket: Option<std::path::PathBuf>) {}
    }

    impl crate::mux::Mux {
        pub fn configure_remote_host(self: &std::sync::Arc<Self>, _daemon_socket: &std::path::Path) {}
    }
}
#[cfg(not(any(unix, windows)))]
pub(crate) use imp::*;

#[cfg(all(test, any(unix, windows)))]
mod endpoint_dir_tests {
    use std::path::Path;

    /// The folder acpmux is told is the one the host writes `endpoint.json`
    /// into: the host's `--layout-dir` (the runtime folder) plus `cu`.
    #[test]
    fn the_endpoint_folder_is_the_hosts_layout_cu_folder() {
        let socket = Path::new("/tmp/cmux-test/daemon.sock");
        let paths = super::imp::paths_for(socket, Path::new("/tmp/cmux-test/state"));
        assert_eq!(super::computer_use_endpoint_dir(socket), paths.runtime.join("cu"));
        assert_ne!(
            super::computer_use_endpoint_dir(socket),
            super::computer_use_endpoint_dir(Path::new("/tmp/cmux-test/other.sock")),
            "each daemon has its own host"
        );
    }
}
