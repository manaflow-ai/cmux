//! Frontend-facing session abstraction.
//!
//! The TUI runs against either an in-process mux (`Session::Local`) or a
//! remote one over the control socket (`Session::Remote`). Remote
//! surfaces are mirrored locally: the server sends a VT replay of each
//! surface's state followed by the live pty stream, and the client feeds
//! both into its own ghostty terminal. Rendering, key encoding, and mode
//! queries then work identically in both cases.

mod cursor_provenance;
mod remote;
pub(crate) mod tree;

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_tui_core::resource::ResourceOperation;
use cmux_tui_core::server::{
    CLIENT_FOCUS_CAPABILITY, CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY,
    FRONTEND_JOURNAL_CAPABILITY, LAYOUT_UNDO_CAPABILITY, MAX_CREATION_SELECTOR_FALLBACKS,
    PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY, VIEWPORT_COLUMN_RESIZE_CAPABILITY,
    VIEWPORT_SPLITS_CAPABILITY,
};
use cmux_tui_core::{
    BrowserFrameUpdate, BrowserStatus, ClearHistoryFailure, GuardedMouseEncode, LayoutRatioError,
    LayoutUndoError, LayoutUndoResult, Mux, MuxEventReceiver, PaneId, PointerSemanticProbe,
    PointerSnapshotProbe, ResourceSelectors, ScreenId, SidebarPluginStatus, SplitDir, SplitId,
    Surface, SurfaceId, SurfaceKind, SurfaceRenderFrame, SurfaceResizeReporter,
    TerminalPointerSnapshot, ViewportWidthError, WorkspaceId, WorkspaceMutation, ZoomMode,
};
use ghostty_vt::{
    KeyInput, MouseInput, RenderState, Scrollbar, Terminal, TerminalPointerSemanticSnapshot,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

pub(crate) use remote::{
    PipeIoEvent, PipeIoQueue, PipeIoQueuePushError, RemoteMessageReader, RemoteMessageWriter,
    RemoteSession, RemoteSurface, RemoteTransport, RemoteTransportAbort,
};
pub use tree::{TabNotificationView, TreeView, WorkspaceView};

pub(crate) const CLEAR_HISTORY_UNSUPPORTED_ERROR: &str =
    "remote server does not support clear-history; restart the cmux-tui server";

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
}

#[derive(Clone)]
pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

/// Stable frontend boundary for session reads.
///
/// This is deliberately small: mutations and transport recovery remain on
/// `Session` until their command and acknowledgement semantics are migrated.
/// Agent metadata is exposed through this boundary while the normal tree read
/// remains on `Session::tree`.
pub(crate) trait SessionPort: Send + Sync {
    fn agents(&self) -> Vec<AgentInfo>;
}

impl SessionPort for Session {
    fn agents(&self) -> Vec<AgentInfo> {
        self.agents_impl()
    }
}

#[derive(Clone, Debug)]
pub(crate) struct CreationReceipt {
    origin: String,
    id: String,
}

impl CreationReceipt {
    pub(crate) fn new() -> Self {
        Self { origin: "cmux-tui".to_string(), id: uuid::Uuid::new_v4().to_string() }
    }
}

#[derive(Clone)]
pub(crate) struct AmbiguousCreation {
    remote: Arc<RemoteSession>,
    request: Value,
    created: &'static str,
}

impl std::fmt::Debug for AmbiguousCreation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AmbiguousCreation")
            .field("created", &self.created)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Display for AmbiguousCreation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} creation response timed out", self.created)
    }
}

impl std::error::Error for AmbiguousCreation {}

impl AmbiguousCreation {
    pub(crate) fn retry(&self) -> anyhow::Result<SurfaceId> {
        request_receipted_creation(&self.remote, self.request.clone(), self.created)
    }
}

fn request_receipted_creation(
    remote: &Arc<RemoteSession>,
    request: Value,
    created: &'static str,
) -> anyhow::Result<SurfaceId> {
    match remote.request(request.clone()) {
        Ok(result) => response_surface(&result, created),
        Err(error) if is_remote_timeout(&error) => {
            Err(AmbiguousCreation { remote: remote.clone(), request, created }.into())
        }
        Err(error) => Err(error),
    }
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
    test_remote_rejected_error_with_message("unknown surface")
}

#[cfg(test)]
pub(crate) fn test_remote_rejected_error_with_message(message: &str) -> anyhow::Error {
    remote::RemoteRequestError::Rejected { error: message.to_string(), code: None, delivery: None }
        .into()
}

#[cfg(test)]
fn test_remote_rejected_error_with_code(message: &str, code: &str) -> anyhow::Error {
    remote::RemoteRequestError::Rejected {
        error: message.to_string(),
        code: Some(code.to_string()),
        delivery: None,
    }
    .into()
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
    pub updated_at_ms: u64,
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
    if tree.workspaces.is_empty() {
        return InitialBootstrap::FirstWorkspace;
    }
    if tree.workspaces.iter().all(|workspace| workspace.screens.is_empty()) {
        return InitialBootstrap::ShellInActiveWorkspace;
    }
    InitialBootstrap::LayoutIntact
}

/// Attach optional cols/rows fields to a remote command.
fn with_size(mut cmd: Value, size: Option<(u16, u16)>) -> Value {
    if let Some((cols, rows)) = size {
        cmd["cols"] = json!(cols);
        cmd["rows"] = json!(rows);
    }
    cmd
}

fn creation_fields(size: Option<(u16, u16)>) -> Map<String, Value> {
    let mut fields = Map::new();
    if let Some((cols, rows)) = size {
        fields.insert("cols".to_string(), json!(cols));
        fields.insert("rows".to_string(), json!(rows));
    }
    fields
}

fn creation_mutation(receipt: &CreationReceipt) -> anyhow::Result<WorkspaceMutation> {
    WorkspaceMutation::new(receipt.id.clone(), receipt.origin.clone())
}

fn creation_selector_fallbacks(
    remote: &RemoteSession,
    candidates: Vec<ResourceSelectors>,
) -> Vec<ResourceSelectors> {
    if remote.supports_capability(CREATION_SELECTOR_FALLBACKS_CAPABILITY) {
        candidates
    } else {
        Vec::new()
    }
}

fn response_surface(result: &Value, created: &str) -> anyhow::Result<SurfaceId> {
    result
        .get("surface")
        .and_then(Value::as_u64)
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

impl Session {
    /// Returns the first reason recorded when a remote transport reader stops.
    pub(crate) fn transport_disconnect_reason(&self) -> Option<String> {
        match self {
            Session::Local(_) => None,
            Session::Remote(remote) => remote.transport_disconnect_reason(),
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

    pub fn claim_terminal_geometry(&self, surface: SurfaceId) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux
                .claim_terminal_geometry(surface, 0)
                .map(|_| ())
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {surface}")),
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
            Session::Remote(_) => false,
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
                // One snapshot serves both the decision and the target
                // selection; a second read could disagree with the first
                // when another mux owner mutates the tree in between.
                let tree = self.tree();
                match initial_bootstrap(&tree) {
                    InitialBootstrap::FirstWorkspace => {
                        mux.new_workspace(None, size)?;
                    }
                    InitialBootstrap::ShellInActiveWorkspace => {
                        let workspace = tree
                            .workspaces
                            .get(tree.active_workspace)
                            .or_else(|| tree.workspaces.first())
                            .expect("bare-session bootstrap requires at least one workspace")
                            .id;
                        mux.create_terminal_in_workspace(workspace, None, None, None, size)?;
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
                            !remote.refresh_tree()?.workspaces.is_empty(),
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
                                    Some(key) if !key.is_empty() => request["key"] = json!(key),
                                    _ => request["workspace"] = target["id"].clone(),
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
                                .workspaces
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
                mux.with_state(|state| {
                    tree::tree_from_state_with_notifications(state, &notifications)
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

    fn pane_creation_selector_candidates(
        &self,
        pane: Option<PaneId>,
        mut candidates: Vec<ResourceSelectors>,
    ) -> anyhow::Result<Vec<ResourceSelectors>> {
        if candidates.is_empty() {
            candidates.push(
                self.tree()
                    .resource_selectors_for_pane(pane)
                    .ok_or_else(|| anyhow::anyhow!("pane has no stable resource identity"))?,
            );
        }
        let mut unique = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            if !unique.contains(&candidate) {
                unique.push(candidate);
            }
        }
        anyhow::ensure!(
            unique.len() <= MAX_CREATION_SELECTOR_FALLBACKS + 1,
            "creation accepts one primary selector and at most \
             {MAX_CREATION_SELECTOR_FALLBACKS} fallbacks"
        );
        Ok(unique)
    }

    pub(crate) fn new_tab_receipted(
        &self,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::TabCreateTerminal,
                    selector_candidates,
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-tab",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "tab",
                    );
                }
                let result =
                    remote.request(with_size(json!({"cmd": "new-tab", "pane": pane}), size))?;
                response_surface(&result, "tab")
            }
        }
    }

    pub(crate) fn run_command_receipted(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("argv".to_string(), json!(argv));
                if let Some(cwd) = cwd {
                    fields.insert("cwd".to_string(), json!(cwd));
                }
                mux.receipted_surface_creation(
                    ResourceOperation::PaneRun,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "run-command",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "argv": argv,
                                "pane": pane,
                                "cwd": cwd,
                            }),
                            size,
                        ),
                        "command",
                    );
                }
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
            Session::Local(mux) => mux.surface(surface).and_then(|surface| surface.local_cwd()),
            Session::Remote(remote) => remote
                .request(json!({"cmd": "process-info", "surface": surface}))
                .ok()
                .and_then(|data| data.get("cwd").and_then(Value::as_str).map(str::to_owned)),
        }
    }

    pub(crate) fn new_browser_tab_receipted(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(pane, selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = Map::new();
                fields.insert("url".to_string(), json!(url));
                if let Some((cols, rows)) = size {
                    let (cell_width, cell_height) = mux.cell_pixel_size();
                    fields.insert(
                        "width_px".to_string(),
                        json!(u64::from(cols) * u64::from(cell_width)),
                    );
                    fields.insert(
                        "height_px".to_string(),
                        json!(u64::from(rows) * u64::from(cell_height)),
                    );
                }
                mux.receipted_surface_creation(
                    ResourceOperation::TabCreateBrowser,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if !remote.supports_browser_attach() {
                    anyhow::bail!("browser panes are not supported over attach yet");
                }
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-browser-tab",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "url": url,
                                "pane": pane,
                            }),
                            size,
                        ),
                        "browser",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-browser-tab", "url": url, "pane": pane}),
                    size,
                ))?;
                result
                    .get("surface")
                    .and_then(Value::as_u64)
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

    pub(crate) fn new_workspace_receipted(
        &self,
        size: Option<(u16, u16)>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("initial_content".to_string(), json!("terminal"));
                mux.receipted_surface_creation(
                    ResourceOperation::WorkspaceCreate,
                    vec![TreeView::session_resource_selectors()],
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = TreeView::session_resource_selectors();
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-workspace",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                            }),
                            size,
                        ),
                        "workspace",
                    );
                }
                let result = remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                response_surface(&result, "workspace")
            }
        }
    }

    pub(crate) fn new_screen_receipted(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let selectors = self
            .tree()
            .resource_selectors_for_workspace(workspace)
            .ok_or_else(|| anyhow::anyhow!("workspace has no stable resource identity"))?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::ScreenCreate,
                    vec![selectors],
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-screen",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "workspace": workspace,
                            }),
                            size,
                        ),
                        "screen",
                    );
                }
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
                if mux.close_screen(screen)? {
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
                mux.rename_screen(screen, name);
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
                let _ = mux.zoom_pane(pane, mode);
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

    pub(crate) fn split_receipted(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
        mut selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        let direction = match dir {
            SplitDir::Right => "right",
            SplitDir::Down => "down",
        };
        match self {
            Session::Local(mux) => {
                let mutation = WorkspaceMutation::new(receipt.id.clone(), receipt.origin.clone())?;
                let mut fields = Map::new();
                fields.insert("direction".to_string(), json!(direction));
                if let Some((cols, rows)) = size {
                    fields.insert("cols".to_string(), json!(cols));
                    fields.insert("rows".to_string(), json!(rows));
                }
                mux.receipted_surface_creation(
                    ResourceOperation::PaneSplit,
                    selector_candidates,
                    fields,
                    &mutation,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": format!("split-{direction}"),
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "split",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "split", "pane": pane, "dir": direction}),
                    size,
                ))?;
                response_surface(&result, "split")
            }
        }
    }

    pub(crate) fn new_pane_receipted(
        &self,
        pane: PaneId,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        let mut selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        match self {
            Session::Local(mux) => mux
                .receipted_surface_creation(
                    ResourceOperation::PaneCreate,
                    selector_candidates,
                    creation_fields(size),
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface),
            Session::Remote(remote) => {
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-pane",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                            }),
                            size,
                        ),
                        "pane",
                    );
                }
                let result =
                    remote.request(with_size(json!({"cmd": "new-pane", "pane": pane}), size))?;
                response_surface(&result, "pane")
            }
        }
    }

    pub(crate) fn new_pane_right_receipted(
        &self,
        pane: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<ResourceSelectors>,
        receipt: &CreationReceipt,
    ) -> anyhow::Result<SurfaceId> {
        validate_viewport_width(width)?;
        let mut selector_candidates =
            self.pane_creation_selector_candidates(Some(pane), selector_candidates)?;
        match self {
            Session::Local(mux) => {
                let mut fields = creation_fields(size);
                fields.insert("direction".to_string(), json!("right"));
                fields.insert("viewport_width".to_string(), json!(width));
                mux.receipted_surface_creation(
                    ResourceOperation::PaneSplit,
                    selector_candidates,
                    fields,
                    &creation_mutation(receipt)?,
                )
                .map(|(surface, _)| surface)
            }
            Session::Remote(remote) => {
                if !remote.supports_capability(VIEWPORT_SPLITS_CAPABILITY) {
                    anyhow::bail!(
                        crate::localization::catalog().layout.remote_viewport_panes_unsupported
                    );
                }
                if remote.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
                    let selectors = selector_candidates.remove(0);
                    return request_receipted_creation(
                        remote,
                        with_size(
                            json!({
                                "cmd": "create-surface-with-receipt",
                                "operation": "new-pane-right",
                                "origin": &receipt.origin,
                                "receipt": &receipt.id,
                                "selectors": selectors,
                                "selector_fallbacks": creation_selector_fallbacks(
                                    remote,
                                    selector_candidates,
                                ),
                                "pane": pane,
                                "width": width,
                            }),
                            size,
                        ),
                        "pane",
                    );
                }
                let result = remote.request(with_size(
                    json!({"cmd": "new-pane-right", "pane": pane, "width": width}),
                    size,
                ))?;
                response_surface(&result, "pane")
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
                    || mux.set_split_ratio_checked(split, ratio),
                    |(owner, transaction)| {
                        mux.set_split_ratio_in_process_transaction_checked(
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
                    || mux.set_viewport_pane_width_checked(pane, width),
                    |(owner, transaction)| {
                        mux.set_viewport_pane_width_in_process_transaction_checked(
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
            Session::Local(mux) => mux.undo_layout(pane, revision, confirm_close),
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
                if mux.close_surface(surface)? {
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
                if mux.close_pane(pane)? {
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
            Session::Local(mux) => mux
                .close_workspace_at_revision(workspace, None)?
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
                .close_provider_managed_workspace(workspace, &key)?
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
            Session::Local(mux) => mux
                .rename_workspace_at_revision(workspace, name, None)?
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
                .rename_provider_managed_workspace(workspace, &key, name)?
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
                mux.move_workspace_at_revision(workspace, index, None)?;
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({"cmd": "move-workspace", "workspace": workspace, "index": index}))
                .map(|_| ()),
        }
    }
}

impl SurfaceHandle {
    #[cfg(test)]
    pub(crate) fn test_scan_cursor_provenance(&self, bytes: &[u8]) {
        if let SurfaceHandle::Remote(surface, _) = self {
            surface.test_scan_cursor_provenance(bytes);
        }
    }

    pub fn is_remote(&self) -> bool {
        matches!(self, SurfaceHandle::Remote(_, _))
    }

    /// Whether the terminal application authored its cursor style (DECSCUSR)
    /// rather than inheriting a session or frontend default. A scoped attach
    /// client mirrors the cursor to the host terminal only when this is true.
    /// Local surfaces render inside a full TUI that owns the host cursor, so
    /// they always report true.
    pub fn cursor_style_authored(&self) -> bool {
        match self {
            SurfaceHandle::Local(_, _) => true,
            SurfaceHandle::Remote(surface, _) => surface.cursor_style_authored(),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn kind(&self) -> SurfaceKind {
        match self {
            SurfaceHandle::Local(surface, _) => surface.kind(),
            SurfaceHandle::Remote(surface, _) => surface.kind,
            SurfaceHandle::RemoteBrowserUnsupported => SurfaceKind::Browser,
        }
    }

    pub fn is_dead(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.is_dead(),
            SurfaceHandle::Remote(surface, session) => session.surface_is_exited(surface.id),
            SurfaceHandle::RemoteBrowserUnsupported => false,
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
                let mut request = json!({
                    "cmd": "resize-surface",
                    "surface": surface.id,
                    "cols": desired.0,
                    "rows": desired.1,
                });
                if session
                    .supports_capability(cmux_tui_core::server::VIEW_ATTACHMENT_LEASE_CAPABILITY)
                {
                    let Some(lease) = session.attachment_lease(surface.id) else {
                        // The surface handle can outlive the attachment that
                        // authorized this resize. Treat that lifecycle race as
                        // superseded, exactly like the server does for a
                        // retired lease token.
                        surface.clear_reported_size();
                        report(None);
                        return Ok(false);
                    };
                    request = json!({
                        "cmd": "resize-attached-view",
                        "surface": surface.id,
                        "lease": lease,
                        "cols": desired.0,
                        "rows": desired.1,
                    });
                }
                let response = match session.request(request) {
                    Ok(response) => response,
                    Err(error) => {
                        report(None);
                        return Err(error);
                    }
                };
                match response.get("outcome").and_then(Value::as_str) {
                    Some("superseded") => {
                        report(None);
                        return Ok(false);
                    }
                    Some("passive") => {
                        surface.set_reported_size(desired);
                        report(None);
                        return Ok(false);
                    }
                    Some("applied") | None => {}
                    Some(other) => {
                        report(None);
                        anyhow::bail!("unknown resize outcome {other}");
                    }
                }
                let accepted = response.get("accepted").and_then(Value::as_bool).unwrap_or(true);
                surface.set_reported_size(desired);
                if !accepted {
                    report(None);
                    return Ok(false);
                }
                response.get("reservation_id").and_then(Value::as_u64).or(Some(0))
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
            SurfaceHandle::Local(surface, _) => surface.render_view_frame(rs),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                rs.update(&mut term)?;
                let palette_colors = std::array::from_fn(|idx| rs.palette_color(idx as u8));
                let palette_overridden =
                    std::array::from_fn(|idx| rs.palette_overridden(idx as u8));
                Ok(Arc::new(SurfaceRenderFrame {
                    frame: rs.build_frame()?,
                    content_generation: surface.content_generation.load(Ordering::Acquire),
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
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
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse(input, output),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse(input, output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_if_semantics(expected, input, output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_if_semantics(expected, input, output))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_if_snapshot(expected, input, output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_if_snapshot(expected, input, output))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
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
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
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

    pub fn encode_mouse_press_pair_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse_press_pair_if_snapshot(
                expected,
                press,
                release,
                press_output,
                release_output,
            ),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_press_pair_if_snapshot(
                    expected,
                    press,
                    release,
                    press_output,
                    release_output,
                ))
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

    pub fn try_pointer_semantics(&self) -> Option<PointerSemanticProbe> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.try_pointer_semantics(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.try_pointer_semantics())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn try_pointer_snapshot(&self) -> Option<PointerSnapshotProbe> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.try_pointer_snapshot(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.try_pointer_snapshot())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_delta(&self, delta: isize) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let before = surface.view_scrollbar()?.offset;
                let after = surface.view_scroll_delta(delta).ok()??.offset;
                Some(before != after)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_delta(delta);
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                if before != after {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> Option<Scrollbar> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.view_scroll_delta_if_scrollbar(expected, delta).ok().flatten()
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar();
                if before != Some(expected) {
                    return None;
                }
                term.scroll_delta(delta);
                let after = term.scrollbar();
                if after != before {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                after
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_to_bottom(&self) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.view_scroll_to_bottom().ok(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_to_bottom();
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                if before != after {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scrollbar(&self) -> Option<Scrollbar> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.view_scrollbar(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.term.lock().unwrap().scrollbar()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frame_update(&self) -> Option<BrowserFrameUpdate> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_update(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_update()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_metadata(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_metadata()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    #[cfg(test)]
    pub fn browser_frame_seq(&self) -> Option<u64> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_seq(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_seq()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_accepts_pointer_frame(frame_seq),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_accepts_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn browser_pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_pointer_frame_is_in_current_route(frame_seq)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_pointer_frame_is_in_current_route(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    /// Update the renderer-local presentation acknowledgement immediately.
    /// Returns whether the exact acknowledged token changed.
    pub fn browser_acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_acknowledge_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.acknowledge_browser_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    /// Publish a renderer acknowledgement to the surface owner. Remote calls
    /// perform control-socket I/O and must run off the app event loop.
    pub fn browser_publish_pointer_frame(&self, frame_seq: u64) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let _ = surface.browser_acknowledge_pointer_frame(frame_seq);
                Ok(())
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({
                        "cmd": "browser-frame-presented",
                        "surface": surface.id,
                        "frame_seq": frame_seq,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn has_browser_frame(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.has_browser_frame(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.has_browser_frame()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
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

    pub fn browser_key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_key_press(key, code, windows_virtual_key_code, modifiers, text)
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({
                        "cmd": "browser-key-press",
                        "surface": surface.id,
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

    pub fn browser_mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_mouse_event_for_frame(
                event_type,
                x,
                y,
                button,
                click_count,
                frame_seq,
            ),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let frame_seq = frame_seq.ok_or_else(|| {
                    anyhow::anyhow!("remote browser pointer input requires an admitted frame")
                })?;
                let (kind, lifecycle) = match event_type {
                    "mousePressed" => ("down", remote::GuardedPointerLifecycle::CaptureMutation),
                    "mouseReleased" => ("up", remote::GuardedPointerLifecycle::CaptureMutation),
                    "mouseMoved" => ("move", remote::GuardedPointerLifecycle::Motion),
                    _ => anyhow::bail!("bad browser mouse event type {event_type:?}"),
                };
                session
                    .request_guarded_pointer(
                        json!({
                            "cmd": "browser-mouse-guarded",
                            "surface": surface.id,
                            "kind": kind,
                            "x_px": x,
                            "y_px": y,
                            "button": button,
                            "click_count": click_count,
                            "frame_seq": frame_seq,
                        }),
                        lifecycle,
                    )
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_wheel_for_frame(x, y, delta_y, frame_seq)
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let frame_seq = frame_seq.ok_or_else(|| {
                    anyhow::anyhow!("remote browser pointer input requires an admitted frame")
                })?;
                session
                    .request(json!({
                        "cmd": "browser-wheel-guarded",
                        "surface": surface.id,
                        "x_px": x,
                        "y_px": y,
                        "delta_y_px": delta_y,
                        "frame_seq": frame_seq,
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
mod tests {
    use cmux_tui_core::{LayoutUndoError, Mux, SurfaceOptions};

    use super::{
        Session, SessionPort, is_remote_surface_unavailable, normalize_remote_layout_undo_error,
        resize_action, test_remote_rejected_error_with_code,
        test_remote_rejected_error_with_message, test_remote_session_with_view_attachment_leases,
        test_remote_surface_with_missing_attachment_lease, test_remote_transport_error,
    };

    #[test]
    fn releasing_a_missing_remote_attachment_lease_is_idempotent() {
        let session = test_remote_session_with_view_attachment_leases();

        session.release_surface_size(77).expect("a missing lease is already released");
    }

    #[test]
    fn remote_transport_shutdown_is_not_a_local_owner_shutdown() {
        let session = super::test_remote_session_without_provider_authority();

        assert!(!session.daemon_shutdown_requested());
        session.begin_shutdown();
        assert!(!session.daemon_shutdown_requested());
    }

    #[test]
    fn resizing_a_surface_after_its_attachment_disappears_is_superseded() {
        let surface = test_remote_surface_with_missing_attachment_lease(77);
        let (report_tx, report_rx) = std::sync::mpsc::sync_channel(1);

        let accepted = surface
            .resize_reporting_acceptance(
                100,
                30,
                false,
                Box::new(move |reservation| report_tx.send(reservation).unwrap()),
            )
            .expect("a resize cannot fail after its attachment has already disappeared");

        assert!(!accepted);
        assert_eq!(report_rx.recv().unwrap(), None);
    }

    #[test]
    fn remote_surface_unavailable_matches_only_the_requested_surface_rejection() {
        assert!(is_remote_surface_unavailable(
            &test_remote_rejected_error_with_message("unknown surface 77"),
            77
        ));
        assert!(!is_remote_surface_unavailable(
            &test_remote_rejected_error_with_message("unknown surface 78"),
            77
        ));
        assert!(!is_remote_surface_unavailable(&test_remote_transport_error(), 77));
    }

    #[test]
    fn remote_layout_undo_error_codes_restore_typed_failures() {
        let stale = normalize_remote_layout_undo_error(test_remote_rejected_error_with_code(
            "layout changed",
            LayoutUndoError::STALE_CODE,
        ));
        assert!(matches!(
            stale.downcast_ref::<LayoutUndoError>(),
            Some(LayoutUndoError::Stale(message)) if message == "layout changed"
        ));

        let unavailable = normalize_remote_layout_undo_error(test_remote_rejected_error_with_code(
            "no layout change to undo",
            LayoutUndoError::UNAVAILABLE_CODE,
        ));
        assert!(matches!(
            unavailable.downcast_ref::<LayoutUndoError>(),
            Some(LayoutUndoError::Unavailable)
        ));
    }

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

    #[test]
    fn session_port_agents_matches_existing_agent_read() {
        let session =
            Session::Local(Mux::new("session-port-agents-test", SurfaceOptions::default()));
        let direct = session.agents_impl();
        let port: &dyn SessionPort = &session;
        assert_eq!(port.agents(), direct);
    }

    #[test]
    fn local_provider_guard_surfaces_actionable_ordinary_mutation_errors() {
        let mux = Mux::new("local-provider-guard-test", SurfaceOptions::default());
        let workspace = mux
            .create_empty_workspace(
                Some("managed".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa06".into()),
                None,
            )
            .unwrap();
        let session = Session::Local(mux.clone());
        session.mark_workspaces_provider_managed().unwrap();

        let rename_error =
            session.rename_workspace(workspace.workspace, "raw rename".into()).unwrap_err();
        let close_error = session.close_workspace(workspace.workspace).unwrap_err();

        assert_eq!(
            rename_error.to_string(),
            "cannot rename a provider-managed workspace directly; use the managed workspace lifecycle controls"
        );
        assert_eq!(
            close_error.to_string(),
            "cannot close a provider-managed workspace directly; use the managed workspace lifecycle controls"
        );
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].name, "managed");
        });
    }
}
