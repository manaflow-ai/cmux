use std::collections::BTreeMap;

use serde_json::json;

use super::*;

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

#[test]
fn a_chat_leaving_a_machine_with_memory_on_carries_its_owner() {
    let on = r#"{"agents": {"memory": {"enabled": true, "owner": "mac-mini", "ownerArgs": ["--peer", "x"]}}}"#;
    assert_eq!(
        outgoing(Some(on), &BTreeMap::new(), None),
        Some(json!({"owner": "mac-mini", "ownerArgs": ["--peer", "x"]}))
    );
    // The machine itself holds the index and serves no remote daemon: memory still follows,
    // with no route.
    let own = r#"{"agents": {"memory": {"enabled": true}}}"#;
    assert_eq!(
        outgoing(Some(own), &BTreeMap::new(), None),
        Some(json!({"owner": null, "ownerArgs": []}))
    );
}

#[test]
fn a_mac_that_owns_its_index_sends_the_route_back_to_itself() {
    let here = route_back(Some("127.0.0.1:7781"), Some("bWFjLWtleQ=="));
    assert_eq!(
        here,
        Some(Followed {
            owner: Some("ws://127.0.0.1:7781/v1/link".into()),
            owner_args: vec!["--via-machine".into(), "bWFjLWtleQ==".into()],
        })
    );
    let own = r#"{"agents": {"memory": {"enabled": true}}}"#;
    let field = outgoing(Some(own), &BTreeMap::new(), here.clone()).unwrap();
    assert_eq!(
        field,
        json!({"owner": "ws://127.0.0.1:7781/v1/link", "ownerArgs": ["--via-machine", "bWFjLWtleQ=="]})
    );
    // The Cloud machine it lands on records that route and hands it to the memory server.
    let mut session_env = BTreeMap::new();
    apply(&mut session_env, &json!({(MANIFEST_FIELD): field}));
    let followed = followed(&session_env).unwrap();
    assert_eq!(Some(followed.clone()), here);
    assert_eq!(
        server_env(&followed),
        vec![
            (OWNER_ENV.to_owned(), "ws://127.0.0.1:7781/v1/link".to_owned()),
            (OWNER_ARGS_ENV.to_owned(), r#"["--via-machine","bWFjLWtleQ=="]"#.to_owned()),
        ]
    );

    // A set owner, or the owner the chat came in with, still wins over the route back.
    let set = r#"{"agents": {"memory": {"enabled": true, "owner": "ssh://studio"}}}"#;
    assert_eq!(
        outgoing(Some(set), &BTreeMap::new(), here.clone()).unwrap()["owner"],
        "ssh://studio"
    );
    let brought = env(&[(FOLLOWS_ENV, "1"), (OWNER_ENV, "mac-mini")]);
    assert_eq!(outgoing(Some(own), &brought, here.clone()).unwrap()["owner"], "mac-mini");
    // Memory off here sends nothing, route or not.
    let off = r#"{"agents": {"memory": {"enabled": false}}}"#;
    assert_eq!(outgoing(Some(off), &BTreeMap::new(), here), None);

    // No route without a loopback remote daemon and a carrier key.
    assert_eq!(route_back(None, Some("k")), None);
    assert_eq!(route_back(Some("127.0.0.1:7781"), None), None);
    assert_eq!(route_back(Some("10.0.0.2:7781"), Some("k")), None);
    assert_eq!(route_back(Some("127.0.0.1:0"), Some("k")), None);
    assert_eq!(route_back(Some("127.0.0.1:7781"), Some("a\nb")), None);
}

#[test]
fn memory_off_or_unset_carries_nothing_unless_the_chat_brought_it() {
    let off = r#"{"agents": {"memory": {"enabled": false, "owner": "mac-mini"}}}"#;
    let brought = env(&[(FOLLOWS_ENV, "1"), (OWNER_ENV, "mac-mini")]);
    assert_eq!(outgoing(Some(off), &brought, None), None);
    assert_eq!(outgoing(None, &BTreeMap::new(), None), None);
    assert_eq!(outgoing(Some("{}"), &BTreeMap::new(), None), None);
    // Moved on again from a machine with no setting: it keeps what it brought.
    assert_eq!(outgoing(None, &brought, None), Some(json!({"owner": "mac-mini", "ownerArgs": []})));
    // A machine with memory on and no owner of its own passes the brought owner on.
    let own = r#"{"agents": {"memory": {"enabled": true}}}"#;
    assert_eq!(
        outgoing(Some(own), &brought, None),
        Some(json!({"owner": "mac-mini", "ownerArgs": []}))
    );
}

#[test]
fn apply_records_the_move_and_replaces_what_the_bundle_held() {
    let mut session_env = env(&[(OWNER_ENV, "stale"), ("CMUX_WORKSPACE_ID", "w")]);
    let manifest = json!({(MANIFEST_FIELD): {"owner": "mac-mini", "ownerArgs": ["--peer", "x"]}});
    apply(&mut session_env, &manifest);
    assert_eq!(session_env.get(FOLLOWS_ENV).map(String::as_str), Some("1"));
    assert_eq!(session_env.get(OWNER_ENV).map(String::as_str), Some("mac-mini"));
    assert_eq!(session_env.get(OWNER_ARGS_ENV).map(String::as_str), Some(r#"["--peer","x"]"#));
    assert_eq!(session_env.get("CMUX_WORKSPACE_ID").map(String::as_str), Some("w"));
    assert_eq!(
        followed(&session_env),
        Some(Followed {
            owner: Some("mac-mini".into()),
            owner_args: vec!["--peer".into(), "x".into()]
        })
    );

    // A move without the field: the chat had no memory where it came from.
    apply(&mut session_env, &json!({}));
    assert_eq!(followed(&session_env), None);
    assert!(!session_env.contains_key(OWNER_ENV));
}

#[test]
fn a_bad_field_is_no_memory() {
    for field in [
        json!("mac-mini"),
        json!({"owner": 3}),
        json!({"owner": "a\nb"}),
        json!({"owner": "x".repeat(MAX_TEXT + 1)}),
        json!({"owner": "m", "ownerArgs": vec!["a"; MAX_ARGS + 1]}),
        json!({"owner": "m", "ownerArgs": [1]}),
    ] {
        assert_eq!(parse(&field), None, "{field}");
    }
    assert_eq!(parse(&json!({})), Some(Followed::default()));
}

#[test]
fn a_bundles_session_json_gets_the_field() {
    let mut meta = json!({"id": "s", "sessionEnv": {(OWNER_ENV): "stale"}});
    apply_to_meta(&mut meta, &json!({(MANIFEST_FIELD): {"owner": "mac-mini"}}));
    assert_eq!(meta["sessionEnv"], json!({(FOLLOWS_ENV): "1", (OWNER_ENV): "mac-mini"}));
    apply_to_meta(&mut meta, &json!({}));
    assert!(meta.get("sessionEnv").is_none());
}

#[test]
fn the_server_env_names_the_owner_only_when_there_is_one() {
    assert!(server_env(&Followed::default()).is_empty());
    let env = server_env(&Followed { owner: Some("m".into()), owner_args: vec![] });
    assert_eq!(env, vec![(OWNER_ENV.to_owned(), "m".to_owned())]);
}
