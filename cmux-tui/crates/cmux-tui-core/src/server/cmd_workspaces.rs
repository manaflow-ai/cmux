//! Workspace command handlers: create, close, rename, move, select, pin,
//! metadata, provider-managed workspaces, and workspace groups. Each
//! function is one `Command` arm of `handle_command_with_cancellation`.

use super::workspace_group_json;
use super::workspace_groups_json;

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

pub(super) fn create_workspace(
    mux: &Arc<Mux>,
    client: u64,
    name: Option<String>,
    key: Option<String>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    if let Some(key) = key.as_deref()
        && !crate::workspace_registry::is_canonical_workspace_key(key)
    {
        anyhow::bail!("workspace key must be a lowercase UUID");
    }
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let placement = mux.create_empty_workspace_with_mutation(
        name,
        key,
        mutation.expected_generation.as_deref(),
        mutation.expected_revision,
        &workspace_mutation,
    )?;
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

pub(super) fn close_workspace(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    end_terminals: bool,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = if end_terminals {
        mux.close_workspace_ending_terminals(
            workspace,
            key.as_deref(),
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
        )?
        .0
    } else {
        mux.close_workspace_with_mutation(
            workspace,
            key.as_deref(),
            mutation.expected_generation.as_deref(),
            mutation.expected_revision,
            &workspace_mutation,
        )?
    };
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

pub(super) fn rename_workspace(
    mux: &Arc<Mux>,
    client: u64,
    workspace: Option<WorkspaceId>,
    key: Option<String>,
    name: String,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
    let result = mux.rename_workspace_with_mutation(
        workspace,
        key.as_deref(),
        name,
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
