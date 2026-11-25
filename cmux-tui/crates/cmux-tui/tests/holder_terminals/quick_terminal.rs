//! The quick terminal (`quick-terminal-v1`) on a real daemon and a real holder: a hide closes nothing, so a
//! hidden quick terminal comes back hidden after the daemon died, with the same shell and its history. Part
//! of `holder_terminals.rs`; it waits with that file's helpers.

use super::*;

/// The screen and the pane of the daemon's tree that hold `surface`.
fn place_of(socket: &Path, surface: u64) -> (Value, Value) {
    let tree = request(socket, json!({"cmd": "list-workspaces"}));
    let screens = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten());
    for screen in screens {
        for pane in screen["panes"].as_array().into_iter().flatten() {
            let mut tabs = pane["tabs"].as_array().into_iter().flatten();
            if tabs.any(|tab| tab["surface"] == json!(surface)) {
                return (screen.clone(), pane.clone());
            }
        }
    }
    panic!("no pane holds surface {surface}: {tree}")
}

/// The rows of the history of `surface` that the flood printed, oldest first.
fn flood_lines(socket: &Path, surface: u64) -> Vec<String> {
    history(socket, surface)
        .iter()
        .map(row_text)
        .filter(|row| row.starts_with("quick-line-"))
        .collect()
}

#[test]
fn a_hidden_quick_terminal_keeps_its_shell_and_its_history_through_a_daemon_crash() {
    let mut daemon = Daemon::start();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
            "name": "quick-terminal", "cols": 80, "rows": 24}),
    );
    let first = created["surface"].as_u64().unwrap();
    daemon.track(first);
    let (screen, _) = place_of(&daemon.socket, first);

    let made = request(&daemon.socket, json!({"cmd": "quick-terminal", "screen": screen["id"]}));
    assert_eq!(made["created"], true, "{made}");
    let surface = made["surface"].as_u64().unwrap();
    daemon.track(surface);
    let (_, pane) = place_of(&daemon.socket, surface);
    let terminal_id = pane["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|tab| tab["surface"] == json!(surface))
        .and_then(|tab| tab["terminal_id"].as_str())
        .unwrap_or_else(|| panic!("the quick terminal has no terminal id: {pane}"))
        .to_string();

    // The shell prints `quick-ready-42` after it ended the echo of what it reads, so the next line is not on
    // the screen as typed text. Then 200 short lines, then `cat`: nothing more is printed after the last line.
    send(&daemon.socket, surface, "stty -echo; echo quick-ready-$((40 + 2))");
    screen_contains(&daemon.socket, surface, "quick-ready-42");
    send(
        &daemon.socket,
        surface,
        "i=0; while [ $i -lt 200 ]; do echo quick-line-$i; i=$((i + 1)); done; exec cat",
    );
    screen_contains(&daemon.socket, surface, "quick-line-199");
    let hidden = request(
        &daemon.socket,
        json!({"cmd": "quick-terminal", "screen": screen["id"], "mode": "hide"}),
    );
    assert_eq!(hidden["hidden"], true, "{hidden}");
    let shell = shell_pid(&daemon.socket, surface);
    let before = flood_lines(&daemon.socket, surface);
    assert!(before.len() >= 100, "the fixture: the flood is in the history: {before:?}");
    // The shell does not echo, so the first line of the flood can be on the row of the prompt: the rows that
    // are a line of the flood and nothing more start at a later line, and go on with no gap.
    let start: usize = before
        .first()
        .and_then(|row| row.strip_prefix("quick-line-"))
        .and_then(|line| line.parse().ok())
        .unwrap_or_else(|| {
            panic!("the fixture: the first row is no line of the flood: {before:?}")
        });
    let counted: Vec<String> =
        (start..start + before.len()).map(|line| format!("quick-line-{line}")).collect();
    assert_eq!(before, counted, "the fixture: each line of the flood once, in its order");

    daemon.sigkill();
    assert!(alive(shell), "the shell of the hidden quick terminal died with the daemon");
    daemon.restart();
    let restored = running_surface(&daemon.socket, &terminal_id);
    screen_contains(&daemon.socket, restored, "quick-line-199");
    assert_eq!(shell_pid(&daemon.socket, restored), shell, "the shell is another process");
    let (screen, pane) = place_of(&daemon.socket, restored);
    let mark = &screen["quick_terminal"];
    assert_eq!(mark["hidden"], true, "the start showed a hidden quick terminal: {mark}");
    assert_eq!(mark["pane"], pane["id"], "the mark names another pane: {mark}");
    assert_ne!(screen["active_pane"], pane["id"], "a hidden quick terminal has the focus");
    let after = flood_lines(&daemon.socket, restored);
    assert_eq!(after, before, "the rows of the history changed through the crash");

    let shown = request(&daemon.socket, json!({"cmd": "quick-terminal", "screen": screen["id"]}));
    assert_eq!(shown["created"], false, "the toggle made a second quick terminal: {shown}");
    assert_eq!(shown["hidden"], false, "{shown}");
    send(&daemon.socket, restored, "after-start");
    screen_contains(&daemon.socket, restored, "after-start");
}
