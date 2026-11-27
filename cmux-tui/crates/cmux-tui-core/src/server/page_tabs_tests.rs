//! `page-tabs-v1`: a conversation tab whose source is one of the app's own
//! pages (App Store, Settings, ...) is an ordinary store tab. It keeps its
//! record across every move, a pane holding only a page tab is a valid
//! pane, closing it deletes its store rows, Reopen Closed brings it back,
//! and a connection without the capability reads it as a browser tab with
//! no record.

use super::super::*;

fn writer_with_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (writer, outbound)
}

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let (writer, _) = writer_with_outbound();
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn test_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

/// A new workspace with one terminal; returns (terminal surface, its pane).
fn terminal_pane(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    (terminal, mux.with_state(|state| state.pane_of(terminal)).unwrap())
}

fn page_tab(mux: &Arc<Mux>, pane: PaneId, page: &str) -> anyhow::Result<Value> {
    run(mux, json!({"cmd":"new-conversation-tab","pane":pane,"page":page}))
}

fn surface_of(created: &Value) -> SurfaceId {
    created["surface"].as_u64().unwrap()
}

/// The raw tree tab of `surface`, if it is placed.
fn raw_tab(mux: &Arc<Mux>, surface: SurfaceId) -> Option<Value> {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()?
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"] == json!(surface))
        .cloned()
}

fn pane_tabs(mux: &Arc<Mux>, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()).unwrap_or_default())
}

fn page_rows(mux: &Arc<Mux>, browser_id: &str) -> i64 {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT count(*) FROM page_tabs WHERE browser_id = ?1",
            [browser_id],
            |row| row.get::<_, i64>(0),
        )?)
    })
    .unwrap()
}

fn resource(mux: &Arc<Mux>, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                              "operation":operation,"params":params});
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"].clone()
}

/// A page tab keeps its record across move-tab, move-tab-to-split (alone in
/// the new pane) and move-tab-to-new-workspace, and its pane's last other
/// tab can close without closing it. Its close deletes its row.
#[test]
fn page_tab_is_an_ordinary_store_tab() {
    let mux = test_mux("page-tabs-moves");
    let (terminal, first) = terminal_pane(&mux);
    let (_, second) = terminal_pane(&mux);
    let created = page_tab(&mux, first, "app-store").unwrap();
    let surface = surface_of(&created);
    assert_eq!(created["conversation"], json!({"page":"app-store"}), "{created}");
    let tab = raw_tab(&mux, surface).unwrap();
    assert_eq!(tab["kind"], "conversation");
    assert_eq!(tab["conversation"], json!({"page":"app-store"}));

    // The terminal leaves; the page tab holds the pane.
    run(&mux, json!({"cmd":"close-surface","surface":terminal})).unwrap();
    assert_eq!(pane_tabs(&mux, first), vec![surface], "a page tab alone is a valid pane");

    run(&mux, json!({"cmd":"move-tab","surface":surface,"pane":second,"index":0})).unwrap();
    assert_eq!(mux.with_state(|state| state.pane_of(surface)), Some(second));
    run(&mux, json!({"cmd":"move-tab-to-split","surface":surface,"pane":second,"edge":"right"}))
        .unwrap();
    let split = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_ne!(split, second);
    assert_eq!(pane_tabs(&mux, split), vec![surface]);
    run(&mux, json!({"cmd":"move-tab-to-new-workspace","surface":surface})).unwrap();
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"], json!({"page":"app-store"}));

    let browser = created["content_resource_id"].as_str().unwrap().to_string();
    assert_eq!(page_rows(&mux, &browser), 1);
    run(&mux, json!({"cmd":"close-surface","surface":surface})).unwrap();
    assert_eq!(page_rows(&mux, &browser), 0);
    mux.shutdown();
}

/// Reopen Closed brings a page tab back with its page, from the close record,
/// and `closed.list` names that page.
#[test]
fn reopened_page_tab_keeps_its_page() {
    let mux = test_mux("page-tabs-reopen");
    let (terminal, pane) = terminal_pane(&mux);
    let created = page_tab(&mux, pane, "settings").unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    let closed = resource(&mux, "closed.list", json!({}), None);
    let group = closed.as_array().unwrap().first().cloned().expect("the close is recorded");
    // Recently Closed names the page, not the page tab's `about:blank` address (cx-h7y9).
    let listed = &group["screens"][0]["tabs"][0];
    assert_eq!(listed["page"], "settings", "{group}");
    assert_eq!(group["members"][0]["screens"][0]["tabs"][0]["page"], "settings", "{group}");
    resource(&mux, "closed.reopen", json!({"closed": group["id"]}), Some("page-re-1"));
    let back = pane_tabs(&mux, pane).into_iter().find(|surface| *surface != terminal).unwrap();
    let tab = raw_tab(&mux, back).unwrap();
    assert_eq!(tab["kind"], "conversation", "{tab}");
    assert_eq!(tab["conversation"], json!({"page":"settings"}));
    mux.shutdown();
}

/// Recently Closed leaves out a tab that reopens as nothing (Leo 2026-10-11: it filled with
/// "about:blank about:blank" rows). `closed.list` marks `empty` an untouched New Tab page (a chat
/// tab with no session yet) and a browser on `about:blank`; a chat, a page, a browser on an
/// address and a terminal are never empty, so a closed chat with no title yet still reopens.
#[test]
fn closed_list_marks_tabs_that_reopen_empty() {
    let mux = test_mux("closed-empty");
    let (_, pane) = terminal_pane(&mux);
    let agent = |session: Value| {
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:a","session":session,"harness":"claude"}})
    };
    let browser = |url: &str| json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"webkit"});
    let tabs = [
        ("new tab page", agent(Value::Null)),
        ("chat", agent(json!("ses-1"))),
        ("blank browser", browser("about:blank")),
        ("browser", browser("https://example.com/")),
        ("page", json!({"cmd":"new-conversation-tab","pane":pane,"page":"settings"})),
        ("terminal", json!({"cmd":"new-tab","pane":pane})),
    ];
    let ids = |closed: &Value| -> Vec<String> {
        closed
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_str().unwrap().to_string())
            .collect()
    };
    let mut marks = Vec::new();
    for (name, request) in tabs {
        let before = ids(&resource(&mux, "closed.list", json!({}), None));
        let created = run(&mux, request).unwrap();
        run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
        let closed = resource(&mux, "closed.list", json!({}), None);
        let item = closed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| !before.contains(&item["id"].as_str().unwrap().to_string()));
        let item = item.unwrap_or_else(|| panic!("{name}: no closed item in {closed}"));
        let top = item["screens"][0]["tabs"][0]["empty"].as_bool().unwrap_or(false);
        let member =
            item["members"][0]["screens"][0]["tabs"][0]["empty"].as_bool().unwrap_or(false);
        marks.push(format!("{name}: {top} {member}"));
    }
    assert_eq!(
        marks,
        [
            "new tab page: true true",
            "chat: false false",
            "blank browser: true true",
            "browser: false false",
            "page: false false",
            "terminal: false false",
        ]
    );
    mux.shutdown();
}

/// History's Recently Closed (`history.entries.list`, closed rows) leaves out
/// a tab that reopens as nothing and never names a row "about:blank" (Leo
/// 2026-10-11: it was full of "about:blank about:blank" rows). A closed chat
/// is kept as a browser tab on `about:blank`, unmarked: it stays.
#[test]
fn history_closed_rows_leave_out_tabs_that_reopen_empty() {
    let mux = test_mux("history-closed-empty");
    let (_, pane) = terminal_pane(&mux);
    let agent = |session: Value| {
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:a","session":session,"harness":"claude"}})
    };
    let browser = |url: &str| json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"webkit"});
    for request in [
        agent(Value::Null),
        agent(json!("ses-1")),
        browser("about:blank"),
        browser("https://example.com/"),
    ] {
        let created = run(&mux, request).unwrap();
        run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    }
    let listed = resource(&mux, "history.entries.list", json!({"kinds":["closed"]}), None);
    let rows: Vec<String> = listed["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            format!(
                "{} · {}",
                entry["title"].as_str().unwrap_or(""),
                entry["detail"].as_str().unwrap_or("-")
            )
        })
        .collect();
    assert_eq!(rows.len(), 2, "{rows:?}");
    assert!(rows.iter().all(|row| !row.contains("about:blank")), "{rows:?}");
    assert!(rows[0].contains("example.com"), "{rows:?}");
    mux.shutdown();
}

/// Recently Closed lists only what is worth reopening (Leo 2026-10-14): no Chromium New Tab
/// page, and one row per page however often it was closed, at its newest close. Removing that
/// row removes every close of the page, so an older one never takes its place.
#[test]
fn history_closed_rows_are_only_things_worth_reopening() {
    let mux = test_mux("history-closed-signal");
    let (_, pane) = terminal_pane(&mux);
    let browser = |url: &str| json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"webkit"});
    for url in [
        "chrome://newtab/",
        "https://example.com/",
        "chrome://newtab",
        "https://example.com/",
        "https://cmux.com/",
    ] {
        let created = run(&mux, browser(url)).unwrap();
        run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    }
    let closed = |mux: &Arc<Mux>| {
        let listed = resource(mux, "history.entries.list", json!({"kinds":["closed"]}), None);
        listed["entries"].as_array().unwrap().clone()
    };
    let shown = |entries: &[Value]| -> Vec<String> {
        entries.iter().map(|entry| entry["detail"].as_str().unwrap_or("-").to_owned()).collect()
    };
    let entries = closed(&mux);
    assert_eq!(shown(&entries), ["https://cmux.com/", "https://example.com/"], "{entries:?}");

    let example = entries[1]["id"].clone();
    resource(&mux, "history.entries.remove", json!({"ids":[example]}), Some("remove-example"));
    let entries = closed(&mux);
    assert_eq!(shown(&entries), ["https://cmux.com/"], "{entries:?}");
    mux.shutdown();
}

/// Reopening a page closed several times takes every close of it out of Recently Closed: the
/// page is open again, so no older close becomes its row and Cmd-Shift-T never opens it twice.
#[test]
fn history_closed_reopening_a_page_leaves_no_older_close_of_it() {
    let mux = test_mux("history-closed-reopen-once");
    let (_, pane) = terminal_pane(&mux);
    let browser = |url: &str| json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"webkit"});
    for url in ["https://example.com/", "https://cmux.com/", "https://example.com/"] {
        let created = run(&mux, browser(url)).unwrap();
        run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    }
    let closed = |mux: &Arc<Mux>| {
        let listed = resource(mux, "history.entries.list", json!({"kinds":["closed"]}), None);
        listed["entries"].as_array().unwrap().clone()
    };
    let shown = |entries: &[Value]| -> Vec<String> {
        entries.iter().map(|entry| entry["detail"].as_str().unwrap_or("-").to_owned()).collect()
    };
    let entries = closed(&mux);
    assert_eq!(shown(&entries), ["https://example.com/", "https://cmux.com/"], "{entries:?}");

    let example = entries[0]["id"].as_str().unwrap().strip_prefix("closed:daemon:").unwrap();
    resource(&mux, "closed.reopen", json!({"closed": example}), Some("reopen-example"));
    let entries = closed(&mux);
    assert_eq!(shown(&entries), ["https://cmux.com/"], "{entries:?}");
    mux.shutdown();
}

/// A page id is 1 to 64 lowercase letters, digits or '-', '_', '.'; a page
/// and another source together are refused.
#[test]
fn page_source_is_validated() {
    let mux = test_mux("page-tabs-validate");
    let (_, pane) = terminal_pane(&mux);
    for page in ["", "App Store", "a/b", &"x".repeat(65)] {
        let error = page_tab(&mux, pane, page).unwrap_err();
        assert!(error.to_string().starts_with("bad request"), "{page}: {error}");
    }
    let both = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,"page":"settings",
               "conversation":"conv_1","owner":"local"}),
    );
    assert!(both.unwrap_err().to_string().starts_with("bad request"));
    assert!(page_tab(&mux, pane, "debug-settings").is_ok());
    mux.shutdown();
}

/// A connection without `page-tabs-v1` reads a page tab as a browser with
/// no record, in v2 and raw form; agent session and conversation sources
/// are untouched by it.
#[test]
fn page_tabs_downgrade_without_the_capability() {
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let page = json!({"page":"app-store"});
    let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
    let message = json!({
        "tabs":[{"content_kind":"conversation","extra":{"conversation":page}},
                {"content_kind":"conversation","extra":{"conversation":agent}}],
        "raw":[{"kind":"conversation","browser_renderer":"frontend","conversation":page}],
    });
    let (writer, outbound) = writer_with_outbound();
    let negotiated = ["conversation-tabs-v1".to_string(), "agent-session-tabs-v1".to_string()];
    writer.negotiate_conversation_tabs(negotiated.iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "browser", "{read}");
    assert!(read["tabs"][0]["extra"].get("conversation").is_none(), "{read}");
    assert_eq!(read["tabs"][1]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["kind"], "browser");
    assert_eq!(read["raw"][0]["conversation"], Value::Null);

    writer.negotiate_conversation_tabs(["page-tabs-v1".to_string()].iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["conversation"], page);
}

/// The daemon advertises `page-tabs-v1`, and `set-client-info` negotiates it.
#[test]
fn page_tabs_capability_is_advertised_and_negotiated() {
    let mux = test_mux("page-tabs-capability");
    assert!(identify_capabilities(&mux).contains(&"page-tabs-v1"), "page-tabs-v1 is advertised");
    let (writer, _) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    let capabilities = vec!["conversation-tabs-v1".to_string(), "page-tabs-v1".into()];
    mux.control_clients.set_info(client, None, None, Some(capabilities)).unwrap();
    assert!(mux.control_clients.supports_capability(client, "page-tabs-v1"));
    mux.shutdown();
}
