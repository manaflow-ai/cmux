//! Frontend-facing session abstraction.
//!
//! The TUI runs against either an in-process mux (`Session::Local`) or a
//! remote one over the control socket (`Session::Remote`). Remote
//! surfaces are mirrored locally: the server sends a VT replay of each
//! surface's state followed by the live pty stream, and the client feeds
//! both into its own ghostty terminal. Rendering, key encoding, and mode
//! queries then work identically in both cases.

mod remote;
pub(crate) mod tree;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_tui_core::{
    BrowserFrame, BrowserStatus, DefaultColors, Mux, MuxEventReceiver, PaneId, ScreenId,
    SidebarPluginStatus, SplitDir, SplitId, Surface, SurfaceId, SurfaceKind, SurfaceRenderFrame,
    SurfaceResizeReporter, WorkspaceId, ZoomMode,
};
use ghostty_vt::{MouseInput, RenderState, Terminal};
use serde::Deserialize;
use serde_json::json;

pub use remote::{RemoteSession, RemoteSurface};
pub use tree::{TabNotificationView, TreeView, WorkspaceView};

#[derive(Clone)]
pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

pub(crate) fn is_remote_transport_failure(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<remote::RemoteRequestError>()
        .is_some_and(remote::RemoteRequestError::is_transport_failure)
}

pub(crate) fn is_remote_timeout(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<remote::RemoteRequestError>()
        .is_some_and(remote::RemoteRequestError::is_timeout)
}

#[cfg(test)]
pub(crate) fn test_remote_timeout_error() -> anyhow::Error {
    remote::RemoteRequestError::Timeout.into()
}

#[cfg(test)]
pub(crate) fn test_remote_transport_error() -> anyhow::Error {
    remote::RemoteRequestError::Transport(std::io::Error::new(
        std::io::ErrorKind::BrokenPipe,
        "socket closed",
    ))
    .into()
}

#[cfg(test)]
pub(crate) fn test_remote_rejected_error() -> anyhow::Error {
    remote::RemoteRequestError::Rejected("unknown surface".to_string()).into()
}

pub struct SidebarPluginSurface {
    pub surface_id: Option<SurfaceId>,
    pub error: Option<String>,
    pub retry_after_ms: Option<u64>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ClientSizeInfo {
    pub surface: SurfaceId,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ClientInfo {
    pub client: u64,
    pub transport: String,
    pub name: Option<String>,
    pub kind: Option<String>,
    pub connected_seconds: u64,
    pub attached: Vec<SurfaceId>,
    pub sizes: Vec<ClientSizeInfo>,
    #[serde(rename = "self")]
    pub is_self: bool,
    #[serde(default = "default_true")]
    pub size_participating: bool,
}

fn default_true() -> bool {
    true
}

/// Attach optional cols/rows fields to a remote command.
fn with_size(mut cmd: serde_json::Value, size: Option<(u16, u16)>) -> serde_json::Value {
    if let Some((cols, rows)) = size {
        cmd["cols"] = json!(cols);
        cmd["rows"] = json!(rows);
    }
    cmd
}

fn response_surface(result: &serde_json::Value, created: &str) -> anyhow::Result<SurfaceId> {
    result
        .get("surface")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| anyhow::anyhow!("remote {created} creation omitted its surface"))
}

fn sidebar_status_to_surface(status: SidebarPluginStatus) -> SidebarPluginSurface {
    let surface_id = status.surface;
    SidebarPluginSurface {
        surface_id,
        error: status.error,
        retry_after_ms: status.retry_after.map(|duration| duration.as_millis() as u64),
    }
}

pub(crate) fn resize_action(desired: (u16, u16), asserted: Option<(u16, u16)>) -> bool {
    asserted != Some(desired)
}

#[derive(Clone)]
pub enum SurfaceHandle {
    Local(Arc<Surface>, Arc<Mux>),
    Remote(Arc<RemoteSurface>, Arc<RemoteSession>),
    RemoteBrowserUnsupported,
}

impl Session {
    pub fn clients(&self) -> anyhow::Result<Vec<ClientInfo>> {
        let value = match self {
            Session::Local(mux) => mux.control_clients_json(0),
            Session::Remote(remote) => remote.request(json!({"cmd": "list-clients"}))?,
        };
        serde_json::from_value(value).map_err(Into::into)
    }

    pub fn set_client_sizing(&self, client: u64, enabled: bool) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .set_client_size_participation(client, enabled)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown client {client}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "client": client,
                    "enabled": enabled,
                }))
                .map(|_| ()),
        }
    }

    pub fn use_only_client_sizing(&self, client: u64) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .use_only_client_size(client)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown client {client}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "client": client,
                    "enabled": true,
                    "exclusive": true,
                }))
                .map(|_| ()),
        }
    }

    pub fn use_all_client_sizing(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.use_all_client_sizes();
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "enabled": true,
                }))
                .map(|_| ()),
        }
    }

    pub fn disconnect_client(&self, client: u64) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                if cmux_tui_core::server::detach_control_client(mux, client) {
                    Ok(())
                } else {
                    anyhow::bail!("unknown client {client}")
                }
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "detach-client", "client": client})).map(|_| ())
            }
        }
    }

    pub fn begin_shutdown(&self) {
        if let Session::Remote(remote) = self {
            remote.begin_shutdown();
        }
    }
    pub fn invalidate_remote_tree(&self) {
        if let Session::Remote(remote) = self {
            remote.invalidate_tree();
        }
    }

    pub fn take_remote_tree_stale(&self) -> bool {
        match self {
            Session::Local(_) => false,
            Session::Remote(remote) => remote.take_tree_stale(),
        }
    }

    pub fn remote_tree_is_stale(&self) -> bool {
        match self {
            Session::Local(_) => false,
            Session::Remote(remote) => remote.tree_is_stale(),
        }
    }

    pub fn refresh_tree(&self) -> anyhow::Result<TreeView> {
        match self {
            Session::Local(_) => Ok(self.tree()),
            Session::Remote(remote) => remote.refresh_tree(),
        }
    }

    pub fn refresh_tree_background(&self) -> anyhow::Result<TreeView> {
        match self {
            Session::Local(_) => Ok(self.tree()),
            Session::Remote(remote) => remote.refresh_tree_background(),
        }
    }

    /// Make sure the session has at least one workspace to show. `size`
    /// is the expected content size of the first pane, when known.
    pub fn ensure_initial(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.new_workspace(None, size)?;
                Ok(())
            }
            Session::Remote(remote) => {
                if remote.refresh_tree()?.workspaces.is_empty() {
                    remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                }
                Ok(())
            }
        }
    }

    pub fn events(&self) -> MuxEventReceiver {
        match self {
            Session::Local(mux) => mux.subscribe(),
            Session::Remote(remote) => remote.subscribe(),
        }
    }

    pub fn respond_pairing(&self, request: u64, approve: bool) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                if mux.respond_pairing(request, approve) {
                    Ok(())
                } else {
                    anyhow::bail!("unknown or expired pairing request {request}")
                }
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "pairing-response",
                    "request": request,
                    "approve": approve,
                }))
                .map(|_| ()),
        }
    }

    pub fn set_default_colors(&self, colors: DefaultColors) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.set_default_colors(colors);
                Ok(())
            }
            Session::Remote(remote) => remote.set_default_colors(colors),
        }
    }

    pub fn apply_config(&self, config: &crate::config::Config) {
        if let Session::Local(mux) = self {
            mux.update_surface_options(|options| {
                crate::config::apply_browser_to_surface_options(config, options);
            });
            mux.configure_sidebar_plugin(config.sidebar.plugin.clone());
        }
    }

    pub fn sidebar_plugin(&self, size: (u16, u16), relaunch: bool) -> SidebarPluginSurface {
        match self {
            Session::Local(mux) => {
                let status = mux.ensure_sidebar_plugin(size.0, size.1, relaunch);
                sidebar_status_to_surface(status)
            }
            Session::Remote(remote) => {
                let Ok(data) = remote.request(json!({
                    "cmd": "sidebar-plugin",
                    "cols": size.0,
                    "rows": size.1,
                    "relaunch": relaunch,
                })) else {
                    return SidebarPluginSurface {
                        surface_id: None,
                        error: Some("sidebar plugin unavailable over attach".to_string()),
                        retry_after_ms: None,
                    };
                };
                let requested_surface_id = data
                    .get("surface")
                    .and_then(serde_json::Value::as_u64)
                    .map(|id| id as SurfaceId);
                let mut error =
                    data.get("error").and_then(serde_json::Value::as_str).map(str::to_string);
                let surface_id = match requested_surface_id {
                    Some(id) => {
                        match remote.try_ensure_surface_with_kind(id, SurfaceKind::Pty, Some(size))
                        {
                            Ok(Some(_)) => Some(id),
                            Ok(None) => {
                                error.get_or_insert_with(|| {
                                    format!("sidebar plugin surface {id} is unavailable")
                                });
                                None
                            }
                            Err(attach_error) => {
                                error.get_or_insert_with(|| {
                                    format!(
                                        "sidebar plugin surface {id} attach failed: {attach_error}"
                                    )
                                });
                                None
                            }
                        }
                    }
                    None => None,
                };
                SidebarPluginSurface {
                    surface_id,
                    error,
                    retry_after_ms: data.get("retry_after_ms").and_then(serde_json::Value::as_u64),
                }
            }
        }
    }

    pub fn tree(&self) -> TreeView {
        match self {
            Session::Local(mux) => {
                let notifications = mux.surface_notifications();
                mux.with_state(|state| {
                    tree::tree_from_state_with_notifications(state, &notifications)
                })
            }
            Session::Remote(remote) => remote.cached_tree(),
        }
    }

    pub fn cached_surface(&self, id: SurfaceId) -> Option<SurfaceHandle> {
        match self {
            Session::Local(mux) => {
                mux.surface(id).map(|surface| SurfaceHandle::Local(surface, mux.clone()))
            }
            Session::Remote(remote) => {
                if remote.surface_kind(id) == SurfaceKind::Browser
                    && !remote.supports_browser_attach()
                {
                    Some(SurfaceHandle::RemoteBrowserUnsupported)
                } else {
                    remote.surface(id).map(|surface| SurfaceHandle::Remote(surface, remote.clone()))
                }
            }
        }
    }

    pub fn has_surface(&self, id: SurfaceId) -> bool {
        match self {
            Session::Local(mux) => mux.surface(id).is_some(),
            Session::Remote(remote) => remote.has_surface(id),
        }
    }

    pub fn has_surface_size_report(&self, id: SurfaceId) -> bool {
        match self {
            Session::Local(mux) => mux.client_surface_size(id, 0).is_some(),
            Session::Remote(remote) => {
                remote.surface(id).and_then(|surface| surface.reported_size()).is_some()
            }
        }
    }

    pub fn invalidate_surface_size_report(&self, id: SurfaceId) {
        if let Session::Remote(remote) = self
            && let Some(surface) = remote.surface(id)
        {
            surface.clear_reported_size();
        }
    }

    pub fn can_attach_after_overflow(&self, id: SurfaceId) -> bool {
        match self {
            Session::Local(_) => true,
            Session::Remote(remote) => remote.can_attach_after_overflow(id),
        }
    }

    pub fn surface_overflow_retry_due(&self) -> bool {
        match self {
            Session::Local(_) => false,
            Session::Remote(remote) => remote.surface_overflow_retry_due(),
        }
    }

    /// Applies the render size through the authoritative mux resize path.
    /// Remote mirrors are created after the server resize, so their attach
    /// replay arrives at final geometry.
    pub fn try_surface_sized(
        &self,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<SurfaceHandle>> {
        match self {
            Session::Local(mux) => mux
                .surface(id)
                .map(|surface| {
                    if let Some((cols, rows)) = size {
                        mux.resize_surface_for_client(id, 0, cols, rows)?;
                    }
                    Ok(SurfaceHandle::Local(surface, mux.clone()))
                })
                .transpose(),
            Session::Remote(remote) => {
                if remote.surface_kind(id) == SurfaceKind::Browser {
                    if remote.supports_browser_attach() {
                        remote.try_ensure_surface(id, size).map(|surface| {
                            surface.map(|surface| SurfaceHandle::Remote(surface, remote.clone()))
                        })
                    } else {
                        Ok(Some(SurfaceHandle::RemoteBrowserUnsupported))
                    }
                } else {
                    remote.try_ensure_surface(id, size).map(|surface| {
                        surface.map(|surface| SurfaceHandle::Remote(surface, remote.clone()))
                    })
                }
            }
        }
    }

    /// Release this frontend's sizing lease without dropping its cached
    /// attach stream. A later resize reclaims visibility for the surface.
    pub fn release_surface_size(&self, id: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                let changed = mux.client_surface_size(id, 0).is_some();
                mux.remove_surface_size_client(id, 0);
                if changed {
                    mux.emit(cmux_tui_core::MuxEvent::ClientChanged {
                        client: 0,
                        name: Some("This TUI".to_string()),
                        kind: Some("tui".to_string()),
                    });
                }
                Ok(())
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "release-surface-size", "surface": id}))?;
                if let Some(surface) = remote.surface(id) {
                    surface.clear_reported_size();
                }
                Ok(())
            }
        }
    }

    pub fn new_tab(
        &self,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.new_tab(pane, None, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                let result =
                    remote.request(with_size(json!({"cmd": "new-tab", "pane": pane}), size))?;
                response_surface(&result, "tab")
            }
        }
    }

    pub fn run_command(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux
                .run_command_surface(argv, pane, false, cwd, None, size)
                .map(|placement| placement.surface),
            Session::Remote(remote) => {
                let result = remote.request(with_size(
                    json!({"cmd": "run", "argv": argv, "pane": pane, "cwd": cwd}),
                    size,
                ))?;
                response_surface(&result, "command")
            }
        }
    }

    pub fn surface_cwd(&self, surface: SurfaceId) -> Option<String> {
        match self {
            Session::Local(mux) => mux
                .surface(surface)
                .and_then(|surface| surface.pwd().or_else(|| surface.spawn_cwd())),
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "process-info", "surface": surface})).ok().and_then(
                    |data| data.get("cwd").and_then(serde_json::Value::as_str).map(str::to_owned),
                )
            }
        }
    }

    pub fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.new_browser_tab(url, pane, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                if !remote.supports_browser_attach() {
                    anyhow::bail!("browser panes are not supported over attach yet");
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-browser-tab", "url": url, "pane": pane}),
                    size,
                ))?;
                result
                    .get("surface")
                    .and_then(serde_json::Value::as_u64)
                    .ok_or_else(|| anyhow::anyhow!("remote browser creation omitted its surface"))
            }
        }
    }

    pub fn set_cell_pixel_size(
        &self,
        width_px: u16,
        height_px: u16,
        report: SurfaceResizeReporter,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                let update = mux.set_cell_pixel_size_reporting(width_px, height_px, report);
                if update.failures.is_empty() {
                    Ok(())
                } else {
                    anyhow::bail!(
                        "cell pixel update rejected: {}",
                        update
                            .failures
                            .into_iter()
                            .map(|failure| format!(
                                "surface {}: {}",
                                failure.surface, failure.error
                            ))
                            .collect::<Vec<_>>()
                            .join("; ")
                    )
                }
            }
            Session::Remote(remote) => {
                let update = remote.set_cell_pixel_size(width_px, height_px)?;
                for (surface, desired, reservation_id) in update.resizes {
                    report(surface, desired, reservation_id.or(Some(0)));
                }
                if update.failures.is_empty() {
                    Ok(())
                } else {
                    anyhow::bail!(
                        "cell pixel update rejected: {}",
                        update
                            .failures
                            .into_iter()
                            .map(|(surface, error)| format!("surface {surface}: {error}"))
                            .collect::<Vec<_>>()
                            .join("; ")
                    )
                }
            }
        }
    }

    pub fn new_workspace(&self, size: Option<(u16, u16)>) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.new_workspace(None, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                let result = remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                response_surface(&result, "workspace")
            }
        }
    }

    pub fn new_screen(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.new_screen(workspace, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                let result = remote.request(with_size(
                    json!({"cmd": "new-screen", "workspace": workspace}),
                    size,
                ))?;
                response_surface(&result, "screen")
            }
        }
    }

    pub fn close_screen(&self, screen: ScreenId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.close_screen(screen);
                Ok(())
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-screen", "screen": screen})).map(|_| ())
            }
        }
    }

    pub fn rename_screen(&self, screen: ScreenId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.rename_screen(screen, name);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "rename-screen", "screen": screen, "name": name}))
                .map(|_| ()),
        }
    }

    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.select_screen(index, delta);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "select-screen", "index": index, "delta": delta}))
                .map(|_| ()),
        }
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                let _ = mux.zoom_pane(pane, ZoomMode::Toggle);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "zoom-pane", "pane": pane, "mode": "toggle"}))
                .map(|_| ()),
        }
    }

    pub fn split(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.split(pane, dir, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                let result = remote
                    .request(with_size(json!({"cmd": "split", "pane": pane, "dir": dir}), size))?;
                response_surface(&result, "split")
            }
        }
    }

    pub fn new_pane(&self, pane: PaneId, size: Option<(u16, u16)>) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => mux.new_pane(pane, size).map(|surface| surface.id),
            Session::Remote(remote) => {
                let result =
                    remote.request(with_size(json!({"cmd": "new-pane", "pane": pane}), size))?;
                response_surface(&result, "pane")
            }
        }
    }

    pub fn set_split_ratio(&self, split: SplitId, ratio: f32) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .set_split_ratio(split, ratio)
                .then_some(())
                .ok_or_else(|| anyhow::anyhow!("unknown split {split}")),
            Session::Remote(remote) => remote
                .request(json!({"cmd": "set-split-ratio", "split": split, "ratio": ratio}))
                .map(|_| ()),
        }
    }

    pub fn close_surface(&self, surface: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.close_surface(surface);
                Ok(())
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-surface", "surface": surface})).map(|_| ())
            }
        }
    }

    pub fn close_pane(&self, pane: PaneId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.close_pane(pane);
                Ok(())
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-pane", "pane": pane})).map(|_| ())
            }
        }
    }

    pub fn swap_pane(&self, pane: PaneId, target: PaneId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.swap_panes(pane, target);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "swap-pane", "pane": pane, "target": target}))
                .map(|_| ()),
        }
    }

    pub fn close_workspace(&self, workspace: WorkspaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.close_workspace(workspace);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "close-workspace", "workspace": workspace}))
                .map(|_| ()),
        }
    }

    pub fn rename_surface(&self, surface: SurfaceId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.rename_surface(surface, name);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "rename-surface", "surface": surface, "name": name}))
                .map(|_| ()),
        }
    }

    pub fn rename_workspace(&self, workspace: WorkspaceId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.rename_workspace(workspace, name);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "rename-workspace",
                    "workspace": workspace,
                    "name": name
                }))
                .map(|_| ()),
        }
    }

    /// Drop the local mirror of an exited surface. The server (local mux
    /// or remote session) reaps its own tree.
    pub fn forget_surface(&self, surface: SurfaceId) {
        if let Session::Remote(remote) = self {
            remote.drop_surface(surface);
        }
    }

    pub fn focus_pane(&self, pane: PaneId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.focus_pane(pane);
                Ok(())
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "focus-pane", "pane": pane})).map(|_| ())
            }
        }
    }

    pub fn select_tab(
        &self,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.select_tab(pane, index, delta);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "select-tab",
                    "pane": pane,
                    "index": index,
                    "delta": delta
                }))
                .map(|_| ()),
        }
    }

    pub fn select_workspace(
        &self,
        index: Option<usize>,
        delta: Option<isize>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.select_workspace(index, delta);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "select-workspace", "index": index, "delta": delta}))
                .map(|_| ()),
        }
    }

    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.move_tab(surface, pane, index);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "move-tab",
                    "surface": surface,
                    "pane": pane,
                    "index": index
                }))
                .map(|_| ()),
        }
    }

    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.move_workspace(workspace, index);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "move-workspace", "workspace": workspace, "index": index}))
                .map(|_| ()),
        }
    }
}

impl SurfaceHandle {
    pub fn is_remote(&self) -> bool {
        matches!(self, SurfaceHandle::Remote(_, _))
    }

    pub fn kind(&self) -> SurfaceKind {
        match self {
            SurfaceHandle::Local(surface, _) => surface.kind(),
            SurfaceHandle::Remote(surface, _) => surface.kind,
            SurfaceHandle::RemoteBrowserUnsupported => SurfaceKind::Browser,
        }
    }

    pub fn write_bytes(&self, bytes: &[u8]) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.write_bytes(bytes).map_err(Into::into),
            SurfaceHandle::Remote(surface, session) => session.send_bytes(surface.id, bytes),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser surface does not accept PTY input")
            }
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, false, Box::new(|_| {}))
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        _reassert: bool,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<bool> {
        let desired = (cols.max(1), rows.max(1));
        let reservation_id = match self {
            SurfaceHandle::Local(surface, mux) => {
                let report_changed = mux.client_surface_size(surface.id, 0) != Some(desired);
                let (accepted, reservation_id) = mux.resize_surface_for_client_with_reservation(
                    surface.id, 0, desired.0, desired.1,
                )?;
                if report_changed {
                    mux.emit(cmux_tui_core::MuxEvent::ClientChanged {
                        client: 0,
                        name: Some("This TUI".to_string()),
                        kind: Some("tui".to_string()),
                    });
                }
                report(reservation_id);
                return Ok(accepted);
            }
            SurfaceHandle::Remote(surface, session) => {
                if !resize_action(desired, surface.reported_size()) {
                    report(None);
                    return Ok(false);
                }
                let response = match session.request(json!({
                    "cmd": "resize-surface",
                    "surface": surface.id,
                    "cols": desired.0,
                    "rows": desired.1,
                })) {
                    Ok(response) => response,
                    Err(error) => {
                        report(None);
                        return Err(error);
                    }
                };
                let accepted =
                    response.get("accepted").and_then(serde_json::Value::as_bool).unwrap_or(true);
                surface.set_reported_size(desired);
                if !accepted {
                    report(None);
                    return Ok(false);
                }
                response.get("reservation_id").and_then(serde_json::Value::as_u64).or(Some(0))
            }
            SurfaceHandle::RemoteBrowserUnsupported => {
                report(None);
                anyhow::bail!("browser surface is unavailable")
            }
        };
        report(reservation_id);
        Ok(true)
    }

    pub fn resize_needed(&self, cols: u16, rows: u16, _user_interaction: bool) -> bool {
        let desired = (cols.max(1), rows.max(1));
        match self {
            SurfaceHandle::Local(surface, mux) => {
                resize_action(desired, mux.client_surface_size(surface.id, 0))
            }
            SurfaceHandle::Remote(surface, _) => resize_action(desired, surface.reported_size()),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn reassert_size(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, true, Box::new(|_| {}))
    }
    pub fn take_dirty(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.take_dirty(),
            SurfaceHandle::Remote(surface, _) => surface.dirty.swap(false, Ordering::AcqRel),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn render_frame(
        &self,
        rs: &mut RenderState,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.render_frame(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                rs.update(&mut term)?;
                let palette_colors = std::array::from_fn(|idx| rs.palette_color(idx as u8));
                let palette_overridden =
                    std::array::from_fn(|idx| rs.palette_overridden(idx as u8));
                Ok(Arc::new(SurfaceRenderFrame {
                    frame: rs.build_frame()?,
                    scrollback_rows: term.history_rows(),
                    palette_colors,
                    palette_overridden,
                }))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => {
                Err(ghostty_vt::Error::InvalidValue)
            }
        }
    }

    /// Run `f` against the surface's terminal state (the mirror, for
    /// remote surfaces — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.with_terminal(f),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut terminal = surface.term.lock().unwrap();
                let result = f(&mut terminal);
                surface.sync_mouse_encoders(&terminal);
                Some(result)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse(input, output),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse(input, output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse_release(input, output),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse_release(input, output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_press_pair(
        &self,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut Vec<u8>,
        release_output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_press_pair(press, release, press_output, release_output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse_press_pair(press, release, press_output, release_output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn reset_mouse_motion_dedupe(&self) {
        match self {
            SurfaceHandle::Local(surface, _) => surface.reset_mouse_motion_dedupe(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.reset_mouse_motion_dedupe();
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => {}
        }
    }

    pub fn scroll_delta(&self, delta: isize) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let before = surface
                    .with_terminal(|term| term.scrollbar().map(|sb| sb.offset))
                    .flatten()
                    .unwrap_or(0);
                surface.scroll_delta(delta).ok()?;
                let after = surface
                    .with_terminal(|term| term.scrollbar().map(|sb| sb.offset))
                    .flatten()
                    .unwrap_or(0);
                Some(before != after)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_delta(delta);
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_to_bottom(&self) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let before = surface
                    .with_terminal(|term| term.scrollbar().map(|sb| sb.offset))
                    .flatten()
                    .unwrap_or(0);
                surface.scroll_to_bottom().ok()?;
                let after = surface
                    .with_terminal(|term| term.scrollbar().map(|sb| sb.offset))
                    .flatten()
                    .unwrap_or(0);
                Some(before != after)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_to_bottom();
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frame(&self) -> Option<BrowserFrame> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_url(&self) -> Option<String> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_url(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_url()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_status(&self) -> Option<BrowserStatus> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_status(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                Some(surface.browser_status())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frames_stalled(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frames_stalled().unwrap_or(false),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frames_stalled()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn browser_insert_text(&self, text: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_insert_text(text),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(
                        json!({"cmd": "browser-insert-text", "surface": surface.id, "text": text}),
                    )
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_key_event(
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            ),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let kind = match event_type {
                    "keyDown" => "down",
                    "keyUp" => "up",
                    _ => anyhow::bail!("bad browser key event type {event_type:?}"),
                };
                session
                    .request(json!({
                        "cmd": "browser-key",
                        "surface": surface.id,
                        "kind": kind,
                        "key": key,
                        "code": code,
                        "windows_virtual_key_code": windows_virtual_key_code,
                        "modifiers": modifiers,
                        "text": text,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_mouse_event(event_type, x, y, button, click_count)
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let kind = match event_type {
                    "mousePressed" => "down",
                    "mouseReleased" => "up",
                    "mouseMoved" => "move",
                    _ => anyhow::bail!("bad browser mouse event type {event_type:?}"),
                };
                session
                    .request(json!({
                        "cmd": "browser-mouse",
                        "surface": surface.id,
                        "kind": kind,
                        "x_px": x,
                        "y_px": y,
                        "button": button,
                        "click_count": click_count,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_wheel(x, y, delta_y),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({
                        "cmd": "browser-wheel",
                        "surface": surface.id,
                        "x_px": x,
                        "y_px": y,
                        "delta_y_px": delta_y,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_navigate(&self, url: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_navigate(url),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({"cmd": "browser-navigate", "surface": surface.id, "url": url}))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_back(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-back")
    }

    pub fn browser_forward(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-forward")
    }

    pub fn browser_reload(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-reload")
    }

    pub fn browser_activate(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-activate")
    }

    fn browser_nav_command(&self, cmd: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => match cmd {
                "browser-back" => surface.browser_back(),
                "browser-forward" => surface.browser_forward(),
                "browser-reload" => surface.browser_reload(),
                "browser-activate" => surface.browser_activate(),
                _ => unreachable!(),
            },
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session.request(json!({"cmd": cmd, "surface": surface.id})).map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use cmux_tui_core::{Mux, SurfaceOptions};

    use super::{Session, resize_action};

    #[test]
    fn first_layout_after_attach_sends_ordered_resize() {
        let desired = (123, 65);
        assert!(resize_action(desired, None));
    }

    #[test]
    fn already_sized_first_layout_does_not_send_redundant_resize() {
        let desired = (123, 65);
        assert!(!resize_action(desired, Some(desired)));
    }

    #[test]
    fn shared_resize_does_not_reassert_unchanged_local_report() {
        let desired = (123, 65);
        assert!(!resize_action(desired, Some(desired)));
    }

    #[test]
    fn steady_state_does_not_send() {
        let desired = (123, 65);
        assert!(!resize_action(desired, Some(desired)));
    }

    #[test]
    fn local_set_split_ratio_rejects_an_unknown_split() {
        let session =
            Session::Local(Mux::new("unknown-local-split-test", SurfaceOptions::default()));

        let error = session.set_split_ratio(999_999, 0.5).unwrap_err();
        assert_eq!(error.to_string(), "unknown split 999999");
    }
}
