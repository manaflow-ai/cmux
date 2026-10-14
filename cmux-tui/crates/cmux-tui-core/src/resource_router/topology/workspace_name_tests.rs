//! `workspace.rename` name provenance on the resource API (hq#1957): an
//! automatic name never replaces a person's, and a stale callback loses.

use super::*;
use crate::SurfaceOptions;
use crate::resource::{RequestEnvelope, RequestId};

fn rename(
    mux: &Arc<Mux>,
    workspace: &str,
    fields: Value,
    key: &str,
) -> Result<Value, ResourceError> {
    dispatch(
        mux,
        ParsedResourceRequest {
            envelope: RequestEnvelope::request(
                RequestId::parse("workspace-name-test").unwrap(),
                ResourceOperation::WorkspaceRename,
                json!({}),
                Some(key.to_string()),
            ),
            selectors: ResourceSelectors {
                machine: Some("current".to_string()),
                session: Some("current".to_string()),
                workspace: Some(workspace.to_string()),
                ..Default::default()
            },
            fields: fields.as_object().unwrap().clone(),
            actor: crate::Actor::local_user(),
        },
    )
}

fn snapshot_workspace(mux: &Arc<Mux>, workspace: &str) -> Value {
    let snapshot = public_session_snapshot(mux).unwrap();
    snapshot["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == workspace)
        .cloned()
        .unwrap()
}

fn auto_fields(mux: &Arc<Mux>, name: &str, revision: &Value) -> Value {
    let (_, generation) = mux.registry_identity();
    json!({
        "name":name, "source":"auto",
        "expected_generation":generation,
        "expected_name_revision":revision,
    })
}

fn created_workspace(mux: &Arc<Mux>) -> String {
    let placement = mux.create_empty_workspace(None, None, None).unwrap();
    mux.with_state(|state| {
        state.workspace_by_key(&placement.key).map(|workspace| workspace.public_id.to_string())
    })
    .unwrap()
}

#[test]
fn workspace_name_source_projects_on_resource_values() {
    let mux = Mux::new_for_test("workspace-name-projection", SurfaceOptions::default());
    let workspace = created_workspace(&mux);
    let created = snapshot_workspace(&mux, &workspace);
    // A daemon-chosen default name belongs to the automatic namer.
    assert_eq!(created["extra"]["name_source"], "auto", "{created}");
    assert_eq!(created["extra"]["name_revision"], "0", "{created}");

    let renamed = rename(&mux, &workspace, json!({"name":"Billing"}), "user-name").unwrap();
    assert_eq!(renamed["value"]["name"], "Billing");
    assert_eq!(renamed["value"]["extra"]["name_source"], "user");
    assert_eq!(renamed["value"]["extra"]["name_revision"], "1");
    let observed = snapshot_workspace(&mux, &workspace);
    assert_eq!(observed["extra"]["name_source"], "user");
    assert_eq!(observed["extra"]["name_revision"], "1");
}

#[test]
fn workspace_name_source_auto_rename_respects_user_names() {
    let mux = Mux::new_for_test("workspace-name-auto", SurfaceOptions::default());
    let workspace = created_workspace(&mux);
    let revision = snapshot_workspace(&mux, &workspace)["extra"]["name_revision"].clone();

    let first =
        rename(&mux, &workspace, auto_fields(&mux, "Fix Login", &revision), "auto-1").unwrap();
    assert_eq!(first["value"]["name"], "Fix Login");
    assert_eq!(first["value"]["extra"]["name_source"], "auto");

    // The same captured revision accepts at most one rename.
    let stale =
        rename(&mux, &workspace, auto_fields(&mux, "Old Topic", &revision), "auto-2").unwrap_err();
    assert_eq!(stale.code, "revision.conflict", "{stale:?}");

    let unversioned =
        rename(&mux, &workspace, json!({"name":"Topic", "source":"auto"}), "auto-3").unwrap_err();
    assert_eq!(unversioned.code, "validation.invalid", "{unversioned:?}");

    let pinned = rename(&mux, &workspace, json!({"name":"Billing"}), "user").unwrap();
    let pinned_revision = pinned["value"]["extra"]["name_revision"].clone();
    let refused =
        rename(&mux, &workspace, auto_fields(&mux, "Fix Login", &pinned_revision), "auto-4");
    assert!(refused.is_err(), "an automatic name cannot replace a person's");
    let latest = snapshot_workspace(&mux, &workspace);
    assert_eq!(latest["name"], "Billing");
    assert_eq!(latest["extra"]["name_source"], "user");
    assert_eq!(latest["extra"]["name_revision"], pinned_revision);
}

/// A person hands a pinned name back to the automatic namer: `source: auto`
/// with `release: true`, no name and no expected revision.
#[test]
fn workspace_name_source_release_returns_a_pinned_name_to_auto() {
    let mux = Mux::new_for_test("workspace-name-release", SurfaceOptions::default());
    let workspace = created_workspace(&mux);
    let pinned = rename(&mux, &workspace, json!({"name":"Billing"}), "pin").unwrap();
    assert_eq!(pinned["value"]["extra"]["name_revision"], "1");

    let released =
        rename(&mux, &workspace, json!({"source":"auto","release":true}), "release").unwrap();
    assert_eq!(released["value"]["name"], "Billing", "a release keeps the text");
    assert_eq!(released["value"]["extra"]["name_source"], "auto");
    assert_eq!(released["value"]["extra"]["name_revision"], "2");

    // The namer may now replace it from the released revision.
    let named =
        rename(&mux, &workspace, auto_fields(&mux, "Fix Login", &json!("2")), "auto").unwrap();
    assert_eq!(named["value"]["name"], "Fix Login");

    let mut auto_without_name = auto_fields(&mux, "", &json!("3"));
    auto_without_name.as_object_mut().unwrap().remove("name");
    for (fields, key) in [
        (json!({"release":true}), "release-user"),
        (json!({"source":"user","release":true}), "release-explicit-user"),
        (json!({"source":"auto","release":true,"name":"Other"}), "release-renames"),
        (auto_without_name, "auto-without-name"),
    ] {
        let error = rename(&mux, &workspace, fields.clone(), key).unwrap_err();
        assert_eq!(error.code, "validation.invalid", "{fields}: {error:?}");
    }
    let latest = snapshot_workspace(&mux, &workspace);
    assert_eq!(latest["name"], "Fix Login");
    assert_eq!(latest["extra"]["name_revision"], "3");
}
