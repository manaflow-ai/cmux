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
