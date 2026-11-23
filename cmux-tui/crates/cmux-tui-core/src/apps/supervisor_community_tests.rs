//! The Community source through `store_call` (`community.rs`): a fixture
//! registry, no network.

use super::*;
use crate::apps::community::Community;
use crate::apps::community::tests::{FakeRegistry, listing};

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const BASE: &str = "https://registry.test";

fn with_registry(f: &Fixture, items: Vec<Value>) -> Arc<FakeRegistry> {
    let registry = FakeRegistry::with(vec![(
        format!("{BASE}/v1/extensions?status=reviewed&limit=100").as_str(),
        Ok(json!({ "items": items })),
    )]);
    let community = Community::new(Some(&f.state), BASE, registry.clone());
    assert!(f.supervisor.community.set(community).is_ok());
    registry
}

fn store(f: &Fixture, op: &str, args: Value) -> Value {
    f.supervisor.store_call(CLIENT, op, args, Origin::User).unwrap()
}

/// Waits for the background refresh's `apps-changed {transaction: community}`.
fn wait_refreshed(f: &Fixture) {
    f.wait("community refresh", |e| {
        e["event"] == "apps-changed" && e["transaction"] == "community"
    });
}

#[test]
fn catalog_list_with_source_community_serves_the_registry_index() {
    let f = fixture();
    with_registry(&f, vec![listing("Acme", "notes", SHA_A), listing("Zed", "timer", SHA_B)]);
    // First read: nothing cached yet, a refresh starts off the request.
    let first = store(&f, "apps.catalog.list", json!({ "source": "community" }));
    assert_eq!(first["source"], "community");
    assert_eq!(first["listings"], json!([]));
    assert_eq!(first["stale"], true);
    wait_refreshed(&f);
    let list = store(&f, "apps.catalog.list", json!({ "source": "community" }));
    assert_eq!(list["listings"].as_array().unwrap().len(), 2);
    assert_eq!(list["stale"], false);
    assert!(list["fetched_at"].as_u64().is_some());
    // The page router adds the local catalog's params; they are ignored here.
    let found = store(
        &f,
        "apps.catalog.list",
        json!({ "source": "community", "query": "TIMER", "developer": false }),
    );
    assert_eq!(found["listings"][0]["ref"], "github.com/Zed/timer");
    let paged = store(
        &f,
        "apps.catalog.list",
        json!({ "source": "community", "limit": 1, "sort": "name" }),
    );
    assert_eq!(paged["next_cursor"], "1");
    // The local catalog is unchanged by the Community source.
    let local = store(&f, "apps.catalog.list", json!({}));
    assert!(local.get("source").is_none());
    assert!(local["listings"].as_array().unwrap().iter().all(|r| r.get("ref").is_none()));
}

#[test]
fn catalog_get_with_source_community_answers_the_readme() {
    let f = fixture();
    with_registry(&f, vec![listing("Acme", "notes", SHA_A)]);
    store(&f, "apps.catalog.list", json!({ "source": "community" }));
    wait_refreshed(&f);
    let detail = store(
        &f,
        "apps.catalog.get",
        json!({ "source": "community", "ref": "github.com/acme/NOTES" }),
    );
    assert_eq!(detail["readme"], "# notes\n\nHello");
    assert_eq!(detail["install_app"], format!("github.com/Acme/notes@{SHA_A}"));
    let missing = f.supervisor.store_call(
        CLIENT,
        "apps.catalog.get",
        json!({ "source": "community", "ref": "github.com/acme/none" }),
        Origin::User,
    );
    assert_eq!(missing.unwrap_err().code, "apps.community.unknown");
}

#[test]
fn a_failed_registry_never_fails_the_local_catalog() {
    let f = fixture();
    let registry = FakeRegistry::with(vec![]);
    assert!(f.supervisor.community.set(Community::new(Some(&f.state), BASE, registry)).is_ok());
    let list = store(&f, "apps.catalog.list", json!({ "source": "community" }));
    assert_eq!(list["listings"], json!([]));
    wait_refreshed(&f);
    let list = store(&f, "apps.catalog.list", json!({ "source": "community" }));
    assert!(list["error"].as_str().is_some());
    assert!(store(&f, "apps.catalog.list", json!({}))["listings"].as_array().is_some());
}

#[test]
fn installs_sync_here_and_offer_install_on_this_mac_for_the_rest() {
    let f = fixture();
    with_registry(&f, vec![listing("Acme", "notes", SHA_A)]);
    // An installed git app (the git install path's sources.json).
    f.install("cmux/demo");
    std::fs::create_dir_all(f.state.join("apps/git")).unwrap();
    std::fs::write(
        f.state.join("apps/git/sources.json"),
        serde_json::to_vec(&json!({ "apps": { "cmux/demo": {
            "repository": "https://github.com/acme/demo", "host": "github.com", "owner": "acme",
            "repo": "demo", "commit": SHA_A, "tag": "v1.0.0", "version": "1.0.0",
            "sha256": "x", "dir": "d" } } }))
        .unwrap(),
    )
    .unwrap();
    let installs = store(&f, "apps.community.installs", json!({}));
    assert_eq!(installs["here"][0]["ref"], "github.com/acme/demo");
    assert_eq!(installs["here"][0]["tag"], "v1.0.0");
    assert_eq!(installs["here"][0]["commit"], SHA_A);
    assert_eq!(installs["here"][0]["kind"], "extension");

    // The account says another device has demo (here already) and notes.
    let synced = store(
        &f,
        "apps.community.synced.put",
        json!({ "idempotency_key": "s1", "items": [
            { "ref": "github.com/acme/demo", "kind": "extension", "commit": SHA_A },
            { "ref": "github.com/Acme/notes", "kind": "extension", "tag": "v1.2.0", "commit": SHA_B }
        ] }),
    );
    let elsewhere = synced["elsewhere"].as_array().unwrap();
    assert_eq!(elsewhere.len(), 1);
    assert_eq!(elsewhere[0]["ref"], "github.com/Acme/notes");
    assert_eq!(elsewhere[0]["action"], "install_on_this_mac");
    assert_eq!(elsewhere[0]["install_app"], format!("github.com/Acme/notes@{SHA_B}"));
    // Nothing installed itself: the offer waits for the person and the consent card.
    let installed =
        f.supervisor.store_call(CLIENT, "apps.installed.list", json!({}), Origin::User).unwrap();
    assert!(installed["apps"].as_array().unwrap().iter().all(|a| a["app"] != "acme/notes"));
    let list = store(&f, "apps.catalog.list", json!({ "source": "community" }));
    assert_eq!(list["on_other_devices"][0]["ref"], "github.com/Acme/notes");
    // That read started a refresh: let it finish before the state dir goes.
    wait_refreshed(&f);

    let bad = f.supervisor.store_call(
        CLIENT,
        "apps.community.synced.put",
        json!({ "idempotency_key": "s2", "items": [{ "ref": "x", "kind": "extension", "commit": SHA_A }] }),
        Origin::User,
    );
    assert_eq!(bad.unwrap_err().code, "bad-request");
    assert!(crate::apps::store_op_mutates("cmux.apps.community.synced.put"));
}

/// `cmux/demo` installed from `github.com/acme/demo` at `commit` (the git
/// install path's sources.json).
fn git_installed(f: &Fixture, commit: &str) {
    f.install("cmux/demo");
    std::fs::create_dir_all(f.state.join("apps/git")).unwrap();
    std::fs::write(
        f.state.join("apps/git/sources.json"),
        serde_json::to_vec(&json!({ "apps": { "cmux/demo": {
            "repository": "https://github.com/acme/demo", "host": "github.com", "owner": "acme",
            "repo": "demo", "commit": commit, "tag": "v1.0.0", "version": "1.0.0",
            "sha256": "x", "dir": "d" } } }))
        .unwrap(),
    )
    .unwrap();
}

/// `apps.updates.list` once the background refresh has filled the cache
/// (the first read answers from the empty cache and starts it).
fn updates_after_refresh(f: &Fixture) -> Value {
    let first = store(f, "apps.updates.list", json!({}));
    assert_eq!(first["updates"], json!([]));
    assert_eq!(first["stale"], true);
    wait_refreshed(f);
    let list = store(f, "apps.updates.list", json!({}));
    assert_eq!(list["stale"], false);
    assert!(list["revision"].as_u64().is_some());
    list
}

fn installed_demo(f: &Fixture) -> Value {
    let installed = store(f, "apps.installed.list", json!({}));
    installed["apps"].as_array().unwrap().iter().find(|a| a["app"] == "cmux/demo").unwrap().clone()
}

#[test]
fn updates_list_is_empty_with_no_git_apps() {
    let f = fixture();
    with_registry(&f, vec![listing("acme", "demo", SHA_B)]);
    // A catalog app ships with cmux: always current, never an update.
    f.install("cmux/demo");
    let list = updates_after_refresh(&f);
    assert_eq!(list["updates"], json!([]));
    assert_eq!(installed_demo(&f)["state"]["update"], Value::Null);
}

#[test]
fn an_installed_git_app_at_an_older_commit_lists_one_update() {
    let f = fixture();
    with_registry(&f, vec![listing("acme", "demo", SHA_B), listing("Zed", "timer", SHA_A)]);
    git_installed(&f, SHA_A);
    let list = updates_after_refresh(&f);
    let updates = list["updates"].as_array().unwrap();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["app"], "cmux/demo");
    assert_eq!(updates[0]["name"], "demo name");
    assert_eq!(updates[0]["ref"], "github.com/acme/demo");
    assert_eq!(updates[0]["current_version"], "1.0.0");
    assert_eq!(updates[0]["current_commit"], SHA_A);
    assert_eq!(updates[0]["version"], "1.2.0");
    assert_eq!(updates[0]["commit"], SHA_B);
    assert_eq!(updates[0]["install_app"], format!("github.com/acme/demo@{SHA_B}"));
    // The installed row says it too, as `{version, commit}`.
    assert_eq!(
        installed_demo(&f)["state"]["update"],
        json!({ "version": "1.2.0", "commit": SHA_B })
    );
    // Updating is a user action, as installing is.
    let agent = f.supervisor.store_call(
        CLIENT,
        "apps.update",
        json!({ "app": "cmux/demo", "idempotency_key": "u1" }),
        Origin::Cli,
    );
    assert_eq!(agent.unwrap_err().code, "apps.origin");
}

#[test]
fn an_installed_git_app_at_the_current_commit_lists_none() {
    let f = fixture();
    with_registry(&f, vec![listing("acme", "demo", SHA_B)]);
    git_installed(&f, SHA_B);
    let list = updates_after_refresh(&f);
    assert_eq!(list["updates"], json!([]));
    assert_eq!(installed_demo(&f)["state"]["update"], Value::Null);
    let current = f.supervisor.store_call(
        CLIENT,
        "apps.update",
        json!({ "app": "cmux/demo", "idempotency_key": "u1" }),
        Origin::User,
    );
    assert_eq!(current.unwrap_err().code, "apps.update.none");
}

#[test]
fn updating_an_unknown_app_is_refused() {
    let f = fixture();
    with_registry(&f, vec![listing("acme", "demo", SHA_B)]);
    let unknown = f.supervisor.store_call(
        CLIENT,
        "apps.update",
        json!({ "app": "acme/none", "idempotency_key": "u1" }),
        Origin::User,
    );
    assert_eq!(unknown.unwrap_err().code, "apps.update.none");
    let bad = f.supervisor.store_call(CLIENT, "apps.update", json!({}), Origin::User);
    assert_eq!(bad.unwrap_err().code, "bad-request");
    assert!(crate::apps::store_op_mutates("cmux.apps.update"));
    assert!(!crate::apps::store_op_mutates("cmux.apps.updates.list"));
}
