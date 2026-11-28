//! Raw protocol handlers for remote-terminal tabs (`remote-terminal-tabs-v1`,
//! plans/cmux-next/data-model.md 1.2b): `new-remote-terminal-tab`,
//! `update-remote-terminal-tab`, `remote-terminal-snapshot`, and the
//! `kind:"remote-terminal"` tab with its `remote` object in the tree. The
//! daemon stores the reference and never attaches, spawns or bootstraps the
//! terminal; the app attaches on the terminal's own session.

use super::*;
use crate::state::remote_terminal_tabs_store::{
    REMOTE_TERMINAL_KIND, RemoteTerminalRecord, RemoteTerminalUpdate,
};

#[derive(Deserialize)]
pub(super) struct NewParams {
    session_id: String,
    terminal_id: String,
    session_name: String,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Deserialize)]
pub(super) struct UpdateParams {
    surface: SurfaceId,
    #[serde(default, deserialize_with = "super::present_nullable")]
    title: Option<Option<String>>,
    #[serde(default)]
    session_name: Option<String>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    snapshot: Option<Option<String>>,
}

#[derive(Deserialize)]
pub(super) struct SnapshotParams {
    surface: SurfaceId,
}

pub(super) fn create(
    mux: &Arc<Mux>,
    actor: &crate::Actor,
    params: NewParams,
) -> anyhow::Result<Value> {
    let NewParams { session_id, terminal_id, session_name, pane, title, cols, rows } = params;
    let record = RemoteTerminalRecord { session_id, terminal_id, session_name, title };
    let size = paired_surface_size("new-remote-terminal-tab", cols, rows)?;
    let surface = mux.new_remote_terminal_tab_as(actor, pane, record, size)?;
    let identity = surface.resource_identity();
    let (workspace, pane) = cmd_tabs::surface_placement(mux, surface.id);
    Ok(json!({
        "surface": surface.id,
        "pane": pane,
        "workspace": workspace,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
    }))
}

pub(super) fn update(mux: &Arc<Mux>, params: UpdateParams) -> anyhow::Result<Value> {
    let UpdateParams { surface, title, session_name, snapshot } = params;
    let change = mux.update_remote_terminal_tab(
        surface,
        RemoteTerminalUpdate { title, session_name, snapshot },
    )?;
    Ok(json!({"surface": surface, "changed": change.presentation || change.snapshot}))
}

pub(super) fn snapshot(mux: &Arc<Mux>, params: SnapshotParams) -> anyhow::Result<Value> {
    let snapshot = mux.remote_terminal_snapshot(params.surface)?;
    Ok(json!({"surface": params.surface, "snapshot": snapshot}))
}

/// Report a remote-terminal tab's placeholder as a remote-terminal tab:
/// `kind:"remote-terminal"` with its `remote` reference and title, and none
/// of the placeholder browser's or a local terminal's fields.
pub(super) fn apply(tab: &mut Value, remote: Option<&RemoteTerminalRecord>) {
    let (Some(remote), Some(object)) = (remote, tab.as_object_mut()) else { return };
    for field in ["terminal_id", "terminal_resource_id", "terminal_incarnation"] {
        object.remove(field);
    }
    for field in [
        "browser_source",
        "browser_status",
        "browser_error",
        "browser_renderer",
        "browser_engine",
        "browser_owner",
        "favicon_url",
        "browser_profile_id",
        "browser_frames_stalled",
        "url",
        "cwd",
        "git_branch",
    ] {
        object.insert(field.to_string(), Value::Null);
    }
    object.insert("kind".into(), json!(REMOTE_TERMINAL_KIND));
    object.insert("remote".into(), remote.wire());
    object.insert("title".into(), json!(remote.display_title()));
}
