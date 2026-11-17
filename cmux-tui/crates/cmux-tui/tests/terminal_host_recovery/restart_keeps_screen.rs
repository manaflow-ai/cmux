//! A daemon that adopts a terminal host (after an app update, a crash or a
//! resync) rebuilds its terminal from the host's replay. The person's screen
//! comes from that terminal, and a program that repaints only changed cells
//! never corrects it, so the rebuilt screen must equal the one before.

use super::*;

const MARKER: &str = "keep-this-line-marker";

/// Runs `printf '<drawing>'` in a new 80x24 terminal and returns the screen
/// (`read-screen`) before the daemon is killed and after a new daemon has
/// adopted the terminal's host. `drawing` puts [`MARKER`] on row 8.
fn screens_around_a_daemon_restart(name: &str, drawing: &str) -> (String, String) {
    let mut harness = RecoveryHarness::start(name);
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", format!("printf '{drawing}'; sleep 60")],
            "new_workspace": true,
            "name": name,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let before = wait_for_screen(&harness.socket, surface, MARKER);
    assert_eq!(
        before.lines().nth(7),
        Some(MARKER),
        "setup did not draw the marker on row 8: {before:?}"
    );
    wait_for_host_records(&harness.host_root(), 1);

    harness.sigkill();
    harness.restart();
    let deadline = Instant::now() + Duration::from_secs(15);
    let adopted_surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "the new daemon did not adopt the terminal");
        std::thread::sleep(Duration::from_millis(50));
    };
    let after = wait_for_screen(&harness.socket, adopted_surface, MARKER);

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
    (before, after)
}

/// A row that soft-wrapped and whose continuation row was erased afterwards
/// (a shell redrawing a long input line, a TUI that clears a row with a
/// background color). The replay used to glue the erased row to the wrapped
/// one: the erase then ran on the wrapped row, its last character went, and
/// every row below came back one row higher.
#[test]
fn adopted_terminal_keeps_a_wrapped_row_whose_continuation_was_erased() {
    // Row 5: `x` at the last column, the text after it wraps to row 6. Row 6
    // is then erased with a background color.
    let (before, after) = screens_around_a_daemon_restart(
        "restart-wrap-erased",
        concat!(
            r"\033[5;80Hx-wrapped that \033[48;5;194m\033[2K\033[0m",
            r"\033[8;1Hkeep-this-line-marker\033[10;1H",
        ),
    );
    assert!(
        before.lines().nth(4).is_some_and(|row| row.len() == 80 && row.ends_with('x')),
        "setup did not draw the wrapped row: {before:?}"
    );
    assert_eq!(after, before, "the adopted terminal shows another screen than before the restart");
}

/// The same wrapped row with its continuation intact, in a terminal whose
/// program then turned autowrap off. The replay sets the modes before it
/// writes the text, so a joined row would not wrap on the new terminal: the
/// continuation would overwrite the last column and every row below would
/// move up.
#[test]
fn adopted_terminal_keeps_a_wrapped_row_while_autowrap_is_off() {
    let (before, after) = screens_around_a_daemon_restart(
        "restart-wrap-autowrap-off",
        concat!(r"\033[5;80Hxy-wrapped", r"\033[8;1Hkeep-this-line-marker\033[?7l\033[10;1H",),
    );
    assert!(
        before.lines().nth(4).is_some_and(|row| row.ends_with('x'))
            && before.lines().nth(5) == Some("y-wrapped"),
        "setup did not draw the wrapped row and its continuation: {before:?}"
    );
    assert_eq!(after, before, "the adopted terminal shows another screen than before the restart");
}
