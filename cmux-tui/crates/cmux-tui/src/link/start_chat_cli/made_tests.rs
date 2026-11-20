//! A machine made for a send stays that send's to delete across its retries (Codex review on #40957):
//! the first try knew it made the machine, its retry planned onto the pin and forgot.

use serde_json::{Value, json};

use super::super::{Keys, create_begin, pin, plan};

const ACCOUNT: &str = "user-leo/team-a";

fn on(key: &str) -> String {
    json!({"key": key, "account": ACCOUNT, "workspace": "ws-1", "user": "user-leo", "loaded": true,
        "machines": [{"id": "vm-new", "title": "cloud-chats", "created_by": "user-leo", "status": "running"}]})
    .to_string()
}

fn key() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

#[test]
fn a_retry_of_a_start_whose_machine_was_made_for_it_still_says_so() {
    let scratch = tempfile::tempdir().unwrap();
    let path = scratch.path().join("cloud-start-chat").join("destinations.json");
    // The first try made vm-new (create-begin, then the App's pin): its retry plans onto it and says so.
    let mine = key();
    let create = Keys::of(&mine).create;
    assert_eq!(create_begin(&path, &mine, ACCOUNT, "cloud-chats", &create)["ok"], true);
    assert_eq!(pin(&path, &mine, ACCOUNT, "vm-new", Some("ws-1"))["ok"], true);
    let retry = plan(&path, &on(&mine));
    assert_eq!(retry["machine"], "vm-new");
    assert_eq!(retry["ensured"]["created"], true, "{retry}");
    // Another send of the workspace that planned onto it was not made for it.
    let other = plan(&path, &on(&key()));
    assert_eq!(other["machine"], "vm-new");
    assert_eq!(other["ensured"], Value::Null, "{other}");
    // A repick pins a machine the person chose: never made for the send.
    let picked = key();
    assert_eq!(pin(&path, &picked, ACCOUNT, "vm-new", None)["ok"], true);
    assert_eq!(plan(&path, &on(&picked))["ensured"], Value::Null);
}
