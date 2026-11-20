//! `rename-workspace` name provenance over the wire (hq#1957): the app's
//! automatic namer never replaces a person's name, and a stale callback loses.

use super::*;

fn listed(mux: &Arc<Mux>, key: &str) -> Value {
    let tree = run_json_command(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"] == json!(key))
        .cloned()
        .unwrap()
}

#[test]
fn workspace_name_source_auto_rename_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&WORKSPACE_NAME_SOURCE_CAPABILITY));
    let key = mux.create_empty_workspace(None, None, None).unwrap().key;
    let (_, generation) = mux.registry_identity();
    let auto = |name: &str, revision: &Value| {
        json!({
            "cmd":"rename-workspace", "key":key, "name":name, "source":"auto",
            "expected_generation":generation, "expected_name_revision":revision,
        })
    };

    let created = listed(&mux, &key);
    assert_eq!(created["name_source"], "auto", "{created}");
    assert_eq!(created["name_revision"], "0", "{created}");

    run_json_command(&mux, auto("Fix Login", &created["name_revision"])).unwrap();
    let named = listed(&mux, &key);
    assert_eq!(named["name"], "Fix Login");
    assert_eq!(named["name_source"], "auto");
    assert_eq!(named["name_revision"], "1");

    // A callback that captured the older revision loses.
    let stale = run_json_command(&mux, auto("Old Topic", &created["name_revision"]));
    assert!(stale.is_err(), "a stale automatic name was accepted");
    assert_eq!(listed(&mux, &key)["name"], "Fix Login");

    // An automatic rename must say which revision it read.
    let unversioned = json!({"cmd":"rename-workspace","key":key,"name":"Topic","source":"auto"});
    assert!(run_json_command(&mux, unversioned).is_err());

    // A rename without a source stays a person's rename and pins the name.
    run_json_command(&mux, json!({"cmd":"rename-workspace","key":key,"name":"Billing"})).unwrap();
    let pinned = listed(&mux, &key);
    assert_eq!(pinned["name_source"], "user");
    assert_eq!(pinned["name_revision"], "2");
    let refused = run_json_command(&mux, auto("Fix Login", &pinned["name_revision"]));
    assert!(refused.is_err(), "an automatic name replaced a person's");
    let latest = listed(&mux, &key);
    assert_eq!(latest["name"], "Billing");
    assert_eq!(latest["name_source"], "user");
    assert_eq!(latest["name_revision"], "2");
}

#[test]
fn workspace_name_source_named_creation_is_user_owned() {
    let mux = test_mux();
    let key = mux.create_empty_workspace(Some("Billing".into()), None, None).unwrap().key;
    let created = listed(&mux, &key);
    assert_eq!(created["name_source"], "user", "{created}");
    let (_, generation) = mux.registry_identity();
    let refused = run_json_command(
        &mux,
        json!({
            "cmd":"rename-workspace", "key":key, "name":"Fix Login", "source":"auto",
            "expected_generation":generation, "expected_name_revision":created["name_revision"],
        }),
    );
    assert!(refused.is_err(), "an automatic name replaced a chosen one");
}

/// Cmd-N creates its workspace under the default name it already shows (#26680): that name is
/// the automatic namer's, so the chat's generated title can replace it.
#[test]
fn workspace_name_source_requested_default_name_stays_automatic() {
    let mux = test_mux();
    let key = mux.create_empty_workspace(Some("workspace-151".into()), None, None).unwrap().key;
    let created = listed(&mux, &key);
    assert_eq!(created["name"], "workspace-151", "{created}");
    assert_eq!(created["name_source"], "auto", "{created}");
    let (_, generation) = mux.registry_identity();
    run_json_command(
        &mux,
        json!({
            "cmd":"rename-workspace", "key":key, "name":"Fix Login", "source":"auto",
            "expected_generation":generation, "expected_name_revision":created["name_revision"],
        }),
    )
    .unwrap();
    assert_eq!(listed(&mux, &key)["name"], "Fix Login");
}

fn open_registry_mux(root: &Path, session: &str) -> Arc<Mux> {
    Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        crate::workspace_registry::WorkspaceRegistry::open(root, session).unwrap(),
        crate::mux::ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

/// An automatic name set through v1 `rename-workspace` is stored as auto, so
/// after a daemon restart the namer may still replace it.
#[test]
fn workspace_name_source_v1_auto_rename_survives_restart() {
    let root = std::env::temp_dir().join(format!(
        "cmux-workspace-name-restart-{}",
        crate::resource::WorkspacePublicId::random().unwrap()
    ));
    let session = "workspace-name-restart";
    let mux = open_registry_mux(&root, session);
    let key = mux.create_empty_workspace(None, None, None).unwrap().key;
    let (_, generation) = mux.registry_identity();
    run_json_command(
        &mux,
        json!({
            "cmd":"rename-workspace", "key":key, "name":"Fix Login", "source":"auto",
            "expected_generation":generation, "expected_name_revision":"0",
        }),
    )
    .unwrap();
    mux.shutdown();
    drop(mux);

    {
        let registry = crate::workspace_registry::WorkspaceRegistry::open(&root, session).unwrap();
        let stored = registry.snapshot().unwrap();
        let workspace = stored.workspaces.iter().find(|workspace| workspace.key == key).unwrap();
        assert_eq!(workspace.name, "Fix Login");
        assert_eq!(workspace.name_source, crate::resource_name::NameSource::Auto);
        assert_eq!(workspace.name_revision, 1);
    }

    let mux = open_registry_mux(&root, session);
    let restored = listed(&mux, &key);
    assert_eq!(restored["name"], "Fix Login");
    assert_eq!(restored["name_source"], "auto", "{restored}");
    assert_eq!(restored["name_revision"], "1", "{restored}");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// v1 `rename-workspace` releases a pinned name with `source: "auto"`,
/// `release: true` and the current name.
#[test]
fn workspace_name_source_v1_release_returns_a_pinned_name_to_auto() {
    let mux = test_mux();
    let key = mux.create_empty_workspace(Some("Billing".into()), None, None).unwrap().key;
    let release = |name: &str| json!({"cmd":"rename-workspace","key":key,"name":name,"source":"auto","release":true});
    let renamed = run_json_command(&mux, release("Other"));
    assert!(renamed.is_err(), "a release renamed the workspace");
    let no_source = json!({"cmd":"rename-workspace","key":key,"name":"Billing","release":true});
    assert!(run_json_command(&mux, no_source).is_err(), "a user rename released the name");
    assert_eq!(listed(&mux, &key)["name_source"], "user");

    run_json_command(&mux, release("Billing")).unwrap();
    let released = listed(&mux, &key);
    assert_eq!(released["name"], "Billing");
    assert_eq!(released["name_source"], "auto", "{released}");
    assert_eq!(released["name_revision"], "1", "{released}");

    let (_, generation) = mux.registry_identity();
    run_json_command(
        &mux,
        json!({
            "cmd":"rename-workspace", "key":key, "name":"Fix Login", "source":"auto",
            "expected_generation":generation, "expected_name_revision":"1",
        }),
    )
    .unwrap();
    assert_eq!(listed(&mux, &key)["name"], "Fix Login");
}
