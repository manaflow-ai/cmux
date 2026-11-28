//! A tab group takes a custom `#RRGGBB` color as well as a palette token,
//! through a real daemon (cx-wqn5): created and recolored over v2 from the
//! CLI, stored as given, and anything else refused.
#![cfg(unix)]

use super::*;

/// The CLI's output for `args`, success or not.
fn state_cli_output(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .arg("--json")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .arg("--socket")
        .arg(&server.socket)
        .output()
        .unwrap()
}

#[test]
fn a_tab_group_takes_a_hex_color_through_a_real_daemon() {
    let server = HeadlessServer::start("tab-group-hex");
    state_cli(&server, None, &["workspace", "create", "--name", "hex"]);
    let snapshot = state_cli_topology(&server);
    let tab = snapshot["terminals"][0]["tab_id"]
        .as_str()
        .unwrap_or_else(|| panic!("no tab: {snapshot}"))
        .to_string();

    state_cli(
        &server,
        None,
        &["tab", "group", "create", "--tabs", &tab, "--name", "ink", "--color", "#3366cc"],
    );
    let group = state_cli(&server, None, &["tab", "group", "ink", "show"]);
    assert_eq!(group["color"], "#3366cc", "{group}");

    state_cli(&server, None, &["tab", "group", "ink", "update", "--color", "#A1B2C3"]);
    let group = state_cli(&server, None, &["tab", "group", "ink", "show"]);
    assert_eq!(group["color"], "#A1B2C3", "{group}");

    // Tokens still work, and back.
    state_cli(&server, None, &["tab", "group", "ink", "update", "--color", "cyan"]);
    let group = state_cli(&server, None, &["tab", "group", "ink", "show"]);
    assert_eq!(group["color"], "cyan", "{group}");

    for bad in ["#12345", "#1234567", "#12345g", "teal", "3366cc"] {
        let output = state_cli_output(&server, &["tab", "group", "ink", "update", "--color", bad]);
        assert!(
            !output.status.success(),
            "{bad} was accepted: {}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
    let group = state_cli(&server, None, &["tab", "group", "ink", "show"]);
    assert_eq!(group["color"], "cyan", "a refused color changes nothing: {group}");
}
