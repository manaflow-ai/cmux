//! Supervisor tests of the App Store ops (`cmux.apps.*`, store.rs).

use super::*;

/// Runs one store op as `origin` and waits for its answer.
fn store(
    f: &Fixture,
    op: &str,
    params: Value,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    let (tx, rx) = channel();
    f.supervisor.store_call(CLIENT, op, params, origin, Box::new(move |r| tx.send(r).unwrap()));
    rx.recv_timeout(Duration::from_secs(10)).unwrap()
}

fn ids(listings: &Value) -> Vec<String> {
    listings.as_array().unwrap().iter().map(|l| l["app"].as_str().unwrap().to_string()).collect()
}

/// The fixture plus a first-party `cmux/app-store` package.
fn store_fixture() -> Fixture {
    let root = temp_dir();
    write_app(
        &root.0.join("bundled"),
        "app-store",
        "cmux/app-store",
        json!({ "workspace:read": "r" }),
    );
    fixture_with(&[], Duration::from_secs(60), root)
}

#[test]
fn the_catalog_lists_packages_but_never_the_app_store() {
    let f = store_fixture();
    f.install("cmux/demo");
    let page = store(&f, "cmux.apps.catalog.list", json!({}), Origin::Cli).unwrap();
    assert_eq!(ids(&page["listings"]), ["cmux/demo", "local/spy"]);
    assert_eq!(page["next_cursor"], Value::Null);
    assert!(page["revision"].as_u64().is_some());
    let demo = &page["listings"][0];
    assert_eq!(
        (
            demo["publisher"].clone(),
            demo["tier"].clone(),
            demo["version"].clone(),
            demo["hide_only"].clone()
        ),
        (json!("cmux"), json!("first-party"), json!("1.0.0"), json!(true))
    );
    assert_eq!((demo["name"].clone(), demo["summary"].clone()), (json!("Demo"), json!("d")));
    assert_eq!(demo["categories"], json!([]));
    assert_eq!(demo["install"]["installed"], json!(true));
    let spy = &page["listings"][1];
    assert_eq!((spy["hide_only"].clone(), spy["install"].clone()), (json!(false), Value::Null));
    // Filters, paging and refused fields.
    let unverified =
        store(&f, "cmux.apps.catalog.list", json!({ "tier": "unverified" }), Origin::Cli).unwrap();
    assert_eq!(ids(&unverified["listings"]), ["local/spy"]);
    let query =
        store(&f, "cmux.apps.catalog.list", json!({ "query": "SPY" }), Origin::Cli).unwrap();
    assert_eq!(ids(&query["listings"]), ["local/spy"]);
    let first = store(&f, "cmux.apps.catalog.list", json!({ "limit": 1 }), Origin::Cli).unwrap();
    assert_eq!(ids(&first["listings"]), ["cmux/demo"]);
    let cursor = first["next_cursor"].clone();
    let second =
        store(&f, "cmux.apps.catalog.list", json!({ "limit": 1, "cursor": cursor }), Origin::Cli)
            .unwrap();
    assert_eq!(
        (ids(&second["listings"]), second["next_cursor"].clone()),
        (vec!["local/spy".to_string()], Value::Null)
    );
    let bad = store(&f, "cmux.apps.catalog.list", json!({ "bogus": 1 }), Origin::Cli).unwrap_err();
    assert_eq!(bad.code, "bad-request");
}

#[test]
fn installed_list_and_set_follow_the_install_mirror() {
    let f = store_fixture();
    f.install("cmux/demo");
    let list = store(&f, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    assert_eq!(ids(&list["apps"]), ["cmux/demo"]);
    let demo = &list["apps"][0];
    assert_eq!(
        demo["state"],
        json!({ "installed": true, "enabled": true, "hidden": false, "sandboxed": false, "source": "user", "version": "1.0.0", "update": null })
    );
    assert_eq!(
        (demo["hide_only"].clone(), demo["tier"].clone()),
        (json!(true), json!("first-party"))
    );
    // Hiding works from any origin; enabling needs the user.
    let hidden = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "hidden": true, "idempotency_key": "h" }),
        Origin::Cli,
    )
    .unwrap();
    assert_eq!(hidden["app"]["state"]["hidden"], json!(true));
    assert!(hidden["revision"].as_u64().is_some());
    let refused = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "enabled": false, "idempotency_key": "e1" }),
        Origin::Cli,
    )
    .unwrap_err();
    assert_eq!(refused.code, "apps.origin");
    let disabled = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "enabled": false, "idempotency_key": "e2" }),
        Origin::User,
    )
    .unwrap();
    assert_eq!(disabled["app"]["state"]["enabled"], json!(false));
    // Enabling needs the user too (both directions), and so does sandboxing.
    let enable = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "enabled": true, "idempotency_key": "e3" }),
        Origin::Cli,
    )
    .unwrap_err();
    assert_eq!(enable.code, "apps.origin");
    let sandbox = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "sandboxed": true, "idempotency_key": "s1" }),
        Origin::Cli,
    )
    .unwrap_err();
    assert_eq!(sandbox.code, "apps.origin");
    let sandboxed = store(
        &f,
        "cmux.apps.set",
        json!({ "app": "cmux/demo", "sandboxed": true, "idempotency_key": "s2" }),
        Origin::User,
    )
    .unwrap();
    assert_eq!(sandboxed["app"]["state"]["sandboxed"], json!(true));
    // A watch stream event names the app that changed.
    let changed =
        f.wait("apps-changed", |e| e["event"] == "apps-changed" && e["app"] == "cmux/demo");
    assert!(changed["revision"].as_u64().is_some());
}

#[test]
fn install_and_uninstall_need_the_user_and_skip_first_party_apps() {
    let f = store_fixture();
    let spy = json!({ "app": "local/spy", "idempotency_key": "i1" });
    let refused = store(&f, "cmux.apps.install", spy.clone(), Origin::Cli).unwrap_err();
    assert_eq!(refused.code, "apps.origin");
    let installed = store(&f, "cmux.apps.install", spy, Origin::User).unwrap();
    assert_eq!(installed["app"]["state"]["installed"], json!(true));
    let removed = store(
        &f,
        "cmux.apps.uninstall",
        json!({ "app": "local/spy", "idempotency_key": "u1" }),
        Origin::User,
    )
    .unwrap();
    assert_eq!(removed["app"]["state"]["installed"], json!(false));
    for op in ["cmux.apps.install", "cmux.apps.uninstall"] {
        let first_party = store(
            &f,
            op,
            json!({ "app": "cmux/demo", "idempotency_key": format!("{op}-1") }),
            Origin::User,
        )
        .unwrap_err();
        assert_eq!(first_party.code, "apps.first_party_hide_only", "{op}");
    }
}

#[test]
fn open_is_not_a_daemon_op() {
    // cmux.apps.open opens UI, so the Mac app answers it; the daemon does not.
    let f = store_fixture();
    for op in ["cmux.apps.open", "cmux.apps.nope"] {
        let unknown = store(&f, op, json!({ "app": "cmux/demo" }), Origin::User).unwrap_err();
        assert_eq!(unknown.code, "apps.op.unknown", "{op}");
    }
}

#[test]
fn catalog_get_adds_the_scopes_with_their_risk() {
    let f = store_fixture();
    let detail =
        store(&f, "cmux.apps.catalog.get", json!({ "app": "cmux/demo" }), Origin::Cli).unwrap();
    assert_eq!(
        (detail["app"].clone(), detail["hide_only"].clone()),
        (json!("cmux/demo"), json!(true))
    );
    let scopes = detail["scopes"].as_array().unwrap();
    let row = |scope: &str| scopes.iter().find(|s| s["scope"] == scope).cloned().unwrap();
    assert_eq!(
        row("workspace:read"),
        json!({ "scope": "workspace:read", "reason": "r", "risk": "standard", "optional": false })
    );
    assert_eq!(row("actions:run")["risk"], json!("sensitive"));
    let hidden =
        store(&f, "cmux.apps.catalog.get", json!({ "app": "cmux/app-store" }), Origin::Cli)
            .unwrap_err();
    assert_eq!(hidden.code, "apps.unknown");
}
