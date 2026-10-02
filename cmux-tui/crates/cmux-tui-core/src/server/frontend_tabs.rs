//! Frontend-rendered tabs: browser tabs whose page a frontend renders
//! (WebKit or CEF), and remote-terminal tabs (`remote-terminal-tabs-v1`) that
//! reference a terminal on another session. The daemon stores both records
//! and never attaches a CDP target, a PTY or a terminal host for either.

use super::*;
use crate::workspace_registry::{
    FrontendBrowserRecord, RemoteTerminalRecord, RemoteTerminalUpdate,
};

/// Remote-terminal tabs: a tab in this session's layout that references a
/// terminal on another session (`new-remote-terminal-tab`,
/// `update-remote-terminal-tab`, `remote-terminal-snapshot`, and the
/// `kind:"remote-terminal"` tab with its `remote` object;
/// plans/cmux-next/data-model.md sections 1.2 and 2).
pub const REMOTE_TERMINAL_TABS_CAPABILITY: &str = "remote-terminal-tabs-v1";

#[derive(Deserialize)]
pub(super) struct NewFrontendBrowserTab {
    url: String,
    engine: String,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    favicon_url: Option<String>,
    #[serde(default)]
    profile_id: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Deserialize)]
pub(super) struct UpdateFrontendBrowserTab {
    surface: SurfaceId,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default, deserialize_with = "present_nullable")]
    favicon_url: Option<Option<String>>,
}

/// The daemon stores the reference and never attaches, spawns, or
/// bootstraps the terminal.
#[derive(Deserialize)]
pub(super) struct NewRemoteTerminalTab {
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
pub(super) struct UpdateRemoteTerminalTab {
    surface: SurfaceId,
    #[serde(default, deserialize_with = "present_nullable")]
    title: Option<Option<String>>,
    #[serde(default)]
    session_name: Option<String>,
    #[serde(default, deserialize_with = "present_nullable")]
    snapshot: Option<Option<String>>,
}

#[derive(Deserialize)]
pub(super) struct RemoteTerminalSnapshot {
    surface: SurfaceId,
}

pub(super) fn new_browser_tab(
    mux: &Arc<Mux>,
    request: NewFrontendBrowserTab,
) -> anyhow::Result<Value> {
    let NewFrontendBrowserTab { url, engine, pane, title, favicon_url, profile_id, cols, rows } =
        request;
    let record = FrontendBrowserRecord { engine, url, title, favicon_url, profile_id };
    let surface = mux.new_frontend_browser_tab(
        pane,
        record,
        paired_surface_size("new-frontend-browser-tab", cols, rows)?,
    )?;
    let identity = surface.resource_identity();
    Ok(json!({
        "surface": surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
    }))
}

pub(super) fn update_browser_tab(
    mux: &Arc<Mux>,
    request: UpdateFrontendBrowserTab,
) -> anyhow::Result<Value> {
    let UpdateFrontendBrowserTab { surface, url, title, favicon_url } = request;
    let (record, changed) = mux.update_frontend_browser_tab(surface, url, title, favicon_url)?;
    Ok(json!({
        "surface": surface,
        "url": record.url,
        "title": record.title,
        "favicon_url": record.favicon_url,
        "changed": changed,
    }))
}

pub(super) fn new_remote_tab(
    mux: &Arc<Mux>,
    request: NewRemoteTerminalTab,
) -> anyhow::Result<Value> {
    let NewRemoteTerminalTab { session_id, terminal_id, session_name, pane, title, cols, rows } =
        request;
    let record = RemoteTerminalRecord { session_id, terminal_id, session_name, title };
    let surface = mux.new_remote_terminal_tab(
        pane,
        record,
        paired_surface_size("new-remote-terminal-tab", cols, rows)?,
    )?;
    let identity = surface.resource_identity();
    let (workspace, pane) = surface_placement(mux, surface.id);
    Ok(json!({
        "surface": surface.id,
        "pane": pane,
        "workspace": workspace,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
    }))
}

pub(super) fn update_remote_tab(
    mux: &Arc<Mux>,
    request: UpdateRemoteTerminalTab,
) -> anyhow::Result<Value> {
    let UpdateRemoteTerminalTab { surface, title, session_name, snapshot } = request;
    let change = mux.update_remote_terminal_tab(
        surface,
        RemoteTerminalUpdate { title, session_name, snapshot },
    )?;
    Ok(json!({"surface": surface, "changed": change.presentation || change.snapshot}))
}

pub(super) fn remote_snapshot(
    mux: &Arc<Mux>,
    request: RemoteTerminalSnapshot,
) -> anyhow::Result<Value> {
    let snapshot = mux.remote_terminal_snapshot(request.surface)?;
    Ok(json!({ "surface": request.surface, "snapshot": snapshot }))
}

/// The remote-terminal record behind a tab's placeholder surface, if any.
pub(super) fn remote_terminal_of<'a>(
    surface: Option<&Arc<crate::Surface>>,
    notifications: &'a TreeDecorations,
) -> Option<&'a RemoteTerminalRecord> {
    let identity = surface?.resource_identity()?;
    let ContentPublicId::Browser(id) = &identity.content_id else { return None };
    notifications.presentation.remote_terminals.get(id.as_str())
}

/// Report a remote-terminal tab's placeholder as a remote-terminal tab.
pub(super) fn apply_remote_terminal(tab: &mut Value, remote: Option<&RemoteTerminalRecord>) {
    if let Some(remote) = remote {
        remote_terminal_tab_json(tab, remote);
    }
}

/// A remote-terminal tab on the wire: `kind:"remote-terminal"` with its
/// `remote` reference and title, and none of the placeholder browser's or a
/// local terminal's fields.
fn remote_terminal_tab_json(tab: &mut Value, remote: &RemoteTerminalRecord) {
    let Some(object) = tab.as_object_mut() else { return };
    for field in ["terminal_id", "terminal_resource_id", "terminal_incarnation"] {
        object.remove(field);
    }
    for field in [
        "browser_source",
        "browser_status",
        "browser_error",
        "browser_renderer",
        "browser_engine",
        "favicon_url",
        "browser_profile_id",
        "browser_frames_stalled",
        "url",
        "cwd",
        "git_branch",
    ] {
        object.insert(field.to_string(), Value::Null);
    }
    object.insert("kind".into(), json!("remote-terminal"));
    object.insert(
        "remote".into(),
        json!({
            "session_id": remote.session_id,
            "terminal_id": remote.terminal_id,
            "session_name": remote.session_name,
        }),
    );
    object.insert("title".into(), json!(remote.display_title()));
}

#[cfg(test)]
#[path = "remote_terminal_tabs_tests.rs"]
mod remote_terminal_tabs_tests;
