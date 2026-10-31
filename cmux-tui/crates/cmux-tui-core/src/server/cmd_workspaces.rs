//! Workspace command handlers: create, close, rename, move, select, pin,
//! metadata, provider-managed workspaces, and workspace groups. Each
//! function is one `Command` arm of `handle_command_with_cancellation`.

use super::workspace_group_json;
use super::workspace_groups_json;
use crate::panic_free::JsonFields;

use super::MutationRequest;
use super::list_workspaces_reply;
use super::optional_surface_size;
use super::personal;
use super::workspace_mutation;
use super::zeroize_string;
use crate::Actor;
use crate::Mux;
use crate::WorkspaceId;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn list_workspaces(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    list_workspaces_reply(mux)
}

pub(super) fn new_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    name: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Value> {
    let surface = mux.new_workspace_as(&actor, name, optional_surface_size(cols, rows))?;
    Ok(json!({ "surface": surface.id }))
}

/// The client's placement of a new workspace (`create-workspace {places_by_setting, current,
/// placement}`), or None when it names none. A current workspace that is no workspace key counts as
/// none; an unknown placement value leaves this daemon's settings file to decide.
pub(super) fn client_placement(
    places_by_setting: bool,
    current: Option<String>,
    placement: Option<String>,
) -> Option<crate::state::personal_order::ClientCurrent> {
    let current = current.filter(|key| crate::workspace_registry::is_canonical_workspace_key(key));
    let placement =
        placement.as_deref().and_then(crate::user_settings::NewWorkspacePlacement::from_name);
    let named = places_by_setting || current.is_some();
    named.then_some(crate::state::personal_order::ClientCurrent { current, placement })
}

pub(super) fn create_workspace(
    mux: &Arc<Mux>,
    client: u64,
    name: Option<String>,
    key: Option<String>,
    placed_by: Option<crate::state::personal_order::ClientCurrent>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    if let Some(key) = key.as_deref()
        && !crate::workspace_registry::is_canonical_workspace_key(key)
    {
        anyhow::bail!("workspace key must be a lowercase UUID");
    }
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let placement = crate::state::personal_order::with_client_current(placed_by, || {
        mux.create_empty_workspace_with_mutation(
            name,
            key,
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
        )
    })?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": placement.workspace,
        "key": placement.key,
        "index": placement.index,
        "workspace_revision": placement.revision,
        "replayed": placement.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

pub(super) fn move_workspace(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    index: usize,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.move_workspace_with_mutation(
        workspace,
        key.as_deref(),
        index,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": result.workspace,
        "key": result.key,
        "index": result.index,
        "workspace_revision": result.revision,
        "changed": result.changed,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn set_workspace_metadata(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    color: Option<Option<String>>,
    icon: Option<Option<String>>,
    title: Option<Option<String>>,
    pinned: Option<bool>,
    marked_unread: Option<bool>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let update = crate::workspace_registry::WorkspacePresentationUpdate {
        group: None,
        color,
        icon,
        title,
        pinned,
        marked_unread,
        ..Default::default()
    };
    let result = mux.set_workspace_metadata(
        workspace,
        key.as_deref(),
        update,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let presentation = mux.presentation_snapshot();
    let record = presentation.workspace(&result.key).cloned().unwrap_or_default();
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": result.workspace,
        "key": result.key,
        "color": record.color,
        "icon": record.icon,
        "title": record.title,
        "pinned": record.pinned,
        "marked_unread": record.marked_unread,
        "workspace_revision": result.revision,
        "changed": result.changed,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

pub(super) fn pin_workspace(
    mux: &Arc<Mux>,
    session_id: String,
    workspace_key: String,
    profile: String,
) -> anyhow::Result<Value> {
    personal::pin_workspace(mux, &session_id, &workspace_key, &profile)
}

pub(super) fn unpin_workspace(
    mux: &Arc<Mux>,
    session_id: String,
    workspace_key: String,
) -> anyhow::Result<Value> {
    personal::unpin_workspace(mux, &session_id, &workspace_key)
}

pub(super) fn list_workspace_groups(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    Ok(json!({ "groups": workspace_groups_json(&mux.presentation_snapshot()) }))
}

pub(super) fn create_workspace_group(
    mux: &Arc<Mux>,
    name: String,
    group: Option<String>,
    color: Option<String>,
    collapsed: bool,
    index: Option<usize>,
) -> anyhow::Result<Value> {
    let change = mux.create_workspace_group(group, name, color, collapsed, index)?;
    Ok(json!({
        "group": workspace_group_json(&change.group, change.index),
        "changed": change.changed,
    }))
}

pub(super) fn update_workspace_group(
    mux: &Arc<Mux>,
    group: String,
    name: Option<String>,
    color: Option<Option<String>>,
    collapsed: Option<bool>,
) -> anyhow::Result<Value> {
    let change = mux.update_workspace_group(&group, name, color, collapsed)?;
    Ok(json!({
        "group": workspace_group_json(&change.group, change.index),
        "changed": change.changed,
    }))
}

pub(super) fn delete_workspace_group(mux: &Arc<Mux>, group: String) -> anyhow::Result<Value> {
    let ungrouped = mux.delete_workspace_group(&group)?;
    Ok(json!({ "group": group, "ungrouped_keys": ungrouped }))
}

pub(super) fn move_workspace_group(
    mux: &Arc<Mux>,
    group: String,
    index: usize,
) -> anyhow::Result<Value> {
    let change = mux.move_workspace_group(&group, index)?;
    Ok(json!({
        "group": workspace_group_json(&change.group, change.index),
        "changed": change.changed,
    }))
}

pub(super) fn move_workspace_to_group(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    group: Option<String>,
    index: Option<usize>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.move_workspace_to_group(
        workspace,
        key.as_deref(),
        group.clone(),
        index,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": result.workspace,
        "key": result.key,
        "index": result.index,
        "group": group,
        "workspace_revision": result.revision,
        "changed": result.changed,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

/// How `close-workspace` ends: `terminals` also ends its terminals (`batch-close-v1`), and a
/// `reason` (`close-reason-v1`, only with `terminals`) keeps the close out of closed history.
/// `if_empty` (`close-workspace-if-empty-v1`) closes only a workspace with no tab.
pub(super) struct Ending {
    pub terminals: bool,
    pub reason: Option<crate::mux::CloseReason>,
    pub if_empty: bool,
    /// With `terminals`: answer `closed_ids` (opt-in, version skew).
    pub report_closed_ids: bool,
}

pub(super) fn close_workspace(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    ending: Ending,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    if ending.reason.is_some() && !ending.terminals {
        anyhow::bail!("bad request: close-workspace takes a reason only with end_terminals");
    }
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let (result, closed_ids) = if ending.terminals {
        let (result, outcome) = mux.close_workspace_ending_terminals_for(
            workspace,
            key.as_deref(),
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
            ending.reason,
            ending.if_empty,
        )?;
        let ids = outcome.result.get("closed_ids").filter(|_| ending.report_closed_ids);
        (result, ids.cloned())
    } else {
        let result = mux.close_workspace_with_mutation_guarded(
            workspace,
            key.as_deref(),
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
            ending.if_empty,
        )?;
        (result, None)
    };
    let (registry_id, generation) = mux.registry_identity();
    let mut reply = json!({
        "workspace": result.workspace,
        "key": result.key,
        "index": result.index,
        "workspace_revision": result.revision,
        "changed": result.changed,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    });
    // With `end_terminals` and `report_closed_ids`: the closed groups this
    // close stored, oldest first.
    if let Some(ids) = closed_ids {
        reply.insert("closed_ids", ids);
    }
    Ok(reply)
}

pub(super) fn mark_workspaces_provider_managed(
    mux: &Arc<Mux>,
    authority: String,
) -> anyhow::Result<Value> {
    authorize_provider_workspace_command(mux, authority)?;
    Ok(json!({}))
}

pub(super) fn close_provider_managed_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    workspace: WorkspaceId,
    key: String,
    authority: String,
) -> anyhow::Result<Value> {
    let Some(revision) = with_provider_workspace_authority(authority, |authority| {
        mux.close_provider_managed_workspace_authorized(&actor, workspace, &key, authority)
    })?
    else {
        anyhow::bail!("unknown provider-managed workspace selector");
    };
    Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
}

/// Workspace name provenance (hq#1957): `source`, `expected_generation` and
/// `expected_name_revision` on `rename-workspace` and `workspace.rename`, and
/// `name_source`/`name_revision` on every workspace (`extra` in resource
/// snapshots). An automatic rename never replaces a user name.
pub const WORKSPACE_NAME_SOURCE_CAPABILITY: &str = "workspace-name-source-v1";

/// The `rename-workspace` fields besides the mutation envelope.
#[derive(serde::Deserialize)]
pub(super) struct WorkspaceRenameRequest {
    #[serde(default)]
    pub(super) workspace: Option<WorkspaceId>,
    #[serde(default)]
    pub(super) key: Option<String>,
    pub(super) name: String,
    /// `workspace-name-source-v1`: who chose the name (absent = `user`).
    #[serde(default)]
    pub(super) source: Option<crate::resource_name::NameSource>,
    /// `workspace-name-source-v1`: the decimal name revision an automatic
    /// rename read; required with `source: auto`.
    #[serde(default)]
    pub(super) expected_name_revision: Option<String>,
    /// `workspace-name-source-v1`: with `source: auto`, hand the current name
    /// (`name` must equal it) back to the automatic namer.
    #[serde(default)]
    pub(super) release: bool,
}

pub(super) fn rename_workspace(
    mux: &Arc<Mux>,
    client: u64,
    request: WorkspaceRenameRequest,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let WorkspaceRenameRequest { workspace, key, name, source, expected_name_revision, release } =
        request;
    let name_revision = expected_name_revision
        .as_deref()
        .map(crate::resource_name::parse_name_revision)
        .transpose()
        .map_err(|error| anyhow::anyhow!("bad request: expected_name_revision: {error}"))?;
    let name_authority = crate::resource_name::WorkspaceNameUpdate::from_request(
        source,
        mutation.expected_generation.clone(),
        name_revision,
        release,
    )?;
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.rename_workspace_with_name_authority(
        workspace,
        key.as_deref(),
        name,
        &name_authority,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": result.workspace,
        "key": result.key,
        "index": result.index,
        "workspace_revision": result.revision,
        "changed": result.changed,
        "replayed": result.replayed,
        "registry_id": registry_id,
        "generation": generation,
    }))
}

pub(super) fn rename_provider_managed_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    workspace: WorkspaceId,
    key: String,
    name: String,
    authority: String,
) -> anyhow::Result<Value> {
    let Some(revision) = with_provider_workspace_authority(authority, |authority| {
        mux.rename_provider_managed_workspace_authorized(&actor, workspace, &key, name, authority)
    })?
    else {
        anyhow::bail!("unknown provider-managed workspace selector");
    };
    Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
}

pub(super) fn select_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    index: Option<usize>,
    delta: Option<isize>,
) -> anyhow::Result<Value> {
    mux.select_workspace_as(&actor, index, delta);
    Ok(json!({}))
}

fn authorize_provider_workspace_command(mux: &Mux, mut authority: String) -> anyhow::Result<()> {
    let result = mux.authorize_provider_workspace_authority(&authority);
    zeroize_string(&mut authority);
    result
}

fn with_provider_workspace_authority<T>(
    mut authority: String,
    operation: impl FnOnce(&str) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let result = operation(&authority);
    zeroize_string(&mut authority);
    result
}
