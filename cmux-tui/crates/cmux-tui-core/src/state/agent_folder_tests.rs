//! `workspace.agent_folder.set` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the
//! folder new agent chats of a workspace start in, set by the user, carried
//! as `extra.agent_folder` on every workspace snapshot, durable across a
//! restart. Origin rules are in `server/origin_gate_tests.rs`.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::tests::{Session, changes_after, empty_workspace, error_code, mutate, revision, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// A fresh canonical directory (the temp dir itself may be a symlink, as
/// `/var` is on macOS).
fn folder(name: &str) -> (PathBuf, String) {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-folder-{name}-{}", WorkspacePublicId::random().unwrap()));
    std::fs::create_dir_all(root.join("project")).unwrap();
    let canonical = std::fs::canonicalize(root.join("project")).unwrap();
    let text = canonical.to_str().unwrap().to_string();
    (root, text)
}

fn listed(mux: &Arc<Mux>, workspace: &str) -> Value {
    super::tests::snapshot(mux)["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == workspace)
        .cloned()
        .unwrap()
}

#[test]
fn agent_folder_round_trips_through_result_snapshot_events_replay_and_restart() {
    let (root, path) = folder("round-trip");
    let session = Session::new("agent-folder");
    let workspace = {
        let mux = session.open();
        let workspace = empty_workspace(&mux, "home-ish");
        assert!(listed(&mux, &workspace)["extra"].get("agent_folder").is_none());
        let before = revision(&mux);
        let params = json!({"workspace": workspace, "path": path});
        let set = mutate(&mux, "workspace.agent_folder.set", params.clone(), "folder-1");
        assert_eq!(set["id"], workspace);
        assert_eq!(set["extra"]["agent_folder"], path);
        assert_eq!(listed(&mux, &workspace)["extra"]["agent_folder"], path);
        assert!(changes_after(&mux, before).iter().any(|change| change["resource"] == "workspace"
            && change["value"]["extra"]["agent_folder"] == path));
        let replay = send(&mux, "workspace.agent_folder.set", params, Some("folder-1")).unwrap();
        assert_eq!(replay["replayed"], true);
        // A rename restates the workspace with its folder.
        let renamed = mutate(
            &mux,
            "workspace.rename",
            json!({"workspace": workspace, "name": "renamed"}),
            "rename-1",
        );
        assert_eq!(renamed["extra"]["agent_folder"], path);
        workspace
    };
    // Saved with the workspace state: it survives a restart.
    let mux = session.open();
    assert_eq!(listed(&mux, &workspace)["extra"]["agent_folder"], path);
    let cleared = mutate(
        &mux,
        "workspace.agent_folder.set",
        json!({"workspace": workspace, "path": null}),
        "folder-2",
    );
    assert!(cleared["extra"].get("agent_folder").is_none());
    assert!(listed(&mux, &workspace)["extra"].get("agent_folder").is_none());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn agent_folder_must_be_an_absolute_existing_canonical_directory() {
    let (root, path) = folder("invalid");
    let mux = Mux::new_for_test("agent-folder-invalid", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "w");
    let file = Path::new(&path).join("file.txt");
    std::fs::write(&file, b"x").unwrap();
    let link = Path::new(&path).parent().unwrap().join("link");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    let invalid = [
        json!("relative/dir"),
        json!(""),
        json!(format!("{path}/missing")),
        json!(file.to_str().unwrap()),
        // Not canonical: a symlink, a `..` step, a trailing slash.
        json!(link.to_str().unwrap()),
        json!(format!("{path}/../project")),
        json!(format!("{path}/")),
        json!(format!("{path}\u{0}x")),
        json!(42),
    ];
    for (index, value) in invalid.into_iter().enumerate() {
        let result = send(
            &mux,
            "workspace.agent_folder.set",
            json!({"workspace": workspace, "path": value}),
            Some(&format!("bad-{index}")),
        );
        assert_eq!(error_code(result), "validation.invalid", "{value}");
    }
    // `path` is required: null clears, an absent field is refused.
    assert_eq!(
        error_code(send(
            &mux,
            "workspace.agent_folder.set",
            json!({"workspace": workspace}),
            Some("missing-path")
        )),
        "validation.invalid"
    );
    // The canonical folder itself is accepted.
    let set = mutate(
        &mux,
        "workspace.agent_folder.set",
        json!({"workspace": workspace, "path": path}),
        "good-1",
    );
    assert_eq!(set["extra"]["agent_folder"], path);
    let _ = std::fs::remove_dir_all(root);
}
