//! `new-frontend-browser-tab {idempotency_key}`: a retry after a lost reply
//! creates exactly one tab, like every other typed creation (ownership rule:
//! every change is an op with a client-chosen idempotency key).

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// Frontend-rendered browser tabs in the raw tree.
fn frontend_tabs(mux: &Arc<Mux>) -> Vec<Value> {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .filter(|tab| tab["browser_renderer"] == "frontend")
        .cloned()
        .collect()
}

fn create(pane: PaneId, url: &str, key: &str) -> Value {
    json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"cef",
           "owner":"install-a","idempotency_key":key})
}

#[test]
fn keyed_frontend_browser_tab_retry_after_a_lost_reply_creates_one_tab() {
    let mux = Mux::new_for_test("frontend-browser-keys", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();

    // The client sends the create and loses the reply (timeout or
    // disconnect), then resends the same request with the same key.
    let first = run(&mux, create(pane, "https://cmux.com", "gpui-create-1")).unwrap();
    let retry = run(&mux, create(pane, "https://cmux.com", "gpui-create-1")).unwrap();
    assert_eq!(retry["tab_resource_id"], first["tab_resource_id"], "{first} {retry}");
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["content_resource_id"], first["content_resource_id"]);
    assert_eq!(first["replayed"], false);
    assert_eq!(retry["replayed"], true);
    assert_eq!(frontend_tabs(&mux).len(), 1, "a keyed retry must not create a second tab");

    // The size is only a hint: a retry with another size still replays.
    let mut resized = create(pane, "https://cmux.com", "gpui-create-1");
    resized["cols"] = json!(100);
    resized["rows"] = json!(30);
    assert_eq!(run(&mux, resized).unwrap()["tab_resource_id"], first["tab_resource_id"]);

    // The same key with another request is a conflict and creates nothing.
    let conflict = run(&mux, create(pane, "https://example.com", "gpui-create-1")).unwrap_err();
    assert!(conflict.to_string().contains("idempotency"), "{conflict}");
    assert_eq!(frontend_tabs(&mux).len(), 1);

    // A new key is a new tab.
    let second = run(&mux, create(pane, "https://cmux.com", "gpui-create-2")).unwrap();
    assert_ne!(second["tab_resource_id"], first["tab_resource_id"]);
    assert_eq!(second["replayed"], false);
    assert_eq!(frontend_tabs(&mux).len(), 2);
    mux.shutdown();
}

/// Without a key the command keeps its old behavior: every request is a tab.
#[test]
fn unkeyed_frontend_browser_tab_creates_a_tab_per_request() {
    let mux = Mux::new_for_test("frontend-browser-unkeyed", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let request = json!({"cmd":"new-frontend-browser-tab","pane":pane,
                         "url":"https://cmux.com","engine":"webkit"});
    let first = run(&mux, request.clone()).unwrap();
    let second = run(&mux, request).unwrap();
    assert_ne!(first["tab_resource_id"], second["tab_resource_id"]);
    assert_eq!(frontend_tabs(&mux).len(), 2);
    mux.shutdown();
}

/// The daemon says it dedupes, so a client can tell before it relies on it.
#[test]
fn frontend_browser_tab_keys_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"frontend-browser-tab-keys-v1"));
}

fn pane_of_new_workspace(mux: &Arc<Mux>) -> PaneId {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    mux.with_state(|state| state.pane_of(terminal)).unwrap()
}

/// A crash between the record commit and the tab commit leaves the key and
/// record rows without a tab: the retry creates the tab under that browser.
#[test]
fn keyed_retry_after_a_crash_before_the_tab_commit_creates_the_recorded_tab() {
    let mux = Mux::new_for_test("frontend-browser-keys-resume", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let pane_id = mux.with_state(|state| state.resource_indexes.pane_ids[&pane].clone());
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "cef".into(),
        url: "https://cmux.com".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: Some("install-a".into()),
    };
    let browser = BrowserPublicId::random().unwrap();
    let fingerprint = json!({"pane": pane_id, "record": &record});
    {
        let key_row = |tx: &rusqlite::Transaction<'_>| {
            crate::state::frontend_browser_keys::insert_key(
                tx,
                "gpui-crash-1",
                browser.as_str(),
                &fingerprint,
            )
        };
        let mut registry = mux.workspace_registry.lock().unwrap();
        registry.put_frontend_browser(browser.as_str(), &record, Some(&key_row)).unwrap();
        mux.reload_presentation(&registry).unwrap();
    }
    assert!(frontend_tabs(&mux).is_empty());
    let resumed = run(&mux, create(pane, "https://cmux.com", "gpui-crash-1")).unwrap();
    assert_eq!(resumed["content_resource_id"], browser.as_str(), "{resumed}");
    assert_eq!(resumed["replayed"], false);
    let replay = run(&mux, create(pane, "https://cmux.com", "gpui-crash-1")).unwrap();
    assert_eq!(
        (replay["surface"].clone(), replay["replayed"].clone()),
        (resumed["surface"].clone(), json!(true))
    );
    assert_eq!(frontend_tabs(&mux).len(), 1);
    mux.shutdown();
}

/// A retry after the tab was closed creates nothing and says why.
#[test]
fn keyed_retry_after_the_tab_closed_is_refused_and_creates_nothing() {
    let mux = Mux::new_for_test("frontend-browser-keys-closed", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let first = run(&mux, create(pane, "https://cmux.com", "gpui-closed-1")).unwrap();
    run(&mux, json!({"cmd":"close-tabs","surfaces":[first["surface"]]})).unwrap();
    assert!(frontend_tabs(&mux).is_empty());
    let error = run(&mux, create(pane, "https://cmux.com", "gpui-closed-1")).unwrap_err();
    assert!(error.to_string().contains("closed"), "{error}");
    assert!(frontend_tabs(&mux).is_empty());
    mux.shutdown();
}

/// A retry that arrives while the first request still runs waits for it and
/// gets its tab: both answers name one tab.
#[test]
fn concurrent_requests_with_one_key_create_one_tab() {
    let mux = Mux::new_for_test("frontend-browser-keys-race", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let requests = (0..2)
        .map(|_| {
            let (mux, barrier) = (mux.clone(), barrier.clone());
            std::thread::spawn(move || {
                barrier.wait();
                run(&mux, create(pane, "https://cmux.com", "gpui-race-1")).unwrap()
            })
        })
        .collect::<Vec<_>>();
    let answers = requests.into_iter().map(|r| r.join().unwrap()).collect::<Vec<_>>();
    assert_eq!(answers[0]["tab_resource_id"], answers[1]["tab_resource_id"], "{answers:?}");
    let mut replayed = answers.iter().map(|a| a["replayed"].as_bool().unwrap()).collect::<Vec<_>>();
    replayed.sort_unstable();
    assert_eq!(replayed, vec![false, true]);
    assert_eq!(frontend_tabs(&mux).len(), 1);
    mux.shutdown();
}
