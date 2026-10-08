//! Raw protocol handlers for the home session's personal state
//! (`profiles-v1`, plans/cmux-next/data-model.md section 3). Rooms are
//! `profile` on the wire. Every change emits `personal-changed`.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::{PersonalWorkspaceUpdate, ProfileInput, ProfileUpdate};

/// One group of `import-session-organization`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportedGroup {
    id: String,
    name: String,
    #[serde(default)]
    color: Option<String>,
    #[serde(default)]
    collapsed: bool,
}

/// One workspace of `import-session-organization`, in sidebar order.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportedWorkspace {
    workspace_key: String,
    #[serde(default)]
    group: Option<String>,
}

fn pairs(values: &[(String, String)]) -> Value {
    json!(
        values
            .iter()
            .map(|(session_id, workspace_key)| json!({"session_id": session_id, "workspace_key": workspace_key}))
            .collect::<Vec<_>>()
    )
}

pub(super) fn list(mux: &Mux) -> anyhow::Result<Value> {
    Ok(serde_json::to_value(mux.personal_snapshot()?)?)
}

pub(super) fn create_profile(mux: &Mux, input: ProfileInput) -> anyhow::Result<Value> {
    let (profile, changed) = mux.personal_mutation(|registry| registry.create_profile(input))?;
    Ok(json!({"profile": profile, "changed": changed}))
}

pub(super) fn update_profile(mux: &Mux, id: &str, update: ProfileUpdate) -> anyhow::Result<Value> {
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.update_profile(id, update))?;
    Ok(json!({"profile": profile, "changed": changed}))
}

pub(super) fn move_profile(mux: &Mux, id: &str, index: usize) -> anyhow::Result<Value> {
    let (profile, changed) = mux.personal_mutation(|registry| registry.move_profile(id, index))?;
    Ok(json!({"profile": profile, "changed": changed}))
}

/// Delete a room. Without `move_to` this is Delete Space: the shared path
/// closes its workspaces as one reopenable group (`closed_id`,
/// SPACE-DELETE-CLOSES-ITS-WORKSPACES); with `move_to` its pins and groups
/// move there.
pub(super) fn delete_profile(mux: &Mux, id: &str, move_to: Option<&str>) -> anyhow::Result<Value> {
    if move_to.is_none() {
        let closed_id = crate::state::closed_history_store::new_closed_id();
        let mutation = crate::WorkspaceMutation::local("delete-profile");
        let fingerprint = json!({"operation": "delete-profile", "profile": id});
        let deleted =
            mux.state_room_delete(&mutation, "room.delete", &fingerprint, None, id, &closed_id)?;
        return Ok(json!({
            "profile": id,
            "moved_to": null,
            "unpinned": pairs(&deleted.unpinned),
            "closed_id": closed_id,
        }));
    }
    let (deletion, _) =
        mux.personal_mutation(|registry| Ok((registry.delete_profile(id, move_to)?, true)))?;
    Ok(json!({"profile": id, "moved_to": deletion.moved_to, "unpinned": pairs(&deletion.unpinned)}))
}

pub(super) fn set_profile_follows(
    mux: &Mux,
    id: &str,
    sessions: &[String],
) -> anyhow::Result<Value> {
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.set_profile_follows(id, sessions))?;
    Ok(json!({"profile": profile, "changed": changed}))
}

pub(super) fn pin_workspace(
    mux: &Mux,
    session: &str,
    key: &str,
    profile: &str,
) -> anyhow::Result<Value> {
    let ((), changed) = mux.personal_mutation(|registry| {
        let changed = registry.pin_workspace(session, key, profile)?;
        Ok(((), changed))
    })?;
    Ok(json!({"changed": changed}))
}

pub(super) fn unpin_workspace(mux: &Mux, session: &str, key: &str) -> anyhow::Result<Value> {
    let ((), changed) =
        mux.personal_mutation(|registry| Ok(((), registry.unpin_workspace(session, key)?)))?;
    Ok(json!({"changed": changed}))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn put_session(
    mux: &Mux,
    session: &str,
    machine_name: Option<&str>,
    session_name: Option<&str>,
    transport: &Value,
    capabilities: Option<&Value>,
    follow_with: Option<&str>,
) -> anyhow::Result<Value> {
    let ((record, created), _) = mux.personal_mutation(|registry| {
        let result = registry.put_session(
            session,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        )?;
        Ok((result, true))
    })?;
    Ok(json!({"session": record, "created": created}))
}

pub(super) fn forget_session(mux: &Mux, session: &str, force: bool) -> anyhow::Result<Value> {
    let ((), changed) =
        mux.personal_mutation(|registry| Ok(((), registry.forget_session(session, force)?)))?;
    Ok(json!({"changed": changed}))
}

pub(super) fn import_session_organization(
    mux: &Mux,
    session: &str,
    groups: Vec<Value>,
    workspaces: Vec<Value>,
) -> anyhow::Result<Value> {
    let groups = groups
        .into_iter()
        .map(serde_json::from_value::<ImportedGroup>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| anyhow::anyhow!("bad request: invalid group: {error}"))?
        .into_iter()
        .map(|group| (group.id, group.name, group.color, group.collapsed))
        .collect::<Vec<_>>();
    let workspaces = workspaces
        .into_iter()
        .map(serde_json::from_value::<ImportedWorkspace>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| anyhow::anyhow!("bad request: invalid workspace: {error}"))?;
    let workspaces = workspaces
        .into_iter()
        .map(|workspace| (workspace.workspace_key, workspace.group))
        .collect::<Vec<_>>();
    let ((), imported) = mux.personal_mutation(|registry| {
        Ok(((), registry.import_session_organization(session, &groups, &workspaces)?))
    })?;
    Ok(json!({"imported": imported}))
}

pub(super) fn create_group(
    mux: &Mux,
    id: Option<String>,
    profile: Option<&str>,
    name: &str,
    color: Option<&str>,
    collapsed: bool,
    index: Option<usize>,
) -> anyhow::Result<Value> {
    let (group, changed) = mux.personal_mutation(|registry| {
        registry.create_personal_group(id, profile, name, color, collapsed, index)
    })?;
    Ok(json!({"group": group, "changed": changed}))
}

pub(super) fn update_group(
    mux: &Mux,
    id: &str,
    name: Option<&str>,
    color: Option<Option<String>>,
    collapsed: Option<bool>,
    profile: Option<&str>,
) -> anyhow::Result<Value> {
    let (group, changed) = mux.personal_mutation(|registry| {
        registry.update_personal_group(
            id,
            name,
            color.as_ref().map(Option::as_deref),
            collapsed,
            profile,
        )
    })?;
    Ok(json!({"group": group, "changed": changed}))
}

/// The same delete as `workspace_group.delete` (one closed-history record,
/// so Reopen Closed forms the group again); the raw result shape stays.
pub(super) fn delete_group(mux: &Mux, id: &str) -> anyhow::Result<Value> {
    let commit = mux.state_personal(
        &crate::WorkspaceMutation::local("delete-personal-group"),
        "workspace_group.delete",
        None,
        &Mux::ordinary_resource_selectors(),
        crate::state::personal::PersonalChange::GroupDelete { group: id.to_string() },
    )?;
    let ungrouped = commit.result["ungrouped"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|workspace| {
            json!({
                "session_id": workspace["session_id"],
                "workspace_key": workspace["workspace_ref"],
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({"group": id, "ungrouped": ungrouped}))
}

pub(super) fn move_group(mux: &Mux, id: &str, index: usize) -> anyhow::Result<Value> {
    let (group, changed) =
        mux.personal_mutation(|registry| registry.move_personal_group(id, index))?;
    Ok(json!({"group": group, "changed": changed}))
}

pub(super) fn set_workspace(
    mux: &Mux,
    session: &str,
    key: &str,
    update: PersonalWorkspaceUpdate,
) -> anyhow::Result<Value> {
    let (workspace, changed) =
        mux.personal_mutation(|registry| registry.set_personal_workspace(session, key, update))?;
    Ok(json!({"workspace": workspace, "changed": changed}))
}

pub(super) fn set_terminal(
    mux: &Mux,
    session: &str,
    key: &str,
    theme: Option<&str>,
) -> anyhow::Result<Value> {
    let (terminal, changed) =
        mux.personal_mutation(|registry| registry.set_personal_terminal(session, key, theme))?;
    Ok(json!({"terminal": terminal, "changed": changed}))
}
