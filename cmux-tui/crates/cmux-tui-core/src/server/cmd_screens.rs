//! Screen and screen-group command handlers: new, select, rename, move,
//! pin, metadata and close screens, and screen groups (create, update, add,
//! remove, move, ungroup, close, save, reopen). Each function is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::new_screen;
use super::screen_group_outcome_json;
use crate::Actor;
use crate::Mux;
use crate::ScreenId;
use crate::WorkspaceId;
use anyhow::Context;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn new_screen(
    mux: &Arc<Mux>,
    client: u64,
    params: new_screen::NewScreenParams,
) -> anyhow::Result<Value> {
    new_screen::new_screen(mux, client, params)
}

pub(super) fn set_screen_metadata(
    mux: &Arc<Mux>,
    actor: Actor,
    screen: ScreenId,
    color: Option<Option<String>>,
    icon: Option<Option<String>>,
) -> anyhow::Result<Value> {
    let changed = mux.set_screen_metadata_as(&actor, screen, color, icon)?;
    let presentation = mux.presentation_snapshot();
    let record = mux
        .with_state(|state| {
            state.workspaces.iter().flat_map(|w| w.screens.iter()).find(|s| s.id == screen).map(
                |s| presentation.screens.screen(s.public_id.as_str()).cloned().unwrap_or_default(),
            )
        })
        .unwrap_or_default();
    Ok(json!({"screen": screen, "color": record.color, "icon": record.icon, "changed": changed}))
}

pub(super) fn set_screen_pinned(
    mux: &Arc<Mux>,
    actor: Actor,
    screen: ScreenId,
    pinned: bool,
) -> anyhow::Result<Value> {
    let (changed, index) = mux.set_screen_pinned_as(&actor, screen, pinned)?;
    Ok(json!({"screen": screen, "pinned": pinned, "index": index, "changed": changed}))
}

pub(super) fn move_screen(
    mux: &Arc<Mux>,
    actor: Actor,
    screen: ScreenId,
    index: Option<usize>,
    workspace: Option<WorkspaceId>,
    new_workspace: bool,
) -> anyhow::Result<Value> {
    let destination = if new_workspace {
        crate::ScreenDestination::NewWorkspace
    } else {
        crate::ScreenDestination::Workspace { workspace, index }
    };
    let outcome = mux.move_screen_as(&actor, screen, destination)?;
    Ok(json!({
        "screen": outcome.screen,
        "workspace": outcome.workspace,
        "key": outcome.key,
        "index": outcome.index,
    }))
}

pub(super) fn create_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    screens: Vec<ScreenId>,
    name: Option<String>,
    color: Option<String>,
) -> anyhow::Result<Value> {
    Ok(screen_group_outcome_json(&mux.create_screen_group_as(&actor, &screens, name, color)?))
}

pub(super) fn update_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    name: Option<String>,
    color: Option<String>,
    collapsed: Option<bool>,
) -> anyhow::Result<Value> {
    Ok(screen_group_outcome_json(
        &mux.update_screen_group_as(&actor, &group, name, color, collapsed)?,
    ))
}

pub(super) fn add_screens_to_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    screens: Vec<ScreenId>,
    index: Option<usize>,
) -> anyhow::Result<Value> {
    Ok(screen_group_outcome_json(
        &mux.add_screens_to_screen_group_as(&actor, &group, &screens, index)?,
    ))
}

pub(super) fn remove_screens_from_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    screens: Vec<ScreenId>,
) -> anyhow::Result<Value> {
    let groups = mux.remove_screens_from_screen_group_as(&actor, &screens)?;
    Ok(json!({ "screens": screens, "groups": groups }))
}

pub(super) fn move_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    index: Option<usize>,
    workspace: Option<WorkspaceId>,
    new_workspace: bool,
) -> anyhow::Result<Value> {
    let destination = if new_workspace {
        crate::ScreenDestination::NewWorkspace
    } else {
        crate::ScreenDestination::Workspace { workspace, index }
    };
    Ok(screen_group_outcome_json(&mux.move_screen_group_as(&actor, &group, destination)?))
}

pub(super) fn ungroup_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
) -> anyhow::Result<Value> {
    let screens = mux.ungroup_screen_group_as(&actor, &group)?;
    Ok(json!({ "group": group, "screens": screens }))
}

pub(super) fn close_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    end_terminals: bool,
) -> anyhow::Result<Value> {
    let closed = mux.close_screen_group_as(&actor, &group, end_terminals)?;
    Ok(json!({ "group": group, "closed": closed }))
}

pub(super) fn list_saved_screen_groups(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    let presentation = mux.presentation_snapshot();
    let groups = presentation
        .saved_screen_groups
        .iter()
        .map(|saved| {
            let open = presentation
                .screens
                .groups
                .values()
                .find(|group| group.saved_id.as_deref() == Some(saved.id.as_str()))
                .map(|group| group.id.clone());
            json!({
                "id": saved.id,
                "name": saved.name,
                "color": saved.color,
                "profile_id": saved.profile_id,
                "members": saved.members,
                "updated_at_ms": saved.updated_at_ms,
                "open_group": open,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "groups": groups }))
}

pub(super) fn save_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
) -> anyhow::Result<Value> {
    let saved = mux.save_screen_group_as(&actor, &group)?;
    let mut value = screen_group_outcome_json(&mux.screen_group_outcome_public(&group));
    value["saved"] = json!(saved);
    Ok(value)
}

pub(super) fn unsave_screen_group(mux: &Arc<Mux>, group: String) -> anyhow::Result<Value> {
    mux.unsave_screen_group(&group)?;
    Ok(screen_group_outcome_json(&mux.screen_group_outcome_public(&group)))
}

pub(super) fn delete_saved_screen_group(mux: &Arc<Mux>, saved: String) -> anyhow::Result<Value> {
    mux.delete_saved_screen_group(&saved)?;
    Ok(json!({}))
}

pub(super) fn reopen_saved_screen_group(
    mux: &Arc<Mux>,
    actor: Actor,
    saved: String,
    workspace: Option<WorkspaceId>,
) -> anyhow::Result<Value> {
    let workspace = match workspace {
        Some(workspace) => workspace,
        None => mux
            .with_state(|state| state.workspaces.get(state.active_workspace).map(|w| w.id))
            .context("no workspace to reopen the screen group into")?,
    };
    Ok(screen_group_outcome_json(&mux.reopen_saved_screen_group_as(&actor, &saved, workspace)?))
}

pub(super) fn close_screen(
    mux: &Arc<Mux>,
    actor: Actor,
    screen: ScreenId,
    end_terminals: bool,
) -> anyhow::Result<Value> {
    if end_terminals {
        mux.close_container_ending_terminals_as(&actor, crate::BatchCloseTarget::Screen(screen))?;
    } else if !mux.close_screen_as(&actor, screen)? {
        anyhow::bail!("unknown screen {screen}");
    }
    Ok(json!({}))
}

pub(super) fn rename_screen(
    mux: &Arc<Mux>,
    actor: Actor,
    screen: ScreenId,
    name: String,
) -> anyhow::Result<Value> {
    if !mux.rename_screen_as(&actor, screen, name) {
        anyhow::bail!("unknown screen {screen}");
    }
    Ok(json!({}))
}

pub(super) fn select_screen(
    mux: &Arc<Mux>,
    actor: Actor,
    index: Option<usize>,
    delta: Option<isize>,
) -> anyhow::Result<Value> {
    mux.select_screen_as(&actor, index, delta);
    Ok(json!({}))
}
