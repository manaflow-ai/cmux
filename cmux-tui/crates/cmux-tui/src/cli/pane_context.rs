//! Which multiplexer a `cmux` call runs in, innermost first.
//!
//! A cmux-tui started in a cmux app terminal inherits that app's
//! `CMUX_SOCKET_PATH` (and `CMUX_BUNDLE_ID`, `CMUX_TAG`), and its daemon
//! hands them on to every pane it spawns. The daemon's own keys
//! (`CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID`) always name the pane's own
//! session, so a pane whose session is not the app's own daemon is a
//! cmux-tui pane: there the session wins (`cmux identify` reports the pane),
//! and the outer app stays reachable explicitly (`cmux app identify`,
//! `--app-socket`).
#![cfg_attr(not(unix), allow(dead_code))]

use std::path::{Path, PathBuf};

/// Where the caller runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Innermost {
    /// No cmux terminal names this process (a plain shell, an app agent chat).
    Outside,
    /// A terminal of the cmux app's own session: the app knows the caller.
    AppPane,
    /// A terminal of a cmux-tui session no app owns (or another app's
    /// session nested in this one): the session daemon knows the caller.
    SessionPane { socket: PathBuf, terminal: String },
}

/// [`Innermost`] from `env`, with `app_owns` saying whether the app this
/// CLI resolves owns the daemon at a socket.
pub(super) fn innermost_with(
    env: impl Fn(&str) -> Option<String>,
    app_owns: impl FnOnce(&Path) -> bool,
) -> Innermost {
    let set = |key: &str| env(key).filter(|value| !value.trim().is_empty());
    let Some(terminal) = set("CMUX_TUI_TERMINAL_ID").filter(|id| id.starts_with("term_")) else {
        return Innermost::Outside;
    };
    let Some(socket) = set("CMUX_TUI_SOCKET").or_else(|| set("CMUX_MUX_SOCKET")) else {
        return Innermost::Outside;
    };
    let socket = PathBuf::from(socket);
    if app_owns(&socket) { Innermost::AppPane } else { Innermost::SessionPane { socket, terminal } }
}

/// [`innermost_with`] for this process. A `cmux` bundled in one app and run
/// in a terminal of another acts for its own app (app_identity.rs
/// `OTHER_APP_STATE_KEYS`): the daemon keys there are the other app's.
pub(super) fn innermost() -> Innermost {
    if in_other_apps_terminal() {
        return Innermost::Outside;
    }
    innermost_with(|key| std::env::var(key).ok(), owning_app)
}

#[cfg(unix)]
fn in_other_apps_terminal() -> bool {
    crate::app_identity::this_process_in_other_apps_terminal()
}

#[cfg(not(unix))]
fn in_other_apps_terminal() -> bool {
    false
}

#[cfg(unix)]
fn owning_app(socket: &Path) -> bool {
    super::frontend_browser::app_daemon_is(socket)
}

#[cfg(not(unix))]
fn owning_app(_socket: &Path) -> bool {
    false
}

/// Whether a cmux app answers on the control socket this CLI resolves
/// (`CMUX_SOCKET_PATH`, the bundle, `--app-socket`). A connect is local and
/// takes well under a millisecond; nothing is sent.
pub(super) fn app_reachable(app_socket: Option<&Path>) -> bool {
    #[cfg(unix)]
    {
        let path = match app_socket {
            Some(path) => Some(path.to_path_buf()),
            None => {
                let exe = std::env::current_exe().ok();
                let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
                crate::app_identity::AppIdentity::detect(
                    |key| std::env::var(key).ok(),
                    exe.as_deref(),
                )
                .map(|identity| identity.control_socket(&home))
            }
        };
        path.is_some_and(|path| std::os::unix::net::UnixStream::connect(path).is_ok())
    }
    #[cfg(not(unix))]
    {
        let _ = app_socket;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> =
            pairs.iter().map(|(key, value)| ((*key).to_owned(), (*value).to_owned())).collect();
        move |key| map.get(key).cloned()
    }

    /// The bench case (round 1, T1): a cmux-tui started in a cmux app tab
    /// inherits the app's `CMUX_SOCKET_PATH`; its pane still belongs to the
    /// cmux-tui session, so the session wins.
    #[test]
    fn a_tui_pane_inside_an_app_terminal_belongs_to_the_tui_session() {
        let pane = env(&[
            ("CMUX_SOCKET_PATH", "/Users/me/Library/cmux-nightly.sock"),
            ("CMUX_BUNDLE_ID", "com.cmuxterm.app.nightly"),
            ("CMUX_TUI_SOCKET", "/tmp/cmux-tui-501/bench.sock"),
            ("CMUX_TUI_TERMINAL_ID", "term_abc"),
        ]);
        assert_eq!(
            innermost_with(pane, |_| false),
            Innermost::SessionPane {
                socket: PathBuf::from("/tmp/cmux-tui-501/bench.sock"),
                terminal: "term_abc".into(),
            }
        );
    }

    /// A terminal of the app's own session keeps the app's answer.
    #[test]
    fn an_app_terminal_stays_the_apps() {
        let pane = env(&[
            ("CMUX_SOCKET_PATH", "/Users/me/Library/cmux-nightly.sock"),
            ("CMUX_TUI_SOCKET", "/var/folders/x/T/cmux-tui-501/cmux-app-nightly.sock"),
            ("CMUX_TUI_TERMINAL_ID", "term_abc"),
        ]);
        let mut asked = None;
        let found = innermost_with(pane, |socket| {
            asked = Some(socket.to_path_buf());
            true
        });
        assert_eq!(found, Innermost::AppPane);
        assert_eq!(
            asked.as_deref(),
            Some(Path::new("/var/folders/x/T/cmux-tui-501/cmux-app-nightly.sock"))
        );
    }

    /// A standalone cmux-tui (no app anywhere) is a session pane;
    /// `CMUX_MUX_SOCKET` counts like `CMUX_TUI_SOCKET`.
    #[test]
    fn a_standalone_tui_pane_is_a_session_pane() {
        let pane = env(&[
            ("CMUX_MUX_SOCKET", "/run/user/1/cmux-tui/main.sock"),
            ("CMUX_TUI_TERMINAL_ID", "term_1"),
        ]);
        assert!(matches!(innermost_with(pane, |_| false), Innermost::SessionPane { .. }));
    }

    /// Without both the terminal id and a session socket no terminal names
    /// the caller; a blank or non-terminal id does not count.
    #[test]
    fn no_terminal_means_outside() {
        for pairs in [
            vec![("CMUX_SOCKET_PATH", "/x/cmux.sock")],
            vec![("CMUX_TUI_SOCKET", "/x/s.sock")],
            vec![("CMUX_TUI_TERMINAL_ID", "term_1")],
            vec![("CMUX_TUI_SOCKET", "/x/s.sock"), ("CMUX_TUI_TERMINAL_ID", " ")],
            vec![("CMUX_TUI_SOCKET", "/x/s.sock"), ("CMUX_TUI_TERMINAL_ID", "pane_1")],
            vec![("CMUX_TUI_SOCKET", ""), ("CMUX_TUI_TERMINAL_ID", "term_1")],
        ] {
            assert_eq!(innermost_with(env(&pairs), |_| true), Innermost::Outside, "{pairs:?}");
        }
    }
}
