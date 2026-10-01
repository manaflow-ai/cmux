//! Raw protocol handlers for browser profile records in the home session's
//! personal state (`browser-profiles-v1`, plans/cmux-next/data-model.md
//! section 5). Every change emits `personal-changed`.

use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::{BrowserProfileInput, BrowserProfileUpdate};

pub(super) fn create(mux: &Mux, input: BrowserProfileInput) -> anyhow::Result<Value> {
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.create_browser_profile(input))?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn update(mux: &Mux, id: &str, update: BrowserProfileUpdate) -> anyhow::Result<Value> {
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.update_browser_profile(id, update))?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn move_to(mux: &Mux, id: &str, index: usize) -> anyhow::Result<Value> {
    let (profile, changed) =
        mux.personal_mutation(|registry| registry.move_browser_profile(id, index))?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn delete(mux: &Mux, id: &str) -> anyhow::Result<Value> {
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
