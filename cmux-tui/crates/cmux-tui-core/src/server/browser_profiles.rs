//! Raw protocol handlers for browser profile records in the home session's
//! personal state (`browser-profiles-v1`, plans/cmux-next/data-model.md
//! section 5). Every change emits `personal-changed`; deleting a profile
//! that had bookmarks also emits `bookmarks-changed`.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::resource::{BrowserPublicId, ContentPublicId};
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
    /// The proxy (#24432); null makes the profile direct again.
    #[serde(default, deserialize_with = "super::present_nullable")]
    proxy: Option<Option<Value>>,
}

/// `move-browser-profile`: an insertion index among browser profiles.
#[derive(Deserialize)]
pub(super) struct MoveParams {
    browser_profile: String,
    index: usize,
}

/// `delete-browser-profile` (not `default`, verified app connection only):
/// clears the workspace and room defaults that name it and deletes its
/// bookmarks.
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
    let update = BrowserProfileUpdate {
        name: params.name,
        color: params.color,
        icon: params.icon,
        proxy: params.proxy,
    };
    // Resolve the id or exact name under the same registry lock as the update.
    let (profile, changed) = mux.personal_mutation(|registry| {
        let browser_profile = registry.resolve_browser_profile_id(&params.browser_profile)?;
        registry.update_browser_profile(&browser_profile, update)
    })?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

pub(super) fn move_to(mux: &Mux, params: MoveParams) -> anyhow::Result<Value> {
    // Resolve the id or exact name under the same registry lock as the move.
    let (profile, changed) = mux.personal_mutation(|registry| {
        let browser_profile = registry.resolve_browser_profile_id(&params.browser_profile)?;
        registry.move_browser_profile(&browser_profile, params.index)
    })?;
    Ok(json!({"browser_profile": profile, "changed": changed}))
}

/// A `delete-browser-profile` from a connection that is not the verified
/// cmux app (an agent, a script, the CLI, a page relay): only the person
/// deletes a browser profile and its data, through the app (Settings, the
/// palette, the menu), which asks first.
#[derive(Debug)]
pub(super) struct DeleteNeedsPerson;

impl std::fmt::Display for DeleteNeedsPerson {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "only a person deletes a browser profile, in the cmux app: {}",
            crate::request_origin::NEEDS_VERIFIED_APP
        )
    }
}

impl std::error::Error for DeleteNeedsPerson {}

/// The wire code of a [`DeleteNeedsPerson`] refusal (`origin.forbidden`).
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error
        .downcast_ref::<DeleteNeedsPerson>()
        .map(|_| crate::request_origin::ORIGIN_FORBIDDEN.to_string())
}

pub(super) fn delete(mux: &Mux, client: u64, params: DeleteParams) -> anyhow::Result<Value> {
    if !super::origin_gate::is_user(mux, client) {
        return Err(DeleteNeedsPerson.into());
    }
    // Resolve the id or exact name under the same registry lock as the delete.
    let ((id, deletion), _) = mux.personal_mutation(|registry| {
        let id = registry.resolve_browser_profile_id(&params.browser_profile)?;
        let deletion = registry.delete_browser_profile(&id)?;
        if !deletion.cleared_browsers.is_empty() {
            mux.reload_presentation(registry)?;
        }
        Ok(((id, deletion), true))
    })?;
    if let Some(revision) = deletion.bookmarks_revision {
        mux.emit_bookmarks_changed(id.to_string(), revision);
    }
    // Each tab that named the profile is on the default one now (cx-d0d.89).
    for browser_id in &deletion.cleared_browsers {
        let Ok(browser_id) = BrowserPublicId::parse(browser_id.clone()) else { continue };
        let content = ContentPublicId::Browser(browser_id);
        if let Some(surface) = mux.with_state(|state| state.single_placement_of_content(&content)) {
            mux.emit_tab_changed(surface);
        }
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
        "cleared_browsers": deletion.cleared_browsers,
    }))
}
