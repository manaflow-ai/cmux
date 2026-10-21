//! `workspace.open_url` (cx-ebm.59.3, `workspace-open-url-v1`) through a real
//! headless daemon. A web link a person clicks in the Chief chat opens on the
//! right side of the workspace: the daemon reuses the browser tab the person
//! looked at last, else makes one in a right-side pane, and never puts it in
//! the left agent chat dock or moves the keyboard focus out of the chat.
//!
//! A headless daemon has no browser engine. Without a cmux-browser provider,
//! the create path fails with the same `engine_unavailable` error that
//! `tab.create_browser` returns. With a stand-in provider that publishes no
//! target, a created tab stays `starting`: the first link creates it, and the
//! second link reuses that tab (its navigation waits for the browser to
//! attach) instead of a second tab.
#![cfg(unix)]

use serde_json::{Value, json};

use super::*;

/// One `cmux.protocol/2` request on its own connection; the whole response.
fn v2(server: &HeadlessServer, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let mut request = json!({"protocol": "cmux.protocol/2", "type": "request",
                             "id": format!("open-url-{operation}"), "operation": operation,
                             "params": fields});
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| {
        panic!("{operation}: no JSON reply: {line}; daemon stderr:\n{}", server.stderr_tail())
    })
}

fn value(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], true, "{reply}");
    &reply["result"]["value"]
}

fn error(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], false, "expected a refusal: {reply}");
    &reply["error"]
}

fn raw(server: &HeadlessServer, request: Value) -> Value {
    try_json_socket_request(&server.socket, request.clone())
        .unwrap_or_else(|| panic!("{request} failed; daemon stderr:\n{}", server.stderr_tail()))
}

/// The raw tree's first screen of the workspace with public id `workspace`.
fn screen(server: &HeadlessServer, workspace: &str) -> Value {
    let tree = raw(server, json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["resource_id"] == workspace)
        .unwrap_or_else(|| panic!("no workspace {workspace}: {tree}"))["screens"][0]
        .clone()
}

fn pane_by_resource<'a>(screen: &'a Value, pane: &Value) -> &'a Value {
    screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["resource_id"] == *pane)
        .unwrap_or_else(|| panic!("no pane {pane}: {screen}"))
}

fn tab_count(screen: &Value) -> usize {
    screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["tabs"].as_array().unwrap().len())
        .sum()
}

/// The engine refusal `tab.create_browser` gives a daemon with no provider.
fn assert_engine_unavailable(reply: &Value, direct: &Value) {
    let refusal = error(reply);
    assert_eq!(refusal["code"], "operation.failed", "{reply}");
    assert_eq!(refusal["details"]["extra"]["code"], "engine_unavailable", "{reply}");
    assert_eq!(refusal["details"]["reason"], direct["details"]["reason"], "{reply}");
}

#[test]
fn open_url_refuses_non_web_urls_and_takes_the_create_path_without_an_engine() {
    let server = HeadlessServer::start("open-url-create");
    let created = v2(
        &server,
        "workspace.create",
        json!({"initial_content": "terminal", "name": "links"}),
        Some("open-url-ws"),
    );
    let workspace = value(&created)["workspace_id"].as_str().unwrap().to_string();

    let long = format!("https://example.com/{}", "a".repeat(8192));
    for (index, url) in [
        "ftp://example.com/file",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "about:blank",
        "https://",
        "https://exa mple.com/",
        "cmux://workspace/1",
        "https://user@example.com/",
        "https://user:secret@example.com/",
        "https://example.com/\u{202E}gnp.exe",
        "https://exa\u{200B}mple.com/",
        "data:text/html,hi",
        long.as_str(),
    ]
    .into_iter()
    .enumerate()
    {
        let reply = v2(
            &server,
            "workspace.open_url",
            json!({"workspace": workspace, "url": url}),
            Some(&format!("open-url-bad-{index}")),
        );
        let refusal = error(&reply);
        assert_eq!(refusal["code"], "validation.invalid", "{url}: {reply}");
        assert_eq!(refusal["details"]["field"], "url", "{url}: {reply}");
    }
    // The CLI form refuses the same way.
    let output = json_cli(&server, &["workspace", &workspace, "open-url", "--url", "ftp://x/"]);
    assert!(!output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
    assert_eq!(json_error(&output)["code"], "validation.invalid", "{}", json_error(&output));

    let before = tab_count(&screen(&server, &workspace));
    let direct = v2(
        &server,
        "tab.create_browser",
        json!({"workspace": workspace, "url": "https://example.com/"}),
        Some("open-url-direct"),
    );
    let direct = error(&direct).clone();
    assert_eq!(direct["details"]["extra"]["code"], "engine_unavailable", "{direct}");
    let opened = v2(
        &server,
        "workspace.open_url",
        json!({"workspace": workspace, "url": "https://example.com/docs"}),
        Some("open-url-1"),
    );
    assert_engine_unavailable(&opened, &direct);
    assert_eq!(tab_count(&screen(&server, &workspace)), before, "a refused open made a tab");

    // Without a workspace the operation targets the home workspace; with no
    // home workspace there is nothing to open in.
    let homeless = v2(
        &server,
        "workspace.open_url",
        json!({"url": "https://example.com/"}),
        Some("open-url-homeless"),
    );
    let refusal = error(&homeless);
    assert_eq!(refusal["code"], "selector.not_found", "{homeless}");
    assert_eq!(refusal["details"]["scope"], "workspace", "{homeless}");

    let home = v2(&server, "workspace.ensure_home", json!({}), Some("open-url-home"));
    let home = value(&home)["workspace_id"].as_str().unwrap().to_string();
    let terminal =
        v2(&server, "tab.create_terminal", json!({"workspace": home}), Some("open-url-home-tab"));
    value(&terminal);
    let at_home = v2(
        &server,
        "workspace.open_url",
        json!({"url": "https://example.com/home"}),
        Some("open-url-home-open"),
    );
    assert_engine_unavailable(&at_home, &direct);
}

/// A stand-in cmux-browser provider: registered on a connection that stays
/// open (the lease ends with it); it publishes no CDP target.
fn browser_provider(server: &HeadlessServer) -> impl Sized {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let request = json!({
        "id": 1, "cmd": "register-browser-provider", "provider_id": "open-url-test",
        "endpoint": "ws://127.0.0.1:9/devtools/browser/test", "authentication": "none",
        "targets": [],
    });
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "provider registration failed: {response}");
    (writer, reader)
}

/// A workspace whose screen has a docked column `dock` on the left, holding
/// one terminal, and two right-side panes in layout order: its public id,
/// the dock pane and the right-side panes (raw tree values).
fn docked_workspace(
    server: &HeadlessServer,
    name: &str,
    dock: Value,
) -> (String, Value, Vec<Value>) {
    let created = v2(
        server,
        "workspace.create",
        json!({"initial_content": "terminal", "name": name}),
        Some(&format!("{name}-ws")),
    );
    let workspace = value(&created)["workspace_id"].as_str().unwrap().to_string();
    let first = screen(server, &workspace);
    let left = first["panes"][0]["id"].clone();
    raw(server, json!({"cmd": "new-pane-right", "pane": left, "width": 0.5}));
    let strip = screen(server, &workspace);
    let right = strip["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != left)
        .unwrap();
    raw(server, json!({"cmd": "new-tab", "pane": right}));
    let tabs = screen(server, &workspace)["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == right)
        .unwrap()["tabs"]
        .clone();
    let chat = tabs.as_array().unwrap().last().unwrap()["surface"].clone();
    raw(server, json!({"cmd": "move-tab-to-column", "surface": chat, "pane": right, "dock": dock}));
    let docked = screen(server, &workspace);
    assert_eq!(docked["columns"][0]["dock"], dock, "{docked}");
    let dock = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["tabs"].as_array().unwrap().iter().any(|tab| tab["surface"] == chat))
        .unwrap()
        .clone();
    let right_side = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|pane| pane["id"] != dock["id"])
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(right_side.len(), 2, "{docked}");
    (workspace, dock, right_side)
}

fn focus(server: &HeadlessServer, pane: &Value, key: &str) {
    value(&v2(server, "pane.focus", json!({"pane": pane["resource_id"]}), Some(key)));
}

#[test]
fn open_url_opens_right_of_the_agent_chat_dock_and_reuses_that_tab() {
    let server = HeadlessServer::start("open-url-dock");
    let (endpoint, navigations) = wedged_cdp_endpoint("https://example.com/one");
    let mut provider = Line::open(&server);
    register_provider(&mut provider, 1, &endpoint, json!([]));
    let (workspace, dock, right_panes) = docked_workspace(
        &server,
        "open-url-dock",
        json!({"edge": "left", "mode": "docked", "role": "agent_chat"}),
    );
    // The person last used the second right-side pane (not the first in the
    // layout), then went back to type in the chat: the dock has the focus.
    let recent = right_panes[1].clone();
    focus(&server, &recent, "open-url-dock-focus-recent");
    focus(&server, &dock, "open-url-dock-focus-chat");
    let right_side = right_panes.iter().map(|pane| pane["resource_id"].clone()).collect::<Vec<_>>();
    let before = screen(&server, &workspace);
    assert_eq!(before["active_pane"], dock["id"], "{before}");

    let opened = v2(
        &server,
        "workspace.open_url",
        json!({"workspace": workspace, "url": "https://example.com/one"}),
        Some("open-url-dock-1"),
    );
    let first_open = value(&opened).clone();
    assert_eq!(first_open["kind"], "browser", "{opened}");
    assert_eq!(first_open["reused"], false, "{opened}");
    assert_eq!(first_open["workspace_id"], workspace, "{opened}");
    assert!(right_side.contains(&first_open["pane_id"]), "not a right-side pane: {opened}");
    assert_eq!(
        first_open["pane_id"], recent["resource_id"],
        "the link must open in the right-side pane used last: {opened}"
    );
    let after = screen(&server, &workspace);
    assert_eq!(after["active_pane"], dock["id"], "the keyboard focus left the chat: {after}");
    assert_eq!(
        pane_by_resource(&after, &dock["resource_id"])["tabs"].as_array().unwrap().len(),
        1,
        "a browser tab went into the agent chat dock: {after}"
    );
    let target = pane_by_resource(&after, &first_open["pane_id"]);
    let active = target["active_tab"].as_u64().unwrap() as usize;
    assert_eq!(
        target["tabs"][active]["tab_resource_id"], first_open["tab_id"],
        "the new browser tab is not its pane's selected tab: {after}"
    );
    assert_eq!(tab_count(&after), tab_count(&before) + 1, "{after}");

    // A retry of the same request replays it: no second tab.
    let replayed = v2(
        &server,
        "workspace.open_url",
        json!({"workspace": workspace, "url": "https://example.com/one"}),
        Some("open-url-dock-1"),
    );
    assert_eq!(value(&replayed)["tab_id"], first_open["tab_id"], "{replayed}");
    assert_eq!(tab_count(&screen(&server, &workspace)), tab_count(&after), "a replay made a tab");

    // The next links reuse that browser tab while it is still starting (the
    // provider has not published its page): each navigation is queued, no
    // second tab is made, and the newer link supersedes the older one.
    for (url, key) in [
        ("https://example.com/two", "open-url-dock-2"),
        ("https://example.com/three", "open-url-dock-3"),
    ] {
        let again = v2(
            &server,
            "workspace.open_url",
            json!({"workspace": workspace, "url": url}),
            Some(key),
        );
        assert_eq!(value(&again)["reused"], true, "{again}");
        assert_eq!(value(&again)["tab_id"], first_open["tab_id"], "{again}");
    }
    let last = screen(&server, &workspace);
    assert_eq!(tab_count(&last), tab_count(&after), "a later link made a tab: {last}");
    assert_eq!(last["active_pane"], dock["id"], "the keyboard focus left the chat: {last}");

    // The provider publishes the page: the browser attaches and loads the
    // newest pending link, never the superseded one.
    let tab = first_open["tab_id"].clone();
    register_provider(
        &mut provider,
        2,
        &endpoint,
        json!([{"tab_id": tab, "target_id": "target-1"}]),
    );
    wait_live(&server, &workspace, &tab);
    assert_eq!(next_navigation(&navigations), "https://example.com/three");
    let later = navigations.recv_timeout(Duration::from_millis(500)).ok();
    assert_ne!(later.as_deref(), Some("https://example.com/two"), "a superseded link loaded");
}

/// A left-edge dock without the agent chat role is not the right side either.
#[test]
fn open_url_never_opens_in_a_left_edge_dock() {
    let server = HeadlessServer::start("open-url-left-dock");
    let _provider = browser_provider(&server);
    let (workspace, dock, right_panes) =
        docked_workspace(&server, "open-url-left", json!({"edge": "left", "mode": "docked"}));
    focus(&server, &dock, "open-url-left-focus");
    let opened = v2(
        &server,
        "workspace.open_url",
        json!({"workspace": workspace, "url": "https://example.com/left"}),
        Some("open-url-left-1"),
    );
    let pane = value(&opened)["pane_id"].clone();
    assert_ne!(pane, dock["resource_id"], "a link opened in the left dock: {opened}");
    assert!(
        right_panes.iter().any(|candidate| candidate["resource_id"] == pane),
        "not a right-side pane: {opened}"
    );
    let after = screen(&server, &workspace);
    assert_eq!(after["active_pane"], dock["id"], "the keyboard focus moved: {after}");
}

/// One line connection that stays open (a page relay keeps its page id).
struct Line {
    writer: Box<dyn Write>,
    reader: Box<dyn BufRead>,
}

impl Line {
    fn open(server: &HeadlessServer) -> Self {
        let stream = transport::connect(&server.socket).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { writer: Box::new(writer), reader: Box::new(BufReader::new(stream)) }
    }

    fn send(&mut self, request: &Value) -> Value {
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == request["id"] {
                return value;
            }
        }
    }
}

/// The Channels page (Home) may call `workspace.open_url` only on the
/// person's gesture, and nothing else of the catalog.
#[test]
fn the_home_channels_page_opens_a_link_only_on_a_gesture() {
    let server = HeadlessServer::start("open-url-page");
    let mut page = Line::open(&server);
    let hello = page.send(
        &json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "home-channels"}),
    );
    assert_eq!(hello["ok"], true, "{hello}");
    let request = |id: &str, operation: &str, params: Value, key: Option<&str>| {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                                 "operation": operation, "params": params});
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        request
    };
    let listed = page.send(&request("list", "workspace.list", json!({}), None));
    assert_eq!(error(&listed)["code"], "origin.forbidden", "{listed}");
    assert_eq!(error(&listed)["details"]["reason"], "page_not_allowed", "{listed}");

    // A link needs the person's click: the host proves it with a confirmation
    // for the request (origin.confirmation.issue, the verified app only).
    let opened = page.send(&request(
        "open",
        "workspace.open_url",
        json!({"url": "https://example.com/from-chat"}),
        Some("open-url-page-open"),
    ));
    assert_eq!(error(&opened)["code"], "origin.forbidden", "{opened}");
    assert_eq!(error(&opened)["details"]["reason"], "gesture_required", "{opened}");
}

/// The tree tab with public id `tab` in `screen`.
fn tab_by_resource<'a>(screen: &'a Value, tab: &Value) -> &'a Value {
    screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|pane| pane["tabs"].as_array().unwrap())
        .find(|candidate| candidate["tab_resource_id"] == *tab)
        .unwrap_or_else(|| panic!("no tab {tab}: {screen}"))
}

fn selected_tab(screen: &Value, pane: &Value) -> Value {
    let pane = pane_by_resource(screen, pane);
    let active = pane["active_tab"].as_u64().unwrap() as usize;
    pane["tabs"][active]["tab_resource_id"].clone()
}

/// In a session whose frontend renders browser tabs (the cmux app declares
/// `frontend-browser-tabs-v1`), a link makes a frontend browser tab on the
/// right side through the daemon's frontend tab path (no browser engine is
/// needed), the next link navigates that tab through the frontend record,
/// and a retry with the same key answers the first result even after the
/// selection changed.
#[test]
fn open_url_uses_the_frontend_browser_path_when_the_app_renders_browsers() {
    let server = HeadlessServer::start("open-url-frontend");
    // The app's connection: it stays open and declares that it renders
    // browser tabs. No cmux-browser provider is registered.
    let mut app = Line::open(&server);
    let info = app.send(&json!({"id": 1, "cmd": "set-client-info", "name": "app",
                                "capabilities": ["frontend-browser-tabs-v1"]}));
    assert_eq!(info["ok"], true, "{info}");
    let (workspace, dock, right_panes) = docked_workspace(
        &server,
        "open-url-frontend",
        json!({"edge": "left", "mode": "docked", "role": "agent_chat"}),
    );
    let recent = right_panes[1].clone();
    let other = right_panes[0].clone();
    focus(&server, &recent, "open-url-frontend-focus-recent");
    focus(&server, &dock, "open-url-frontend-focus-chat");
    let before = screen(&server, &workspace);

    let open = |url: &str, key: &str| {
        v2(&server, "workspace.open_url", json!({"workspace": workspace, "url": url}), Some(key))
    };
    let opened = open("https://example.com/one", "open-url-frontend-1");
    let first = value(&opened).clone();
    assert_eq!(first["kind"], "browser", "{opened}");
    assert_eq!(first["reused"], false, "{opened}");
    assert_eq!(
        first["pane_id"], recent["resource_id"],
        "not the right-side pane used last: {opened}"
    );
    let tab = first["tab_id"].clone();
    assert!(tab.as_str().is_some_and(|id| id.starts_with("tab_")), "{opened}");
    assert!(first["browser_id"].as_str().is_some_and(|id| id.starts_with("browser_")), "{opened}");
    let after = screen(&server, &workspace);
    let created = tab_by_resource(&after, &tab);
    assert_eq!(created["browser_renderer"], "frontend", "not a frontend browser tab: {after}");
    assert_eq!(created["url"], "https://example.com/one", "{after}");
    assert_eq!(selected_tab(&after, &recent["resource_id"]), tab, "not selected: {after}");
    assert_eq!(after["active_pane"], dock["id"], "the keyboard focus left the chat: {after}");
    assert_eq!(
        pane_by_resource(&after, &dock["resource_id"])["tabs"].as_array().unwrap().len(),
        1,
        "a browser tab went into the agent chat dock: {after}"
    );
    assert_eq!(tab_count(&after), tab_count(&before) + 1, "{after}");

    // The next link reuses that tab: the frontend record gets the new URL.
    let again = open("https://example.com/two", "open-url-frontend-2");
    let second = value(&again).clone();
    assert_eq!(second["reused"], true, "{again}");
    assert_eq!(second["tab_id"], tab, "{again}");
    assert_eq!(second["browser_id"], first["browser_id"], "{again}");
    let reused = screen(&server, &workspace);
    assert_eq!(tab_by_resource(&reused, &tab)["url"], "https://example.com/two", "{reused}");
    assert_eq!(tab_count(&reused), tab_count(&after), "the second link made a tab: {reused}");
    assert_eq!(reused["active_pane"], dock["id"], "the keyboard focus left the chat: {reused}");

    // The page then goes on to another URL (the app reports it), and the
    // person selects another browser tab in the other right-side pane.
    let created_surface = created["surface"].clone();
    let navigated = raw(
        &server,
        json!({"cmd": "update-frontend-browser-tab", "surface": created_surface,
               "url": "https://example.com/three"}),
    );
    assert_eq!(navigated["url"], "https://example.com/three", "{navigated}");
    let other_browser = raw(
        &server,
        json!({"cmd": "new-frontend-browser-tab", "pane": other["id"], "engine": "webkit",
               "url": "https://example.com/other"}),
    );
    let other_tab = other_browser["tab_resource_id"].clone();
    focus(&server, &other, "open-url-frontend-focus-other");
    focus(&server, &dock, "open-url-frontend-focus-chat-2");
    let moved = screen(&server, &workspace);

    // A retry of each request answers its first result: no second tab and
    // no second navigation, although the selection changed.
    let retried = open("https://example.com/one", "open-url-frontend-1");
    assert_eq!(value(&retried), &first, "{retried}");
    let retried = open("https://example.com/two", "open-url-frontend-2");
    assert_eq!(value(&retried), &second, "{retried}");
    let replayed = screen(&server, &workspace);
    assert_eq!(tab_count(&replayed), tab_count(&moved), "a retry made a tab: {replayed}");
    assert_eq!(tab_by_resource(&replayed, &tab)["url"], "https://example.com/three", "{replayed}");
    assert_eq!(
        tab_by_resource(&replayed, &other_tab)["url"],
        "https://example.com/other",
        "a retry navigated another tab: {replayed}"
    );
    // The same key with another link is a conflict.
    let conflict = open("https://example.com/four", "open-url-frontend-2");
    assert_eq!(error(&conflict)["code"], "idempotency.conflict", "{conflict}");

    // A new link reuses the browser tab the person looked at last.
    let third = open("https://example.com/five", "open-url-frontend-3");
    assert_eq!(value(&third)["reused"], true, "{third}");
    assert_eq!(value(&third)["tab_id"], other_tab, "{third}");
    let last = screen(&server, &workspace);
    assert_eq!(tab_by_resource(&last, &other_tab)["url"], "https://example.com/five", "{last}");
    assert_eq!(tab_by_resource(&last, &tab)["url"], "https://example.com/three", "{last}");
    assert_eq!(last["active_pane"], dock["id"], "the keyboard focus left the chat: {last}");
    drop(app);
}

/// The app's connection: it stays open and declares that it renders
/// browser tabs.
fn frontend_app(server: &HeadlessServer) -> Line {
    let mut app = Line::open(server);
    let info = app.send(&json!({"id": 1, "cmd": "set-client-info", "name": "app",
                                "capabilities": ["frontend-browser-tabs-v1"]}));
    assert_eq!(info["ok"], true, "{info}");
    app
}

/// With the app attached, a link in a home workspace that has no screen yet
/// (a fresh Home) gets the workspace's first screen with a frontend browser
/// tab; a retry answers the first result and the next link reuses the tab.
#[test]
fn open_url_in_an_empty_home_makes_a_frontend_tab() {
    let server = HeadlessServer::start("open-url-frontend-home");
    let _app = frontend_app(&server);
    let home = v2(&server, "workspace.ensure_home", json!({}), Some("open-url-fresh-home"));
    let home = value(&home)["workspace_id"].as_str().unwrap().to_string();

    let open =
        |url: &str, key: &str| v2(&server, "workspace.open_url", json!({"url": url}), Some(key));
    let opened = open("https://example.com/home", "open-url-fresh-home-1");
    let first = value(&opened).clone();
    assert_eq!(first["kind"], "browser", "{opened}");
    assert_eq!(first["reused"], false, "{opened}");
    assert_eq!(first["workspace_id"], home, "{opened}");
    let made = screen(&server, &home);
    let tab = tab_by_resource(&made, &first["tab_id"]);
    assert_eq!(tab["browser_renderer"], "frontend", "not a frontend browser tab: {made}");
    assert_eq!(tab["url"], "https://example.com/home", "{made}");
    assert_eq!(made["panes"].as_array().unwrap().len(), 1, "{made}");
    assert_eq!(pane_by_resource(&made, &first["pane_id"])["resource_id"], first["pane_id"]);

    let retried = open("https://example.com/home", "open-url-fresh-home-1");
    assert_eq!(value(&retried), &first, "{retried}");
    assert_eq!(tab_count(&screen(&server, &home)), 1, "a retry made a tab");
    let again = open("https://example.com/home-2", "open-url-fresh-home-2");
    assert_eq!(value(&again)["reused"], true, "{again}");
    assert_eq!(value(&again)["tab_id"], first["tab_id"], "{again}");
    assert_eq!(tab_count(&screen(&server, &home)), 1, "the second link made a tab");
}

/// The page the wedged browser below shows when it attaches.
const WEDGED_PAGE: &str = "https://example.com/wedged";

/// A stand-in cmux-browser endpoint whose page shows `page` when it attaches
/// and never answers `Page.navigate` (a slow site, or a stuck renderer): it
/// answers the attach steps, holds every navigation and reports its URL.
fn wedged_cdp_endpoint(page: &'static str) -> (String, mpsc::Receiver<String>) {
    let (navigations, reported) = mpsc::channel();
    use tokio_tungstenite::tungstenite::{self, Message};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let navigations = navigations.clone();
            std::thread::spawn(move || {
                let Ok(mut socket) = tungstenite::accept(stream) else { return };
                let mut held = Vec::new();
                loop {
                    let request: Value = match socket.read() {
                        Ok(Message::Text(text)) => serde_json::from_str(&text).unwrap_or_default(),
                        Ok(Message::Close(_)) | Err(_) => return,
                        Ok(_) => continue,
                    };
                    let id = request["id"].clone();
                    let result = match request["method"].as_str().unwrap_or_default() {
                        "Page.navigate" => {
                            let url = request["params"]["url"].as_str().unwrap_or_default();
                            let _ = navigations.send(url.to_string());
                            held.push(id);
                            continue;
                        }
                        "Target.attachToTarget" => json!({"sessionId": "session-1"}),
                        "Page.getFrameTree" => json!({"frameTree": {"frame": {
                            "id": "main-frame", "loaderId": "loader-1", "url": page,
                        }}}),
                        _ => json!({}),
                    };
                    let reply = json!({"id": id, "result": result}).to_string();
                    if socket.send(Message::Text(reply.into())).is_err() {
                        return;
                    }
                }
            });
        }
    });
    (format!("ws://{address}/devtools/browser/wedged"), reported)
}

/// The next navigation the endpoint reports, within 10 seconds.
fn next_navigation(navigations: &mpsc::Receiver<String>) -> String {
    navigations.recv_timeout(Duration::from_secs(10)).expect("no Page.navigate reached the page")
}

/// `register-browser-provider` for `endpoint` on the provider's connection
/// (its lease lasts as long as the connection), publishing `targets`.
fn register_provider(provider: &mut Line, id: u64, endpoint: &str, targets: Value) {
    let reply = provider.send(&json!({"id": id, "cmd": "register-browser-provider",
                                      "provider_id": "open-url-cdp", "endpoint": endpoint,
                                      "authentication": "none", "targets": targets}));
    assert_eq!(reply["ok"], true, "{reply}");
}

/// Wait until the browser tab `tab` of `workspace` is live.
fn wait_live(server: &HeadlessServer, workspace: &str, tab: &Value) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let shown = screen(server, workspace);
        if tab_by_resource(&shown, tab)["browser_status"] == "live" {
            return;
        }
        assert!(Instant::now() < deadline, "the browser never went live: {shown}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A link into a daemon-rendered browser tab whose page never answers a
/// navigation: `cmux workspace open-url` answers at once (the tab is
/// reused and loads the link), instead of waiting on the page until the
/// CLI gives up with no answer.
#[test]
fn open_url_into_a_browser_whose_page_never_answers_returns_at_once() {
    let server = HeadlessServer::start("open-url-wedged");
    let (endpoint, navigations) = wedged_cdp_endpoint(WEDGED_PAGE);
    let mut provider = Line::open(&server);
    register_provider(&mut provider, 1, &endpoint, json!([]));
    let created = v2(
        &server,
        "workspace.create",
        json!({"initial_content": "terminal", "name": "wedged"}),
        Some("open-url-wedged-ws"),
    );
    let workspace = value(&created)["workspace_id"].as_str().unwrap().to_string();
    let open = |url: &str| {
        let started = Instant::now();
        let output = json_cli(&server, &["workspace", &workspace, "open-url", "--url", url]);
        (output, started.elapsed())
    };

    let (first, _) = open(WEDGED_PAGE);
    assert_success(&first);
    let first = json_output(&first)["value"].clone();
    assert_eq!(first["reused"], false, "{first}");
    let tab = first["tab_id"].clone();
    // The provider publishes the tab's page: the browser goes live.
    register_provider(
        &mut provider,
        2,
        &endpoint,
        json!([{"tab_id": tab, "target_id": "target-1"}]),
    );
    wait_live(&server, &workspace, &tab);

    let (second, elapsed) = open("https://example.com/next");
    assert!(
        second.status.success(),
        "the second link failed after {elapsed:?}: {}{}",
        String::from_utf8_lossy(&second.stdout),
        String::from_utf8_lossy(&second.stderr)
    );
    assert!(elapsed < Duration::from_secs(5), "the second link took {elapsed:?}");
    let second = json_output(&second)["value"].clone();
    assert_eq!(second["reused"], true, "{second}");
    assert_eq!(second["tab_id"], tab, "{second}");
    // The link reaches the page.
    assert_eq!(next_navigation(&navigations), "https://example.com/next");
    // The daemon still answers.
    let listed = json_cli(&server, &["workspace", "list"]);
    assert_success(&listed);
    drop(provider);
}

/// `tab.create_browser` (`cmux browser open`, `cmux tab create browser`, the
/// MCP `tab_create_browser`) with no cmux-browser provider: before the app
/// attaches it refuses with `engine_unavailable` and a reason that says what
/// to do; once the app attaches (`frontend-browser-tabs-v1`) the same create
/// makes a frontend browser tab the app renders, and a retry with the same
/// key answers the first tab instead of a second one. Live repro before the
/// fix: an agent whose CLI talks to a Chief session the app shows got "no
/// browser engine: no cmux-browser provider is attached" for every
/// `cmux browser open`.
#[test]
fn tab_create_browser_makes_a_frontend_tab_when_the_app_is_attached() {
    let server = HeadlessServer::start("create-browser-frontend");
    let created = v2(
        &server,
        "workspace.create",
        json!({"initial_content": "terminal", "name": "create-browser-frontend"}),
        Some("create-browser-frontend-ws"),
    );
    let workspace = value(&created)["workspace_id"].as_str().unwrap().to_string();
    let create = |url: &str, key: &str| {
        v2(&server, "tab.create_browser", json!({"workspace": workspace, "url": url}), Some(key))
    };

    let refused = create("https://example.com/none", "create-browser-frontend-0");
    let refusal = error(&refused);
    assert_eq!(refusal["details"]["extra"]["code"], "engine_unavailable", "{refused}");
    assert!(
        refusal["details"]["reason"].as_str().is_some_and(|reason| reason.contains("cmux app")),
        "the refusal says to open the cmux app: {refused}"
    );
    let before = screen(&server, &workspace);

    let _app = frontend_app(&server);
    let opened = create("https://example.com/agent", "create-browser-frontend-1");
    let first = value(&opened).clone();
    assert!(first["browser_id"].as_str().is_some_and(|id| id.starts_with("browser_")), "{opened}");
    let after = screen(&server, &workspace);
    let tab = tab_by_resource(&after, &first["tab_id"]);
    assert_eq!(tab["browser_renderer"], "frontend", "not a frontend browser tab: {after}");
    assert_eq!(tab["url"], "https://example.com/agent", "{after}");
    assert_eq!(tab_count(&after), tab_count(&before) + 1, "{after}");
    // An agent's tab opens in the person's `browser.defaultEngine`
    // (Chromium unless set to WebKit), as a tab the person opens does.
    assert_eq!(tab["browser_engine"], "cef", "an agent tab skipped the default engine: {after}");

    let retried = create("https://example.com/agent", "create-browser-frontend-1");
    assert_eq!(value(&retried)["browser_id"], first["browser_id"], "{retried}");
    assert_eq!(value(&retried)["tab_id"], first["tab_id"], "{retried}");
    assert_eq!(tab_count(&screen(&server, &workspace)), tab_count(&after), "a retry made a tab");

    let conflict = create("https://example.com/other", "create-browser-frontend-1");
    assert_eq!(error(&conflict)["code"], "idempotency.conflict", "{conflict}");

    // `engine` (`cmux browser open --engine webkit`, MCP `tab_create_browser`
    // `engine`) picks the engine of that one tab.
    let webkit = v2(
        &server,
        "tab.create_browser",
        json!({"workspace": workspace, "url": "https://example.com/webkit", "engine": "webkit"}),
        Some("create-browser-frontend-2"),
    );
    let listed = screen(&server, &workspace);
    let tab = tab_by_resource(&listed, &value(&webkit)["tab_id"]);
    assert_eq!(tab["browser_engine"], "webkit", "{listed}");
}
