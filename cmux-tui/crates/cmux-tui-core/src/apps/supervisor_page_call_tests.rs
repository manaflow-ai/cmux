//! Supervisor tests of web pane calls (`page_calls.rs`, `apps-page-call`):
//! a page reaches cmux only through its app's grant.

use super::*;
use crate::apps::catalog::Package;
use crate::apps::mirror::{self, Op};

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
        "scopes": {
            "workspace:read": "List your workspaces.", "agent_chat:read": "List your agent chats.",
            "workspace:write": "Rename your workspaces.", "net:api.example.com": "Reach the API.",
            "integration:github": "Change your GitHub."
        },
        "files": ["web/"]
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
/// is told at once (`provider.unavailable`, retryable), past the grant check.
#[test]
fn a_provider_op_without_a_provider_is_answered_at_once() {
    let f = web_fixture();
    install_with_read(&f);
    f.set("grant-chat", WEB_APP, Origin::User, |o| {
        o.grant = Some(("agent_chat:read".into(), true));
    })
    .unwrap();
    let answer = page_call(&f, "p1", json!({ "id": "c5", "op": "agent_chat.list" })).unwrap();
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error"]["code"], "provider.unavailable", "{answer}");
    assert_eq!(answer["error"]["retryable"], true, "{answer}");
    assert_eq!(answer["error"]["details"]["family"], "agent_chat", "{answer}");
    assert!(f.router.calls.lock().unwrap().is_empty(), "a provider op never reached the router");
}

/// How a test takes back an app's access: its name and the change.
type Revocation = (&'static str, fn(&mut SetOp));

const REVOCATIONS: [Revocation; 3] = [
    ("uninstall", |o| o.installed = Some(false)),
    ("disable", |o| o.enabled = Some(false)),
    // Narrower: the fetch's host is no longer granted.
    ("regrant", |o| o.grant = Some(("net:api.example.com".into(), false))),
];

/// Installed, unsandboxed, with a fetch host, a write and an integration write.
fn install_with_net_and_writes(f: &Fixture) {
    f.install(WEB_APP);
    f.set("unsandbox", WEB_APP, Origin::User, |o| o.sandboxed = Some(false)).unwrap();
    for scope in ["net:api.example.com", "workspace:write", "integration:github"] {
        f.set(&format!("grant-{scope}"), WEB_APP, Origin::User, |o| {
            o.grant = Some((scope.into(), true));
        })
        .unwrap();
    }
}

type Answer = Result<Value, super::super::supervisor::ApiError>;

fn responder() -> (super::super::supervisor::Responder, Receiver<Answer>) {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    (
        Box::new(move |result| {
            let _ = tx.lock().unwrap().send(result);
        }),
        rx,
    )
}

/// F1 (review at 4c4d2d8d): a call admitted before its app's access is
/// taken back never runs after it. Under one hold of the supervisor lock a
/// page's `net.fetch` and `workspace.rename` are admitted (their workers
/// wait for the lock) and the app is uninstalled, turned off, or regranted
/// narrower; then the lock goes. No request is made, nothing is routed,
/// and both callers are told `app.revoked` (base red: the worker checked
/// only `page_grant_locked(..).revoked`, which an uninstall leaves false,
/// and a fetch or a routed op never checked at all).
#[test]
fn a_page_call_admitted_before_its_access_is_taken_back_never_runs() {
    for (how, revoke) in REVOCATIONS {
        let f = web_fixture();
        install_with_net_and_writes(&f);
        let (fetch_respond, fetch_rx) = responder();
        let (write_respond, write_rx) = responder();
        let fetch = json!({ "id": "f1", "op": "net.fetch", "params": { "url": "https://api.example.com/x" } });
        let write = json!({ "id": "w1", "op": "workspace.rename", "params": { "workspace": "w1", "name": "x" } });
        let outs = {
            let mut inner = f.supervisor.inner.lock().unwrap();
            let mut outs = Vec::new();
            for (message, respond) in [(fetch, fetch_respond), (write, write_respond)] {
                outs.extend(f.supervisor.page_call_locked(
                    &mut inner,
                    CLIENT,
                    WEB_APP,
                    "p1",
                    &message.to_string(),
                    respond,
                ));
            }
            let mut op = SetOp {
                key: format!("revoke-{how}"),
                app: WEB_APP.into(),
                origin: Origin::User,
                ..SetOp::default()
            };
            revoke(&mut op);
            // The revoke commits while the calls are in flight, under the
            // same lock (the disk write is skipped: nothing here reads it).
            let facts = inner.catalog.packages.get(WEB_APP).map(Package::facts);
            let outcome = mirror::reduce(&inner.mirror, &Op::Set(op), facts.as_ref()).unwrap();
            f.supervisor.apply_commit_locked(&mut inner, outcome, WEB_APP, "t-revoke", &mut outs);
            outs
        };
        f.supervisor.emit(outs);
        for (rx, id) in [(fetch_rx, "f1"), (write_rx, "w1")] {
            let answer = rx.recv_timeout(Duration::from_secs(10)).expect("answered").unwrap();
            assert_eq!(answer["id"], id, "{how}: {answer}");
            assert_eq!(answer["ok"], false, "{how}: {answer}");
            assert_eq!(answer["error"]["code"], "app.revoked", "{how}: {answer}");
        }
        assert!(f.fetcher.requests.lock().unwrap().is_empty(), "{how}: no request was made");
        assert!(f.router.calls.lock().unwrap().is_empty(), "{how}: nothing was routed");
    }
}

/// A page's call queued at the provider (the Mac app) ends when its app's
/// access is taken back: the page is told `app.revoked` at once, the
/// provider is told to drop the work (`apps-provider-cancel`), and its late
/// answer is refused (base red: only host calls were cancelled, so the page
/// waited on the provider).
#[test]
fn a_page_call_queued_at_the_provider_is_cancelled_when_access_is_taken_back() {
    const PROVIDER: u64 = 9;
    for (how, revoke) in REVOCATIONS {
        let f = web_fixture();
        install_with_net_and_writes(&f);
        let (tx, provider_rx) = channel();
        let tx = Mutex::new(tx);
        f.supervisor.register_client(
            PROVIDER,
            Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
        );
        let claim = super::super::provider::ProviderClaim { agent: false, verified_app: true };
        f.supervisor.register_provider(PROVIDER, claim, vec!["integration".into()]).unwrap();
        let (respond, rx) = responder();
        let call = json!({ "id": "i1", "op": "integration.request", "params": { "provider": "github", "method": "POST", "path": "/x" } });
        f.supervisor.page_call(CLIENT, WEB_APP, "p1", &call.to_string(), respond);
        let next = |name: &str| loop {
            let event = provider_rx.recv_timeout(Duration::from_secs(10)).expect(name);
            if event["event"] == name {
                return event;
            }
        };
        let request_id = next("apps-provider-request")["request_id"].as_u64().unwrap();
        f.set(&format!("revoke-{how}"), WEB_APP, Origin::User, revoke).unwrap();
        let cancel = next("apps-provider-cancel");
        assert_eq!(cancel["request_id"], request_id, "{how}: {cancel}");
        let answer = rx.recv_timeout(Duration::from_secs(10)).expect("answered").unwrap();
        assert_eq!(answer["id"], "i1", "{how}: {answer}");
        assert_eq!(answer["error"]["code"], "app.revoked", "{how}: {answer}");
        let late = f.supervisor.provider_result(PROVIDER, request_id, true, json!({ "value": 1 }));
        assert_eq!(late.unwrap_err().code, "apps.provider.unknown", "{how}");
    }
}
