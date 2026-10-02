use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::tests::{changes_after, empty_workspace, error_code, mutate, revision, send};
use crate::Mux;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn entries(mux: &Arc<Mux>, workspace: &str) -> Vec<Value> {
    let list = send(mux, "workspace_status.list", json!({"workspace": workspace}), None).unwrap();
    list[0]["entries"].as_array().cloned().unwrap_or_default()
}

/// Bounded wait for a daemon-side removal (test-only sleep).
fn wait_until(mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    done()
}

#[test]
fn loading_fields_round_trip_and_old_callers_stay_plain() {
    let mux = Mux::new_for_test("status-meta-fields", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "fields");
    let set = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "cli:a", "text": "Building", "state": "busy",
               "progress": 0.4, "style": "native"}),
        "m1",
    );
    assert_eq!(set["entries"][0]["state"], "busy");
    assert_eq!(set["entries"][0]["progress"], 0.4);
    assert_eq!(set["entries"][0]["style"], "native");
    let plain = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "k", "text": "t"}),
        "m2",
    );
    assert!(plain["entries"][1].get("state").is_none());
    // A replay with the same key returns the stored result and changes nothing.
    let before = revision(&mux);
    let replay = send(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "cli:a", "text": "Building", "state": "busy",
               "progress": 0.4, "style": "native"}),
        Some("m1"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(revision(&mux), before);
    // Finishing the run records the outcome.
    let done = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "cli:a", "text": "Building", "state": "error",
               "exit_code": 2, "duration_ms": 1234}),
        "m3",
    );
    assert_eq!(done["entries"][0]["exit_code"], 2);
    assert_eq!(done["entries"][0]["duration_ms"], "1234");
    assert!(done["entries"][0]["progress"].is_null());
    mux.shutdown();
}

#[test]
fn invalid_owners_are_rejected_before_anything_is_written() {
    let mux = Mux::new_for_test("status-meta-invalid", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "invalid");
    let unknown_terminal = format!("term_{}", "ab".repeat(16));
    for (key, params) in [
        ("i1", json!({"owner": {"terminal": unknown_terminal}})),
        ("i2", json!({"owner": {"pid": u32::MAX - 7}})),
        ("i3", json!({"state": "info", "progress": 0.5})),
    ] {
        let mut params = params;
        params["workspace"] = json!(workspace);
        params["key"] = json!("k");
        params["text"] = json!("t");
        params["state"] = params.get("state").cloned().unwrap_or(json!("busy"));
        assert_eq!(
            error_code(send(&mux, "workspace_status.set", params, Some(key))),
            "validation.invalid"
        );
    }
    assert!(entries(&mux, &workspace).is_empty());
    mux.shutdown();
}

#[test]
fn ttl_expiry_removes_the_entry_in_a_daemon_commit() {
    let mux = Mux::new_for_test("status-meta-ttl", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "ttl");
    let before = revision(&mux);
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "done", "text": "Tests passed", "state": "success", "ttl_ms": 150}),
        "t1",
    );
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "keep", "text": "stays"}),
        "t2",
    );
    assert!(wait_until(|| entries(&mux, &workspace).len() == 1), "the TTL entry was not removed");
    assert_eq!(entries(&mux, &workspace)[0]["key"], "keep");
    let upserts = changes_after(&mux, before)
        .into_iter()
        .filter(|change| {
            change["kind"] == "state_upsert" && change["resource"] == "workspace_status"
        })
        .count();
    assert_eq!(upserts, 3, "two sets and one expiry commit");
    mux.shutdown();
}

#[cfg(unix)]
#[test]
fn owner_process_exit_removes_only_its_entries() {
    let mux = Mux::new_for_test("status-meta-pid", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "pid");
    let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "run", "text": "Tests", "state": "busy", "owner": {"pid": child.id()}}),
        "p1",
    );
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "other", "text": "x", "state": "busy"}),
        "p2",
    );
    assert_eq!(entries(&mux, &workspace)[0]["owner"]["pid"], child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(
        wait_until(|| entries(&mux, &workspace).len() == 1),
        "the owned entry outlived its process"
    );
    assert_eq!(entries(&mux, &workspace)[0]["key"], "other");
    mux.shutdown();
}
