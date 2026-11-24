//! The store's shelves (`cmux.apps.catalog.sections`) and a listing's
//! versions and What's New through a real daemon socket: the raw
//! `apps-store` command the CLI uses, and v2 on the Apps page's relay
//! (page-router.json lists the op for page `apps`).

use serde_json::{Value, json};

use super::apps_store::{Apps, ok, v2_ok, write_app};

#[test]
fn the_store_shelves_and_whats_new_reach_the_cli_and_the_apps_page() {
    let apps = Apps::new("sections");
    let first_party = apps.dir.join("first-party");
    write_app(&first_party, "cmux", "notes", json!({ "categories": ["productivity"] }));
    write_app(&first_party, "cmux", "cloud", json!({ "categories": ["cloud"] }));
    write_app(&apps.dir.join("bundled"), "acme", "tool", json!({ "categories": ["fun"] }));
    std::fs::create_dir_all(first_party.join("notes/catalog")).unwrap();
    let news = json!({
        "version": "1.0.0",
        "items": [{ "title": "Notes open faster", "pr": 44805 }],
        "versions": [{ "version": "1.0.0", "commit": "abc", "date_ms": 1_700_000_000_000_i64 }],
    });
    std::fs::write(first_party.join("notes/catalog/whats-new.json"), news.to_string()).unwrap();
    apps.start();

    // Featured leads with Cloud; recent lists only a dated version; the SDK
    // example's category is on no store shelf.
    let mut agent = apps.agent();
    let reply = agent.store("cmux.apps.catalog.sections", json!({}), "cli");
    let shelves: Vec<(Value, Value)> = ok(&reply)["sections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| (s["id"].clone(), s["apps"].clone()))
        .collect();
    assert_eq!(
        shelves,
        [
            (json!("featured"), json!(["cmux/cloud", "cmux/notes"])),
            (json!("recent"), json!(["cmux/notes"])),
            (json!("category:cloud"), json!(["cmux/cloud"])),
            (json!("category:productivity"), json!(["cmux/notes"])),
        ],
        "{reply}"
    );

    // The Apps page's relay pages one section.
    let mut relay = apps.agent();
    relay.rpc(json!({ "cmd": "client-hello", "role": "page_relay", "page": "apps" }));
    let reply = relay.v2(
        "apps.catalog.sections",
        json!({ "section": "featured", "cursor": "1", "limit": 1 }),
        json!({ "origin": { "claim": "page" } }),
    );
    assert_eq!(
        v2_ok(&reply)["sections"],
        json!([{
            "id": "featured", "kind": "featured", "title_key": "apps.store.section.featured",
            "apps": ["cmux/notes"],
        }]),
        "{reply}"
    );

    // A listing answers its versions, and What's New when its package has it.
    let reply = agent.store("cmux.apps.catalog.get", json!({ "app": "cmux/notes" }), "cli");
    let notes = ok(&reply);
    assert_eq!(
        (&notes["versions"], &notes["whats_new"]),
        (
            &news["versions"],
            &json!({ "version": "1.0.0", "items": [{ "title": "Notes open faster", "pr": 44805 }] })
        ),
        "{reply}"
    );
    let reply = agent.store("cmux.apps.catalog.get", json!({ "app": "cmux/cloud" }), "cli");
    let cloud = ok(&reply);
    assert_eq!(cloud["versions"], json!([{ "version": "1.0.0" }]), "{reply}");
    assert!(cloud.get("whats_new").is_none(), "{reply}");
}
