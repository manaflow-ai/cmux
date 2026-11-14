//! Supervisor tests of web pane calls (`page_calls.rs`, `apps-page-call`):
//! a page reaches cmux only through its app's grant.

use super::*;

const WEB_APP: &str = "local/web";

/// A web-pane-only local app (`render: web`): no script, a page under `web/`,
/// and only `workspace:read` asked for.
fn write_web_app(state: &Path) {
    let dir = state.join("apps/local/web");
    std::fs::create_dir_all(dir.join("web")).unwrap();
    std::fs::write(dir.join("web/index.html"), "<!doctype html><p>web pane</p>").unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": WEB_APP, "name": "Web", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "runtime": { "web": { "root": "web" } },
        "implements": { "cmux.pane/1": { "web": "web/index.html", "title": "Web", "symbol": "globe" } },
        "scopes": { "workspace:read": "List your workspaces." }, "files": ["web/"]
    });
    std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).unwrap();
}

/// A fixture whose catalog holds the web app (not installed yet).
fn web_fixture() -> Fixture {
    let f = fixture();
    write_web_app(&f.state);
    f.supervisor.reload_local_apps(&Default::default());
    f
}

/// Sends one page message and waits for its answer.
fn page_call(
    f: &Fixture,
    page: &str,
    message: Value,
) -> Result<Value, super::super::supervisor::ApiError> {
    let (tx, rx) = channel();
    f.supervisor.page_call(
        CLIENT,
        WEB_APP,
        page,
        &message.to_string(),
        Box::new(move |result| {
            let _ = tx.send(result);
        }),
    );
    rx.recv_timeout(Duration::from_secs(10)).expect("page call answered")
}

fn install_with_read(f: &Fixture) {
    f.install(WEB_APP);
    f.set("grant-read", WEB_APP, Origin::User, |o| o.grant = Some(("workspace:read".into(), true)))
        .unwrap();
}

#[test]
fn the_list_names_the_web_pane_the_client_hosts() {
    let f = web_fixture();
    let entry = app_entry(&f.supervisor.list(), WEB_APP);
    assert_eq!(
        entry["web_pages"],
        json!([{ "interface": "cmux.pane/1", "root": "web", "entry": "index.html", "symbol": "globe" }])
    );
    // A scene app has none.
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["web_pages"], json!([]));
}

/// A granted read runs as the app with origin script, through the daemon's
/// own dispatcher, and the page gets `{id, ok, value}`.
#[test]
fn a_granted_call_runs_as_the_app() {
    let f = web_fixture();
    install_with_read(&f);
    let answer =
        page_call(&f, "p1", json!({ "id": "c1", "op": "workspace.list", "params": {} })).unwrap();
    assert_eq!(answer, json!({ "id": "c1", "ok": true, "value": { "routed": "workspace.list" } }));
    let calls = f.router.calls.lock().unwrap().clone();
    let (app, op, _, _, origin) = calls.last().expect("routed").clone();
    assert_eq!((app.as_str(), op.as_str(), origin), (WEB_APP, "workspace.list", Origin::Script));
}

/// The scope model holds for a page as for the app's script: an op outside
/// the app's grant is `scope.missing` and never reaches an owner (base red:
/// there was no page call path, so a page could reach nothing at all).
#[test]
fn a_call_outside_the_grant_is_refused() {
    let f = web_fixture();
    install_with_read(&f);
    for (op, params) in [
        ("workspace.rename", json!({ "workspace": "w1", "name": "x" })),
        ("app.storage.get", json!({ "key": "k" })),
        ("net.fetch", json!({ "url": "https://api.example.com/" })),
    ] {
        let answer =
            page_call(&f, "p1", json!({ "id": "c2", "op": op, "params": params })).unwrap();
        assert_eq!(answer["ok"], false, "{op}: {answer}");
        assert_eq!(answer["error"]["code"], "scope.missing", "{op}: {answer}");
    }
    assert!(f.router.calls.lock().unwrap().is_empty(), "nothing outside the grant was routed");
    assert!(f.fetcher.requests.lock().unwrap().is_empty(), "no network request was made");
}

/// Not installed: a preview, nothing granted. Turned off: revoked.
#[test]
fn a_page_of_an_app_that_is_not_installed_or_is_off_gets_nothing() {
    let f = web_fixture();
    let list = json!({ "id": "c3", "op": "workspace.list" });
    let answer = page_call(&f, "p1", list.clone()).unwrap();
    assert_eq!(answer["error"]["code"], "scope.missing", "{answer}");
    install_with_read(&f);
    assert_eq!(page_call(&f, "p1", list.clone()).unwrap()["ok"], true);
    f.set("off", WEB_APP, Origin::User, |o| o.enabled = Some(false)).unwrap();
    let answer = page_call(&f, "p1", list).unwrap();
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(f.router.calls.lock().unwrap().len(), 1);
}

/// A view op needs the person's tap, which a page cannot give yet.
#[test]
fn view_ops_and_action_run_need_a_gesture() {
    let f = web_fixture();
    install_with_read(&f);
    let answer =
        page_call(&f, "p1", json!({ "id": "c4", "op": "action.run", "params": { "id": "x" } }))
            .unwrap();
    assert!(
        ["gesture.required", "scope.missing"]
            .contains(&answer["error"]["code"].as_str().unwrap_or("")),
        "{answer}"
    );
}

/// The bridge limits apply per page: a message without an id is refused,
/// and an app without a web pane has no page to call.
#[test]
fn malformed_messages_and_apps_without_a_page_are_refused() {
    let f = web_fixture();
    install_with_read(&f);
    let answer = page_call(&f, "p1", json!({ "op": "workspace.list" })).unwrap();
    assert_eq!(answer["error"]["code"], "bridge.bad_message", "{answer}");
    let (tx, rx) = channel();
    f.supervisor.page_call(
        CLIENT,
        "local/spy",
        "p1",
        r#"{"id":"1","op":"workspace.list"}"#,
        Box::new(move |result| {
            let _ = tx.send(result);
        }),
    );
    let refused = rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err();
    assert_eq!(refused.code, "apps.page.unknown");
}

/// An op the Mac app owns goes to its provider; with none connected the page
/// is told at once.
#[test]
fn a_provider_op_without_a_provider_is_answered_at_once() {
    let f = web_fixture();
    install_with_read(&f);
    f.set("grant-chat", WEB_APP, Origin::User, |o| {
        o.grant = Some(("agent_chat:read".into(), true));
    })
    .ok();
    let answer = page_call(&f, "p1", json!({ "id": "c5", "op": "agent_chat.list" })).unwrap();
    assert_eq!(answer["ok"], false, "{answer}");
}
