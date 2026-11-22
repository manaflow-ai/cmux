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

/// The mux owner socket `ensure_daemon` uses: `explicit` (or
/// `CMUX_MUX_SOCKET`) when set; else, for a session with its own state root,
/// a socket in that state, because the default per-session socket may be
/// served by an owner of the default state root; else `None` (derived).
/// The first start of such a session imports its default-root registry once.
pub(super) fn socket_for(
    explicit: Option<&Path>,
    session: &str,
    state_root: Option<&Path>,
    session_state: &Path,
) -> anyhow::Result<Option<PathBuf>> {
    if let Some(socket) = explicit {
        return Ok(Some(socket.to_path_buf()));
    }
    if let Some(socket) = std::env::var_os("CMUX_MUX_SOCKET") {
        return Ok(Some(socket.into()));
    }
    let Some(state_root) = state_root else { return Ok(None) };
    import_default_root_session(session, state_root);
    daemon_mux_socket_path(session_state).map(Some)
}

/// Before an explicit `--state-dir` reached the mux owner, the owner kept
/// this link's workspaces in the default state root. The first start with an
/// empty `<state-dir>/workspace` copies that registry once (cx-0b8z). A
/// failed import is logged and the owner starts on its own store.
fn import_default_root_session(session: &str, state_root: &Path) {
    use cmux_tui_core::session_state_import::{SessionStateImport, import_default_root_session};
    let Some(default_root) = cmux_tui_core::platform::workspace_state_dir() else { return };
    let target = mux_state_root(state_root);
    match import_default_root_session(&default_root, &target, session) {
        Ok(SessionStateImport::Imported { from, to }) => {
            let (from, to) = (from.display(), to.display());
            eprintln!("cmux-tui: imported session registry {from} into {to}");
        }
        Ok(SessionStateImport::Skipped) => {}
        Err(error) => eprintln!("cmux-tui: default-root session import failed: {error:#}"),
    }
}

/// The mux owner socket of a session that keeps its state in `state`
/// (`daemon_paths`): beside its link socket, or in the same private runtime
/// directory when that path is too long. It depends on the state directory,
/// so a mux owner of another state root never answers for this one (cx-0b8z).
#[cfg(unix)]
pub(super) fn daemon_mux_socket_path(state: &Path) -> anyhow::Result<PathBuf> {
    let beside = state.join("mux.sock");
    if crate::remote_runtime::unix_socket_path_fits(&beside) {
        return Ok(beside);
    }
    let (link, _) = crate::remote_runtime::daemon_runtime_socket_paths(state)?;
    let name = link
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix("-l.sock"))
        .ok_or_else(|| anyhow!("remote daemon runtime socket name is unexpected"))?;
    let mux = link.with_file_name(format!("{name}-m.sock"));
    if !crate::remote_runtime::unix_socket_path_fits(&mux) {
        return Err(anyhow!("remote daemon runtime socket path is too long for this platform"));
    }
    Ok(mux)
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
