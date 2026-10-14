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
