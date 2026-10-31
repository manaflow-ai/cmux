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


/// Advertised by `identify` once `remote-host-status` and `remote-host-call` exist.
pub(crate) const REMOTE_HOST_CAPABILITY: &str = "remote-host-v1";

#[cfg(unix)]
#[path = "remote_host/unix.rs"]
mod imp;
#[cfg(unix)]
pub(crate) use imp::*;

#[cfg(not(unix))]
mod imp {
    use serde_json::{Value, json};

    /// cmux Remote runs on macOS; elsewhere the commands answer that.
    #[derive(Default)]
    pub(crate) struct RemoteHostSupervisor;

    impl RemoteHostSupervisor {
        pub(crate) fn status(&self) -> Value {
            json!({"state": "off", "reason": "cmux Remote runs on macOS only"})
        }
        pub(crate) fn call(&self, _method: &str, _params: Value) -> Result<Value, String> {
            Err("cmux Remote runs on macOS only".into())
        }
        pub(crate) fn set_config(&self, _update: &Value) -> Result<Value, String> {
            Err("cmux Remote runs on macOS only".into())
        }
    }

    impl crate::mux::Mux {
        pub fn configure_remote_host(self: &std::sync::Arc<Self>, _daemon_socket: &std::path::Path) {}
    }
}
#[cfg(not(unix))]
pub(crate) use imp::*;
