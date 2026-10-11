//! Reopen Closed (cx-gzh.9, plans/cmux-next/reopen-closed.md 3.0 and 4):
//! every surface kind the daemon owns comes back from its closed history,
//! driven over the daemon socket as the app drives it. A terminal, a
//! frontend browser tab, an agent chat tab, a page tab and a viewer page tab
//! on a route (`page-tab-route-v1`, the viewer's file) each close and reopen
//! through `closed.reopen`; the reopened tab has the same kind and record.

use super::*;

/// One connection that reads conversation, agent session and page tabs in
/// their canonical form (as the app negotiates them).
struct AppConnection {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    next: u64,
}

impl AppConnection {
    fn open(harness: &RecoveryHarness) -> Self {
        let stream = transport::connect(&harness.socket).unwrap();
        let writer = stream.try_clone_box().unwrap();
        let mut connection = Self { writer, reader: BufReader::new(stream), next: 1 };
        connection.send(serde_json::json!({
            "cmd":"set-client-info","name":"reopen-kinds","kind":"test",
            "capabilities":["conversation-tabs-v1","agent-session-tabs-v1","page-tabs-v1"],
        }));
        connection
    }

    fn send(&mut self, mut value: serde_json::Value) -> serde_json::Value {
        value["id"] = serde_json::json!(self.next);
        self.next += 1;
        // `stream_request` checks `ok` and returns the reply's `data`.
        stream_request(&mut self.writer, &mut self.reader, value)
    }

    fn tabs(&mut self) -> Vec<serde_json::Value> {
        let tree = self.send(serde_json::json!({"cmd":"list-workspaces"}));
        tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .cloned()
            .collect()
    }

    fn tab(&mut self, surface: u64) -> serde_json::Value {
        self.tabs()
            .into_iter()
            .find(|tab| tab["surface"].as_u64() == Some(surface))
            .unwrap_or_else(|| panic!("no tab shows surface {surface}"))
    }

    /// The tab of public id `tab_id`, once the tree lists it.
    fn tab_by_id(&mut self, tab_id: &str) -> serde_json::Value {
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        loop {
            if let Some(tab) = self.tabs().into_iter().find(|tab| tab["tab_resource_id"] == tab_id)
            {
                return tab;
            }
            assert!(Instant::now() < deadline, "no tab {tab_id} after the reopen");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// A daemon with one workspace; returns it, an app connection and the pane.
fn start(tag: &str) -> (RecoveryHarness, AppConnection, u64) {
    let harness = RecoveryHarness::start(tag);
    let mut app = AppConnection::open(&harness);
    app.send(serde_json::json!({"cmd":"new-workspace","name":"kinds"}));
    let pane = app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .and_then(|workspace| workspace["screens"][0]["panes"][0]["id"].as_u64())
        .expect("the workspace has a pane");
    (harness, app, pane)
}

/// Close `surface` as Cmd-W does, then reopen the newest closed group as
/// Cmd-Shift-T does; returns the reopened tab as the tree lists it.
fn close_and_reopen(
    harness: &RecoveryHarness,
    app: &mut AppConnection,
    surface: u64,
    key: &str,
) -> serde_json::Value {
    app.send(serde_json::json!({"cmd":"close-tabs","surfaces":[surface],"end_terminals":false}));
    let closed = resource_request(
        &harness.socket,
        &format!("{key}-list"),
        "closed.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let id =
        closed[0]["id"].as_str().unwrap_or_else(|| panic!("the close was not recorded: {closed}"));
    let reopened = resource_request(
        &harness.socket,
        &format!("{key}-reopen"),
        "closed.reopen",
        serde_json::json!({"machine":"current","session":"current","closed":id}),
        Some(&format!("{key}-reopen")),
    );
    let tab_id =
        reopened["value"]["tab_ids"][0].as_str().expect("the reopen returned no tab").to_string();
    app.tab_by_id(&tab_id)
}

#[test]
fn a_closed_terminal_tab_reopens_as_a_terminal() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-terminal");
    let surface =
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}))["surface"].as_u64().unwrap();
    let kind = app.tab(surface)["kind"].clone();
    let back = close_and_reopen(&harness, &mut app, surface, "terminal");
    assert_eq!(back["kind"], kind, "{back}");
    assert!(back["terminal_id"].is_string(), "a reopened terminal has a terminal: {back}");
}

#[test]
fn a_closed_browser_tab_reopens_on_its_url() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-browser");
    let created = app.send(serde_json::json!({
        "cmd":"new-frontend-browser-tab","pane":pane,"url":"https://example.com/reopen","engine":"webkit",
    }));
    let surface = created["surface"].as_u64().expect("no browser surface");
    let back = close_and_reopen(&harness, &mut app, surface, "browser");
    assert_eq!(back["kind"], "browser", "{back}");
    assert_eq!(back["url"], "https://example.com/reopen", "{back}");
}

#[test]
fn a_closed_agent_chat_tab_reopens_on_its_session() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-agent");
    let source =
        serde_json::json!({"host":"install:reopen-kinds","session":"ses-reopen","harness":"codex"});
    let created = app
        .send(serde_json::json!({"cmd":"new-conversation-tab","pane":pane,"agent_session":source}));
    let surface = created["surface"].as_u64().expect("no agent surface");
    let back = close_and_reopen(&harness, &mut app, surface, "agent");
    assert_eq!(back["kind"], "conversation", "{back}");
    assert_eq!(back["conversation"]["agent_session"]["session"], "ses-reopen", "{back}");
}

#[test]
fn a_closed_page_tab_reopens_on_its_page() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-page");
    let created =
        app.send(serde_json::json!({"cmd":"new-conversation-tab","pane":pane,"page":"settings"}));
    let surface = created["surface"].as_u64().expect("no page surface");
    let back = close_and_reopen(&harness, &mut app, surface, "page");
    assert_eq!(back["kind"], "conversation", "{back}");
    assert_eq!(back["conversation"], serde_json::json!({"page":"settings"}), "{back}");
}

/// A viewer is a page tab on a route (`page-tab-route-v1`): the reopened tab
/// shows the same file.
#[test]
fn a_closed_viewer_tab_reopens_on_its_file() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-viewer");
    let route = "/tmp/reopen kinds/notes.md";
    let created =
        app.send(serde_json::json!({"cmd":"new-conversation-tab","pane":pane,"page":"markdown","route":route}));
    assert_eq!(created["conversation"], serde_json::json!({"page":"markdown","route":route}));
    let surface = created["surface"].as_u64().expect("no viewer surface");
    let back = close_and_reopen(&harness, &mut app, surface, "viewer");
    assert_eq!(back["kind"], "conversation", "{back}");
    assert_eq!(
        back["conversation"],
        serde_json::json!({"page":"markdown","route":route}),
        "{back}"
    );
}
