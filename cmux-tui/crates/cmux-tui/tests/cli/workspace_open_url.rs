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
//! second link reuses that tab (its `browser.navigate` answers that the
//! browser is still starting) instead of a second tab.
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

#[test]
fn open_url_opens_right_of_the_agent_chat_dock_and_reuses_that_tab() {
    let server = HeadlessServer::start("open-url-dock");
    let _provider = browser_provider(&server);
    let created = v2(
        &server,
        "workspace.create",
        json!({"initial_content": "terminal", "name": "home-like"}),
        Some("open-url-dock-ws"),
    );
    let workspace = value(&created)["workspace_id"].as_str().unwrap().to_string();
    let first = screen(&server, &workspace);
    let left = first["panes"][0]["id"].clone();
    raw(&server, json!({"cmd": "new-pane-right", "pane": left, "width": 0.5}));
    let strip = screen(&server, &workspace);
    let right = strip["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != left)
        .unwrap();
    raw(&server, json!({"cmd": "new-tab", "pane": right}));
    let tabs = screen(&server, &workspace)["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == right)
        .unwrap()["tabs"]
        .clone();
    let chat = tabs.as_array().unwrap().last().unwrap()["surface"].clone();
    raw(
        &server,
        json!({
            "cmd": "move-tab-to-column", "surface": chat, "pane": right,
            "dock": {"edge": "left", "mode": "docked", "role": "agent_chat"},
        }),
    );
    let docked = screen(&server, &workspace);
    assert_eq!(docked["columns"][0]["dock"]["role"], "agent_chat", "{docked}");
    let dock = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["tabs"].as_array().unwrap().iter().any(|tab| tab["surface"] == chat))
        .unwrap()
        .clone();
    // The person types in the chat: the dock pane has the keyboard focus.
    let focus = v2(
        &server,
        "pane.focus",
        json!({"pane": dock["resource_id"]}),
        Some("open-url-dock-focus"),
    );
    value(&focus);
    let right_side = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|pane| pane["id"] != dock["id"])
        .map(|pane| pane["resource_id"].clone())
        .collect::<Vec<_>>();
    assert_eq!(right_side.len(), 2, "{docked}");
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

    // The next link reuses that browser tab: it navigates it (the stand-in
    // provider never gives it a page, so the navigation answers that the
    // browser is still starting) and makes no second tab.
    let again = v2(
        &server,
        "workspace.open_url",
        json!({"workspace": workspace, "url": "https://example.com/two"}),
        Some("open-url-dock-2"),
    );
    let refusal = error(&again);
    assert_eq!(refusal["code"], "operation.failed", "{again}");
    assert_eq!(refusal["details"]["operation"], "browser.navigate", "{again}");
    assert_eq!(refusal["details"]["extra"]["status"], "starting", "{again}");
    let last = screen(&server, &workspace);
    assert_eq!(tab_count(&last), tab_count(&after), "the second link made a tab: {last}");
    assert_eq!(last["active_pane"], dock["id"], "the keyboard focus left the chat: {last}");
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

/// The Channels page (Home) opens a clicked link with `workspace.open_url`
/// through its page connection; the page may call nothing else.
#[test]
fn the_home_channels_page_may_open_a_link_and_nothing_else() {
    let server = HeadlessServer::start("open-url-page");
    let home = v2(&server, "workspace.ensure_home", json!({}), Some("open-url-page-home"));
    let home = value(&home)["workspace_id"].as_str().unwrap().to_string();
    value(&v2(&server, "tab.create_terminal", json!({"workspace": home}), Some("open-url-page-t")));

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

    let bad = page.send(&request(
        "bad",
        "workspace.open_url",
        json!({"url": "javascript:alert(1)"}),
        Some("open-url-page-bad"),
    ));
    assert_eq!(error(&bad)["code"], "validation.invalid", "{bad}");
    assert_eq!(error(&bad)["details"]["field"], "url", "{bad}");
    let opened = page.send(&request(
        "open",
        "workspace.open_url",
        json!({"url": "https://example.com/from-chat"}),
        Some("open-url-page-open"),
    ));
    let refusal = error(&opened);
    assert_eq!(refusal["code"], "operation.failed", "{opened}");
    assert_eq!(refusal["details"]["extra"]["code"], "engine_unavailable", "{opened}");
}
