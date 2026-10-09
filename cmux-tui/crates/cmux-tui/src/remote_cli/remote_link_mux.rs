//! Which mux owner `remote-link` reaches, and whether it may start one.
//!
//! A derived socket (no `--mux-socket`) belongs to this session: `remote-link`
//! starts its headless mux owner when none answers. An explicit
//! `--mux-socket PATH` names a daemon that another supervisor owns (a paired
//! server's Chief brain runs its own launchd daemon at a fixed path), so
//! `remote-link` only attaches to it and never starts a second owner there:
//! a down daemon is an error the client shows as unreachable.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use anyhow::anyhow;

/// Arguments for the headless mux owner `ensure_daemon` starts. A derived
/// socket path is left for the owner to derive again from the same session,
/// so it keeps the owner checks it applies to its own runtime directory.
/// With `state_root` (`remote-link --state-dir`) the owner keeps its
/// workspace registry under that root, never in the default durable state
/// root, which can hold an older registry of the same session (cx-0b8z).
pub(super) fn mux_owner_args(
    session: &str,
    mux_socket: &Path,
    mux_socket_is_derived: bool,
    state_root: Option<&Path>,
) -> Vec<OsString> {
    let mut args: Vec<OsString> =
        ["--headless", "--session", session].into_iter().map(OsString::from).collect();
    if !mux_socket_is_derived {
        args.push("--socket".into());
        args.push(mux_socket.into());
    }
    if let Some(state_root) = state_root {
        args.push("--state".into());
        args.push(mux_state_root(state_root).into());
    }
    args
}

/// The workspace state root of the mux owner for remote state `state_root`:
/// its own directory, apart from the remote daemon's `sessions` and identity
/// files.
pub(super) fn mux_state_root(state_root: &Path) -> PathBuf {
    state_root.join("workspace")
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
            mux_owner_args("work", socket, true, None),
            ["--headless", "--session", "work"].map(OsString::from)
        );
        assert_eq!(
            mux_owner_args("work", socket, false, None),
            ["--headless", "--session", "work", "--socket", "/tmp/cmux-tui-501/work.sock"]
                .map(OsString::from)
        );
    }

    #[test]
    fn a_state_dir_gives_the_mux_owner_its_own_state_root() {
        let socket = Path::new("/srv/state/sessions/d29yaw/mux.sock");
        assert_eq!(
            mux_owner_args("work", socket, false, Some(Path::new("/srv/state"))),
            [
                "--headless",
                "--session",
                "work",
                "--socket",
                "/srv/state/sessions/d29yaw/mux.sock",
                "--state",
                "/srv/state/workspace",
            ]
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
