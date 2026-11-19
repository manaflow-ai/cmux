//! A caller in an agent chat dock. The dock takes a new pane only below its
//! chat (Split Down), so a split right of a pane in it is refused by the
//! daemon (`dock-column-agent-chat`). A new pane beside such a caller is a
//! column that shares the window: because the app says the caller is docked,
//! and also when the app says it is not and the daemon refuses the split.

use super::*;

/// `alpha` of the fixture with a left agent chat dock: the chat's pane, the
/// pane Split Down made below it with its shell, and the fixture's own pane,
/// which is now the first pane right of the dock.
struct Docked {
    chat: String,
    shell_pane: String,
    shell: String,
    strip: String,
}

fn raw(server: &HeadlessServer, request: Value) -> Value {
    json_socket_request(&server.socket, request)
}

/// The public id of the pane that shows the raw tab `surface`.
fn pane_of_surface(server: &HeadlessServer, surface: &Value) -> String {
    fn find(node: &Value, surface: &Value) -> Option<String> {
        match node {
            Value::Object(fields) => {
                let shows = fields
                    .get("tabs")
                    .and_then(Value::as_array)
                    .is_some_and(|tabs| tabs.iter().any(|tab| tab["surface"] == *surface));
                match fields.get("resource_id").and_then(Value::as_str) {
                    Some(pane) if shows => Some(pane.to_owned()),
                    _ => fields.values().find_map(|child| find(child, surface)),
                }
            }
            Value::Array(items) => items.iter().find_map(|child| find(child, surface)),
            _ => None,
        }
    }
    let tree = raw(server, json!({"id": 1, "cmd": "list-workspaces"}));
    find(&tree, surface).unwrap_or_else(|| panic!("no pane shows {surface} in {tree}"))
}

/// Docks a chat left of the fixture's pane and splits the dock down.
fn dock_with_a_shell_below_the_chat(split: &Split) -> Docked {
    let Split { server, pane, .. } = split;
    let screen = screen_of_pane(server, pane);
    let own = raw_pane_id(server, pane);
    raw(server, json!({"id": 2, "cmd": "new-pane-right", "pane": own, "width": 0.5}));
    let panes = state_cli_topology(server)["panes"].clone();
    let right = panes
        .as_array()
        .unwrap()
        .iter()
        .filter(|record| record["screen_id"] == screen.as_str())
        .filter_map(|record| record["id"].as_str())
        .find(|id| id != pane)
        .unwrap_or_else(|| panic!("no pane right of the caller: {panes}"))
        .to_owned();
    // The chat: a second tab of that pane, moved into a left agent chat dock.
    let right_raw = raw_pane_id(server, &right);
    let tab = raw(server, json!({"id": 3, "cmd": "new-tab", "pane": right_raw}));
    let chat_tab = tab["surface"].clone();
    assert!(!chat_tab.is_null(), "{tab}");
    raw(
        server,
        json!({"id": 4, "cmd": "move-tab-to-column", "surface": chat_tab, "pane": right_raw,
            "dock": {"edge": "left", "mode": "docked", "role": "agent_chat"}}),
    );
    let chat = pane_of_surface(server, &chat_tab);
    assert_ne!(chat, right, "the chat's tab did not move into a dock");
    // Split Down: the one new pane the dock takes, below the chat.
    let below = state_cli(server, None, &["pane", &chat, "split", "--down"]);
    // The raw commands took the focus: the person looks at `beta` again.
    state_cli(server, None, &["workspace", &split.beta, "focus"]);
    Docked {
        shell_pane: created_pane(&below).to_owned(),
        shell: below["value"]["terminal_id"].as_str().unwrap().to_owned(),
        chat,
        strip: pane.clone(),
    }
}

/// The app's `caller` for a caller in `pane` that it calls `docked`.
fn caller_at(split: &Split, pane: &str, docked: bool) -> Value {
    let screen = screen_of_pane(&split.server, pane);
    json!({"is_caller": true, "workspace": split.alpha, "screen": screen, "pane": pane,
        "docked": docked})
}

/// A shell runs in the pane Split Down made below a docked agent chat, with
/// another agent's pane on its right. Its profile browser tab gets a pane of
/// its own. The CLI asked the daemon for a plain split right of the shell's
/// pane, which the dock refuses, so the command failed. The same holds when
/// the app calls that pane not docked: the refused split becomes a column.
/// A retry with the same key opens nothing more.
#[test]
fn a_shell_below_a_docked_chat_opens_a_profile_browser_tab_in_a_pane_of_its_own() {
    for (name, docked) in [("place-dock-shell-docked", true), ("place-dock-shell-undocked", false)]
    {
        let split = caller_in_alpha_beta_focused(name);
        let Split { server, terminal, alpha, beta, .. } = &split;
        let dock = dock_with_a_shell_below_the_chat(&split);
        // The pane right of the dock is another agent's home.
        let report = ["--state", "idle", "--source", "socket", "--source-session", "dock-neighbor"];
        state_cli(
            server,
            None,
            &[&["agent", "report", "--terminal", terminal][..], &report].concat(),
        );
        let strip_tabs = tabs_and_panes(server, &dock.strip).0;

        let app = FakeApp::start(
            server,
            "app-dock-shell",
            json!({"caller_placement": 2, "caller": caller_at(&split, &dock.shell_pane, docked),
                "beside": {"pane": dock.shell_pane, "placement": "own_pane"}}),
        );
        let who = Who::terminal(&dock.shell).with_app(&app);
        let open = [
            "browser",
            "profile",
            "open",
            "https://example.com/",
            "--profile",
            "default",
            "--engine",
            "webkit",
            "--idempotency-key",
            "dock-shell-page-1",
        ];
        let panes = tabs_and_panes(server, &dock.chat).1;
        let first = run(server, &who, &open);
        let page = created_pane(&first).to_owned();
        for held in [&dock.chat, &dock.shell_pane, &dock.strip] {
            assert_ne!(page, *held, "{name}: {first}");
        }
        assert_eq!(workspace_of_pane(server, &page), *alpha, "{name}: {first}");
        assert_eq!(tabs_and_panes(server, &page), (1, panes + 1), "{name}: {first}");
        assert_eq!(tabs_and_panes(server, &dock.strip).0, strip_tabs, "{name}: the agent's pane");

        let again = run(server, &who, &open);
        assert_eq!(again["value"]["tab_id"], first["value"]["tab_id"], "{name}: {again}");
        assert_eq!(tabs_and_panes(server, &page), (1, panes + 1), "{name}: the retry opened more");
        assert_beta_still_focused(server, beta);
    }
}

/// An agent chat that the app calls not docked, in a column the daemon
/// docks: the plain split right of the chat is refused. The new terminal
/// (CLI and MCP) and the new agent still open beside the chat, in a column,
/// and a retry with the same key makes one terminal.
#[test]
fn an_agent_chat_the_daemon_docks_gets_a_column_when_its_split_is_refused() {
    let split = caller_in_alpha_beta_focused("place-dock-chat-refused");
    let Split { server, alpha, beta, .. } = &split;
    let dock = dock_with_a_shell_below_the_chat(&split);
    let app = FakeApp::start(
        server,
        "app-dock-chat",
        without_column(&caller_at(&split, &dock.chat, false)),
    );
    let who = Who::agent().with_app(&app);
    let create = ["tab", "create", "terminal", "--name", "dev", "--idempotency-key", "dock-chat-1"];

    let panes = tabs_and_panes(server, &dock.chat).1;
    let first = run(server, &who, &create);
    let column = created_pane(&first).to_owned();
    for held in [&dock.chat, &dock.shell_pane, &dock.strip] {
        assert_ne!(column, *held, "{first}");
    }
    assert_eq!(workspace_of_pane(server, &column), *alpha, "{first}");
    assert_eq!(tabs_and_panes(server, &column), (1, panes + 1), "{first}");
    let again = run(server, &who, &create);
    assert_eq!(again["value"]["tab_id"], first["value"]["tab_id"], "{again}");
    assert_eq!(tabs_and_panes(server, &column), (1, panes + 1), "the retry opened more");
    // A retry after the app saw the column: the same terminal, no tab in it.
    let caller = caller_at(&split, &dock.chat, false);
    let seen = FakeApp::start(server, "app-dock-seen", with_column(&caller, &column, "terminal"));
    let again = run(server, &Who::agent().with_app(&seen), &create);
    drop(seen);
    assert_eq!(again["value"]["tab_id"], first["value"]["tab_id"], "{again}");
    assert_eq!(tabs_and_panes(server, &column), (1, panes + 1), "the late retry opened more");

    let script =
        "return await cmux.tab_create_terminal({name: 'dev', idempotency_key: 'dock-chat-mcp-1'});";
    let over_mcp = mcp_exec(server, &who, script);
    let made = created_pane(&over_mcp).to_owned();
    assert_ne!(made, dock.chat, "{over_mcp}");
    assert_eq!(tabs_and_panes(server, &made), (1, panes + 2), "{over_mcp}");
    let again = mcp_exec(server, &who, script);
    assert_eq!(again["value"]["tab_id"], over_mcp["value"]["tab_id"], "{again}");
    assert_eq!(tabs_and_panes(server, &made), (1, panes + 2), "the MCP retry opened more");

    let started = run(
        server,
        &who,
        &["agent", "start", "worker", "--cmd", "sleep 600", "--no-wait", "--no-focus"],
    );
    assert_eq!(started["workspace_id"], alpha.as_str(), "{started}");
    assert_ne!(started["pane_id"], dock.chat.as_str(), "{started}");
    assert_eq!(started["placement"], "split", "{started}");
    assert_beta_still_focused(server, beta);
}
