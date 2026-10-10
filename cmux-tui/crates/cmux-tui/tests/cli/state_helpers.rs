//! CLI helpers for the state tests: run a command against a headless
//! daemon and read ids from its answers.

use super::*;

/// Runs the CLI against `server` with `--json` and returns its JSON result.
/// `caller` runs it as a cmux terminal would: routed by `CMUX_TUI_SOCKET`
/// with `CMUX_TUI_TERMINAL_ID` naming the caller's terminal.
pub(super) fn state_cli(
    server: &HeadlessServer,
    caller: Option<&str>,
    args: &[&str],
) -> serde_json::Value {
    let mut command = Command::new(bin());
    command
        .arg("--json")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG");
    match caller {
        Some(terminal) => {
            command.env("CMUX_TUI_SOCKET", &server.socket).env("CMUX_TUI_TERMINAL_ID", terminal);
        }
        None => {
            command.env_remove("CMUX_TUI_SOCKET").arg("--socket").arg(&server.socket);
        }
    }
    let output = command.output().unwrap();
    assert_success(&output);
    json_output(&output)
}

/// Terminal, tab, screen and workspace ids from one session snapshot.
pub(super) fn state_cli_topology(server: &HeadlessServer) -> serde_json::Value {
    state_cli(server, None, &["session", "current", "snapshot"])
}

pub(super) fn workspace_of_terminal(snapshot: &serde_json::Value, terminal: &str) -> String {
    let find = |kind: &str, id: &str| {
        snapshot[kind]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == id)
            .unwrap_or_else(|| panic!("no {kind} {id}"))
            .clone()
    };
    let tab = find("terminals", terminal)["tab_id"].as_str().unwrap().to_string();
    let pane = find("tabs", &tab)["pane_id"].as_str().unwrap().to_string();
    let screen = find("panes", &pane)["screen_id"].as_str().unwrap().to_string();
    find("screens", &screen)["workspace_id"].as_str().unwrap().to_string()
}

pub(super) fn workspace_id_named(server: &HeadlessServer, name: &str) -> String {
    state_cli(server, None, &["workspace", "list"])
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .and_then(|workspace| workspace["id"].as_str())
        .unwrap_or_else(|| panic!("no workspace named {name}"))
        .to_string()
}
