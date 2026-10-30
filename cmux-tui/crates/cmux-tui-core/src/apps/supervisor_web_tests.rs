//! Web panes and App Store bundles (plans/cmux-next/custom-panes-DESIGN.md
//! sections 3 and 6.4): a pane's `cmux.call` is decided like a host call,
//! its console reaches the log ring, and an approved bundle lands in the
//! catalog only when its hash and package check out.

use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use super::*;

const BOARD: &str = "local/board";

/// A local app with a web pane (`cmux.pane/1` from `web/index.html`).
fn write_web_app(root: &Path, dir: &str, id: &str, version: &str, scopes: Value) -> Value {
    let app = root.join(dir);
    std::fs::create_dir_all(app.join("web")).unwrap();
    std::fs::write(app.join("web/index.html"), "<!doctype html><script src=app.js></script>")
        .unwrap();
    std::fs::write(app.join("web/app.js"), "cmux.call('workspace.list', {})").unwrap();
    let mut manifest = json!({
        "manifestVersion": 2, "id": id, "name": "Board", "version": version, "description": "d",
        "engines": { "cmux": "^2.0" }, "runtime": { "web": { "root": "web/" } },
        "implements": { "cmux.pane/1": { "web": "web/index.html", "title": "Board" } },
        "scopes": scopes, "files": ["web/"]
    });
    if !id.starts_with("local/") {
        manifest["repository"] = json!("https://github.com/octo/board");
    }
    std::fs::write(app.join("cmux-app.json"), manifest.to_string()).unwrap();
    manifest
}

/// A fixture with `local/board` (and the shared demo apps) in the catalog.
fn web_fixture(scopes: Value) -> Fixture {
    let root = temp_dir();
    write_web_app(&root.0.join("state/apps/local"), "board", BOARD, "0.1.0", scopes);
    fixture_with(&[], Duration::from_secs(60), root)
}

/// `apps-web-call` through the supervisor, waiting for its answer.
fn web_call(f: &Fixture, app: &str, op: &str, params: Value) -> Result<Value, ApiErrorView> {
    let (tx, rx) = channel();
    f.supervisor.web_call(
        app,
        op,
        params,
        None,
        Box::new(move |result| {
            let _ = tx.send(result.map_err(|e| ApiErrorView { code: e.code }));
        }),
    );
    rx.recv_timeout(Duration::from_secs(10)).expect("web call answered")
}

#[derive(Debug)]
struct ApiErrorView {
    code: String,
}

fn code(result: Result<Value, ApiErrorView>) -> String {
    result.expect_err("the call is refused").code
}

#[test]
fn a_web_pane_call_is_decided_like_a_host_call() {
    let f = web_fixture(json!({
        "workspace:read": "r", "workspace:write": "w", "storage:local": "s", "net:api.example.com": "n"
    }));
    // Not installed yet: nothing runs.
    assert_eq!(code(web_call(&f, BOARD, "workspace.list", json!({}))), "scope.missing");
    f.install(BOARD);
    // A local app starts sandboxed with only its read scopes.
    let listed = web_call(&f, BOARD, "workspace.list", json!({})).unwrap();
    assert_eq!(listed["value"]["routed"], "workspace.list");
    {
        let calls = f.router.calls.lock().unwrap();
        let (app, op, _, key, origin) = calls.last().unwrap();
        assert_eq!(
            (app.as_str(), op.as_str(), key, *origin),
            (BOARD, "workspace.list", &None, Origin::Script)
        );
    }
    assert_eq!(code(web_call(&f, BOARD, "made.up", json!({}))), "operation.unsupported");
    assert_eq!(code(web_call(&f, BOARD, "agent.list", json!({}))), "scope.missing");
    // Not granted until the person allows it, and never a network call while sandboxed.
    assert_eq!(
        code(web_call(&f, BOARD, "workspace.rename", json!({ "name": "x" }))),
        "scope.missing"
    );
    assert_eq!(
        code(web_call(&f, BOARD, "net.fetch", json!({ "url": "https://api.example.com/" }))),
        "scope.missing"
    );
    assert!(f.fetcher.requests.lock().unwrap().is_empty());
    assert_eq!(
        code(web_call(&f, BOARD, "app.storage.set", json!({ "key": "k", "value": 5 }))),
        "scope.missing"
    );
    f.set("grant-s", BOARD, Origin::User, |o| o.grant = Some(("storage:local".into(), true)))
        .unwrap();
    web_call(&f, BOARD, "app.storage.set", json!({ "key": "k", "value": 5 })).unwrap();
    assert_eq!(web_call(&f, BOARD, "app.storage.get", json!({ "key": "k" })).unwrap()["value"], 5);

    // With the write scope: a mutation runs under a web pane key, without focus.
    f.set("grant-w", BOARD, Origin::User, |o| o.grant = Some(("workspace:write".into(), true)))
        .unwrap();
    web_call(&f, BOARD, "workspace.rename", json!({ "name": "x", "focus": true })).unwrap();
    {
        let calls = f.router.calls.lock().unwrap();
        let (_, op, params, key, origin) = calls.last().unwrap();
        assert_eq!(op, "workspace.rename");
        assert!(params.get("focus").is_none(), "{params}");
        assert!(key.as_deref().is_some_and(|k| k.starts_with("app:local/board:web:")), "{key:?}");
        assert_eq!(*origin, Origin::Script);
    }
    // A page cannot prove a gesture: view-state ops never run from a pane.
    assert_eq!(code(web_call(&f, BOARD, "workspace.focus", json!({}))), "gesture.required");
}

#[test]
fn a_web_pane_has_at_most_64_calls_in_flight() {
    let f = web_fixture(json!({ "workspace:read": "r" }));
    f.install(BOARD);
    let (tx, rx) = channel();
    let send = |tx: &Sender<Result<Value, String>>| {
        let tx = tx.clone();
        f.supervisor.web_call(
            BOARD,
            "workspace.list",
            json!({}),
            None,
            Box::new(move |result| {
                let _ = tx.send(result.map_err(|e| e.code));
            }),
        );
    };
    {
        // Every routed call waits on this lock, so 64 stay in flight.
        let _held = f.router.calls.lock().unwrap();
        for _ in 0..64 {
            send(&tx);
        }
        send(&tx);
        let refused = rx.recv_timeout(Duration::from_secs(10)).expect("the 65th call is answered");
        assert_eq!(refused, Err("app.limit".to_string()));
    }
    for _ in 0..64 {
        rx.recv_timeout(Duration::from_secs(10)).expect("answered").expect("routed");
    }
    // Answered calls give their slots back.
    web_call(&f, BOARD, "workspace.list", json!({})).unwrap();
}

#[test]
fn only_an_installed_enabled_app_with_a_web_pane_is_answered() {
    let f = web_fixture(json!({ "workspace:read": "r" }));
    f.install("cmux/demo");
    // An app without a web pane has no pane to speak for it.
    assert_eq!(code(web_call(&f, "cmux/demo", "workspace.list", json!({}))), "apps.web.none");
    assert_eq!(code(web_call(&f, "octo/missing", "workspace.list", json!({}))), "apps.unknown");
    f.install(BOARD);
    web_call(&f, BOARD, "workspace.list", json!({})).unwrap();
    f.set("off", BOARD, Origin::User, |o| o.enabled = Some(false)).unwrap();
    assert_eq!(code(web_call(&f, BOARD, "workspace.list", json!({}))), "scope.missing");
}

#[test]
fn a_web_pane_console_line_reaches_the_app_log() {
    let f = web_fixture(json!({ "workspace:read": "r" }));
    f.supervisor.web_log(BOARD, "error", "TypeError: x is undefined at app.js:3").unwrap();
    f.supervisor.web_log(BOARD, "shout", &"y".repeat(5_000)).unwrap();
    let logs = f.supervisor.logs(CLIENT, BOARD, false);
    let lines = logs["lines"].as_array().unwrap();
    assert!(
        lines.iter().any(|l| l["level"] == "error"
            && l["message"] == "pane: TypeError: x is undefined at app.js:3"),
        "{logs}"
    );
    let long =
        lines.iter().find(|l| l["message"].as_str().is_some_and(|m| m.contains("yyy"))).unwrap();
    assert_eq!(long["level"], "info");
    assert_eq!(long["message"].as_str().unwrap().chars().count(), "pane: ".len() + 2_000 + 1);
    assert_eq!(f.supervisor.web_log("cmux/demo", "error", "x").unwrap_err().code, "apps.web.none");
}

#[test]
fn apps_list_names_the_local_apps_folder() {
    let f = web_fixture(json!({ "workspace:read": "r" }));
    let dir = f.supervisor.list()["local_dir"].as_str().unwrap().to_string();
    assert_eq!(Path::new(&dir), f.state.join("apps/local"));
}

/// The files of a registry bundle for `octo/board` at `version`, base64.
fn bundle(version: &str) -> BTreeMap<String, String> {
    let root = temp_dir();
    let manifest =
        write_web_app(&root.0, "pkg", "octo/board", version, json!({ "workspace:read": "r" }));
    let read = |p: &str| std::fs::read(root.0.join("pkg").join(p)).unwrap();
    BTreeMap::from([
        ("cmux-app.json".to_string(), manifest.to_string().into_bytes()),
        ("web/index.html".to_string(), read("web/index.html")),
        ("web/app.js".to_string(), read("web/app.js")),
    ])
    .into_iter()
    .map(|(path, bytes)| (path, STANDARD.encode(bytes)))
    .collect()
}

fn hash(files: &BTreeMap<String, String>) -> String {
    let decoded = files.iter().map(|(p, b)| (p.clone(), STANDARD.decode(b).unwrap())).collect();
    super::super::registry::bundle_sha256(&decoded)
}

fn put(
    f: &Fixture,
    app: &str,
    version: &str,
    sha256: &str,
    files: &BTreeMap<String, String>,
) -> Result<Value, String> {
    let args = json!({ "app": app, "version": version, "sha256": sha256, "files": files });
    f.supervisor
        .store_call(CLIENT, "cmux.apps.registry.put", args, Origin::User)
        .map_err(|e| e.code)
}

#[test]
fn registry_ids_follow_the_manifest_schema() {
    use super::super::registry::registry_app;
    for id in ["octo/board", "0x/2048", &format!("{}/{}", "a".repeat(39), "b".repeat(64))] {
        assert!(registry_app(id), "{id}");
    }
    for id in [
        "local/board",
        "cmux/board",
        "-x/board",
        "Octo/board",
        "octo",
        &format!("{}/b", "a".repeat(40)),
    ] {
        assert!(!registry_app(id), "{id}");
    }
}

#[test]
fn a_put_shadowed_by_another_copy_writes_nothing() {
    let root = temp_dir();
    // A bundled copy with the same id wins the catalog (first source wins).
    write_web_app(
        &root.0.join("bundled"),
        "board",
        "octo/board",
        "0.9.0",
        json!({ "workspace:read": "r" }),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    let files = bundle("1.0.0");
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&files), &files).unwrap_err(),
        "apps.registry.shadowed"
    );
    assert!(!f.state.join("apps/registry/octo.board").exists());
    let staging = f.state.join("apps/registry-staging");
    assert!(std::fs::read_dir(&staging).map_or(true, |mut d| d.next().is_none()), "nothing staged");
}

#[test]
fn the_bundle_hash_is_the_registry_contract() {
    // The same vector the Cloud registry's tests assert (section 6.2).
    let files = BTreeMap::from([
        ("b/c.js".to_string(), b"x".to_vec()),
        ("a.txt".to_string(), b"hi".to_vec()),
    ]);
    assert_eq!(
        super::super::registry::bundle_sha256(&files),
        "ec32dc4eccc50390124a5707ff1cc349ed1e9f60f29b1844d52de3157ea674a4"
    );
}

#[test]
fn an_app_store_bundle_lands_only_when_its_hash_and_package_check_out() {
    let f = fixture();
    let files = bundle("1.0.0");
    let sha = hash(&files);
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &"0".repeat(64), &files).unwrap_err(),
        "apps.registry.hash"
    );
    assert_eq!(put(&f, "cmux/board", "1.0.0", &sha, &files).unwrap_err(), "apps.registry.app");
    assert_eq!(put(&f, "local/board", "1.0.0", &sha, &files).unwrap_err(), "apps.registry.app");
    let mut escaping = files.clone();
    escaping.insert("../evil.js".into(), STANDARD.encode("x"));
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&escaping), &escaping).unwrap_err(),
        "apps.registry.path"
    );
    // The listing says one version, the bundle's manifest another.
    assert_eq!(put(&f, "octo/board", "2.0.0", &sha, &files).unwrap_err(), "apps.registry.mismatch");
    let mut broken = files.clone();
    broken.insert("cmux-app.json".into(), STANDARD.encode("{}"));
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&broken), &broken).unwrap_err(),
        "apps.registry.invalid"
    );
    // With both manifest names, the registry and the catalog would read different ones.
    let mut both = files.clone();
    both.insert("cmux-app.v2.json".into(), files["cmux-app.json"].clone());
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&both), &both).unwrap_err(),
        "apps.registry.manifest"
    );
    // In another case, a case-insensitive disk would open it as cmux-app.json.
    let mut cased = files.clone();
    cased.insert("Cmux-App.v2.json".into(), files["cmux-app.json"].clone());
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&cased), &cased).unwrap_err(),
        "apps.registry.manifest"
    );
    let mut renamed = files.clone();
    let manifest = renamed.remove("cmux-app.json").unwrap();
    renamed.insert("CMUX-APP.json".into(), manifest);
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&renamed), &renamed).unwrap_err(),
        "apps.registry.manifest"
    );
    let mut folded = files.clone();
    folded.insert("web/App.js".into(), STANDARD.encode("x"));
    assert_eq!(
        put(&f, "octo/board", "1.0.0", &hash(&folded), &folded).unwrap_err(),
        "apps.registry.path"
    );
    assert!(app_entry(&f.supervisor.list(), "octo/board").is_null(), "nothing landed yet");
    assert!(!f.state.join("apps/registry/octo.board").exists());

    let landed = put(&f, "octo/board", "1.0.0", &sha.to_uppercase(), &files).unwrap();
    assert_eq!(landed, json!({ "app": "octo/board", "version": "1.0.0", "sha256": sha }));
    f.wait("catalog changed", |e| {
        e["event"] == "apps-changed"
            && e["app"] == "octo/board"
            && e["transaction"] == "registry-put"
    });
    let entry = app_entry(&f.supervisor.list(), "octo/board");
    assert_eq!(
        (entry["source"].clone(), entry["tier"].clone()),
        (json!("registry"), json!("unverified"))
    );
    assert_eq!(entry["installed"], false, "getting a bundle installs nothing");
    assert!(f.state.join("apps/registry/octo.board/web/app.js").is_file());
    // Installing it is the person's, and it starts sandboxed like every third-party app.
    f.install("octo/board");
    let entry = app_entry(&f.supervisor.list(), "octo/board");
    assert_eq!(
        (entry["installed"].clone(), entry["sandboxed"].clone()),
        (json!(true), json!(true))
    );

    // A newer approved version replaces the folder in one rename.
    let next = bundle("1.1.0");
    put(&f, "octo/board", "1.1.0", &hash(&next), &next).unwrap();
    assert_eq!(app_entry(&f.supervisor.list(), "octo/board")["version"], "1.1.0");
    let staging = f.state.join("apps/registry-staging");
    assert!(
        std::fs::read_dir(&staging).map_or(true, |mut d| d.next().is_none()),
        "no staging left"
    );
}
