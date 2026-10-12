//! `closed.reopen` publishes the reopened tab's screen on `session.events`
//! like a normal tab create does (cx-gzh.24).
#![cfg(unix)]

use super::*;

/// A `session.events` subscription; its lines arrive on the receiver. The
/// returned writer keeps the stream's connection open.
fn session_events(server: &HeadlessServer) -> (impl Sized + use<>, mpsc::Receiver<String>) {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "reopen-screen-events",
        "operation": "session.events",
        "params": {
            "machine": "current",
            "session": "current",
            "stream_id": "stream_44444444444444448444444444444444",
        },
    });
    writeln!(writer, "{request}").unwrap();
    writer.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).expect("no session.events reply");
        let line = rx.recv_timeout(remaining).expect("no session.events reply");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == "reopen-screen-events" {
            assert_eq!(message["ok"], true, "session.events failed: {message}");
            return (writer, rx);
        }
    }
}

/// The tab ids of the session snapshot.
fn tab_ids(server: &HeadlessServer) -> Vec<String> {
    state_cli_topology(server)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tab| tab["id"].as_str().unwrap().to_string())
        .collect()
}

/// The one tab that `after` has and `before` lacks.
fn new_tab(before: &[String], after: &[String]) -> String {
    let fresh = after.iter().filter(|tab| !before.contains(tab)).collect::<Vec<_>>();
    assert_eq!(fresh.len(), 1, "expected one new tab: before={before:?} after={after:?}");
    fresh[0].clone()
}

/// Read delta items until one upserts `tab`; return the changes of that
/// item and every delta item before it since the last call.
fn changes_through_tab_upsert(rx: &mpsc::Receiver<String>, tab: &str) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        let item = &message["item"];
        if message["type"] != "stream_item" || item["kind"] != "delta" {
            continue;
        }
        let changes = item["changes"].as_array().cloned().unwrap_or_default();
        let has_tab = changes.iter().any(|change| {
            change["kind"] == "upsert" && change["resource"] == "tab" && change["id"] == tab
        });
        seen.push(changes);
        if has_tab {
            return seen.pop().unwrap();
        }
    }
    panic!("no delta upserted tab {tab}; deltas={seen:?}");
}

/// Whether `changes` upsert a screen whose layout holds `tab`.
fn screen_holds_tab(changes: &[serde_json::Value], tab: &str) -> bool {
    changes.iter().any(|change| {
        change["kind"] == "upsert"
            && change["resource"] == "screen"
            && change["value"]["layout"].to_string().contains(&format!("\"{tab}\""))
    })
}

/// A client that builds pane tabs from the screen layout sees a reopened
/// tab at once: the delta that upserts the reopened tab also upserts its
/// screen with the tab in the layout, as for a normal `tab create`.
#[test]
fn closed_reopen_publishes_the_reopened_tab_in_its_screen_like_a_tab_create() {
    let server = HeadlessServer::start("closed-reopen-screen");
    state_cli(&server, None, &["workspace", "create", "--name", "alpha"]);
    let snapshot = state_cli_topology(&server);
    let pane = snapshot["tabs"].as_array().unwrap()[0]["pane_id"].as_str().unwrap().to_string();
    let (_stream, rx) = session_events(&server);

    let before = tab_ids(&server);
    state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane]);
    let created = new_tab(&before, &tab_ids(&server));
    let changes = changes_through_tab_upsert(&rx, &created);
    assert!(
        screen_holds_tab(&changes, &created),
        "a tab create published no screen with tab {created}: {changes:?}"
    );

    state_cli(&server, None, &["tab", &created, "close"]);
    let before = tab_ids(&server);
    assert!(!before.contains(&created), "the closed tab is still open: {before:?}");
    let reopen = state_cli(&server, None, &["closed", "reopen"]);
    let reopened = new_tab(&before, &tab_ids(&server));
    assert_eq!(reopen["value"]["tab_ids"], serde_json::json!([reopened]), "{reopen}");
    let changes = changes_through_tab_upsert(&rx, &reopened);
    assert!(
        screen_holds_tab(&changes, &reopened),
        "closed.reopen published tab {reopened} with no screen that holds it: {changes:?}"
    );
}
