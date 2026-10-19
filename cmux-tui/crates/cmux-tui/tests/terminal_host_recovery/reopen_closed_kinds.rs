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
        // A just-started owner answers `server.restoring` until its terminals
        // are restored (cx-n3bs); the app retries on a new connection.
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        loop {
            let stream = transport::connect(&harness.socket).unwrap();
            let mut writer = stream.try_clone_box().unwrap();
            let mut reader = BufReader::new(stream);
            let hello = serde_json::json!({
                "id":1,"cmd":"set-client-info","name":"reopen-kinds","kind":"test",
                "capabilities":["conversation-tabs-v1","agent-session-tabs-v1","page-tabs-v1"],
            });
            writeln!(writer, "{hello}").unwrap();
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
            if reply["ok"] == true {
                return Self { writer, reader, next: 2 };
            }
            assert_eq!(reply["error_code"], "server.restoring", "set-client-info failed: {reply}");
            assert!(Instant::now() < deadline, "the owner is still restoring: {reply}");
            std::thread::sleep(Duration::from_millis(50));
        }
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

/// `window_record.put` of window `window` of install `reopen-kinds`, listing
/// workspace `key`, open or closed.
fn put_window(
    harness: &RecoveryHarness,
    window: &str,
    key: Option<&str>,
    open: bool,
    request: &str,
) {
    let record = serde_json::json!({
        "id": window, "workspace_key": key, "workspace_keys": key.map(|key| vec![key]).unwrap_or_default(),
        "open": open,
    });
    resource_request(
        &harness.socket,
        request,
        "window_record.put",
        serde_json::json!({"machine":"current","session":"current",
                           "install_id":"reopen-kinds","window_id":window,"record":record}),
        Some(request),
    );
}

fn closed_list(harness: &RecoveryHarness, request: &str) -> Vec<serde_json::Value> {
    resource_request(
        &harness.socket,
        request,
        "closed.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    )
    .as_array()
    .cloned()
    .unwrap_or_default()
}

/// Cmd-Shift-T from window `window`: the reply, ok or not.
fn reopen_from(harness: &RecoveryHarness, window: &str, request: &str) -> serde_json::Value {
    request_response(
        &harness.socket,
        serde_json::json!({
            "protocol":"cmux.protocol/2","type":"request","id":request,"operation":"closed.reopen",
            "params":{"machine":"current","session":"current","window":window},
            "idempotency_key":request,
        }),
    )
}

/// A window the app closes becomes a `window` group, and Cmd-Shift-T in
/// another window reopens it (the reply names the window to show). A
/// window shown again drops its group.
#[test]
fn a_closed_window_reopens_from_another_window() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-window");
    let key = app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
        .expect("the workspace has a key");
    // A window first written closed (restored closed) records nothing.
    put_window(&harness, "win-c", None, false, "win-c-first-closed");
    put_window(&harness, "win-a", Some(&key), true, "win-a-open");
    put_window(&harness, "win-b", None, true, "win-b-open");
    put_window(&harness, "win-a", Some(&key), false, "win-a-close");
    let window_groups = |list: Vec<serde_json::Value>| -> Vec<serde_json::Value> {
        list.into_iter().filter(|item| item["kind"] == "window").collect()
    };
    let groups = window_groups(closed_list(&harness, "list-1"));
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["window"], "reopen-kinds/win-a");
    assert_eq!(groups[0]["name"], "kinds");

    let reply = reopen_from(&harness, "reopen-kinds/win-b", "reopen-window-b");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["value"]["window"], "reopen-kinds/win-a", "{reply}");
    assert!(window_groups(closed_list(&harness, "list-2")).is_empty());

    // Closed again, then shown again by the app (Dock click): no group stays.
    put_window(&harness, "win-a", Some(&key), true, "win-a-open-2");
    put_window(&harness, "win-a", Some(&key), false, "win-a-close-2");
    assert_eq!(window_groups(closed_list(&harness, "list-3")).len(), 1);
    put_window(&harness, "win-a", Some(&key), true, "win-a-open-3");
    assert!(window_groups(closed_list(&harness, "list-4")).is_empty());

    // A window that is gone (its record deleted) leaves no group to reopen.
    put_window(&harness, "win-a", Some(&key), false, "win-a-close-3");
    assert_eq!(window_groups(closed_list(&harness, "list-5")).len(), 1);
    resource_request(
        &harness.socket,
        "win-a-delete",
        "window_record.delete",
        serde_json::json!({"machine":"current","session":"current",
                           "install_id":"reopen-kinds","window_id":"win-a"}),
        Some("win-a-delete"),
    );
    assert!(window_groups(closed_list(&harness, "list-6")).is_empty());
}

/// A tab closed in window A's workspace belongs to A: Cmd-Shift-T in live
/// window B never reopens it, Cmd-Shift-T in A does (decision 1).
#[test]
fn another_live_window_never_reopens_a_windows_closed_tab() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-scope");
    let key = app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
        .expect("the workspace has a key");
    put_window(&harness, "win-a", Some(&key), true, "scope-a-open");
    put_window(&harness, "win-b", None, true, "scope-b-open");
    let surface =
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}))["surface"].as_u64().unwrap();
    app.send(serde_json::json!({"cmd":"close-tabs","surfaces":[surface],"end_terminals":false}));
    let closed = closed_list(&harness, "scope-list");
    assert_eq!(closed[0]["window"], "reopen-kinds/win-a", "{closed:?}");

    let from_b = reopen_from(&harness, "reopen-kinds/win-b", "scope-from-b");
    assert_eq!(from_b["ok"], false, "window B took window A's tab: {from_b}");
    let from_a = reopen_from(&harness, "reopen-kinds/win-a", "scope-from-a");
    assert_eq!(from_a["ok"], true, "{from_a}");
    assert_eq!(from_a["result"]["value"]["tab_ids"].as_array().map(Vec::len), Some(1), "{from_a}");
}

/// Secrets in a closed browser tab's URL never reach closed history
/// (reopen-closed.md 7.17): query keys on the deny-list (tokens, codes,
/// signatures, keys, passwords) are dropped from the URL and from every
/// back/forward entry before the group is stored; the rest of the query,
/// the path and the fragment come back on reopen.
#[test]
fn a_closed_browser_tab_keeps_no_secret_query_keys() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-browser-secrets");
    let url = "https://example.com/cb?page=2&access_token=abc&q=a%20b&code=oauth&X-Amz-Signature=s1&api_key=k&PHPSESSID=p9#top";
    let created = app.send(serde_json::json!({
        "cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"webkit",
    }));
    let surface = created["surface"].as_u64().expect("no browser surface");
    let history = serde_json::json!({
        "entries":[
            {"url":"https://example.com/login?next=%2Fhome&password=hunter2","title":"Login"},
            {"url":url,"title":"Callback"},
            {"url":"https://docs.example.com/d/1/edit?authuser=1&pageToken=pg2&sort_key=name&accessKey=ak7","title":"Doc"},
        ],
        "index":1,"scroll":{"x":0,"y":40},
    });
    app.send(serde_json::json!({"cmd":"set-frontend-browser-history","surface":surface,"history":history}));
    let back = close_and_reopen(&harness, &mut app, surface, "browser-secrets");
    // Kept query bytes stay exactly as they were (no re-encoding).
    assert_eq!(back["url"], "https://example.com/cb?page=2&q=a%20b#top", "{back}");
    let surface = back["surface"].as_u64().expect("the reopened tab has a surface");
    let restored =
        app.send(serde_json::json!({"cmd":"get-frontend-browser-history","surface":surface}));
    let text = restored.to_string();
    for secret in
        ["abc", "oauth", "s1", "hunter2", "api_key", "access_token", "password", "p9", "ak7"]
    {
        assert!(!text.contains(secret), "{secret} reached closed history: {restored}");
    }
    assert!(text.contains("next=%2Fhome"), "a harmless query key was dropped: {restored}");
    // Account choice, pagination and sort keys are not secrets.
    assert!(
        text.contains("edit?authuser=1&pageToken=pg2&sort_key=name"),
        "a harmless query key was dropped: {restored}"
    );
    assert!(text.contains("\"y\":40"), "the scroll position was lost: {restored}");
}

/// An incognito window (its workspaces are ephemeral) leaves no closed
/// history (reopen-closed.md 7.5): closing it records no `window` group,
/// while a normal window that closes still does.
#[test]
fn a_closed_incognito_window_is_never_recorded() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-incognito-window");
    resource_request(
        &harness.socket,
        "incognito-create",
        "workspace.create",
        serde_json::json!({"machine":"current","session":"current","name":"secret",
                           "initial_content":"empty","ephemeral":true}),
        Some("incognito-create"),
    );
    let key_of = |app: &mut AppConnection, name: &str| -> String {
        app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|workspace| workspace["name"] == name)
            .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
            .unwrap_or_else(|| panic!("no workspace {name}"))
    };
    let secret = key_of(&mut app, "secret");
    let kinds = key_of(&mut app, "kinds");
    put_window(&harness, "win-private", Some(&secret), true, "private-open");
    put_window(&harness, "win-private", Some(&secret), false, "private-close");
    let window_groups = |list: Vec<serde_json::Value>| -> Vec<serde_json::Value> {
        list.into_iter().filter(|item| item["kind"] == "window").collect()
    };
    assert!(
        window_groups(closed_list(&harness, "private-list")).is_empty(),
        "an incognito window was recorded"
    );
    put_window(&harness, "win-normal", Some(&kinds), true, "normal-open");
    put_window(&harness, "win-normal", Some(&kinds), false, "normal-close");
    let groups = window_groups(closed_list(&harness, "normal-list"));
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["window"], "reopen-kinds/win-normal");
    // A window listing only workspaces this daemon does not know (another
    // machine's, or not loaded yet) is not incognito: it is recorded.
    put_window(&harness, "win-remote", Some("ws-key-on-another-machine"), true, "remote-open");
    put_window(&harness, "win-remote", Some("ws-key-on-another-machine"), false, "remote-close");
    let groups = window_groups(closed_list(&harness, "remote-list"));
    assert!(groups.iter().any(|group| group["window"] == "reopen-kinds/win-remote"), "{groups:?}");
}

/// The live tab groups the daemon lists.
fn tab_groups(harness: &RecoveryHarness, request: &str) -> Vec<serde_json::Value> {
    let reply = resource_request(
        &harness.socket,
        request,
        "tab_group.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    reply.as_array().or_else(|| reply["value"].as_array()).cloned().unwrap_or_default()
}

/// Ungroup (cx-gzh.10, RECOVERABLE-BY-DEFAULT) is one closed-history group:
/// its tabs stay open, and Cmd-Shift-T in the window forms the group again
/// with its id, name, color and members in order.
#[test]
fn an_ungrouped_tab_group_reopens_whole() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-ungroup");
    let key = app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
        .expect("the workspace has a key");
    put_window(&harness, "win-u", Some(&key), true, "win-u-open");
    let tabs = (0..2)
        .map(|_| {
            let surface = app.send(serde_json::json!({"cmd":"new-tab","pane":pane}))["surface"]
                .as_u64()
                .unwrap();
            app.tab(surface)["tab_resource_id"].as_str().expect("the tab has an id").to_string()
        })
        .collect::<Vec<_>>();
    resource_request(
        &harness.socket,
        "ungroup-create",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current",
                           "tabs":tabs,"name":"Build","color":"blue"}),
        Some("ungroup-create"),
    );
    let created = tab_groups(&harness, "ungroup-list-1");
    assert_eq!(created.len(), 1, "{created:?}");
    let group_id = created[0]["id"].as_str().expect("the group has an id").to_string();
    let before = closed_list(&harness, "ungroup-closed-1").len();

    resource_request(
        &harness.socket,
        "ungroup",
        "tab_group.ungroup",
        serde_json::json!({"machine":"current","session":"current","tab_group":group_id}),
        Some("ungroup"),
    );
    assert!(tab_groups(&harness, "ungroup-list-2").is_empty());
    let closed = closed_list(&harness, "ungroup-closed-2");
    assert_eq!(closed.len(), before + 1, "the ungroup was not recorded: {closed:?}");
    assert_eq!(closed[0]["window"], "reopen-kinds/win-u", "{closed:?}");

    let reply = reopen_from(&harness, "reopen-kinds/win-u", "ungroup-reopen");
    assert_eq!(reply["ok"], true, "{reply}");
    let groups = tab_groups(&harness, "ungroup-list-3");
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Build");
    assert_eq!(groups[0]["color"], "blue");
    assert_eq!(groups[0]["tab_ids"], serde_json::json!(tabs));
    assert_eq!(closed_list(&harness, "ungroup-closed-3").len(), before);

    // A group formed since the ungroup keeps its tab: the reopen forms the
    // old group around the rest.
    resource_request(
        &harness.socket,
        "ungroup-2",
        "tab_group.ungroup",
        serde_json::json!({"machine":"current","session":"current","tab_group":group_id}),
        Some("ungroup-2"),
    );
    resource_request(
        &harness.socket,
        "ungroup-create-2",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current",
                           "tabs":[tabs[1]],"name":"Since","color":"red"}),
        Some("ungroup-create-2"),
    );
    let reply = reopen_from(&harness, "reopen-kinds/win-u", "ungroup-reopen-2");
    assert_eq!(reply["ok"], true, "{reply}");
    let groups = tab_groups(&harness, "ungroup-list-4");
    let by_name = |name: &str| groups.iter().find(|group| group["name"] == name).cloned();
    let old =
        by_name("Build").unwrap_or_else(|| panic!("the group was not formed again: {groups:?}"));
    assert_eq!(old["id"], group_id.as_str());
    assert_eq!(old["tab_ids"], serde_json::json!([tabs[0]]));
    let since =
        by_name("Since").unwrap_or_else(|| panic!("the newer group lost its tab: {groups:?}"));
    assert_eq!(since["tab_ids"], serde_json::json!([tabs[1]]));
}

/// Closing a tab group (cx-gzh.10) is one closed-history group of its tabs,
/// and Cmd-Shift-T reopens them as that group again: its id, name and
/// color around the reopened tabs, in order.
#[test]
fn a_closed_tab_group_reopens_as_its_group() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-group-close");
    for _ in 0..2 {
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}));
    }
    let tabs = kinds_workspace(&mut app)["screens"][0]["panes"][0]["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    assert_eq!(tabs.len(), 3, "{tabs:?}");
    resource_request(
        &harness.socket,
        "group-close-create",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current","tabs":tabs[1..],
                           "name":"Build","color":"blue"}),
        Some("group-close-create"),
    );
    let created = tab_groups(&harness, "group-close-list-1");
    assert_eq!(created.len(), 1, "{created:?}");
    let group_id = created[0]["id"].as_str().expect("the group has an id").to_string();

    let (item, reopened) = close_records_and_reopens(
        &harness,
        "tab_group.close",
        serde_json::json!({"tab_group":group_id}),
        "group-close",
    );
    assert_eq!(item["kind"], "tab", "{item}");
    let back = reopened["tab_ids"].as_array().cloned().unwrap_or_default();
    assert_eq!(back.len(), 2, "both tabs reopen once: {reopened}");
    let groups = tab_groups(&harness, "group-close-list-2");
    assert_eq!(groups.len(), 1, "the reopen formed no group: {groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Build");
    assert_eq!(groups[0]["color"], "blue");
    assert_eq!(groups[0]["tab_ids"], serde_json::Value::Array(back), "{groups:?}");
}

/// Close Group that also ends its terminals takes the batch close path.
#[test]
fn a_tab_group_closed_with_its_terminals_reopens_as_its_group() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-group-end");
    for _ in 0..2 {
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}));
    }
    let tabs = kinds_workspace(&mut app)["screens"][0]["panes"][0]["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    assert_eq!(tabs.len(), 3, "{tabs:?}");
    resource_request(
        &harness.socket,
        "group-end-create",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current","tabs":tabs[1..],
                           "name":"Build","color":"blue"}),
        Some("group-end-create"),
    );
    let group_id = tab_groups(&harness, "group-end-list-1")[0]["id"]
        .as_str()
        .expect("the group has an id")
        .to_string();

    let before = closed_list(&harness, "group-end-closed-1").len();
    app.send(serde_json::json!({"cmd":"close-tab-group","group":group_id,"end_terminals":true}));
    let closed = closed_list(&harness, "group-end-closed-2");
    assert_eq!(closed.len(), before + 1, "the close was not recorded: {closed:?}");
    let reopened = resource_request(
        &harness.socket,
        "group-end-reopen",
        "closed.reopen",
        serde_json::json!({"machine":"current","session":"current","closed":closed[0]["id"]}),
        Some("group-end-reopen"),
    )["value"]
        .clone();
    let back = reopened["tab_ids"].as_array().cloned().unwrap_or_default();
    assert_eq!(back.len(), 2, "both tabs reopen once: {reopened}");
    let groups = tab_groups(&harness, "group-end-list-2");
    assert_eq!(groups.len(), 1, "the reopen formed no group: {groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Build");
    assert_eq!(groups[0]["tab_ids"], serde_json::Value::Array(back), "{groups:?}");
}

#[test]
fn a_closed_tab_group_that_emptied_its_screen_reopens_as_its_group() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-group-screen");
    let workspace = kinds_workspace(&mut app);
    let first = workspace["screens"][0]["resource_id"].clone();
    app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                "cols":80,"rows":24}));
    let screen = |app: &mut AppConnection| {
        kinds_workspace(app)["screens"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|screen| screen["resource_id"] != first)
            .cloned()
            .expect("the new screen is listed")
    };
    let pane = screen(&mut app)["panes"][0]["id"].as_u64().expect("the new screen has a pane");
    app.send(serde_json::json!({"cmd":"new-tab","pane":pane}));
    let tabs = screen(&mut app)["panes"][0]["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    assert_eq!(tabs.len(), 2, "{tabs:?}");
    resource_request(
        &harness.socket,
        "group-screen-create",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current","tabs":tabs,
                           "name":"Build","color":"blue"}),
        Some("group-screen-create"),
    );
    let created = tab_groups(&harness, "group-screen-list-1");
    assert_eq!(created.len(), 1, "{created:?}");
    let group_id = created[0]["id"].as_str().expect("the group has an id").to_string();

    // Its screen's only pane held nothing else: the close takes the screen.
    let (item, reopened) = close_records_and_reopens(
        &harness,
        "tab_group.close",
        serde_json::json!({"tab_group":group_id}),
        "group-screen",
    );
    assert_eq!(item["kind"], "screen", "{item}");
    let back = reopened["tab_ids"].as_array().cloned().unwrap_or_default();
    assert_eq!(back.len(), 2, "both tabs reopen once: {reopened}");
    let groups = tab_groups(&harness, "group-screen-list-2");
    assert_eq!(groups.len(), 1, "the reopen formed no group: {groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Build");
    assert_eq!(groups[0]["color"], "blue");
    assert_eq!(groups[0]["tab_ids"], serde_json::Value::Array(back), "{groups:?}");
}

#[test]
fn a_closed_screen_reopens_with_its_tab_group() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-screen-group");
    let workspace = kinds_workspace(&mut app);
    let first = workspace["screens"][0]["resource_id"].clone();
    app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                "cols":80,"rows":24}));
    let screen = kinds_workspace(&mut app)["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|screen| screen["resource_id"] != first)
        .cloned()
        .expect("the new screen is listed");
    let pane = screen["panes"][0]["id"].as_u64().expect("the new screen has a pane");
    for _ in 0..2 {
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}));
    }
    let tabs = kinds_workspace(&mut app)["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|listed| listed["resource_id"] == screen["resource_id"])
        .map(|listed| listed["panes"][0]["tabs"].as_array().cloned().unwrap_or_default())
        .unwrap_or_default()
        .iter()
        .filter_map(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    assert_eq!(tabs.len(), 3, "{tabs:?}");
    resource_request(
        &harness.socket,
        "screen-group-create",
        "tab_group.create",
        serde_json::json!({"machine":"current","session":"current","tabs":tabs[1..],
                           "name":"Build","color":"blue"}),
        Some("screen-group-create"),
    );
    let group_id = tab_groups(&harness, "screen-group-list-1")[0]["id"]
        .as_str()
        .expect("the group has an id")
        .to_string();

    let (item, reopened) = close_records_and_reopens(
        &harness,
        "screen.close",
        serde_json::json!({"screen":screen["resource_id"]}),
        "screen-group",
    );
    assert_eq!(item["kind"], "screen", "{item}");
    let back = reopened["tab_ids"].as_array().cloned().unwrap_or_default();
    assert_eq!(back.len(), 3, "every tab reopens once: {reopened}");
    let groups = tab_groups(&harness, "screen-group-list-2");
    assert_eq!(groups.len(), 1, "the reopen formed no group: {groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Build");
    assert_eq!(groups[0]["color"], "blue");
    assert_eq!(groups[0]["tab_ids"], serde_json::json!(back[1..]), "{groups:?}");
}

fn screen_groups(harness: &RecoveryHarness, request: &str) -> Vec<serde_json::Value> {
    let reply = resource_request(
        &harness.socket,
        request,
        "screen_group.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    reply.as_array().or_else(|| reply["value"].as_array()).cloned().unwrap_or_default()
}

/// A screen group's Ungroup (cx-gzh.10) is one closed-history group too:
/// Cmd-Shift-T forms it again with its id, name, color and screens in order.
#[test]
fn an_ungrouped_screen_group_reopens_whole() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-screen-ungroup");
    let workspaces = app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"].clone();
    let workspace = workspaces
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .cloned()
        .expect("the workspace exists");
    let key = workspace["key"].as_str().expect("the workspace has a key").to_string();
    put_window(&harness, "win-s", Some(&key), true, "win-s-open");
    for _ in 0..2 {
        app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                    "cols":80,"rows":24}));
    }
    let public = resource_request(
        &harness.socket,
        "screen-ungroup-workspaces",
        "workspace.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    )
    .as_array()
    .into_iter()
    .flatten()
    .find(|listed| listed["name"] == "kinds")
    .and_then(|listed| listed["id"].as_str().map(str::to_string))
    .expect("the workspace has a public id");
    let screens = resource_request(
        &harness.socket,
        "screen-ungroup-screens",
        "screen.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    )
    .as_array()
    .into_iter()
    .flatten()
    .filter(|screen| screen["workspace_id"] == public.as_str())
    .filter_map(|screen| screen["id"].as_str().map(str::to_string))
    .collect::<Vec<_>>();
    assert_eq!(screens.len(), 3, "{screens:?}");
    let members = vec![screens[1].clone(), screens[2].clone()];
    resource_request(
        &harness.socket,
        "screen-ungroup-create",
        "screen_group.create",
        serde_json::json!({"machine":"current","session":"current",
                           "screens":members,"name":"Agents","color":"green"}),
        Some("screen-ungroup-create"),
    );
    let created = screen_groups(&harness, "screen-ungroup-list-1");
    assert_eq!(created.len(), 1, "{created:?}");
    let group_id = created[0]["id"].as_str().expect("the group has an id").to_string();
    let before = closed_list(&harness, "screen-ungroup-closed-1").len();

    resource_request(
        &harness.socket,
        "screen-ungroup",
        "screen_group.ungroup",
        serde_json::json!({"machine":"current","session":"current","screen_group":group_id}),
        Some("screen-ungroup"),
    );
    assert!(screen_groups(&harness, "screen-ungroup-list-2").is_empty());
    let closed = closed_list(&harness, "screen-ungroup-closed-2");
    assert_eq!(closed.len(), before + 1, "the ungroup was not recorded: {closed:?}");
    assert_eq!(closed[0]["window"], "reopen-kinds/win-s", "{closed:?}");

    let reply = reopen_from(&harness, "reopen-kinds/win-s", "screen-ungroup-reopen");
    assert_eq!(reply["ok"], true, "{reply}");
    let groups = screen_groups(&harness, "screen-ungroup-list-3");
    assert_eq!(groups.len(), 1, "{groups:?}");
    assert_eq!(groups[0]["id"], group_id.as_str());
    assert_eq!(groups[0]["name"], "Agents");
    assert_eq!(groups[0]["color"], "green");
    assert_eq!(groups[0]["screen_ids"], serde_json::json!(members));
    assert_eq!(closed_list(&harness, "screen-ungroup-closed-3").len(), before);
}

/// Run the close `operation` with `params` (over the v2 socket, as the app
/// does): it adds one closed-history group, which Cmd-Shift-T reopens.
/// Returns the closed item and the reopen's result.
fn close_records_and_reopens(
    harness: &RecoveryHarness,
    operation: &str,
    params: serde_json::Value,
    key: &str,
) -> (serde_json::Value, serde_json::Value) {
    let before = closed_list(harness, &format!("{key}-closed-1")).len();
    let mut params = params;
    params["machine"] = "current".into();
    params["session"] = "current".into();
    resource_request(&harness.socket, key, operation, params, Some(key));
    let closed = closed_list(harness, &format!("{key}-closed-2"));
    assert_eq!(closed.len(), before + 1, "{operation} was not recorded: {closed:?}");
    let item = closed[0].clone();
    let id = item["id"].as_str().expect("the closed item has an id");
    let reopened = resource_request(
        &harness.socket,
        &format!("{key}-reopen"),
        "closed.reopen",
        serde_json::json!({"machine":"current","session":"current","closed":id}),
        Some(&format!("{key}-reopen")),
    );
    assert_eq!(closed_list(harness, &format!("{key}-closed-3")).len(), before);
    (item, reopened["value"].clone())
}

/// The workspace named `kinds` as the tree lists it.
fn kinds_workspace(app: &mut AppConnection) -> serde_json::Value {
    app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "kinds")
        .cloned()
        .expect("the workspace exists")
}

// Every close path records first (cx-gzh.10 audit): screen.close,
// pane.close, terminal.close and browser.close each add one group that
// Cmd-Shift-T reopens.

#[test]
fn a_closed_screen_reopens() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, _) = start("reopen-path-screen");
    let workspace = kinds_workspace(&mut app);
    let first = workspace["screens"][0]["resource_id"].clone();
    app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                "cols":80,"rows":24}));
    let screens = kinds_workspace(&mut app)["screens"].as_array().cloned().unwrap_or_default();
    assert_eq!(screens.len(), 2, "{screens:?}");
    let screen = screens
        .iter()
        .find(|screen| screen["resource_id"] != first)
        .and_then(|screen| screen["resource_id"].as_str())
        .expect("the new screen has an id")
        .to_string();
    let (item, reopened) = close_records_and_reopens(
        &harness,
        "screen.close",
        serde_json::json!({"screen":screen}),
        "path-screen",
    );
    assert_eq!(item["kind"], "screen", "{item}");
    assert_eq!(reopened["screen_ids"].as_array().map(Vec::len), Some(1), "{reopened}");
    let screens = kinds_workspace(&mut app)["screens"].as_array().cloned().unwrap_or_default();
    assert_eq!(screens.len(), 2, "{screens:?}");
    let back = screens
        .iter()
        .find(|screen| screen["resource_id"] == reopened["screen_ids"][0])
        .unwrap_or_else(|| panic!("the reopened screen is not listed: {screens:?}"));
    let tab = &back["panes"][0]["tabs"][0];
    assert!(tab["terminal_id"].is_string(), "the reopened screen has its terminal: {back}");
}

#[test]
fn a_closed_pane_reopens_in_its_split() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-pane");
    app.send(serde_json::json!({"cmd":"split","pane":pane,"dir":"down","cols":80,"rows":24}));
    let screen = &kinds_workspace(&mut app)["screens"][0];
    let split = screen["layout"]["split"].as_u64().expect("the split is the screen's root");
    app.send(serde_json::json!({"cmd":"set-split-ratio","split":split,"ratio":0.3}));
    let panes = kinds_workspace(&mut app)["screens"][0]["panes"].as_array().cloned().unwrap();
    let closing = panes
        .iter()
        .find(|candidate| candidate["id"].as_u64() == Some(pane))
        .expect("the first pane is listed");
    let closing_id = closing["resource_id"].as_str().expect("the pane has an id").to_string();
    let neighbor = panes
        .iter()
        .find(|candidate| candidate["id"].as_u64() != Some(pane))
        .and_then(|candidate| candidate["id"].as_u64())
        .expect("the split made a pane");
    let (item, reopened) = close_records_and_reopens(
        &harness,
        "pane.close",
        serde_json::json!({"pane":closing_id}),
        "path-pane",
    );
    assert_eq!(item["kind"], "tab", "{item}");
    assert_eq!(item["member_count"], 1, "{item}");
    let tabs = reopened["tab_ids"].as_array().cloned().unwrap_or_default();
    assert_eq!(tabs.len(), 1, "{reopened}");
    let back = app.tab_by_id(tabs[0].as_str().unwrap());
    assert!(back["terminal_id"].is_string(), "{back}");
    // The pane comes back in its own split: above the pane it left, at the
    // height it had, with its tab and no other.
    let screen = kinds_workspace(&mut app)["screens"][0].clone();
    let layout = &screen["layout"];
    assert_eq!((layout["type"].as_str(), layout["dir"].as_str()), (Some("split"), Some("down")));
    let ratio = layout["ratio"].as_f64().expect("the split has a ratio");
    assert!((ratio - 0.3).abs() < 1e-3, "{layout}");
    assert_eq!(layout["b"]["pane"].as_u64(), Some(neighbor), "{layout}");
    let home = layout["a"]["pane"].as_u64().expect("the reopened pane is a leaf");
    let home = screen["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|candidate| candidate["id"].as_u64() == Some(home))
        .unwrap_or_else(|| panic!("the reopened pane is not listed: {screen}"));
    let ids = home["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|tab| tab["tab_resource_id"].clone())
        .collect::<Vec<_>>();
    assert_eq!(ids, vec![back["tab_resource_id"].clone()], "{screen}");
}

/// Reopen `members` (every member when None) of closed group `closed`.
fn reopen_members(
    harness: &RecoveryHarness,
    closed: &str,
    members: Option<serde_json::Value>,
    key: &str,
) -> serde_json::Value {
    let mut params = serde_json::json!({"machine":"current","session":"current","closed":closed});
    if let Some(members) = members {
        params["members"] = members;
    }
    resource_request(&harness.socket, key, "closed.reopen", params, Some(key))["value"].clone()
}

#[test]
fn a_closed_pane_reopened_in_parts_comes_back_as_one_split() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-pane-parts");
    app.send(serde_json::json!({"cmd":"split","pane":pane,"dir":"right","cols":80,"rows":24}));
    let panes = kinds_workspace(&mut app)["screens"][0]["panes"].as_array().cloned().unwrap();
    let split = panes
        .iter()
        .find(|candidate| candidate["id"].as_u64() != Some(pane))
        .expect("the split made a pane");
    let split_id = split["resource_id"].as_str().expect("the pane has an id").to_string();
    app.send(serde_json::json!({"cmd":"new-tab","pane":split["id"]}));
    let before = closed_list(&harness, "pane-parts-closed-1").len();
    resource_request(
        &harness.socket,
        "pane-parts-close",
        "pane.close",
        serde_json::json!({"machine":"current","session":"current","pane":split_id}),
        Some("pane-parts-close"),
    );
    let closed = closed_list(&harness, "pane-parts-closed-2");
    assert_eq!(closed.len(), before + 1, "{closed:?}");
    assert_eq!(closed[0]["member_count"], 2, "{}", closed[0]);
    let id = closed[0]["id"].as_str().expect("the closed item has an id").to_string();
    // One tab now, the other in a later reopen: both land in one pane.
    let first = reopen_members(&harness, &id, Some(serde_json::json!([0])), "pane-parts-1");
    let rest = reopen_members(&harness, &id, None, "pane-parts-2");
    let mut reopened = first["tab_ids"].as_array().cloned().unwrap_or_default();
    reopened.extend(rest["tab_ids"].as_array().cloned().unwrap_or_default());
    assert_eq!(reopened.len(), 2, "{first} {rest}");
    let screen = kinds_workspace(&mut app)["screens"][0].clone();
    let layout = &screen["layout"];
    assert_eq!((layout["type"].as_str(), layout["dir"].as_str()), (Some("split"), Some("right")));
    assert_eq!(layout["a"]["pane"].as_u64(), Some(pane), "{layout}");
    let home = layout["b"]["pane"].as_u64().expect("one pane split off the neighbor");
    let home = screen["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|candidate| candidate["id"].as_u64() == Some(home))
        .unwrap_or_else(|| panic!("the reopened pane is not listed: {screen}"));
    let tabs = home["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|tab| tab["tab_resource_id"].clone())
        .collect::<Vec<_>>();
    assert_eq!(tabs, reopened, "{screen}");
}

#[test]
fn a_closed_pane_reopened_in_parts_never_follows_its_pane_into_another_workspace() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-pane-parts-elsewhere");
    app.send(serde_json::json!({"cmd":"split","pane":pane,"dir":"right","cols":80,"rows":24}));
    let workspace = kinds_workspace(&mut app);
    let screen = workspace["screens"][0].clone();
    let split = screen["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|candidate| candidate["id"].as_u64() != Some(pane))
        .cloned()
        .expect("the split made a pane");
    app.send(serde_json::json!({"cmd":"new-tab","pane":split["id"]}));
    resource_request(
        &harness.socket,
        "parts-elsewhere-close",
        "pane.close",
        serde_json::json!({"machine":"current","session":"current","pane":split["resource_id"]}),
        Some("parts-elsewhere-close"),
    );
    let closed = closed_list(&harness, "parts-elsewhere-closed");
    assert_eq!(closed[0]["member_count"], 2, "{}", closed[0]);
    let id = closed[0]["id"].as_str().expect("the closed item has an id").to_string();
    reopen_members(&harness, &id, Some(serde_json::json!([0])), "parts-elsewhere-1");
    // The screen of the pane the first tab came back in moves to a
    // workspace of its own; the rest stays in the recorded workspace.
    app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                "cols":80,"rows":24}));
    app.send(serde_json::json!({"cmd":"move-screen","screen":screen["id"],"new_workspace":true}));
    let rest = reopen_members(&harness, &id, None, "parts-elsewhere-2");
    assert_eq!(rest["workspace_id"], workspace["resource_id"], "{rest}");
}

#[test]
fn a_closed_pane_never_splits_a_neighbor_in_another_workspace() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-pane-elsewhere");
    app.send(serde_json::json!({"cmd":"split","pane":pane,"dir":"down","cols":80,"rows":24}));
    let workspace = kinds_workspace(&mut app);
    let screen = workspace["screens"][0].clone();
    let split = screen["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|candidate| candidate["id"].as_u64() != Some(pane))
        .and_then(|candidate| candidate["resource_id"].as_str())
        .expect("the split made a pane")
        .to_string();
    resource_request(
        &harness.socket,
        "pane-elsewhere-close",
        "pane.close",
        serde_json::json!({"machine":"current","session":"current","pane":split}),
        Some("pane-elsewhere-close"),
    );
    let closed = closed_list(&harness, "pane-elsewhere-closed");
    let id = closed[0]["id"].as_str().expect("the close was recorded").to_string();
    // The neighbor's screen moves to a workspace of its own.
    app.send(serde_json::json!({"cmd":"new-screen","workspace":workspace["id"],
                                "cols":80,"rows":24}));
    app.send(serde_json::json!({"cmd":"move-screen","screen":screen["id"],"new_workspace":true}));
    let reopened = reopen_members(&harness, &id, None, "pane-elsewhere-reopen");
    assert_eq!(reopened["workspace_id"], workspace["resource_id"], "{reopened}");
    let tree = app.send(serde_json::json!({"cmd":"list-workspaces"}));
    let moved = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().cloned().unwrap_or_default())
        .find(|candidate| candidate["resource_id"] == screen["resource_id"])
        .unwrap_or_else(|| panic!("the moved screen is not listed: {tree}"));
    assert_eq!(moved["layout"]["type"], "leaf", "{moved}");
}

#[test]
fn a_closed_terminal_reopens_as_a_tab() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-terminal");
    let surface =
        app.send(serde_json::json!({"cmd":"new-tab","pane":pane}))["surface"].as_u64().unwrap();
    let tab = app.tab(surface)["tab_resource_id"].clone();
    let terminals = resource_request(
        &harness.socket,
        "path-terminal-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminal = terminals
        .as_array()
        .into_iter()
        .flatten()
        .find(|terminal| terminal["tab_ids"].as_array().is_some_and(|tabs| tabs.contains(&tab)))
        .and_then(|terminal| terminal["id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no terminal shows tab {tab}: {terminals}"));
    let (item, reopened) = close_records_and_reopens(
        &harness,
        "terminal.close",
        serde_json::json!({"terminal":terminal}),
        "path-terminal",
    );
    assert_eq!(item["kind"], "tab", "{item}");
    let tab = reopened["tab_ids"][0].as_str().expect("the reopen returned no tab").to_string();
    assert!(app.tab_by_id(&tab)["terminal_id"].is_string());
}

#[test]
fn a_closed_browser_reopens_on_its_url() {
    let _exclusive = exclusive_process_test();
    let (harness, mut app, pane) = start("reopen-path-browser");
    let created = app.send(serde_json::json!({
        "cmd":"new-frontend-browser-tab","pane":pane,"url":"https://example.com/path","engine":"webkit",
    }));
    let surface = created["surface"].as_u64().expect("no browser surface");
    let tab = app.tab(surface)["tab_resource_id"].clone();
    let browsers = resource_request(
        &harness.socket,
        "path-browser-list",
        "browser.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let browser = browsers
        .as_array()
        .into_iter()
        .flatten()
        .find(|browser| browser["tab_id"] == tab)
        .and_then(|browser| browser["id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no browser for tab {tab}: {browsers}"));
    let (item, reopened) = close_records_and_reopens(
        &harness,
        "browser.close",
        serde_json::json!({"browser":browser}),
        "path-browser",
    );
    assert_eq!(item["kind"], "tab", "{item}");
    let tab = reopened["tab_ids"][0].as_str().expect("the reopen returned no tab").to_string();
    let back = app.tab_by_id(&tab);
    assert_eq!(
        (back["kind"].as_str(), back["url"].as_str()),
        (Some("browser"), Some("https://example.com/path"))
    );
}

#[cfg(target_os = "linux")]
impl RecoveryHarness {
    /// A harness whose daemon runs with `env` added.
    fn start_with_env(name: &str, env: &[(&str, &str)]) -> Self {
        let mut harness = Self::start_unstarted(name);
        harness.extra_env =
            env.iter().map(|(key, value)| ((*key).to_string(), (*value).to_string())).collect();
        harness.restart();
        harness
    }
}

/// The key of the workspace named `name`, once the tree lists it.
#[cfg(target_os = "linux")]
fn workspace_key(app: &mut AppConnection, name: &str) -> Option<String> {
    app.send(serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == name)
        .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
}

/// A closed workspace's agent-home folder (its chat files) follows it on
/// Reopen Closed, and goes to the app's trash-pending folder (never deleted)
/// when its closed group is deleted (cx-gzh.9.2).
#[cfg(target_os = "linux")]
#[test]
fn a_closed_workspaces_agent_home_follows_its_reopen_and_goes_to_trash_on_delete() {
    let _exclusive = exclusive_process_test();
    let data = std::env::temp_dir().join(format!("reopen-agent-home-{}", std::process::id()));
    let _ = fs::remove_dir_all(&data);
    fs::create_dir_all(&data).unwrap();
    let data_text = data.to_string_lossy().into_owned();
    let harness =
        RecoveryHarness::start_with_env("reopen-agent-home", &[("XDG_DATA_HOME", &data_text)]);
    let mut app = AppConnection::open(&harness);
    app.send(serde_json::json!({"cmd":"new-workspace","name":"ah"}));
    let key = workspace_key(&mut app, "ah").expect("the workspace has a key");
    let base = data.join("cmux").join("agent-home");
    fs::create_dir_all(base.join(&key)).unwrap();
    fs::write(base.join(&key).join("chat.jsonl"), "kept").unwrap();

    app.send(serde_json::json!({"cmd":"close-workspace","key":key,"end_terminals":true}));
    let closed = resource_request(
        &harness.socket,
        "ah-list",
        "closed.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let id = closed[0]["id"].as_str().expect("the close is recorded").to_string();
    resource_request(
        &harness.socket,
        "ah-reopen",
        "closed.reopen",
        serde_json::json!({"machine":"current","session":"current","closed":id}),
        Some("ah-reopen"),
    );
    let reopened = workspace_key(&mut app, "ah").expect("the reopened workspace has a key");
    assert_ne!(reopened, key, "a reopened workspace gets a new key");
    assert_eq!(fs::read_to_string(base.join(&reopened).join("chat.jsonl")).unwrap(), "kept");
    assert!(!base.join(&key).exists(), "the old folder moved");

    app.send(serde_json::json!({"cmd":"close-workspace","key":reopened,"end_terminals":true}));
    let closed = resource_request(
        &harness.socket,
        "ah-list-2",
        "closed.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let id = closed[0]["id"].as_str().expect("the second close is recorded").to_string();
    resource_request(
        &harness.socket,
        "ah-delete",
        "closed.delete",
        serde_json::json!({"machine":"current","session":"current","closed":id}),
        Some("ah-delete"),
    );
    assert!(!base.join(&reopened).exists(), "the deleted workspace's folder left agent-home");
    assert_eq!(
        fs::read_to_string(base.join(".trash-pending").join(&reopened).join("chat.jsonl")).unwrap(),
        "kept",
        "it waits for the app's Trash, never deleted"
    );
    drop(harness);
    let _ = fs::remove_dir_all(&data);
}
