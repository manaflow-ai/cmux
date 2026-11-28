//! Existing workspace identities and partial scans must not cause duplicates
//! or take away the original Conductor import.

use super::*;

fn open_at(mux: &Arc<Mux>, path: &Path) -> String {
    let key = open_workspace(mux);
    let id = mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .find(|workspace| workspace.key == key)
            .unwrap()
            .public_id
            .to_string()
    });
    mux.write_registry_meta(|transaction| {
        transaction.execute(
            "INSERT INTO workspace_agent_folder(workspace_id, path) VALUES(?1, ?2)",
            rusqlite::params![id, path.to_str().unwrap()],
        )?;
        Ok(())
    })
    .unwrap();
    key
}

#[test]
fn conductor_import_existing_folder_is_unchecked_without_a_ledger() {
    let mux = Mux::new_for_test("agent-import-open-folder", SurfaceOptions::default());
    let home = home();
    let folder = home.0.join("conductor/workspaces/app/lima");
    let child = folder.join("src");
    std::fs::create_dir(&child).unwrap();
    let key = open_at(&mux, &child);
    assert!(stored_ledger(&mux).is_none());
    let workspace = lima(&plan(&mux, &home));
    assert_eq!(workspace["checked"], false);
    assert_eq!(
        workspace["disposition"],
        json!({"kind": "already-imported", "cmux_workspace": key})
    );
    assert!(stored_ledger(&mux).is_none(), "planning must remain read-only");
}

#[test]
fn conductor_import_pending_folder_still_replaces_its_partial_workspace() {
    let mux = Mux::new_for_test("agent-import-pending-folder", SurfaceOptions::default());
    let home = home();
    let key = open_at(&mux, &home.0.join("conductor/workspaces/app/lima"));
    mutate(
        &mux,
        "conductor_import.record",
        json!({
            "workspace": "w-lima", "stage": "pending", "cmux_workspace": key
        }),
        "partial-folder",
    );
    let result = plan(&mux, &home);
    assert_eq!(result["plan"]["cleanup"], json!([key]));
    assert_eq!(lima(&result)["disposition"]["kind"], "adopt");
    assert_eq!(lima(&result)["checked"], true);
}

#[test]
fn conductor_import_source_limit_preserves_conductor_with_visible_warning() {
    use cmux_conductor_import::{catalog::MAX_ROWS, tools::AdapterKind};

    let mux = Mux::new_for_test("agent-import-fallback", SurfaceOptions::default());
    let home = home();
    let sources: serde_json::Map<String, Value> = AdapterKind::ALL
        .iter()
        .map(|tool| (tool.id().into(), json!({"first_seen_ms": 1, "last_used_ms": 2})))
        .collect();
    mux.write_registry_meta(|transaction| {
        for index in 0..=(MAX_ROWS / AdapterKind::ALL.len()) {
            let path = format!("/missing-import-fixture/{index}");
            let project = json!({"path": path, "sources": sources, "state": "present"});
            transaction.execute(
                "INSERT INTO projects(path, project_json) VALUES(?1, ?2)",
                rusqlite::params![path, project.to_string()],
            )?;
        }
        Ok(())
    })
    .unwrap();
    let result = plan(&mux, &home);
    assert_eq!(lima(&result)["disposition"]["kind"], "adopt");
    let warning = result["plan"]["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|warning| warning["code"] == "agent-source-scan-failed")
        .unwrap();
    assert_eq!(warning["detail"], format!("agent import has more than {MAX_ROWS} source rows"));
    let absent = mux.conductor_import_plan(Some(&home.0.join("empty-home"))).unwrap();
    assert!(absent["plan"].is_null());
    assert_eq!(absent["error"], warning["detail"]);
}
