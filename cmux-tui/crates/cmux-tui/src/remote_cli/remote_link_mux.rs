//! Which mux owner `remote-link` reaches, and whether it may start one.
//!
//! A derived socket (no `--mux-socket`) belongs to this session: `remote-link`
//! starts its headless mux owner when none answers. An explicit
//! `--mux-socket PATH` names a daemon that another supervisor owns (a paired
//! server's Chief brain runs its own launchd daemon at a fixed path), so
//! `remote-link` only attaches to it and never starts a second owner there:
//! a down daemon is an error the client shows as unreachable.

use std::ffi::OsString;
use std::path::Path;

use anyhow::anyhow;

/// Arguments for the headless mux owner `ensure_daemon` starts. A derived
/// socket path is left for the owner to derive again from the same session,
/// so it keeps the owner checks it applies to its own runtime directory.
pub(super) fn mux_owner_args(
    session: &str,
    mux_socket: &Path,
    mux_socket_is_derived: bool,
) -> Vec<OsString> {
    let mut args: Vec<OsString> =
        ["--headless", "--session", session].into_iter().map(OsString::from).collect();
    if !mux_socket_is_derived {
        args.push("--socket".into());
        args.push(mux_socket.into());
    }
    args
}

/// The refusal for an explicit `--mux-socket` whose daemon does not answer.
pub(super) fn not_running(mux_socket: &Path) -> anyhow::Error {
    anyhow!(
        "the session daemon at {} is not running; remote-link attaches to an explicit --mux-socket and never starts it",
        mux_socket.display()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_socket_remote_mux_owner_derives_its_own_socket() {
        let socket = Path::new("/tmp/cmux-tui-501/work.sock");
        assert_eq!(
            mux_owner_args("work", socket, true),
            ["--headless", "--session", "work"].map(OsString::from)
        );
        assert_eq!(
            mux_owner_args("work", socket, false),
            ["--headless", "--session", "work", "--socket", "/tmp/cmux-tui-501/work.sock"]
                .map(OsString::from)
        );
    }

    /// A paired server's brain daemon is down: remote-link refuses and starts
    /// neither a mux owner at the brain's socket nor a sidecar.
    #[test]
    fn explicit_mux_socket_is_attach_only() {
        let directory = tempfile::tempdir().unwrap();
        let session = "server-attach";
        let (session_state, link, _) =
            crate::remote_runtime::daemon_paths(session, Some(directory.path())).unwrap();
        let brain = directory.path().join("brain-daemon.sock");
        let error = super::super::ensure_daemon(
            session,
            Some(directory.path()),
            &session_state,
            &link,
            Some(&brain),
        )
        .expect_err("remote-link started a daemon at an explicit mux socket");
        assert!(error.to_string().contains("is not running"), "{error:#}");
        assert!(!brain.exists(), "a mux owner was started at the explicit socket");
        assert!(!link.exists(), "a sidecar was started for a missing explicit daemon");
    }
}
