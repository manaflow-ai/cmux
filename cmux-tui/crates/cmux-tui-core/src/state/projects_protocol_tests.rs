//! `project.*` (project-list-v1, plans/cmux-next/projects.md) through
//! `cmux.protocol/2` requests: the commit path, replay, the user's overlay,
//! refusals, hiding on remove, the event feed and the decimal wire times.

use serde_json::json;

use super::tests::{changes_after, error_code, read, revision, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn names(list: &Value) -> Vec<String> {
    list["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|project| project["name"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn projects_observe_list_edit_remove_and_events() {
    let mux = Mux::new_for_test("state-projects", SurfaceOptions::default());
    let before = revision(&mux);
    let app = "/srv/cx-m0p7-fixture/app";
    let observed = send(
        &mux,
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "50"}], "complete": true}),
        Some("p-1"),
    )
    .unwrap();
    assert_eq!(observed["value"]["changed"], json!([app]));
    let replay = send(
        &mux,
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "50"}], "complete": true}),
        Some("p-1"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);

    let list = read(&mux, "project.list", json!({}));
    let project = &list["projects"][0];
    assert_eq!(project["path"], app);
    assert_eq!(project["name"], "app");
    assert_eq!(project["last_used_ms"], "50");
    assert_eq!(project["sources"]["codex"]["last_used_ms"], "50");
    assert_eq!(project["state"], "present");

    send(
        &mux,
        "project.update",
        json!({"path": app, "rename": "The App", "pinned": true}),
        Some("p-2"),
    )
    .unwrap();
    // A resync never touches the user's edits.
    send(
        &mux,
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "90"}]}),
        Some("p-3"),
    )
    .unwrap();
    let here = std::env::current_dir().unwrap().canonicalize().unwrap();
    send(&mux, "project.add", json!({"path": here.to_string_lossy()}), Some("p-4")).unwrap();
    let list = read(&mux, "project.list", json!({}));
    assert_eq!(names(&list)[0], "The App", "pinned first");
    assert_eq!(list["projects"].as_array().unwrap().len(), 2);
    assert_eq!(
        read(&mux, "project.list", json!({"query": "the app"}))["projects"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let refused = send(&mux, "project.add", json!({"path": "/"}), Some("p-5")).unwrap_err();
    assert_eq!(refused.code, "validation.invalid");
    assert!(refused.message.starts_with("refused_path"), "{}", refused.message);
    assert_eq!(
        error_code(send(&mux, "project.update", json!({"path": "/srv/none"}), Some("p-6"))),
        "validation.invalid"
    );

    // Removed while a source still reports it: hidden, and the next resync keeps it hidden.
    send(&mux, "project.remove", json!({"path": app}), Some("p-7")).unwrap();
    send(
        &mux,
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "99"}], "complete": true}),
        Some("p-8"),
    )
    .unwrap();
    assert_eq!(read(&mux, "project.list", json!({}))["projects"].as_array().unwrap().len(), 1);
    assert_eq!(
        read(&mux, "project.list", json!({"include_hidden": true}))["projects"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    // The source still reports it, so a missing folder stays present.
    send(&mux, "project.sync", json!({}), Some("p-9")).unwrap();
    let hidden = read(&mux, "project.list", json!({"include_hidden": true}));
    let app_state = hidden["projects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|project| project["path"] == app)
        .unwrap();
    assert_eq!(app_state["state"], "present");

    let kinds: Vec<(String, Value)> = changes_after(&mux, before)
        .into_iter()
        .filter(|change| change["resource"] == "project")
        .map(|change| (change["kind"].as_str().unwrap().to_string(), change["id"].clone()))
        .collect();
    assert_eq!(kinds.first(), Some(&("state_upsert".to_string(), json!(app))));
    assert!(kinds.iter().all(|(kind, _)| kind == "state_upsert"));
}
