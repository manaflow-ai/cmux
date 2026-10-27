//! `caller` and caller-scoped `current` selectors through the CLI and a real
//! daemon: an agent in one workspace must not act on the workspace the person
//! has focused.
#![cfg(unix)]

use super::*;

/// The caller's terminal in `alpha` and its tab, pane and workspace ids,
/// with `beta` focused.
struct Split {
    server: HeadlessServer,
    terminal: String,
    pane: String,
    alpha: String,
    beta: String,
}

fn caller_in_alpha_beta_focused(name: &str) -> Split {
    let server = HeadlessServer::start(name);
    state_cli(&server, None, &["workspace", "create", "--name", "alpha"]);
    state_cli(&server, None, &["workspace", "create", "--name", "beta"]);
    let alpha = workspace_id_named(&server, "alpha");
    let beta = workspace_id_named(&server, "beta");
    let snapshot = state_cli_topology(&server);
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|terminal| terminal["id"].as_str())
        .find(|terminal| workspace_of_terminal(&snapshot, terminal) == alpha)
        .expect("alpha has a terminal")
        .to_string();
    let tab = state_cli(&server, None, &["terminal", &terminal, "show"])["tab_id"]
        .as_str()
        .unwrap()
        .to_string();
    let pane =
        state_cli(&server, None, &["tab", &tab, "show"])["pane_id"].as_str().unwrap().to_string();
    state_cli(&server, None, &["workspace", &beta, "focus"]);
    Split { server, terminal, pane, alpha, beta }
}

fn failed(server: &HeadlessServer, caller: Option<&str>, args: &[&str]) -> String {
    let mut command = Command::new(bin());
    command
        .arg("--json")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
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
    assert!(!output.status.success(), "{args:?} succeeded");
    let stdout = String::from_utf8_lossy(&output.stdout);
    format!("{stdout}{}", String::from_utf8_lossy(&output.stderr))
}

/// `caller` names the caller's own workspace and pane while another
/// workspace is focused, and fails without a caller or with `--socket`.
#[test]
fn caller_selector_names_the_callers_objects_not_the_focused_ones() {
    let Split { server, terminal, pane, alpha, beta } =
        caller_in_alpha_beta_focused("caller-selector");
    let caller = Some(terminal.as_str());

    let workspace = state_cli(&server, caller, &["workspace", "caller", "show"]);
    assert_eq!(workspace["id"], alpha.as_str(), "{workspace}");
    let shown = state_cli(&server, caller, &["pane", "caller", "show"]);
    assert_eq!(shown["id"], pane.as_str(), "{shown}");
    let own = state_cli(&server, caller, &["terminal", "caller", "show"]);
    assert_eq!(own["id"], terminal.as_str(), "{own}");

    // The person's focus is unchanged: beta is still the focused workspace.
    let focused = state_cli(&server, None, &["workspace", "current", "show"]);
    assert_eq!(focused["id"], beta.as_str(), "{focused}");

    let no_caller = failed(&server, None, &["pane", "caller", "show"]);
    assert!(no_caller.contains("selector."), "{no_caller}");
}

/// Inside cmux, `current` is the caller's own object: a rename and a split
/// act on the caller's workspace and pane, not the focused one. Without a
/// caller `current` stays the focused object.
#[test]
fn current_selector_follows_the_caller_and_stays_focused_without_one() {
    let Split { server, terminal, pane, alpha, beta } =
        caller_in_alpha_beta_focused("caller-current");
    let caller = Some(terminal.as_str());

    state_cli(&server, caller, &["workspace", "current", "rename", "mine"]);
    assert_eq!(workspace_id_named(&server, "mine"), alpha);
    let focused = state_cli(&server, None, &["workspace", "current", "show"]);
    assert_eq!(focused["id"], beta.as_str(), "{focused}");
    assert_eq!(focused["name"], "beta", "{focused}");

    let shown = state_cli(&server, caller, &["pane", "current", "show"]);
    assert_eq!(shown["id"], pane.as_str(), "{shown}");
    let split = state_cli(&server, caller, &["pane", "current", "split", "--right"]);
    let new_pane = split["value"]["pane_id"].as_str().unwrap_or_else(|| panic!("{split}"));
    let placed = state_cli(&server, None, &["pane", new_pane, "show"]);
    let screen =
        state_cli(&server, None, &["screen", placed["screen_id"].as_str().unwrap(), "show"]);
    assert_eq!(screen["workspace_id"], alpha.as_str(), "split landed in {screen}");

    // Without a caller in the environment (a shell outside cmux on this
    // session's socket), `current` is still the focused workspace's pane.
    let output = Command::new(bin())
        .args(["--json", "pane", "current", "show"])
        .env("LC_ALL", "C")
        .env("CMUX_TUI_SOCKET", &server.socket)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .output()
        .unwrap();
    assert_success(&output);
    let outside = json_output(&output);
    let routed = state_cli(&server, None, &["pane", "current", "show"]);
    assert_eq!(routed["id"], outside["id"], "--socket: {routed}");
    let outside_screen =
        state_cli(&server, None, &["screen", outside["screen_id"].as_str().unwrap(), "show"]);
    assert_eq!(outside_screen["workspace_id"], beta.as_str(), "{outside_screen}");
    // Focus never moved.
    let focused = state_cli(&server, None, &["workspace", "current", "show"]);
    assert_eq!(focused["id"], beta.as_str(), "{focused}");
}

#[test]
fn state_cli_tab_groups_and_caller_workspace_through_a_real_daemon() {
    let server = HeadlessServer::start("state-cli-groups");
    state_cli(&server, None, &["workspace", "create", "--name", "alpha"]);
    state_cli(&server, None, &["workspace", "create", "--name", "beta", "--empty"]);
    let alpha = workspace_id_named(&server, "alpha");
    let beta = workspace_id_named(&server, "beta");
    let snapshot = state_cli_topology(&server);
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|terminal| terminal["id"].as_str())
        .find(|terminal| workspace_of_terminal(&snapshot, terminal) == alpha)
        .expect("alpha has a terminal")
        .to_string();
    let tab = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == terminal.as_str())
        .unwrap()["tab_id"]
        .as_str()
        .unwrap()
        .to_string();

    // Without a selector, status lands in the caller's workspace even when
    // another workspace is focused.
    state_cli(&server, None, &["workspace", &beta, "focus"]);
    state_cli(&server, Some(&terminal), &["workspace", "status", "set", "caller", "yes"]);
    let mine = state_cli(&server, Some(&terminal), &["workspace", "status", "list"]);
    assert_eq!(mine[0]["workspace_id"], alpha, "{mine}");
    assert_eq!(mine[0]["entries"][0]["key"], "caller");
    let focused = state_cli(&server, None, &["workspace", "current", "status", "list"]);
    assert!(
        focused.as_array().unwrap().iter().all(|entry| entry["workspace_id"] != alpha),
        "{focused}"
    );

    // Tab groups: created over v2, then addressed by name.
    state_cli(&server, None, &["tab", &tab, "pin"]);
    state_cli(&server, None, &["tab", &tab, "unpin"]);
    state_cli(
        &server,
        None,
        &["tab", "group", "create", "--tabs", &tab, "--name", "agents", "--color", "green"],
    );
    let group = state_cli(&server, None, &["tab", "group", "agents", "show"]);
    assert_eq!(group["name"], "agents");
    assert_eq!(group["color"], "green");
    assert_eq!(group["tab_ids"], serde_json::json!([tab]));
    state_cli(&server, None, &["tab", "group", "agents", "update", "--collapse"]);
    let groups = state_cli(&server, None, &["tab", "group", "list"]);
    assert_eq!(groups[0]["collapsed"], true, "{groups}");
    state_cli(&server, None, &["tab", "group", "agents", "ungroup"]);
    assert_eq!(state_cli(&server, None, &["tab", "group", "list"]), serde_json::json!([]));
}
