//! Raw protocol handlers for browser profile records in the home session's
//! personal state (`browser-profiles-v1`, plans/cmux-next/data-model.md
//! section 5). Every change emits `personal-changed`; deleting a profile
//! that had bookmarks also emits `bookmarks-changed`.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::{BrowserProfileInput, BrowserProfileUpdate};

/// `create-browser-profile`. A caller-chosen `browser_profile` id makes a
/// retry return the stored record.
#[derive(Deserialize)]
pub(super) struct CreateParams {
    name: String,
    #[serde(default)]
    browser_profile: Option<String>,
    #[serde(default)]
    color: Option<String>,
    #[serde(default)]
    icon: Option<String>,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    source: Option<Value>,
}

/// `update-browser-profile`. An absent field is unchanged; JSON null clears
/// it.
#[derive(Deserialize)]
pub(super) struct UpdateParams {
    browser_profile: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    color: Option<Option<String>>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    icon: Option<Option<String>>,
}

/// `move-browser-profile`: an insertion index among browser profiles.
#[derive(Deserialize)]
pub(super) struct MoveParams {
    browser_profile: String,
    index: usize,
}

/// `delete-browser-profile` (not `default`): clears the workspace and room
/// defaults that name it and deletes its bookmarks.
#[derive(Deserialize)]
pub(super) struct DeleteParams {
    browser_profile: String,
}

pub(super) fn create(mux: &Mux, params: CreateParams) -> anyhow::Result<Value> {
    let input = BrowserProfileInput {
        id: params.browser_profile,
        name: params.name,
        color: params.color,
        icon: params.icon,
        index: params.index,
        source: params.source,
    };
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.create_browser_profile(input))?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn update(mux: &Mux, params: UpdateParams) -> anyhow::Result<Value> {
    let update = BrowserProfileUpdate { name: params.name, color: params.color, icon: params.icon };
    let (profile, changed) = mux.personal_mutation(|registry| {
        registry.update_browser_profile(&params.browser_profile, update)
    })?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn move_to(mux: &Mux, params: MoveParams) -> anyhow::Result<Value> {
    let (profile, changed) = mux.personal_mutation(|registry| {
        registry.move_browser_profile(&params.browser_profile, params.index)
    })?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn delete(mux: &Mux, params: DeleteParams) -> anyhow::Result<Value> {
    let id = params.browser_profile.as_str();
    let (deletion, _) =
        mux.personal_mutation(|registry| Ok((registry.delete_browser_profile(id)?, true)))?;
    if let Some(revision) = deletion.bookmarks_revision {
        mux.emit_bookmarks_changed(id.to_string(), revision);
    }
    let workspaces = deletion
        .cleared_workspaces
        .iter()
        .map(|(session_id, workspace_key)| {
            json!({"session_id": session_id, "workspace_key": workspace_key})
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "browser_profile": id,
        "cleared_workspaces": workspaces,
        "cleared_rooms": deletion.cleared_rooms,
        "deleted_bookmarks": deletion.deleted_bookmarks,
    }))
}
