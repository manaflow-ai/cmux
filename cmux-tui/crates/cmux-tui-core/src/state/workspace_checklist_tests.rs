//! `workspace_checklist.*` (`workspace-checklist-v1`): each workspace's
//! checklist, shared state of its home session. Items keep their order,
//! text, state (todo, in progress, done), creator and image attachments;
//! every change is one `workspace_checklist` state upsert on
//! `session.events`, the session snapshot lists every non-empty checklist,
//! the rows survive a restart, and closing the workspace removes them.

use serde_json::json;

use super::tests::{
    Session, changes_after, empty_workspace, error_code, mutate, read, revision, send, snapshot,
};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn items(checklist: &Value) -> Vec<Value> {
    checklist["items"].as_array().cloned().unwrap_or_default()
}

fn texts(checklist: &Value) -> Vec<String> {
    items(checklist).iter().map(|item| item["text"].as_str().unwrap().to_string()).collect()
}

#[test]
fn checklist_items_are_added_edited_ordered_and_removed() {
    let mux = Mux::new_for_test("state-checklist", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "todo");
    let before = revision(&mux);

    let first = mutate(
        &mux,
        "workspace_checklist.add",
        json!({"workspace": workspace, "text": "  write the test  "}),
        "a1",
    );
    assert_eq!(first["workspace_id"], workspace.as_str());
    let item = &items(&first)[0];
    assert_eq!(item["text"], "write the test", "text is trimmed");
    assert_eq!(item["state"], "todo");
    assert_eq!(item["origin"], "user");
    assert_eq!(item["attachments"], json!([]));
    let first_id = item["id"].as_str().unwrap().to_string();
    assert!(first_id.starts_with("chk_"), "{first_id}");

    mutate(
        &mux,
        "workspace_checklist.add",
        json!({"workspace": workspace, "text": "ship it", "origin": "agent"}),
        "a2",
    );
    let inserted = mutate(
        &mux,
        "workspace_checklist.add",
        json!({"workspace": workspace, "text": "read the issue", "index": 0}),
        "a3",
    );
    assert_eq!(texts(&inserted), ["read the issue", "write the test", "ship it"]);
    assert_eq!(items(&inserted)[2]["origin"], "agent");

    let edited = mutate(
        &mux,
        "workspace_checklist.update",
        json!({"workspace": workspace, "item": first_id, "text": "write the failing test",
               "state": "in_progress"}),
        "u1",
    );
    assert_eq!(items(&edited)[1]["text"], "write the failing test");
    assert_eq!(items(&edited)[1]["state"], "in_progress");

    let moved = mutate(
        &mux,
        "workspace_checklist.update",
        json!({"workspace": workspace, "item": first_id, "index": 2, "state": "done"}),
        "u2",
    );
    assert_eq!(texts(&moved), ["read the issue", "ship it", "write the failing test"]);
    assert_eq!(items(&moved)[2]["state"], "done");

    let removed = mutate(
        &mux,
        "workspace_checklist.remove",
        json!({"workspace": workspace, "item": first_id}),
        "r1",
    );
    assert_eq!(texts(&removed), ["read the issue", "ship it"]);

    let listed = read(&mux, "workspace_checklist.list", json!({}));
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(texts(&listed[0]), ["read the issue", "ship it"]);
    let one = read(&mux, "workspace_checklist.list", json!({"workspace": workspace}));
    assert_eq!(one[0]["workspace_id"], workspace.as_str());

    let upserts = changes_after(&mux, before)
        .into_iter()
        .filter(|change| {
            change["kind"] == "state_upsert" && change["resource"] == "workspace_checklist"
        })
        .collect::<Vec<_>>();
    assert_eq!(upserts.len(), 6, "one upsert per committed change");
    assert_eq!(upserts.last().unwrap()["id"], workspace.as_str());
    assert_eq!(texts(&upserts.last().unwrap()["value"]), ["read the issue", "ship it"]);

    let state = &snapshot(&mux)["extra"]["state"]["workspace_checklist"];
    assert_eq!(texts(&state[0]), ["read the issue", "ship it"]);
}

#[test]
fn checklist_items_take_image_attachments_by_path() {
    let mux = Mux::new_for_test("state-checklist-images", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "images");
    let added = mutate(
        &mux,
        "workspace_checklist.add",
        json!({"workspace": workspace, "text": "ui"}),
        "a1",
    );
    let item = items(&added)[0]["id"].as_str().unwrap().to_string();
    let attached = mutate(
        &mux,
        "workspace_checklist.update",
        json!({"workspace": workspace, "item": item, "attachments": [
            {"path": "/tmp/shot one.png"},
            {"path": "/tmp/mock.jpg", "name": "Mock"},
        ]}),
        "u1",
    );
    let attachments = items(&attached)[0]["attachments"].as_array().unwrap().clone();
    assert_eq!(attachments.len(), 2);
    assert_eq!(attachments[0]["path"], "/tmp/shot one.png");
    assert_eq!(attachments[0]["name"], "shot one.png", "the name defaults to the file name");
    assert_eq!(attachments[1]["name"], "Mock");
    let kept_id = attachments[1]["id"].as_str().unwrap().to_string();
    assert!(kept_id.starts_with("att_"), "{kept_id}");

    // A later list keeps the ids it names and drops the rest.
    let trimmed = mutate(
        &mux,
        "workspace_checklist.update",
        json!({"workspace": workspace, "item": item, "attachments": [
            {"id": kept_id, "path": "/tmp/mock.jpg", "name": "Mock"},
        ]}),
        "u2",
    );
    assert_eq!(items(&trimmed)[0]["attachments"][0]["id"], kept_id.as_str());
    assert_eq!(items(&trimmed)[0]["attachments"].as_array().unwrap().len(), 1);

    assert_eq!(
        error_code(send(
            &mux,
            "workspace_checklist.update",
            json!({"workspace": workspace, "item": item, "attachments": [{"path": "relative.png"}]}),
            Some("u3"),
        )),
        "validation.invalid",
        "an attachment path is absolute"
    );
}

#[test]
fn checklist_refuses_empty_text_unknown_items_and_a_full_list() {
    let mux = Mux::new_for_test("state-checklist-refusals", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "refusals");
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_checklist.add",
            json!({"workspace": workspace, "text": "   "}),
            Some("e1"),
        )),
        "validation.invalid"
    );
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_checklist.update",
            json!({"workspace": workspace, "item": "chk_missing", "state": "done"}),
            Some("e2"),
        )),
        "validation.invalid"
    );
    for index in 0..50 {
        mutate(
            &mux,
            "workspace_checklist.add",
            json!({"workspace": workspace, "text": format!("item {index}")}),
            &format!("fill-{index}"),
        );
    }
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_checklist.add",
            json!({"workspace": workspace, "text": "one too many"}),
            Some("e3"),
        )),
        "validation.invalid"
    );
}

#[test]
fn checklist_replays_a_retry_survives_a_restart_and_leaves_with_its_workspace() {
    let session = Session::new("checklist-restart");
    let workspace = {
        let mux = session.open();
        let workspace = empty_workspace(&mux, "kept");
        let first = mutate(
            &mux,
            "workspace_checklist.add",
            json!({"workspace": workspace, "text": "survive"}),
            "a1",
        );
        let retried = send(
            &mux,
            "workspace_checklist.add",
            json!({"workspace": workspace, "text": "survive"}),
            Some("a1"),
        )
        .unwrap();
        assert_eq!(retried["replayed"], true);
        assert_eq!(items(&retried["value"]).len(), 1);
        assert_eq!(items(&first)[0]["id"], items(&retried["value"])[0]["id"]);
        workspace
    };
    let mux = session.open();
    let listed = read(&mux, "workspace_checklist.list", json!({"workspace": workspace}));
    assert_eq!(texts(&listed[0]), ["survive"]);

    // Keep another workspace so the session stays open after the close.
    empty_workspace(&mux, "other");
    let before = revision(&mux);
    mutate(&mux, "workspace.close", json!({"workspace": workspace}), "close");
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["kind"] == "state_delete"
            && change["resource"] == "workspace_checklist"
            && change["id"] == workspace.as_str()
    }));
    assert!(read(&mux, "workspace_checklist.list", json!({})).as_array().unwrap().is_empty());
}
