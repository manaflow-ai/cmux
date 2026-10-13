//! `close-workspace` with `if_empty` (`close-workspace-if-empty-v1`,
//! cx-nsiyx) over a real daemon socket. A client moves the last tab out of
//! a workspace and then closes the emptied source; another client opens a
//! tab there between the move and the close. The registry revision does not
//! see that tab (a tab added to an existing workspace does not advance it),
//! so only the daemon can refuse the close. The guarded close refuses
//! (`workspace_not_empty`) and the new tab survives; with no tab opened in
//! between, the same close succeeds.

use serde_json::{Value, json};

use super::*;

const CAPABILITY: &str = "close-workspace-if-empty-v1";

/// One raw request on a new connection (one client); the whole response.
fn send(server: &HeadlessServer, request: Value) -> Value {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|error| panic!("{error}: {line}"))
}

fn ok(server: &HeadlessServer, request: Value) -> Value {
    let response = send(server, request.clone());
    assert_eq!(response["ok"], true, "{request} failed: {response}\n{}", server.stderr_tail());
    response["data"].clone()
}

/// A new workspace named `name`: its key and numeric id.
fn workspace(server: &HeadlessServer, name: &str) -> (String, u64) {
    let created = ok(server, json!({"id": 1, "cmd": "create-workspace", "name": name}));
    (created["key"].as_str().unwrap().to_string(), created["workspace"].as_u64().unwrap())
}

/// A terminal tab in workspace `key`; its surface.
fn open_tab(server: &HeadlessServer, key: &str) -> u64 {
    let created =
        ok(server, json!({"id": 2, "cmd": "create-terminal", "key": key, "argv": ["/bin/cat"]}));
    created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"))
}

/// The surfaces of every tab in workspace `key`; None when it is gone.
fn tabs(server: &HeadlessServer, key: &str) -> Option<Vec<u64>> {
    let tree = ok(server, json!({"id": 3, "cmd": "list-workspaces"}));
    let workspace = tree["workspaces"].as_array().unwrap().iter().find(|ws| ws["key"] == key)?;
    Some(
        workspace["screens"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .map(|tab| tab["surface"].as_u64().unwrap())
            .collect(),
    )
}

/// A source workspace whose only tab was moved to `destination`.
fn emptied_by_move(server: &HeadlessServer, name: &str, destination: u64) -> String {
    let (source, _) = workspace(server, name);
    let moved = open_tab(server, &source);
    ok(
        server,
        json!({"id": 4, "cmd": "move-tab-to-workspace", "surface": moved, "workspace": destination}),
    );
    assert_eq!(tabs(server, &source), Some(vec![]), "the move left a tab in {name}");
    source
}

#[test]
fn guarded_close_spares_a_tab_opened_after_the_move_and_closes_an_empty_workspace() {
    let server = HeadlessServer::start("close-if-empty");
    let identify = ok(&server, json!({"id": 0, "cmd": "identify"}));
    let capabilities = identify["capabilities"].as_array().unwrap();
    assert!(
        capabilities.iter().any(|c| c == CAPABILITY),
        "{CAPABILITY} not advertised: {identify}"
    );

    let (destination_key, destination) = workspace(&server, "destination");
    open_tab(&server, &destination_key);

    // The race: client B opens a tab in the source after client A's move
    // and before A's close. Both close forms refuse and keep the tab: the
    // plain close and the app's form (`end_terminals`, `batch-close-v1`).
    let source = emptied_by_move(&server, "source", destination);
    let opened = open_tab(&server, &source);
    for end_terminals in [false, true] {
        let refused = send(
            &server,
            json!({"id": 5, "cmd": "close-workspace", "key": source, "if_empty": true,
                   "end_terminals": end_terminals}),
        );
        assert_eq!(refused["ok"], false, "the guarded close deleted a tab: {refused}");
        assert_eq!(refused["error_code"], "workspace_not_empty", "{refused}");
        assert_eq!(tabs(&server, &source), Some(vec![opened]), "the new tab did not survive");
    }

    // No race: the guarded close of an emptied workspace succeeds, in both forms.
    for (name, end_terminals) in [("plain", false), ("ending", true)] {
        let source = emptied_by_move(&server, name, destination);
        let closed = ok(
            &server,
            json!({"id": 6, "cmd": "close-workspace", "key": source, "if_empty": true,
                   "end_terminals": end_terminals}),
        );
        assert_eq!(closed["key"], source.as_str(), "{closed}");
        assert_eq!(tabs(&server, &source), None, "{name}: the empty workspace stayed");
    }
    assert!(tabs(&server, &destination_key).is_some_and(|tabs| tabs.len() == 4));
}
