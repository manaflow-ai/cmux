//! Frontend-facing session abstraction.
//!
//! The TUI runs against either an in-process mux (`Session::Local`) or a
//! remote one over the control socket (`Session::Remote`). Remote
//! surfaces are mirrored locally: the server sends a VT replay of each
//! surface's state followed by the live pty stream, and the client feeds
//! both into its own ghostty terminal. Rendering, key encoding, and mode
//! queries then work identically in both cases.

use cmux_json::JsonSet as _;

mod creation;
mod cursor_provenance;
mod frontend_projection;
mod remote;
pub(crate) mod sidebar_doc;
mod surface_handle;
pub(crate) mod tree;

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Instant;

use crate::local_actor::me;
use cmux_tui_core::resource::ResourceOperation;
use cmux_tui_core::server::{
    CLIENT_FOCUS_CAPABILITY, CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY,
    FRONTEND_JOURNAL_CAPABILITY, LAYOUT_UNDO_CAPABILITY, MACHINE_USAGE_CAPABILITY,
    MAX_CREATION_SELECTOR_FALLBACKS, PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
    SHARED_SIZING_CAPABILITY, VIEWPORT_COLUMN_RESIZE_CAPABILITY, VIEWPORT_SPLITS_CAPABILITY,
};
use cmux_tui_core::sizing_policy::{TerminalSizingPolicy, TerminalSizingState};
use cmux_tui_core::{
    BrowserFrameUpdate, BrowserStatus, ClearHistoryFailure, GuardedMouseEncode, LayoutRatioError,
    LayoutUndoError, LayoutUndoResult, MachineUsage, Mux, MuxEventReceiver, PaneId,
    PointerSemanticProbe, PointerSnapshotProbe, ResourceSelectors, ScreenId, SidebarPluginStatus,
    SplitDir, SplitId, Surface, SurfaceId, SurfaceKind, SurfaceRenderFrame, SurfaceResizeReporter,
    TerminalPointerSnapshot, ViewportWidthError, WorkspaceId, WorkspaceMutation, ZoomMode,
};
use ghostty_vt::{
    KeyInput, MouseInput, RenderState, Scrollbar, Terminal, TerminalPointerSemanticSnapshot,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

pub(crate) use creation::{AmbiguousCreation, CreationReceipt};
pub(crate) use frontend_projection::ProjectionKey;
pub(crate) use remote::sidebar_doc::SidebarDropAnchors;
pub use remote::{
    RemoteMessageReader, RemoteMessageWriter, RemoteSession, RemoteSurface, RemoteTransport,
    RemoteTransportAbort,
};
pub use surface_handle::SurfaceHandle;
pub use tree::{TabNotificationView, TreeView, WorkspaceView};

pub(crate) const CLEAR_HISTORY_UNSUPPORTED_ERROR: &str =
    "remote server does not support clear-history; restart the cmux-tui server";

/// Decode the `usage` object shared by the `machine-usage` result and the
/// `machine-usage-changed` event. Anything malformed reads as no readout.
pub(crate) fn parse_machine_usage(value: &Value) -> Option<MachineUsage> {
    let usage = value.get("usage")?;
    if usage.is_null() {
        return None;
    }
    let period_days = u32::try_from(usage.get("period_days")?.as_u64()?).ok()?;
    let api_equivalent_usd = usage.get("api_equivalent_usd")?.as_f64()?;
    if !api_equivalent_usd.is_finite() {
        return None;
    }
    Some(MachineUsage {
        vm_id: usage.get("vm_id")?.as_str()?.to_string(),
        period_days,
        total_tokens: usage.get("total_tokens")?.as_u64()?,
        api_equivalent_usd,
        as_of: usage.get("as_of").and_then(Value::as_str).map(str::to_string),
    })
}

pub(crate) fn parse_identity_capabilities(value: &Value) -> Result<HashSet<String>, &'static str> {
    let Some(capabilities) = value.get("capabilities") else {
        return Ok(HashSet::new());
    };
    let Some(capabilities) = capabilities.as_array() else {
        return Err("capabilities must be an array of strings");
    };
    capabilities
        .iter()
        .map(|capability| {
            capability.as_str().map(str::to_owned).ok_or("capabilities must be an array of strings")
        })
        .collect()
}

pub(crate) fn apply_config_to_local_owner(mux: &Mux, config: &crate::config::Config) {
    mux.update_surface_options(|options| {
        crate::config::apply_browser_to_surface_options(config, options);
    });
    mux.configure_sidebar_plugin(config.sidebar.plugin.clone());
    mux.configure_journal_plugin(config.agents.plugin.clone());
}

#[derive(Clone)]
pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

/// Stable frontend boundary for session reads. It is deliberately small:
/// mutations and transport recovery remain on `Session` until their command
/// and acknowledgement semantics are migrated. Agent metadata is exposed
/// through this boundary while the normal tree read remains on `Session::tree`.
pub(crate) trait SessionPort: Send + Sync {
    fn agents(&self) -> Vec<AgentInfo>;
}

impl SessionPort for Session {
    fn agents(&self) -> Vec<AgentInfo> {
        self.agents_impl()
    }
}

pub(crate) fn is_remote_transport_failure(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<remote::RemoteRequestError>()
        .is_some_and(remote::RemoteRequestError::is_transport_failure)
}

pub(crate) fn is_expected_remote_shutdown(error: &anyhow::Error) -> bool {
    matches!(
        error.downcast_ref::<remote::RemoteRequestError>(),
        Some(remote::RemoteRequestError::DaemonShutdown)
    )
}

pub(crate) fn is_remote_timeout(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<remote::RemoteRequestError>()
        .is_some_and(remote::RemoteRequestError::is_timeout)
}

pub(crate) fn is_remote_surface_unavailable(error: &anyhow::Error, surface: SurfaceId) -> bool {
    let expected = format!("unknown surface {surface}");
    error
        .downcast_ref::<remote::RemoteRequestError>()
        .is_some_and(|error| error.rejection_message() == Some(expected.as_str()))
}

fn normalize_remote_layout_undo_error(error: anyhow::Error) -> anyhow::Error {
    let Some(remote) = error.downcast_ref::<remote::RemoteRequestError>() else {
        return error;
    };
    match remote.rejection_code() {
        Some(LayoutUndoError::UNAVAILABLE_CODE) => LayoutUndoError::Unavailable.into(),
        Some(LayoutUndoError::STALE_CODE) => LayoutUndoError::Stale(
            remote
                .rejection_message()
                .unwrap_or(crate::localization::catalog().layout.layout_changed_before_undo)
                .to_string(),
        )
        .into(),
        _ => error,
    }
}

fn localized_layout_ratio_error(error: LayoutRatioError) -> anyhow::Error {
    let messages = &crate::localization::catalog().layout;
    let message = match error {
        LayoutRatioError::UnknownPaneSplit { pane } => messages.unknown_pane_split(pane),
        LayoutRatioError::UnknownSplit { split } => messages.unknown_split(split),
        LayoutRatioError::UnrepresentableViewportWidth { split, ratio, width } => {
            messages.unrepresentable_viewport_width(split, ratio, width)
        }
        LayoutRatioError::RowSplitCompatReadonly { .. } => messages.row_split_readonly.into(),
    };
    anyhow::anyhow!(message)
}

fn normalize_remote_split_ratio_error(
    error: anyhow::Error,
    split: SplitId,
    ratio: f32,
) -> anyhow::Error {
    let Some(remote) = error.downcast_ref::<remote::RemoteRequestError>() else {
        return error;
    };
    let messages = &crate::localization::catalog().layout;
    match remote.rejection_code() {
        Some(LayoutRatioError::UNKNOWN_TARGET_CODE) => {
            anyhow::anyhow!(messages.unknown_split(split))
        }
        Some(LayoutRatioError::OUT_OF_RANGE_CODE) => {
            anyhow::anyhow!(messages.unrepresentable_viewport_ratio(split, ratio))
        }
        _ => error,
    }
}

fn validate_viewport_width(width: f32) -> anyhow::Result<()> {
    if width.is_finite()
        && (cmux_tui_core::MIN_VIEWPORT_PANE_WIDTH..=cmux_tui_core::MAX_VIEWPORT_PANE_WIDTH)
            .contains(&width)
    {
        return Ok(());
    }
    anyhow::bail!(crate::localization::catalog().layout.viewport_width_out_of_range)
}

fn localized_viewport_width_error(error: ViewportWidthError) -> anyhow::Error {
    let messages = &crate::localization::catalog().layout;
    match error {
        ViewportWidthError::OutOfRange { .. } => {
            anyhow::anyhow!(messages.viewport_width_out_of_range)
        }
        ViewportWidthError::PaneNotResizable { pane } => {
            anyhow::anyhow!(messages.pane_without_resizable_column(pane))
        }
    }
}

fn normalize_remote_viewport_width_error(error: anyhow::Error, pane: PaneId) -> anyhow::Error {
    let Some(remote) = error.downcast_ref::<remote::RemoteRequestError>() else {
        return error;
    };
    let messages = &crate::localization::catalog().layout;
    match remote.rejection_code() {
        Some(ViewportWidthError::OUT_OF_RANGE_CODE) => {
            anyhow::anyhow!(messages.viewport_width_out_of_range)
        }
        Some(ViewportWidthError::COLUMN_MISSING_CODE) => {
            anyhow::anyhow!(messages.pane_without_resizable_column(pane))
        }
        _ => error,
    }
}

#[cfg(test)]
mod local_actor_tests;
#[cfg(test)]
mod test_errors;
#[cfg(test)]
pub(crate) use test_errors::*;

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
    #[serde(default = "default_true")]
    pub size_participating: bool,
}

/// Canonical agent presence projected into sidebar views. Keeping this
/// transport-neutral lets local and remote sessions render identically.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct AgentInfo {
    pub surface: SurfaceId,
    pub state: String,
    pub source: String,
    pub session: Option<String>,
    /// The reporting adapter id (`claude`, `codex`, ...), when known.
    #[serde(default)]
    pub agent: Option<String>,
    pub updated_at_ms: u64,
}

/// A terminal's shared-sizing state as this frontend sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurfaceSizeState {
    pub state: TerminalSizingState,
    /// This frontend's own participant id in `state`, when attached.
    pub self_participant: Option<String>,
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
}

fn default_true() -> bool {
    true
}

/// How attach must bootstrap a session so a bare `cmux` launch never lands on
/// pure emptiness. A brand-new session gets its first workspace. A session
/// whose every workspace has lost its screens (the legitimate outcome of the
/// startup repair that prunes dead terminals) gets the default shell in the
/// active workspace, because empty is indistinguishable from broken at
/// attach. One surviving screen anywhere means the user's layout is intact,
/// and includes the deliberately-empty-workspace case, so startup must not
/// mutate anything.
enum InitialBootstrap {
    FirstWorkspace,
    ShellInActiveWorkspace,
    LayoutIntact,
}

/// Idempotency identity for the bare-session bootstrap create. Uniqueness
/// matters: a collision would make the daemon replay another client's create
/// instead of applying the revision guard.
fn bootstrap_mutation_id() -> anyhow::Result<String> {
    use std::fmt::Write as _;
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("cannot allocate bootstrap mutation identity: {error}"))?;
    let mut id = String::with_capacity(50);
    id.push_str("attach-bootstrap_");
    for byte in bytes {
        let _ = write!(id, "{byte:02x}");
    }
    Ok(id)
}

fn initial_bootstrap(tree: &TreeView) -> InitialBootstrap {
    if tree.workspaces().is_empty() {
        return InitialBootstrap::FirstWorkspace;
    }
    if tree.workspaces().iter().all(|workspace| workspace.screens.is_empty()) {
        return InitialBootstrap::ShellInActiveWorkspace;
    }
    InitialBootstrap::LayoutIntact
}

/// Attach optional cols/rows fields to a remote command.
fn with_size(mut cmd: Value, size: Option<(u16, u16)>) -> Value {
    if let Some((cols, rows)) = size {
        cmd.set("cols", json!(cols));
        cmd.set("rows", json!(rows));
    }
    cmd
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

pub(crate) enum SurfaceAttach {
    Attached(SurfaceHandle),
    Retired,
    Deferred,
    Missing,
}

/// A client's focused pane and tab. Reported to the mux as memory only: a
/// later attach adopts it (the same client through its own record, any other
/// client through the session's last reported focus), and future follow-along
/// clients can subscribe to it. Reports never move the live shared focus, so
/// clients that are already attached stay where they are.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct ClientFocus {
    pub(crate) pane: PaneId,
    pub(crate) tab: usize,
}

/// What a daemon said when it shut down (`daemon-shutdown`'s `restart`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum DaemonShutdownNotice {
    /// `server restart`: a replacement daemon takes over the same session.
    Restart,
    /// `server stop`: the session stops.
    Stop,
    /// An older daemon, or a caller that did not say (an app or update
    /// handoff): a replacement may follow.
    Unspecified,
}

impl DaemonShutdownNotice {
    /// Reads the notice from a `daemon-shutdown` event.
    pub(crate) fn from_event(event: &Value) -> Self {
        match event.get("restart").and_then(Value::as_bool) {
            Some(true) => Self::Restart,
            Some(false) => Self::Stop,
            None => Self::Unspecified,
        }
    }
}

impl Session {
    /// Returns the first reason recorded when a remote transport reader stops.
    pub(crate) fn transport_disconnect_reason(&self) -> Option<String> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.transport_disconnect_reason(),
        }
    }

    /// What the daemon's shutdown notice said; `None` for a local session
    /// or when no notice came.
    pub(crate) fn daemon_shutdown_notice(&self) -> Option<DaemonShutdownNotice> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.daemon_shutdown_notice(),
        }
    }

    /// Best-effort focus report: the client already navigated optimistically,
    /// so failures are ignored and remote sends are never awaited. On the
    /// local path and on a `client-focus-v1` server the report only writes
    /// memory: the session's last reported focus (the adoption default for a
    /// later attach) and, with a client id, this client's own record for its
    /// reconnection. It never moves the live shared focus, so other attached
    /// clients keep their own view. Only a remote server without the
    /// capability degrades to `focus-pane` plus `select-tab`, which does move
    /// the shared focus.
    pub(crate) fn report_focus(
        &self,
        previous: Option<ClientFocus>,
        focus: ClientFocus,
        client_id: Option<&str>,
    ) {
        let pane_changed = previous.map(|value| value.pane) != Some(focus.pane);
        let tab_changed = previous != Some(focus);
        if !pane_changed && !tab_changed {
            return;
        }
        match self {
            Session::Local(mux) => {
                mux.record_session_focus(focus.pane, Some(focus.tab));
                if let Some(client_id) = client_id {
                    mux.remember_client_focus(client_id.to_string(), focus.pane, Some(focus.tab));
                }
            }
            Session::Remote(remote) => {
                let combined =
                    client_id.filter(|_| remote.supports_capability(CLIENT_FOCUS_CAPABILITY));
                if let Some(client_id) = combined {
                    let _ = remote.notify(json!({
                        "cmd": "report-focus",
                        "client_id": client_id,
                        "pane": focus.pane,
                        "tab": focus.tab,
                    }));
                    return;
                }
                if pane_changed {
                    let _ = remote.notify(json!({"cmd": "focus-pane", "pane": focus.pane}));
                }
                if tab_changed {
                    let _ = remote.notify(
                        json!({"cmd": "select-tab", "pane": focus.pane, "index": focus.tab}),
                    );
                }
            }
        }
    }

    /// This client's remembered focus on this session, falling back to the
    /// session's last reported focus from any client, if the server has
    /// either and its pane is still alive. The remote server applies the
    /// same fallback inside the `client-focus` command.
    pub(crate) fn client_focus(&self, client_id: &str) -> Option<ClientFocus> {
        match self {
            Session::Local(mux) => mux
                .client_focus(client_id)
                .or_else(|| mux.session_focus())
                .map(|(pane, tab)| ClientFocus { pane, tab: tab.unwrap_or(0) }),
            Session::Remote(remote) => {
                if !remote.supports_capability(CLIENT_FOCUS_CAPABILITY) {
                    return None;
                }
                let value =
                    remote.request(json!({"cmd": "client-focus", "client_id": client_id})).ok()?;
                let pane: PaneId = serde_json::from_value(value.get("pane")?.clone()).ok()?;
                let tab = value.get("tab").and_then(|tab| tab.as_u64()).unwrap_or(0) as usize;
                Some(ClientFocus { pane, tab })
            }
        }
    }

    pub(crate) fn allocate_layout_resize_owner(&self) -> u64 {
        match self {
            Session::Local(mux) => mux.allocate_in_process_resize_owner(),
            // Remote layout transactions are scoped by the server-assigned
            // control-client ID, so this local value is never serialized.
            Session::Remote(_) => 0,
        }
    }

    pub fn clients(&self) -> anyhow::Result<Vec<ClientInfo>> {
        let value = match self {
            Session::Local(mux) => mux.control_clients_json(0),
            Session::Remote(remote) => remote.request(json!({"cmd": "list-clients"}))?,
        };
        serde_json::from_value(value).map_err(Into::into)
    }

    /// The session's machine-level model spend readout. `None` when the
    /// server has no readout or predates the `machine-usage` command; the
    /// readout is informational, so an old server is not an error.
    pub fn machine_usage(&self) -> anyhow::Result<Option<MachineUsage>> {
        match self {
            Session::Local(mux) => Ok(mux.machine_usage()),
            Session::Remote(remote) => {
                if !remote.supports_capability(MACHINE_USAGE_CAPABILITY) {
                    return Ok(None);
                }
                let value = remote.request(json!({"cmd": "machine-usage"}))?;
                Ok(parse_machine_usage(&value))
            }
        }
    }

    pub fn set_client_sizing(
        &self,
        surface: SurfaceId,
        client: u64,
        enabled: bool,
        exclusive: bool,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => (if exclusive {
                enabled.then(|| mux.use_only_client_size(surface, client)).flatten()
            } else {
                mux.set_client_size_participation(surface, client, enabled)
            })
            .map(|_| ())
            .ok_or_else(|| anyhow::anyhow!("client {client} has no size lease for {surface}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "surface": surface,
                    "client": client,
                    "enabled": enabled,
                    "exclusive": exclusive,
                }))
                .map(|_| ()),
        }
    }

    pub fn use_only_client_sizing(&self, surface: SurfaceId, client: u64) -> anyhow::Result<()> {
        self.set_client_sizing(surface, client, true, true)
    }

    /// Focus on a terminal. Under shared sizing this is activity only
    /// (`note-size-activity`): the legacy `set-client-sizing` would clear a
    /// counts choice another participant made for this view. Daemons without
    /// `shared-sizing-v1` keep the legacy exclusive claim.
    pub fn claim_terminal_geometry(&self, surface: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .claim_terminal_geometry(surface, 0)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface}")),
            Session::Remote(remote) if remote.supports_capability(SHARED_SIZING_CAPABILITY) => {
                remote.request(json!({"cmd": "note-size-activity", "surface": surface})).map(|_| ())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "surface": surface,
                    "enabled": true,
                    "exclusive": true,
                }))
                .map(|_| ()),
        }
    }

    pub fn use_all_client_sizing(&self, surface: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .use_all_client_sizes(surface)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-client-sizing",
                    "surface": surface,
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

    /// The latest shared-sizing state of a terminal and this frontend's own
    /// participant id in it (docs/shared-terminal-sizing.md). `None` before
    /// the host published one, or when the host lacks `shared-sizing-v1`.
    pub fn size_state(&self, surface: SurfaceId) -> Option<SurfaceSizeState> {
        match self {
            Session::Local(mux) => Some(SurfaceSizeState {
                state: mux.terminal_size_state(surface)?,
                self_participant: mux.terminal_view_participant_id(surface, 0),
            }),
            Session::Remote(remote) => remote.size_state(surface),
        }
    }

    /// `set-size-policy {surface, policy}`.
    pub fn set_size_policy(
        &self,
        surface: SurfaceId,
        policy: TerminalSizingPolicy,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .set_terminal_size_policy(surface, Some(policy))
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal")),
            Session::Remote(remote) => remote
                .request(json!({"cmd": "set-size-policy", "surface": surface, "policy": policy}))
                .map(|_| ()),
        }
    }

    /// `set-size-counts {surface, participant, counts}`; `None` restores the
    /// automatic rule.
    pub fn set_size_counts(
        &self,
        surface: SurfaceId,
        participant: &str,
        counts: Option<bool>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .set_terminal_size_counts(surface, participant, counts)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown participant {participant}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-size-counts",
                    "surface": surface,
                    "participant": participant,
                    "counts": counts,
                }))
                .map(|_| ()),
        }
    }

    /// `detach-client {client: <participant>, surface}`: disconnects one
    /// participant of this terminal: a relay sub-view alone, the own view of
    /// a client with `sizing-view-detach-v1` (a Mac keeps its connection and
    /// the phones it relays), otherwise its whole client.
    pub fn disconnect_size_participant(
        &self,
        surface: SurfaceId,
        participant: &str,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                cmux_tui_core::server::detach_size_participant(mux, 0, participant, Some(surface))
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "detach-client", "client": participant, "surface": surface}))
                .map(|_| ()),
        }
    }

    pub fn begin_shutdown(&self) {
        if let Session::Remote(remote) = self {
            remote.begin_shutdown();
        }
    }

    /// Whether this session's transport can still serve requests. A remote
    /// session whose reader hit EOF (VM paused, stream ended, network died)
    /// flips its shutdown flag; a warm connection pool must not hand such a
    /// corpse back to a switch.
    pub fn is_alive(&self) -> bool {
        match self {
            Session::Local(_) => true,
            Session::Remote(remote) => !remote.is_shut_down(),
        }
    }

    pub fn journal_frontend_event(
        &self,
        event: cmux_tui_core::FrontendJournalEvent,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.journal_local_frontend_event(event),
            Session::Remote(remote) if remote.supports_capability(FRONTEND_JOURNAL_CAPABILITY) => {
                remote.request(json!({"cmd":"journal-frontend-event","event":event})).map(|_| ())
            }
            Session::Remote(_) => Ok(()),
        }
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        match self {
            Session::Local(mux) => mux.daemon_shutdown_requested(),
            Session::Remote(remote) => remote.daemon_shutdown_requested(),
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
            Session::Remote(remote) => {
                remote.ensure_sidebar_doc();
                remote.refresh_tree()
            }
        }
    }

    pub fn refresh_tree_background(&self) -> anyhow::Result<TreeView> {
        match self {
            Session::Local(_) => Ok(self.tree()),
            Session::Remote(remote) => {
                remote.ensure_sidebar_doc();
                remote.refresh_tree_background()
            }
        }
    }

    /// Make sure the session has at least one workspace to show. `size`
    /// is the expected content size of the first pane, when known.
    pub fn ensure_initial(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                // Hold the per-mux bootstrap guard across the snapshot and
                // mutation.  Without this, concurrent attaches can both
                // observe a bare session and create duplicate workspaces or
                // shells before either mutation becomes visible.
                let _bootstrap = mux.lock_initial_bootstrap();
                // One snapshot serves both the decision and the target
                // selection; a second read could disagree with the first
                // when another mux owner mutates the tree in between.
                let tree = self.tree();
                match initial_bootstrap(&tree) {
                    InitialBootstrap::FirstWorkspace => {
                        mux.new_workspace_as(me(), None, size)?;
                    }
                    InitialBootstrap::ShellInActiveWorkspace => {
                        let workspace = tree
                            .workspaces()
                            .get(tree.active_workspace)
                            .or_else(|| tree.workspaces().first())
                            .expect("bare-session bootstrap requires at least one workspace")
                            .id;
                        mux.create_terminal_in_workspace_as(
                            me(),
                            workspace,
                            None,
                            None,
                            None,
                            size,
                        )?;
                    }
                    InitialBootstrap::LayoutIntact => {}
                }
                Ok(())
            }
            Session::Remote(remote) => {
                let tree = remote.refresh_tree()?;
                match initial_bootstrap(&tree) {
                    InitialBootstrap::FirstWorkspace => {
                        remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                        anyhow::ensure!(
                            !remote.refresh_tree()?.workspaces().is_empty(),
                            "remote session did not expose the workspace it created"
                        );
                    }
                    InitialBootstrap::ShellInActiveWorkspace => {
                        // Re-read the tree raw so the create can carry the
                        // terminal revision of the very snapshot it targets,
                        // and re-verify bareness from that snapshot: when two
                        // clients attach to one bare session, the daemon
                        // rejects the guarded create whose revision already
                        // moved, and the postcondition accepts the shell
                        // whichever client created it.
                        let snapshot = remote.request(json!({"cmd": "list-workspaces"}))?;
                        let workspaces = snapshot["workspaces"].as_array();
                        let bare = workspaces.is_some_and(|workspaces| {
                            !workspaces.is_empty()
                                // An explicit empty screen array is the only
                                // proof of bareness; a missing or malformed
                                // field fails closed and skips the create.
                                && workspaces.iter().all(|workspace| {
                                    workspace["screens"]
                                        .as_array()
                                        .is_some_and(|screens| screens.is_empty())
                                })
                        });
                        // Fail closed: without the revision metadata the
                        // create cannot carry its guard, and an unguarded
                        // create from two concurrent attaches would add two
                        // shells. A daemon old enough to omit the metadata
                        // keeps its old behavior (the session stays bare).
                        let guard = match (
                            snapshot["generation"].as_str(),
                            snapshot["terminal_revision"].as_u64(),
                        ) {
                            (Some(generation), Some(revision)) => Some((generation, revision)),
                            _ => None,
                        };
                        let create_result = match (bare, guard) {
                            (true, Some((generation, revision))) => {
                                let workspaces = workspaces.expect("bareness implies an array");
                                let target = workspaces
                                    .iter()
                                    .find(|workspace| workspace["active"].as_bool() == Some(true))
                                    .unwrap_or(&workspaces[0]);
                                let mut request = json!({
                                    "cmd": "create-terminal",
                                    "origin": "attach-bare-session-bootstrap",
                                    "mutation_id": bootstrap_mutation_id()?,
                                    "expected_generation": generation,
                                    "expected_revision": revision,
                                });
                                match target["key"].as_str() {
                                    Some(key) if !key.is_empty() => {
                                        request.set("key", json!(key));
                                    }
                                    _ => {
                                        request.set("workspace", target["id"].clone());
                                    }
                                }
                                Some(remote.request(with_size(request, size)).map(|_| ()))
                            }
                            _ => None,
                        };
                        // Refresh unconditionally: when another attach won
                        // between the first tree read and the raw snapshot,
                        // no create runs here, and without this refresh the
                        // cached tree would still show the pre-shell session.
                        let refreshed = remote.refresh_tree()?;
                        if let Some(create_result) = create_result {
                            let bootstrapped = refreshed
                                .workspaces()
                                .iter()
                                .any(|workspace| !workspace.screens.is_empty());
                            if !bootstrapped {
                                return Err(match create_result {
                                    Err(error) => error.context(
                                        "bare-session bootstrap could not create its shell",
                                    ),
                                    Ok(()) => anyhow::anyhow!(
                                        "remote session did not expose the shell it created in its bare workspace"
                                    ),
                                });
                            }
                        }
                    }
                    InitialBootstrap::LayoutIntact => {}
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

    pub fn apply_config(&self, config: &crate::config::Config) {
        if let Session::Local(mux) = self {
            apply_config_to_local_owner(mux, config);
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
                let requested_surface_id =
                    data.get("surface").and_then(Value::as_u64).map(|id| id as SurfaceId);
                let mut error = data.get("error").and_then(Value::as_str).map(str::to_string);
                let surface_id = match requested_surface_id {
                    Some(id) => {
                        match remote.try_ensure_surface_with_kind(id, SurfaceKind::Pty, Some(size))
                        {
                            Ok(remote::RemoteSurfaceAttach::Attached(_)) => Some(id),
                            Ok(
                                remote::RemoteSurfaceAttach::Retired
                                | remote::RemoteSurfaceAttach::Deferred,
                            ) => {
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
                    retry_after_ms: data.get("retry_after_ms").and_then(Value::as_u64),
                }
            }
        }
    }

    pub fn tree(&self) -> TreeView {
        match self {
            Session::Local(mux) => {
                let notifications = mux.surface_notifications();
                let presentation = mux.presentation_snapshot();
                mux.with_state(|state| {
                    let git_branches = mux.tab_git_branches_in_state(state);
                    tree::tree_from_state_with_notifications(
                        state,
                        &notifications,
                        &presentation,
                        &git_branches,
                    )
                })
            }
            Session::Remote(remote) => remote.cached_tree(),
        }
    }

    pub fn agents(&self) -> Vec<AgentInfo> {
        <Self as SessionPort>::agents(self)
    }

    fn agents_impl(&self) -> Vec<AgentInfo> {
        match self {
            Session::Local(mux) => mux
                .list_agents(None, None)
                .into_iter()
                .map(|agent| AgentInfo {
                    surface: agent.surface,
                    state: agent.state.as_str().to_string(),
                    source: agent.source.as_str().to_string(),
                    session: agent.session,
                    agent: agent.agent,
                    updated_at_ms: agent.updated_at_ms,
                })
                .collect(),
            Session::Remote(remote) => remote.cached_agents(),
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

    /// See [`RemoteSession::next_surface_overflow_retry`].
    pub fn next_surface_overflow_retry(&self) -> Option<Instant> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.next_surface_overflow_retry(),
        }
    }

    /// Applies the render size through the authoritative mux resize path.
    /// Remote mirrors are created after the server resize, so their attach
    /// replay arrives at final geometry.
    pub fn try_surface_sized(
        &self,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<SurfaceAttach> {
        match self {
            Session::Local(mux) => mux
                .surface(id)
                .map(|surface| {
                    if let Some((cols, rows)) = size {
                        mux.resize_surface_for_client(id, 0, cols, rows)?;
                    }
                    Ok(SurfaceAttach::Attached(SurfaceHandle::Local(surface, mux.clone())))
                })
                .transpose()
                .map(|surface| surface.unwrap_or(SurfaceAttach::Missing)),
            Session::Remote(remote) => {
                if remote.surface_kind(id) == SurfaceKind::Browser {
                    if remote.supports_browser_attach() {
                        remote.try_ensure_surface(id, size).map(|outcome| match outcome {
                            remote::RemoteSurfaceAttach::Attached(surface) => {
                                SurfaceAttach::Attached(SurfaceHandle::Remote(
                                    surface,
                                    remote.clone(),
                                ))
                            }
                            remote::RemoteSurfaceAttach::Retired => SurfaceAttach::Retired,
                            remote::RemoteSurfaceAttach::Deferred => SurfaceAttach::Deferred,
                        })
                    } else {
                        Ok(SurfaceAttach::Attached(SurfaceHandle::RemoteBrowserUnsupported))
                    }
                } else {
                    remote.try_ensure_surface(id, size).map(|outcome| match outcome {
                        remote::RemoteSurfaceAttach::Attached(surface) => {
                            SurfaceAttach::Attached(SurfaceHandle::Remote(surface, remote.clone()))
                        }
                        remote::RemoteSurfaceAttach::Retired => SurfaceAttach::Retired,
                        remote::RemoteSurfaceAttach::Deferred => SurfaceAttach::Deferred,
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
                let mut request = json!({"cmd": "release-surface-size", "surface": id});
                if remote
                    .supports_capability(cmux_tui_core::server::VIEW_ATTACHMENT_LEASE_CAPABILITY)
                {
                    let Some(lease) = remote.attachment_lease(id) else {
                        // The attachment may disappear before a queued release
                        // reaches the session worker. With lease-aware peers,
                        // no local lease means this view has nothing left to
                        // release, so the operation has already converged.
                        if let Some(surface) = remote.surface(id) {
                            surface.clear_reported_size();
                        }
                        return Ok(());
                    };
                    request = json!({
                        "cmd": "release-attached-view-size",
                        "surface": id,
                        "lease": lease,
                    });
                }
                remote.request(request)?;
                if let Some(surface) = remote.surface(id) {
                    surface.clear_reported_size();
                }
                Ok(())
            }
        }
    }

    pub fn surface_cwd(&self, surface: SurfaceId) -> Option<String> {
        match self {
            Session::Local(mux) => mux.surface(surface).and_then(|surface| surface.local_cwd()),
            Session::Remote(remote) => remote
                .request(json!({"cmd": "process-info", "surface": surface}))
                .ok()
                .and_then(|data| data.get("cwd").and_then(Value::as_str).map(str::to_owned)),
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

    pub fn close_screen(&self, screen: ScreenId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                if mux.close_screen_as(me(), screen)? {
                    Ok(())
                } else {
                    anyhow::bail!("unknown screen {screen}")
                }
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-screen", "screen": screen})).map(|_| ())
            }
        }
    }

    pub fn rename_screen(&self, screen: ScreenId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.rename_screen_as(me(), screen, name);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "rename-screen", "screen": screen, "name": name}))
                .map(|_| ()),
        }
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>, mode: ZoomMode) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                let _ = mux.zoom_pane_as(me(), pane, mode);
                Ok(())
            }
            Session::Remote(remote) => {
                let mode = match mode {
                    ZoomMode::Toggle => "toggle",
                    ZoomMode::On => "on",
                    ZoomMode::Off => "off",
                };
                remote.request(json!({"cmd": "zoom-pane", "pane": pane, "mode": mode})).map(|_| ())
            }
        }
    }

    #[cfg(test)]
    pub fn set_split_ratio(&self, split: SplitId, ratio: f32) -> anyhow::Result<()> {
        self.set_split_ratio_inner(split, ratio, None)
    }

    pub fn set_split_ratio_in_transaction(
        &self,
        split: SplitId,
        ratio: f32,
        owner: u64,
        transaction: u64,
    ) -> anyhow::Result<()> {
        self.set_split_ratio_inner(split, ratio, Some((owner, transaction)))
    }

    fn set_split_ratio_inner(
        &self,
        split: SplitId,
        ratio: f32,
        transaction: Option<(u64, u64)>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => transaction
                .map_or_else(
                    || mux.set_split_ratio_checked_as(me(), split, ratio),
                    |(owner, transaction)| {
                        mux.set_split_ratio_in_process_transaction_checked_as(
                            me(),
                            split,
                            ratio,
                            owner,
                            transaction,
                        )
                    },
                )
                .map_err(localized_layout_ratio_error),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "set-split-ratio",
                    "split": split,
                    "ratio": ratio,
                    "transaction": transaction.map(|(_, transaction)| transaction),
                }))
                .map(|_| ())
                .map_err(|error| normalize_remote_split_ratio_error(error, split, ratio)),
        }
    }

    pub fn set_viewport_pane_width_in_transaction(
        &self,
        pane: PaneId,
        width: f32,
        owner: u64,
        transaction: u64,
    ) -> anyhow::Result<()> {
        self.set_viewport_pane_width_inner(pane, width, Some((owner, transaction)))
    }

    fn set_viewport_pane_width_inner(
        &self,
        pane: PaneId,
        width: f32,
        transaction: Option<(u64, u64)>,
    ) -> anyhow::Result<()> {
        validate_viewport_width(width)?;
        match self {
            Session::Local(mux) => transaction
                .map_or_else(
                    || mux.set_viewport_pane_width_checked_as(me(), pane, width),
                    |(owner, transaction)| {
                        mux.set_viewport_pane_width_in_process_transaction_checked_as(
                            me(),
                            pane,
                            width,
                            owner,
                            transaction,
                        )
                    },
                )
                .map_err(localized_viewport_width_error),
            Session::Remote(remote) => {
                if !remote.supports_capability(VIEWPORT_COLUMN_RESIZE_CAPABILITY) {
                    anyhow::bail!(
                        crate::localization::catalog().layout.remote_viewport_resize_unsupported
                    );
                }
                remote
                    .request(json!({
                        "cmd": "set-viewport-pane-width",
                        "pane": pane,
                        "width": width,
                        "transaction": transaction.map(|(_, transaction)| transaction),
                    }))
                    .map(|_| ())
                    .map_err(|error| normalize_remote_viewport_width_error(error, pane))
            }
        }
    }

    pub fn undo_layout(
        &self,
        pane: PaneId,
        revision: Option<u64>,
        confirm_close: bool,
    ) -> anyhow::Result<LayoutUndoResult> {
        match self {
            Session::Local(mux) => mux.undo_layout_as(me(), pane, revision, confirm_close),
            Session::Remote(remote) => {
                if !remote.supports_capability(LAYOUT_UNDO_CAPABILITY) {
                    anyhow::bail!(
                        crate::localization::catalog().layout.remote_layout_undo_unsupported
                    );
                }
                let result = remote
                    .request(json!({
                        "cmd": "undo-layout",
                        "pane": pane,
                        "revision": revision,
                        "confirm_close": confirm_close,
                    }))
                    .map_err(normalize_remote_layout_undo_error)?;
                crate::layout_undo::decode_layout_undo_result(
                    &result,
                    &crate::localization::catalog().layout,
                )
            }
        }
    }

    pub fn close_surface(&self, surface: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                if mux.close_surface_as(me(), surface)? {
                    Ok(())
                } else {
                    anyhow::bail!("unknown surface {surface}")
                }
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-surface", "surface": surface})).map(|_| ())
            }
        }
    }

    pub fn clear_history_classified(&self, surface: SurfaceId) -> Result<(), ClearHistoryFailure> {
        match self {
            Session::Local(mux) => mux
                .surface(surface)
                .ok_or_else(|| {
                    ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "unknown surface {surface}"
                    ))
                })?
                .clear_history_or_encode_key_classified(None),
            Session::Remote(remote) => remote.clear_history_classified(surface),
        }
    }

    pub fn supports_clear_history_key_fallback(&self, surface: SurfaceId) -> bool {
        match self {
            Session::Local(mux) => mux
                .surface(surface)
                .is_some_and(|surface| surface.supports_clear_history_key_fallback()),
            Session::Remote(remote) => remote.supports_clear_history_key_fallback(surface),
        }
    }

    pub fn clear_history_or_send_key_classified(
        &self,
        surface: SurfaceId,
        fallback_key: &KeyInput,
    ) -> Result<(), ClearHistoryFailure> {
        match self {
            Session::Local(mux) => mux
                .surface(surface)
                .ok_or_else(|| {
                    ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "unknown surface {surface}"
                    ))
                })?
                .clear_history_or_encode_key_classified(Some(fallback_key)),
            Session::Remote(remote) => {
                remote.clear_history_or_send_key_classified(surface, fallback_key)
            }
        }
    }

    pub fn close_pane(&self, pane: PaneId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                if mux.close_pane_as(me(), pane)? {
                    Ok(())
                } else {
                    anyhow::bail!("unknown pane {pane}")
                }
            }
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "close-pane", "pane": pane})).map(|_| ())
            }
        }
    }

    pub fn swap_pane(&self, pane: PaneId, target: PaneId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.swap_panes_as(me(), pane, target);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "swap-pane", "pane": pane, "target": target}))
                .map(|_| ()),
        }
    }

    pub fn close_workspace(&self, workspace: WorkspaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .close_workspace_at_revision_as(me(), workspace, None)?
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown workspace {workspace}")),
            Session::Remote(remote) => remote
                .request(json!({"cmd": "close-workspace", "workspace": workspace}))
                .map(|_| ()),
        }
    }

    pub fn mark_workspaces_provider_managed(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.mark_workspaces_provider_managed_internal();
                Ok(())
            }
            Session::Remote(remote) => {
                if !remote.supports_capability(PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY) {
                    anyhow::bail!(
                        "remote cmux server cannot guard provider-managed workspaces; upgrade the server before attaching"
                    );
                }
                let authority = remote.provider_workspace_authority().ok_or_else(|| {
                    anyhow::anyhow!(
                        "machine provider did not supply workspace mirror authority; upgrade the provider before attaching"
                    )
                })?;
                remote.request(json!({
                    "cmd": "mark-workspaces-provider-managed",
                    "authority": authority.expose(),
                }))?;
                remote.confirm_provider_workspace_guard()
            }
        }
    }

    pub fn workspaces_are_provider_managed(&self) -> bool {
        match self {
            Session::Local(mux) => mux.workspaces_are_provider_managed(),
            Session::Remote(remote) => remote.provider_workspaces_are_guarded(),
        }
    }

    pub fn close_provider_managed_workspace(
        &self,
        workspace: WorkspaceId,
        key: String,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .close_provider_managed_workspace_as(me(), workspace, &key)?
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown provider-managed workspace {key}")),
            Session::Remote(remote) => {
                let authority = remote.provider_workspace_authority().ok_or_else(|| {
                    anyhow::anyhow!("machine provider did not supply workspace mirror authority")
                })?;
                remote
                    .request(json!({
                        "cmd": "close-provider-managed-workspace",
                        "workspace": workspace,
                        "key": key,
                        "authority": authority.expose(),
                    }))
                    .map(|_| ())
            }
        }
    }

    pub fn rename_surface(&self, surface: SurfaceId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.rename_surface_as(me(), surface, name);
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "rename-surface", "surface": surface, "name": name}))
                .map(|_| ()),
        }
    }

    pub fn rename_workspace(&self, workspace: WorkspaceId, name: String) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .rename_workspace_at_revision_as(me(), workspace, name, None)?
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown workspace {workspace}")),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "rename-workspace",
                    "workspace": workspace,
                    "name": name
                }))
                .map(|_| ()),
        }
    }

    pub fn rename_provider_managed_workspace(
        &self,
        workspace: WorkspaceId,
        key: String,
        name: String,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .rename_provider_managed_workspace_as(me(), workspace, &key, name)?
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown provider-managed workspace {key}")),
            Session::Remote(remote) => {
                let authority = remote.provider_workspace_authority().ok_or_else(|| {
                    anyhow::anyhow!("machine provider did not supply workspace mirror authority")
                })?;
                remote
                    .request(json!({
                        "cmd": "rename-provider-managed-workspace",
                        "workspace": workspace,
                        "key": key,
                        "name": name,
                        "authority": authority.expose(),
                    }))
                    .map(|_| ())
            }
        }
    }

    /// Retire a local placement mirror after authoritative topology removes
    /// that view. Terminal process exit alone does not retire a placement.
    pub fn forget_surface(&self, surface: SurfaceId) {
        if let Session::Remote(remote) = self {
            remote.retire_surface(surface);
        }
    }

    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.move_tab_as(me(), surface, pane, index);
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

    pub fn supports_tab_workspace_moves(&self) -> bool {
        match self {
            Session::Local(_) => true,
            Session::Remote(remote) => {
                remote.supports_capability(cmux_tui_core::server::TAB_WORKSPACE_MOVE_CAPABILITY)
            }
        }
    }

    pub fn move_tab_to_workspace(
        &self,
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.supports_tab_workspace_moves(),
            "{}",
            crate::localization::catalog().menu.move_tab_workspace_unsupported
        );
        match self {
            Session::Local(mux) => mux.move_tab_to_workspace_as(me(), surface, workspace),
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd":"move-tab-to-workspace", "surface":surface, "workspace":workspace
                }))
                .map(|_| ()),
        }
    }

    /// Whether the daemon's sidebar document is Pinned for `workspace` (a
    /// workspace public id). `None`: no document (an older daemon or an
    /// in-process mux) or the document does not place the workspace yet.
    pub(crate) fn sidebar_workspace_pinned(&self, workspace: &str) -> Option<bool> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.sidebar_workspace_pinned(workspace),
        }
    }

    /// The section and group that hold `workspace` in the daemon's sidebar
    /// document (`None` without one).
    pub(crate) fn sidebar_workspace_container(
        &self,
        workspace: &str,
    ) -> Option<(String, Option<String>)> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.sidebar_workspace_container(workspace),
        }
    }

    /// The app loop tick: the sidebar document's fallback read.
    pub(crate) fn tick_sidebar_doc(&self) {
        if let Session::Remote(remote) = self {
            remote.tick_sidebar_doc();
        }
    }

    /// When the next sidebar document fallback read is due, if one is.
    pub(crate) fn sidebar_doc_fallback_at(&self) -> Option<Instant> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.sidebar_doc_fallback_at(),
        }
    }

    /// `wake` runs on another thread when this session changed state the
    /// app loop reads after its idle wait without sending an event: a local
    /// mux asked to shut down, or a sidebar document that fell back to reads.
    pub(crate) fn set_idle_waker(&self, wake: impl Fn() + Send + Sync + 'static) {
        match self {
            Session::Local(mux) => mux.set_daemon_shutdown_waker(wake),
            Session::Remote(remote) => remote.set_idle_waker(wake),
        }
    }

    /// `sidebar.pin` / `sidebar.unpin` one workspace (by public id).
    pub(crate) fn set_sidebar_workspace_pinned(
        &self,
        workspace: &str,
        pinned: bool,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(_) => anyhow::bail!("the sidebar document is not available"),
            Session::Remote(remote) => remote.sidebar_set_workspace_pinned(workspace, pinned),
        }
    }

    /// Move a workspace to a drop slot of the drawn list. With the sidebar
    /// document it is one `sidebar.move` next to the slot's neighbor
    /// (`resource` is the workspace's public id); an older daemon gets the
    /// control protocol's `move-workspace` to `index`.
    pub(crate) fn move_workspace_to_slot(
        &self,
        workspace: WorkspaceId,
        index: usize,
        resource: Option<&str>,
        anchors: &SidebarDropAnchors,
    ) -> anyhow::Result<()> {
        if let Session::Remote(remote) = self
            && remote.sidebar_doc_active()
        {
            let resource = resource
                .ok_or_else(|| anyhow::anyhow!("workspace has no stable resource identity"))?;
            return remote.sidebar_move_workspace(resource, anchors);
        }
        self.move_workspace(workspace, index)
    }

    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.move_workspace_at_revision_as(me(), workspace, index, None)?;
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "move-workspace", "workspace": workspace, "index": index}))
                .map(|_| ()),
        }
    }
}

#[cfg(test)]
pub(crate) fn test_remote_session_without_provider_authority() -> Session {
    Session::Remote(remote::test_session_without_provider_authority())
}

/// A remote session whose event transport already died with `reason`, the
/// state the reader thread leaves behind before it synthesizes
/// `MuxEvent::Empty` on connection loss.
#[cfg(test)]
pub(crate) fn test_remote_session_with_lost_transport(reason: &str) -> Session {
    let session = remote::test_session_without_provider_authority();
    session.disconnect_transport_with_reason(Some(reason.to_string()));
    Session::Remote(session)
}

#[cfg(test)]
fn test_remote_session_with_view_attachment_leases() -> Session {
    Session::Remote(remote::test_session_with_view_attachment_leases())
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_unleased_view_surface(
    surface_id: SurfaceId,
) -> (Session, SurfaceHandle) {
    let (session, surface) = remote::test_unleased_view_surface(surface_id);
    let handle = SurfaceHandle::Remote(surface, session.clone());
    (Session::Remote(session), handle)
}

#[cfg(test)]
fn test_remote_surface_with_missing_attachment_lease(surface_id: SurfaceId) -> SurfaceHandle {
    let (session, surface) = remote::test_unleased_view_surface(surface_id);
    SurfaceHandle::Remote(surface, session)
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_live_browser(
    surface_id: SurfaceId,
    frame_seq: u64,
) -> Session {
    Session::Remote(remote::test_session_with_live_browser(surface_id, frame_seq))
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_browser_pointer_range(
    surface_id: SurfaceId,
    pointer_frame_floor_seq: u64,
    frame_seq: u64,
) -> Session {
    Session::Remote(remote::test_session_with_browser_pointer_range(
        surface_id,
        pointer_frame_floor_seq,
        frame_seq,
    ))
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_provider_authority_without_guard() -> Session {
    Session::Remote(remote::test_session_with_provider_authority_without_guard())
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_deferred_attach()
-> (Session, std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
    let (session, started, release) = remote::test_session_with_deferred_attach();
    (Session::Remote(session), started, release)
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_missing_surface_attach(surface: SurfaceId) -> Session {
    Session::Remote(remote::test_session_with_missing_surface_attach(surface))
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_deferred_sized_attach()
-> (Session, std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
    let (session, started, release) = remote::test_session_with_deferred_sized_attach();
    (Session::Remote(session), started, release)
}

#[cfg(test)]
pub(crate) struct DeferredAttachResizeFailureFixture {
    pub session: Session,
    pub attach_started: std::sync::mpsc::Receiver<()>,
    pub release_attach: std::sync::mpsc::Sender<()>,
    pub resize_started: std::sync::mpsc::Receiver<()>,
    pub release_resize: std::sync::mpsc::Sender<()>,
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_deferred_attach_and_first_resize_failure()
-> DeferredAttachResizeFailureFixture {
    let fixture = remote::test_session_with_deferred_attach_and_first_resize_failure();
    DeferredAttachResizeFailureFixture {
        session: Session::Remote(fixture.session),
        attach_started: fixture.attach_started,
        release_attach: fixture.release_attach,
        resize_started: fixture.resize_started,
        release_resize: fixture.release_resize,
    }
}

#[cfg(test)]
pub(crate) fn test_remote_session_with_blocked_attach_transport_failure(
    reached: Arc<std::sync::Barrier>,
    release: Arc<std::sync::Barrier>,
) -> Session {
    Session::Remote(remote::test_session_with_blocked_attach_transport_failure(reached, release))
}

#[cfg(test)]
mod tests;
