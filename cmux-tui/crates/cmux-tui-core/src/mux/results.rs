//! Public option and result types of Mux operations: run placements and results, terminal close/resolve/place/move results, spawn options and env validation, workspace placement and mutation results, sidebar plugin options and status, config reload errors, and daemon handoff requests.

use super::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DaemonIdentity {
    pub(crate) pid: u32,
    pub(crate) generation: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DaemonHandoffRequest {
    pub(crate) expected_identity: Option<DaemonIdentity>,
    pub(crate) force: bool,
}

impl DaemonHandoffRequest {
    pub(crate) fn unfenced(force: bool) -> Self {
        Self { expected_identity: None, force }
    }

    pub(crate) fn fenced(pid: u32, generation: String, force: bool) -> Self {
        Self { expected_identity: Some(DaemonIdentity { pid, generation }), force }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunPlacement {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RunCommandResult {
    pub placement: Option<RunPlacement>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
}

#[derive(Debug, Default)]
pub(crate) struct RunCommandOptions {
    pub pane: Option<PaneId>,
    pub new_workspace: bool,
    pub workspace_key: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub size: Option<(u16, u16)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCloseResult {
    pub surface: Option<SurfaceId>,
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
    pub already_closed: bool,
    pub terminal_revision: u64,
}

/// A precondition checked atomically with a terminal close.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalCloseGuard {
    None,
    /// The terminal has no tab placement and is not marked `keep`
    /// (`terminal-reap-v1`).
    UnplacedAndNotKept,
}

/// The close guard did not hold, so nothing changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalCloseGuardFailed;

impl fmt::Display for TerminalCloseGuardFailed {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("terminal_close_guard_failed")
    }
}

impl std::error::Error for TerminalCloseGuardFailed {}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalResolution {
    pub surface: Option<SurfaceId>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalPlacementResult {
    pub placement: Option<RunPlacement>,
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
    pub terminal_revision: u64,
    pub replayed: bool,
    pub(crate) created_path: Option<Value>,
    pub(crate) created_surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalMoveResult {
    pub placement: Option<RunPlacement>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
    pub replayed: bool,
    pub changed: bool,
}

#[derive(Debug, Clone)]
pub(super) struct TerminalReservationRequest {
    pub(super) terminal_id: TerminalId,
    pub(super) mutation: WorkspaceMutation,
    pub(super) fingerprint: Value,
    pub(super) expected_generation: Option<String>,
    pub(super) expected_revision: Option<u64>,
    pub(super) on_exit: TerminalOnExit,
    /// `split-client-keys-v1`: the tab id fixed when the creation was prepared.
    pub(super) tab_id: Option<crate::resource::TabPublicId>,
    /// Extra environment for this terminal's child only (such as the
    /// frontend user's login-shell environment), applied at spawn. Like
    /// argv and cwd it is kept with the creation receipt in the local state
    /// directory so a recovered creation spawns identically.
    pub(super) env: Vec<(String, String)>,
}

/// Longest accepted per-terminal environment: entries and total bytes.
pub(super) const MAX_TERMINAL_ENV_ENTRIES: usize = 1024;

pub(super) const MAX_TERMINAL_ENV_BYTES: usize = 256 * 1024;

/// Validate a per-terminal environment and return it as ordered pairs.
pub(crate) fn validate_terminal_env(
    env: &std::collections::BTreeMap<String, String>,
) -> anyhow::Result<Vec<(String, String)>> {
    anyhow::ensure!(
        env.len() <= MAX_TERMINAL_ENV_ENTRIES,
        "bad request: env has more than {MAX_TERMINAL_ENV_ENTRIES} entries"
    );
    let mut bytes = 0usize;
    for (key, value) in env {
        anyhow::ensure!(
            !key.is_empty() && !key.contains('=') && !key.contains('\0') && !value.contains('\0'),
            "bad request: env names must be nonempty without '=' or NUL, and values without NUL"
        );
        bytes = bytes.saturating_add(key.len()).saturating_add(value.len());
    }
    anyhow::ensure!(
        bytes <= MAX_TERMINAL_ENV_BYTES,
        "bad request: env exceeds {MAX_TERMINAL_ENV_BYTES} bytes"
    );
    Ok(env.iter().map(|(key, value)| (key.clone(), value.clone())).collect())
}

/// Internal creation field carrying a caller-chosen terminal host id.
pub(crate) const RESERVED_TERMINAL_ID_FIELD: &str = "reserved_terminal_id";

/// Environment pairs stored in a creation's `env` field.
pub(super) fn terminal_env_field(fields: &Value) -> Vec<(String, String)> {
    fields
        .get("env")
        .and_then(Value::as_object)
        .map(|env| {
            env.iter()
                .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspacePlacement {
    pub workspace: WorkspaceId,
    pub key: String,
    pub index: usize,
    pub revision: u64,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutationResult {
    pub workspace: Option<WorkspaceId>,
    pub key: String,
    pub index: Option<usize>,
    pub revision: u64,
    pub replayed: bool,
    pub changed: bool,
}

#[derive(Clone, Copy)]
pub(super) enum TreeCloseTarget {
    Pane(PaneId),
    Screen(ScreenId),
}

pub(super) enum WorkspaceMutationAuthority<'a> {
    Ordinary,
    TrustedProvider,
    ProviderCredential(&'a str),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarPluginOptions {
    pub command: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SidebarPluginStatus {
    pub surface: Option<SurfaceId>,
    pub error: Option<String>,
    pub retry_after: Option<Duration>,
}

#[derive(Debug, Default)]
pub(super) struct SidebarPluginRuntime {
    pub(super) options: Option<SidebarPluginOptions>,
    pub(super) surface: Option<SurfaceId>,
    pub(super) last_size: Option<(u16, u16)>,
    pub(super) last_error: Option<String>,
    pub(super) failures: u32,
    pub(super) retry_at: Option<Instant>,
}

pub(super) enum BrowserSurfaceAttach {
    MissingPane,
    Attached(Option<TreeDelta>),
}

/// Describes why an owner did not confirm a requested configuration reload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigReloadError {
    /// The owner stopped before it could apply the request.
    OwnerStopped,
    /// The owner did not confirm the request before the failure deadline.
    TimedOut,
}

impl fmt::Display for ConfigReloadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::OwnerStopped => "configuration reload owner stopped before applying the request",
            Self::TimedOut => "configuration reload owner did not apply the request",
        })
    }
}

impl std::error::Error for ConfigReloadError {}
