//! A lone column of rows fills the screen through a real daemon: the
//! `set-viewport-pane-width` answer and the layout both report 1.0, and a
//! column beside another keeps the asked width.
#![cfg(unix)]

use super::*;

fn first_screen(server: &HeadlessServer) -> serde_json::Value {
    let tree = raw_json(server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    tree["workspaces"][0]["screens"][0].clone()
}

#[test]
fn a_lone_column_of_rows_keeps_full_width_through_a_real_daemon() {
    let server = HeadlessServer::start("lone-width");
    state_cli(&server, None, &["workspace", "create", "--name", "rows"]);
    let screen = first_screen(&server);
    let pane = screen["active_pane"].as_u64().unwrap_or_else(|| panic!("no pane: {screen}"));
    raw_json(
        &server,
        serde_json::json!({"id": "row", "cmd": "new-row", "pane": pane, "height_permille": 500}),
    );
    let lone = raw_json(
        &server,
        serde_json::json!({"id": "lone", "cmd": "set-viewport-pane-width", "pane": pane, "width": 0.6}),
    );
    assert_eq!(lone["width"].as_f64(), Some(1.0), "a lone column fills the width: {lone}");
    let screen = first_screen(&server);
    assert_eq!(screen["columns"][0]["width"].as_f64(), Some(1.0), "{screen}");

    raw_json(
        &server,
        serde_json::json!({"id": "right", "cmd": "new-pane-right", "pane": pane, "cols": 38, "rows": 22}),
    );
    let set = raw_json(
        &server,
        serde_json::json!({"id": "set", "cmd": "set-viewport-pane-width", "pane": pane, "width": 0.6}),
    );
    let width = set["width"].as_f64().unwrap_or_else(|| panic!("no width: {set}"));
    assert!((width - 0.6).abs() < 1e-6, "{set}");
    let screen = first_screen(&server);
    let column = screen["columns"][0]["width"].as_f64().unwrap_or_else(|| panic!("{screen}"));
    assert!((column - width).abs() < 1e-6, "{screen}");
}

/// `screen … column … update --edge` takes every edge that `column.update`
/// takes, and a refusal names all four.
#[test]
fn screen_column_update_names_every_edge() {
    let server = HeadlessServer::start("lone-width-edge");
    const COLUMN: &str = "split_00000000000000000000000000000011";
    let refused = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["screen", "current", "column", COLUMN, "update", "--dock", "true"])
        .args(["--edge", "middle"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(!refused.status.success());
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.contains("left, right, top, or bottom"), "{stderr}");
}
