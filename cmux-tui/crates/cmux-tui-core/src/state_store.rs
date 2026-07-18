//! Crash-consistent persistence for canonical daemon sessions.
//!
//! A versioned atomic checkpoint contains the latest compacted canonical
//! topology. Every later acknowledged mutation is first appended to a
//! checksummed journal and synced to stable storage. Terminal output and live
//! process identifiers are deliberately absent from this format.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::remote_tmux_producer::ExternalTerminalProvenance;
use crate::terminal_activity::{
    LEGACY_TERMINAL_ACTIVITY_READER_UUID, MAX_TERMINAL_ACTIVITY_FACTS,
    MAX_TERMINAL_ACTIVITY_READERS, MAX_TERMINAL_ACTIVITY_STABLE_RECEIPTS,
};
use crate::{
    PaneUuid, ScreenUuid, SessionId, SurfaceUuid, TerminalActivityFact,
    TerminalActivityReadReceipt, WorkspaceUuid, platform,
};

pub const STATE_STORE_VERSION: u32 = 4;

pub(crate) const MAX_PERSISTED_TOMBSTONES: usize = 1_024;
pub(crate) const MAX_PERSISTED_IDEMPOTENCY_RESULTS: usize = 1_024;

const SESSION_PATH_NAMESPACE: Uuid = Uuid::from_u128(0x9f87_2e39_dcd4_4d89_a43f_2977_1b35_754a);
const CHECKPOINT_FORMAT: &str = "cmux-canonical-session";
const JOURNAL_FORMAT: &str = "cmux-canonical-mutation";
const DEFAULT_MAX_CHECKPOINT_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_MAX_JOURNAL_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_MAX_JOURNAL_RECORD_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_MAX_JOURNAL_RECORDS: usize = 64;
const MAX_PERSISTED_WORKSPACES: usize = 4_096;
const MAX_PERSISTED_SCREENS: usize = 16_384;
const MAX_PERSISTED_PANES: usize = 16_384;
const MAX_PERSISTED_SURFACES: usize = 65_536;
const MAX_NAME_BYTES: usize = 16 * 1024;
const MAX_ARGV_ITEMS: usize = 4_096;
const MAX_ARGV_BYTES: usize = 256 * 1024;
const MAX_CWD_BYTES: usize = 16 * 1024;
const MAX_ENV_ITEMS: usize = 128;
const MAX_ENV_BYTES: usize = 256 * 1024;
const MAX_PERSISTED_LAUNCH_ATTEMPTS: usize = MAX_PERSISTED_SURFACES;
const LAUNCH_ATTEMPT_NAMESPACE: Uuid = Uuid::from_u128(0x30fc_a621_77c7_4df4_abe3_f09f_555b_80e6);

#[derive(Debug)]
pub enum StateStoreError {
    Io { path: PathBuf, source: std::io::Error },
    Corrupt { path: PathBuf, reason: String },
    Unavailable { reason: String },
}

impl StateStoreError {
    fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Self::Io { path: path.into(), source }
    }

    fn corrupt(path: impl Into<PathBuf>, reason: impl Into<String>) -> Self {
        Self::Corrupt { path: path.into(), reason: reason.into() }
    }
}

impl fmt::Display for StateStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => {
                write!(formatter, "state store I/O at {}: {source}", path.display())
            }
            Self::Corrupt { path, reason } => {
                write!(formatter, "refusing corrupt state at {}: {reason}", path.display())
            }
            Self::Unavailable { reason } => formatter.write_str(reason),
        }
    }
}

impl std::error::Error for StateStoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Corrupt { .. } | Self::Unavailable { .. } => None,
        }
    }
}

/// The exact filesystem phase reached by a durable mutation.
///
/// Callers use this value to distinguish a mutation rejected before it could
/// change durable bytes from a mutation whose commit status needs recovery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DurableIoPhase {
    Validation,
    CircuitOpen,
    JournalOpen,
    JournalWrite,
    JournalSync,
    JournalResync,
    JournalRollbackTruncate,
    JournalRollbackSync,
    AtomicTempOpen,
    AtomicTempWrite,
    AtomicTempSync,
    AtomicRename,
    AtomicDirectorySync,
}

impl DurableIoPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Validation => "validation",
            Self::CircuitOpen => "circuit-open",
            Self::JournalOpen => "journal-open",
            Self::JournalWrite => "journal-write",
            Self::JournalSync => "journal-sync",
            Self::JournalResync => "journal-resync",
            Self::JournalRollbackTruncate => "journal-rollback-truncate",
            Self::JournalRollbackSync => "journal-rollback-sync",
            Self::AtomicTempOpen => "atomic-temp-open",
            Self::AtomicTempWrite => "atomic-temp-write",
            Self::AtomicTempSync => "atomic-temp-sync",
            Self::AtomicRename => "atomic-rename",
            Self::AtomicDirectorySync => "atomic-directory-sync",
        }
    }
}

/// Whether a failed operation is known not to have committed or must be
/// reconciled before another durable mutation is allowed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DurableFailureResolution {
    Rejected,
    CommitIndeterminate,
}

#[derive(Debug)]
pub(crate) struct DurableWriteFailure {
    pub phase: DurableIoPhase,
    pub resolution: DurableFailureResolution,
    pub error: StateStoreError,
}

impl DurableWriteFailure {
    fn io(
        phase: DurableIoPhase,
        resolution: DurableFailureResolution,
        path: impl Into<PathBuf>,
        source: std::io::Error,
    ) -> Self {
        Self { phase, resolution, error: StateStoreError::io(path, source) }
    }

    fn rejected(error: StateStoreError) -> Self {
        Self {
            phase: DurableIoPhase::Validation,
            resolution: DurableFailureResolution::Rejected,
            error,
        }
    }
}

/// A successful append receipt or a failure whose commit certainty is
/// explicit. `CommitIndeterminate` must open the storage circuit and retain
/// the exact logical mutation for reconciliation; it must never be retried as
/// a new request.
#[derive(Debug)]
pub(crate) enum DurableAppendOutcome {
    Committed { epoch: u64, sequence: u64 },
    Rejected(DurableWriteFailure),
    CommitIndeterminate(DurableWriteFailure),
}

#[derive(Debug)]
enum DurableIoOutcome {
    Committed,
    Rejected(DurableWriteFailure),
    CommitIndeterminate(DurableWriteFailure),
}

impl DurableAppendOutcome {
    fn into_legacy_result(self) -> Result<(), StateStoreError> {
        match self {
            Self::Committed { .. } => Ok(()),
            Self::Rejected(failure) | Self::CommitIndeterminate(failure) => Err(failure.error),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StorageCircuitIncident {
    pub id: Uuid,
    pub phase: DurableIoPhase,
    pub resolution: DurableFailureResolution,
    pub path: PathBuf,
    pub message: String,
}

/// Session-local storage health. The daemon keeps this value and the session
/// lock alive while degraded so existing PTYs can continue serving reads and
/// input while new durable mutations are rejected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StorageCircuit {
    Healthy,
    Degraded(StorageCircuitIncident),
}

impl StorageCircuit {
    fn incident(failure: &DurableWriteFailure) -> StorageCircuitIncident {
        let (path, message) = match &failure.error {
            StateStoreError::Io { path, source } => (path.clone(), source.to_string()),
            StateStoreError::Corrupt { path, reason } => (path.clone(), reason.clone()),
            StateStoreError::Unavailable { reason } => (PathBuf::new(), reason.clone()),
        };
        StorageCircuitIncident {
            id: Uuid::new_v4(),
            phase: failure.phase,
            resolution: failure.resolution,
            path,
            message,
        }
    }
}

/// Injected durable filesystem boundary. Tests provide a deterministic fault
/// script; production uses direct owner-only file operations. No process-wide
/// environment switches participate in storage behavior.
pub(crate) trait DurableIo: fmt::Debug + Send + Sync {
    fn open_append(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<File>;
    fn open_temp(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<File>;
    fn write(&self, phase: DurableIoPhase, file: &mut File, bytes: &[u8])
    -> std::io::Result<usize>;
    fn sync_file(&self, phase: DurableIoPhase, file: &File) -> std::io::Result<()>;
    fn set_len(&self, phase: DurableIoPhase, file: &File, length: u64) -> std::io::Result<()>;
    fn rename(&self, phase: DurableIoPhase, from: &Path, to: &Path) -> std::io::Result<()>;
    fn sync_directory(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<()>;
}

#[derive(Debug, Default)]
struct SystemDurableIo;

impl DurableIo for SystemDurableIo {
    fn open_append(&self, _phase: DurableIoPhase, path: &Path) -> std::io::Result<File> {
        open_private_state_file(path, |options| {
            options.create(true).append(true);
        })
    }

    fn open_temp(&self, _phase: DurableIoPhase, path: &Path) -> std::io::Result<File> {
        open_private_state_file(path, |options| {
            options.create_new(true).write(true);
        })
    }

    fn write(
        &self,
        _phase: DurableIoPhase,
        file: &mut File,
        bytes: &[u8],
    ) -> std::io::Result<usize> {
        file.write(bytes)
    }

    fn sync_file(&self, _phase: DurableIoPhase, file: &File) -> std::io::Result<()> {
        file.sync_all()
    }

    fn set_len(&self, _phase: DurableIoPhase, file: &File, length: u64) -> std::io::Result<()> {
        file.set_len(length)
    }

    fn rename(&self, _phase: DurableIoPhase, from: &Path, to: &Path) -> std::io::Result<()> {
        fs::rename(from, to)
    }

    fn sync_directory(&self, _phase: DurableIoPhase, path: &Path) -> std::io::Result<()> {
        sync_directory_io(path)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRecovery {
    pub session_id: SessionId,
    pub archived_corrupt_state: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy)]
struct StateStoreLimits {
    max_checkpoint_bytes: usize,
    max_journal_bytes: usize,
    max_journal_record_bytes: usize,
    max_journal_records: usize,
}

impl Default for StateStoreLimits {
    fn default() -> Self {
        Self {
            max_checkpoint_bytes: DEFAULT_MAX_CHECKPOINT_BYTES,
            max_journal_bytes: DEFAULT_MAX_JOURNAL_BYTES,
            max_journal_record_bytes: DEFAULT_MAX_JOURNAL_RECORD_BYTES,
            max_journal_records: DEFAULT_MAX_JOURNAL_RECORDS,
        }
    }
}

#[derive(Debug, Clone)]
pub struct StateStore {
    root: PathBuf,
    limits: StateStoreLimits,
    io: Arc<dyn DurableIo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredSessionV1 {
    version: u32,
    session: String,
    session_id: SessionId,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedSessionStateV2 {
    session_id: SessionId,
    topology_revision: u64,
    active_workspace: Option<WorkspaceUuid>,
    workspaces: Vec<PersistedWorkspace>,
    panes: Vec<PersistedPane>,
    surfaces: Vec<PersistedSurface>,
    tombstones: Vec<PersistedTombstone>,
    idempotency_results: Vec<PersistedIdempotencyResult>,
}

impl From<PersistedSessionStateV2> for PersistedSessionState {
    fn from(state: PersistedSessionStateV2) -> Self {
        Self {
            session_id: state.session_id,
            topology_revision: state.topology_revision,
            active_workspace: state.active_workspace,
            workspaces: state.workspaces,
            panes: state.panes,
            surfaces: state.surfaces,
            tombstones: state.tombstones,
            idempotency_results: state.idempotency_results,
            activity_sequence: 0,
            activity_facts: Vec::new(),
            activity_receipts: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedSessionState {
    pub session_id: SessionId,
    pub topology_revision: u64,
    pub active_workspace: Option<WorkspaceUuid>,
    pub workspaces: Vec<PersistedWorkspace>,
    pub panes: Vec<PersistedPane>,
    pub surfaces: Vec<PersistedSurface>,
    pub tombstones: Vec<PersistedTombstone>,
    pub idempotency_results: Vec<PersistedIdempotencyResult>,
    pub activity_sequence: u64,
    pub activity_facts: Vec<TerminalActivityFact>,
    pub activity_receipts: Vec<TerminalActivityReadReceipt>,
}

impl PersistedSessionState {
    pub(crate) fn empty(session_id: SessionId) -> Self {
        Self {
            session_id,
            topology_revision: 0,
            active_workspace: None,
            workspaces: Vec::new(),
            panes: Vec::new(),
            surfaces: Vec::new(),
            tombstones: Vec::new(),
            idempotency_results: Vec::new(),
            activity_sequence: 0,
            activity_facts: Vec::new(),
            activity_receipts: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedWorkspace {
    pub uuid: WorkspaceUuid,
    pub name: String,
    pub screens: Vec<PersistedScreen>,
    pub active_screen: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedScreen {
    pub uuid: ScreenUuid,
    pub name: Option<String>,
    pub root: PersistedNode,
    pub active_pane: PaneUuid,
    pub zoomed_pane: Option<PaneUuid>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "node", rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) enum PersistedNode {
    Leaf {
        pane_uuid: PaneUuid,
    },
    Split {
        direction: PersistedSplitDirection,
        ratio: f32,
        first: Box<PersistedNode>,
        second: Box<PersistedNode>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum PersistedSplitDirection {
    Horizontal,
    Vertical,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedPane {
    pub uuid: PaneUuid,
    pub name: Option<String>,
    pub tabs: Vec<SurfaceUuid>,
    pub active_tab: usize,
    pub active_at: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedSurface {
    pub uuid: SurfaceUuid,
    pub name: Option<String>,
    pub kind: PersistedSurfaceKind,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum PersistedBrowserPresentationMode {
    /// Historical browser records omitted presentation mode and used cmuxd CDP rendering.
    #[default]
    DaemonRendered,
    FrontendNative,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub(crate) enum PersistedSurfaceKind {
    Terminal {
        launch: PersistedLaunchRecipe,
    },
    /// Ghostty parser/render state fed by an external producer such as tmux.
    /// It deliberately has no command recipe, so recovery cannot accidentally
    /// turn a remote mirror into a local shell.
    ExternalTerminal {
        cols: u16,
        rows: u16,
        scrollback: usize,
        no_reflow: bool,
        #[serde(default)]
        provenance: Option<ExternalTerminalProvenance>,
    },
    /// Browser placement is durable, but its URL and engine state are not.
    /// URLs may contain bearer credentials, query secrets, and private data.
    Browser {
        #[serde(default)]
        presentation: PersistedBrowserPresentationMode,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedLaunchRecipe {
    pub argv: Vec<String>,
    pub cwd: Option<String>,
    pub environment: Vec<PersistedEnvironmentVariable>,
    pub cols: u16,
    pub rows: u16,
    pub scrollback: usize,
    pub wait_after_command: bool,
}

/// Durable activation state for one terminal recipe. Pending and quarantined
/// attempts are deliberately stored outside canonical topology, so daemon
/// recovery cannot discover them through `PersistedSurfaceKind::Terminal` and
/// execute them automatically.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum PersistedLaunchAttemptPhase {
    PendingActivation,
    Active,
    Quarantined,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedLaunchAttempt {
    pub attempt_id: Uuid,
    pub request_id: String,
    pub payload_digest: String,
    pub surface_uuid: SurfaceUuid,
    pub launch: PersistedLaunchRecipe,
    pub phase: PersistedLaunchAttemptPhase,
}

impl PersistedLaunchAttempt {
    /// Startup never promotes a pending launch. It becomes quarantined in the
    /// recovered in-memory image and remains absent from visible topology.
    fn quarantine_for_recovery(&mut self) {
        if self.phase == PersistedLaunchAttemptPhase::PendingActivation {
            self.phase = PersistedLaunchAttemptPhase::Quarantined;
        }
    }
}

impl PersistedLaunchRecipe {
    pub(crate) fn sanitized(
        argv: Vec<String>,
        cwd: Option<String>,
        environment: Vec<(String, String)>,
        cols: u16,
        rows: u16,
        scrollback: usize,
        wait_after_command: bool,
    ) -> Self {
        let environment = environment
            .into_iter()
            .filter(|(name, value)| {
                persisted_environment_name_allowed(name)
                    && !name.contains(['=', '\0'])
                    && !value.contains('\0')
            })
            .collect::<BTreeMap<_, _>>()
            .into_iter()
            .map(|(name, value)| PersistedEnvironmentVariable { name, value })
            .collect();
        let cwd = cwd.map(|cwd| {
            let path = PathBuf::from(&cwd);
            if path.is_absolute() {
                cwd
            } else {
                std::env::current_dir()
                    .unwrap_or_else(|_| PathBuf::from("/"))
                    .join(path)
                    .to_string_lossy()
                    .into_owned()
            }
        });
        Self {
            argv,
            cwd,
            environment,
            cols: cols.max(1),
            rows: rows.max(1),
            scrollback,
            wait_after_command,
        }
    }

    pub(crate) fn environment_pairs(&self) -> Vec<(String, String)> {
        self.environment
            .iter()
            .map(|variable| (variable.name.clone(), variable.value.clone()))
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedEnvironmentVariable {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum PersistedEntityKind {
    Workspace,
    Screen,
    Pane,
    Surface,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedTombstone {
    pub kind: PersistedEntityKind,
    pub uuid: Uuid,
    pub removed_at_topology_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersistedIdempotencyResult {
    pub key: String,
    /// SHA-256 of the complete canonical request payload. Older internal
    /// records deserialize as empty and are never accepted as canonical
    /// replays because their payload identity cannot be proven.
    #[serde(default)]
    pub payload_digest: String,
    pub committed_topology_revision: u64,
    pub workspaces: Vec<WorkspaceUuid>,
    pub screens: Vec<ScreenUuid>,
    pub panes: Vec<PaneUuid>,
    pub surfaces: Vec<SurfaceUuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointBody {
    version: u32,
    format: String,
    session: String,
    epoch: u64,
    sequence: u64,
    state: PersistedSessionState,
    launch_attempts: Vec<PersistedLaunchAttempt>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointEnvelope {
    body: CheckpointBody,
    checksum: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointBodyV3 {
    version: u32,
    format: String,
    session: String,
    epoch: u64,
    sequence: u64,
    state: PersistedSessionState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointEnvelopeV3 {
    body: CheckpointBodyV3,
    checksum: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointBodyV2 {
    version: u32,
    format: String,
    session: String,
    epoch: u64,
    sequence: u64,
    state: PersistedSessionStateV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointEnvelopeV2 {
    body: CheckpointBodyV2,
    checksum: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalBody {
    version: u32,
    format: String,
    session_id: SessionId,
    epoch: u64,
    sequence: u64,
    idempotency_key: String,
    result: Option<PersistedIdempotencyResult>,
    state: PersistedSessionState,
    launch_attempts: Vec<PersistedLaunchAttempt>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalEnvelope {
    body: JournalBody,
    checksum: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalBodyV3 {
    version: u32,
    format: String,
    session_id: SessionId,
    epoch: u64,
    sequence: u64,
    idempotency_key: String,
    result: Option<PersistedIdempotencyResult>,
    state: PersistedSessionState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalEnvelopeV3 {
    body: JournalBodyV3,
    checksum: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalBodyV2 {
    version: u32,
    format: String,
    session_id: SessionId,
    epoch: u64,
    sequence: u64,
    idempotency_key: String,
    result: Option<PersistedIdempotencyResult>,
    state: PersistedSessionStateV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JournalEnvelopeV2 {
    body: JournalBodyV2,
    checksum: String,
}

struct TempStateFile {
    path: PathBuf,
    armed: bool,
}

pub(crate) struct SessionLock(File);

impl TempStateFile {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TempStateFile {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Drop for SessionLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

pub(crate) struct OpenedSession {
    pub snapshot: PersistedSessionState,
    pub launch_attempts: Vec<PersistedLaunchAttempt>,
    pub durable: DurableSession,
    #[cfg_attr(not(test), allow(dead_code))]
    pub quarantined_tail: Option<PathBuf>,
}

/// The daemon-lifetime journal writer and exclusive session lock.
pub(crate) struct DurableSession {
    checkpoint_path: PathBuf,
    journal_path: PathBuf,
    session: String,
    session_id: SessionId,
    epoch: u64,
    sequence: u64,
    journal_records: usize,
    journal_bytes: usize,
    latest: PersistedSessionState,
    latest_launch_attempts: Vec<PersistedLaunchAttempt>,
    limits: StateStoreLimits,
    io: Arc<dyn DurableIo>,
    storage_circuit: StorageCircuit,
    _lock: SessionLock,
}

impl DurableSession {
    /// Compatibility entry point used by the current mux integration. Terminal
    /// surfaces are represented as active attempts deterministically; pending
    /// and quarantined attempts already owned by v4 are preserved.
    pub(crate) fn append(
        &mut self,
        state: PersistedSessionState,
        idempotency_key: String,
        result: Option<PersistedIdempotencyResult>,
    ) -> Result<(), StateStoreError> {
        let launch_attempts = match reconcile_legacy_launch_attempts(
            &self.checkpoint_path,
            &state,
            &self.latest_launch_attempts,
        ) {
            Ok(attempts) => attempts,
            Err(error) => return Err(error),
        };
        self.append_resolved(state, launch_attempts, idempotency_key, result).into_legacy_result()
    }

    /// Append one complete v4 durable image and return explicit commit
    /// certainty. Mux integration must retain the logical mutation whenever
    /// this returns `CommitIndeterminate` and must not issue it again under a
    /// new idempotency key.
    pub(crate) fn append_resolved(
        &mut self,
        state: PersistedSessionState,
        launch_attempts: Vec<PersistedLaunchAttempt>,
        idempotency_key: String,
        result: Option<PersistedIdempotencyResult>,
    ) -> DurableAppendOutcome {
        if let StorageCircuit::Degraded(incident) = &self.storage_circuit {
            return DurableAppendOutcome::Rejected(DurableWriteFailure {
                phase: DurableIoPhase::CircuitOpen,
                resolution: DurableFailureResolution::Rejected,
                error: StateStoreError::Unavailable {
                    reason: format!(
                        "durable storage circuit {} remains degraded at {}",
                        incident.id,
                        incident.phase.as_str()
                    ),
                },
            });
        }
        if let Err(error) = validate_snapshot(&self.checkpoint_path, &state) {
            return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(error));
        }
        if state.session_id != self.session_id {
            return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(
                StateStoreError::corrupt(
                    &self.checkpoint_path,
                    "mutation changed the durable session identity",
                ),
            ));
        }
        if let Err(error) =
            validate_launch_attempts(&self.checkpoint_path, &state, &launch_attempts)
        {
            return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(error));
        }
        if let Err(error) = validate_idempotency_key(&self.journal_path, &idempotency_key) {
            return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(error));
        }

        let mut body = JournalBody {
            version: STATE_STORE_VERSION,
            format: JOURNAL_FORMAT.to_string(),
            session_id: self.session_id,
            epoch: self.epoch,
            sequence: match self.sequence.checked_add(1) {
                Some(sequence) => sequence,
                None => {
                    return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(
                        StateStoreError::corrupt(&self.journal_path, "journal sequence exhausted"),
                    ));
                }
            },
            idempotency_key,
            result,
            state,
            launch_attempts,
        };
        let mut bytes = match encode_journal(&self.journal_path, &body) {
            Ok(bytes) => bytes,
            Err(error) => {
                return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(error));
            }
        };
        if bytes.len() > self.limits.max_journal_record_bytes {
            return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(
                StateStoreError::corrupt(
                    &self.journal_path,
                    format!(
                        "journal record is {} bytes; limit is {}",
                        bytes.len(),
                        self.limits.max_journal_record_bytes
                    ),
                ),
            ));
        }

        if self.journal_records >= self.limits.max_journal_records
            || self.journal_bytes.saturating_add(bytes.len()) > self.limits.max_journal_bytes
        {
            if let Err(failure) = self.compact_latest_resolved() {
                return self.fail_append(failure);
            }
            body.epoch = self.epoch;
            body.sequence = 1;
            bytes = match encode_journal(&self.journal_path, &body) {
                Ok(bytes) => bytes,
                Err(error) => {
                    return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(error));
                }
            };
            if bytes.len() > self.limits.max_journal_record_bytes
                || bytes.len() > self.limits.max_journal_bytes
            {
                return DurableAppendOutcome::Rejected(DurableWriteFailure::rejected(
                    StateStoreError::corrupt(
                        &self.journal_path,
                        "one mutation cannot fit within the bounded journal",
                    ),
                ));
            }
        }

        match append_record_resolved(self.io.as_ref(), &self.journal_path, &bytes) {
            DurableIoOutcome::Committed => {
                self.sequence = body.sequence;
                self.journal_records += 1;
                self.journal_bytes += bytes.len();
                self.latest = body.state;
                self.latest_launch_attempts = body.launch_attempts;
                DurableAppendOutcome::Committed { epoch: self.epoch, sequence: self.sequence }
            }
            DurableIoOutcome::Rejected(failure)
            | DurableIoOutcome::CommitIndeterminate(failure) => self.fail_append(failure),
        }
    }

    pub(crate) fn storage_circuit(&self) -> &StorageCircuit {
        &self.storage_circuit
    }

    pub(crate) fn launch_attempts(&self) -> &[PersistedLaunchAttempt] {
        &self.latest_launch_attempts
    }

    fn fail_append(&mut self, failure: DurableWriteFailure) -> DurableAppendOutcome {
        self.storage_circuit = StorageCircuit::Degraded(StorageCircuit::incident(&failure));
        match failure.resolution {
            DurableFailureResolution::Rejected => DurableAppendOutcome::Rejected(failure),
            DurableFailureResolution::CommitIndeterminate => {
                DurableAppendOutcome::CommitIndeterminate(failure)
            }
        }
    }

    fn compact_latest_resolved(&mut self) -> Result<(), DurableWriteFailure> {
        let next_epoch = self.epoch.checked_add(1).ok_or_else(|| {
            DurableWriteFailure::rejected(StateStoreError::corrupt(
                &self.checkpoint_path,
                "checkpoint epoch exhausted",
            ))
        })?;
        match write_checkpoint_atomic_resolved(
            self.io.as_ref(),
            &self.checkpoint_path,
            &self.session,
            next_epoch,
            0,
            &self.latest,
            &self.latest_launch_attempts,
            self.limits,
        ) {
            DurableIoOutcome::Committed => {}
            DurableIoOutcome::Rejected(failure)
            | DurableIoOutcome::CommitIndeterminate(failure) => return Err(failure),
        }
        match replace_file_atomically_resolved(self.io.as_ref(), &self.journal_path, &[]) {
            DurableIoOutcome::Committed => {}
            DurableIoOutcome::Rejected(mut failure) => {
                // The later-epoch checkpoint is already visible. Keeping the
                // old journal is replay-safe, but the two-file compaction has
                // not reached one stable outcome, so block subsequent writes.
                failure.resolution = DurableFailureResolution::CommitIndeterminate;
                return Err(failure);
            }
            DurableIoOutcome::CommitIndeterminate(failure) => return Err(failure),
        }
        self.epoch = next_epoch;
        self.sequence = 0;
        self.journal_records = 0;
        self.journal_bytes = 0;
        Ok(())
    }
}

impl StateStore {
    /// Create a store rooted at an explicit directory.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            limits: StateStoreLimits::default(),
            io: Arc::new(SystemDurableIo),
        }
    }

    #[cfg(test)]
    fn with_limits(root: impl Into<PathBuf>, max_records: usize, max_bytes: usize) -> Self {
        let limits = StateStoreLimits {
            max_journal_records: max_records,
            max_journal_bytes: max_bytes,
            max_journal_record_bytes: max_bytes,
            ..StateStoreLimits::default()
        };
        Self { root: root.into(), limits, io: Arc::new(SystemDurableIo) }
    }

    #[cfg(test)]
    fn with_io(root: impl Into<PathBuf>, io: Arc<dyn DurableIo>) -> Self {
        Self { root: root.into(), limits: StateStoreLimits::default(), io }
    }

    #[cfg(test)]
    fn with_limits_and_io(
        root: impl Into<PathBuf>,
        max_records: usize,
        max_bytes: usize,
        io: Arc<dyn DurableIo>,
    ) -> Self {
        let limits = StateStoreLimits {
            max_journal_records: max_records,
            max_journal_bytes: max_bytes,
            max_journal_record_bytes: max_bytes,
            ..StateStoreLimits::default()
        };
        Self { root: root.into(), limits, io }
    }

    pub fn platform_default() -> Result<Self, StateStoreError> {
        let root = platform::state_dir().ok_or_else(|| StateStoreError::Unavailable {
            reason: "no platform state directory is available; pass --state-dir".to_string(),
        })?;
        Ok(Self::new(root))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn session_path(&self, session: &str) -> PathBuf {
        let key = session_key(session);
        self.root.join("sessions").join(format!("{key}.json"))
    }

    pub fn journal_path(&self, session: &str) -> PathBuf {
        let key = session_key(session);
        self.root.join("sessions").join(format!("{key}.journal"))
    }

    /// Immutable pre-migration files retained for an explicit version-2 rollback.
    ///
    /// Migration never overwrites these files. A failed or rolled-back release
    /// can therefore restore the exact checkpoint and journal bytes understood
    /// by the previous daemon instead of discovering that startup destroyed its
    /// only compatible state.
    pub fn version_two_backup_paths(&self, session: &str) -> (PathBuf, PathBuf) {
        (
            migration_backup_path(&self.session_path(session), 2),
            migration_backup_path(&self.journal_path(session), 2),
        )
    }

    /// Immutable checkpoint and journal retained before a version-3 to
    /// version-4 migration.
    pub fn version_three_backup_paths(&self, session: &str) -> (PathBuf, PathBuf) {
        (
            migration_backup_path(&self.session_path(session), 3),
            migration_backup_path(&self.journal_path(session), 3),
        )
    }

    /// Restore the exact version-2 bytes retained before migration.
    ///
    /// The caller must stop the active daemon first. The session lock prevents
    /// a concurrent daemon from observing the journal/checkpoint replacement.
    /// Backups remain after restore, so an interrupted rollback is retryable.
    pub fn restore_version_two_backup(&self, session: &str) -> Result<(), StateStoreError> {
        let _lock = self.lock_session(session)?;
        let checkpoint_path = self.session_path(session);
        let journal_path = self.journal_path(session);
        let (checkpoint_backup, journal_backup) = self.version_two_backup_paths(session);
        let checkpoint_bytes = read_bounded(&checkpoint_backup, self.limits.max_checkpoint_bytes)?
            .ok_or_else(|| {
                StateStoreError::corrupt(
                    &checkpoint_backup,
                    "version-2 migration checkpoint backup is missing",
                )
            })?;
        let journal_bytes = read_bounded(
            &journal_backup,
            self.limits.max_journal_bytes.saturating_add(self.limits.max_journal_record_bytes),
        )?
        .ok_or_else(|| {
            StateStoreError::corrupt(
                &journal_backup,
                "version-2 migration journal backup is missing",
            )
        })?;

        let value =
            serde_json::from_slice::<serde_json::Value>(&checkpoint_bytes).map_err(|error| {
                StateStoreError::corrupt(
                    &checkpoint_backup,
                    format!("invalid version-2 backup JSON: {error}"),
                )
            })?;
        let envelope = serde_json::from_value::<CheckpointEnvelopeV2>(value).map_err(|error| {
            StateStoreError::corrupt(
                &checkpoint_backup,
                format!("invalid version-2 backup checkpoint: {error}"),
            )
        })?;
        validate_checkpoint_v2(&checkpoint_backup, session, &envelope)?;
        replay_journal_v2_bytes(
            &journal_backup,
            &journal_bytes,
            envelope.body.epoch,
            envelope.body.sequence,
            envelope.body.state.clone().into(),
            self.limits,
            false,
        )?;

        // Restore journal first. If the process exits between replacements,
        // the still-version-4 checkpoint rejects the old journal rather than
        // opening silently mixed state. The final checkpoint rename makes the
        // pair readable by the previous daemon after it acquires this lock.
        replace_file_atomically(&journal_path, &journal_bytes)?;
        replace_file_atomically(&checkpoint_path, &checkpoint_bytes)
    }

    /// Restore the exact version-3 checkpoint and journal retained before
    /// migration. Validation is read-only and backups remain immutable so an
    /// interrupted rollback can be retried.
    pub fn restore_version_three_backup(&self, session: &str) -> Result<(), StateStoreError> {
        let _lock = self.lock_session(session)?;
        let checkpoint_path = self.session_path(session);
        let journal_path = self.journal_path(session);
        let (checkpoint_backup, journal_backup) = self.version_three_backup_paths(session);
        let checkpoint_bytes = read_bounded(&checkpoint_backup, self.limits.max_checkpoint_bytes)?
            .ok_or_else(|| {
                StateStoreError::corrupt(
                    &checkpoint_backup,
                    "version-3 migration checkpoint backup is missing",
                )
            })?;
        let journal_bytes = read_bounded(
            &journal_backup,
            self.limits.max_journal_bytes.saturating_add(self.limits.max_journal_record_bytes),
        )?
        .ok_or_else(|| {
            StateStoreError::corrupt(
                &journal_backup,
                "version-3 migration journal backup is missing",
            )
        })?;
        let envelope =
            serde_json::from_slice::<CheckpointEnvelopeV3>(&checkpoint_bytes).map_err(|error| {
                StateStoreError::corrupt(
                    &checkpoint_backup,
                    format!("invalid version-3 backup checkpoint: {error}"),
                )
            })?;
        validate_checkpoint_v3(&checkpoint_backup, session, &envelope)?;
        replay_journal_v3_bytes(
            &journal_backup,
            &journal_bytes,
            envelope.body.epoch,
            envelope.body.sequence,
            envelope.body.state,
            self.limits,
            false,
        )?;

        // Journal first leaves a v4 checkpoint that rejects mixed v3 records
        // if rollback stops before the final checkpoint rename.
        replace_file_atomically(&journal_path, &journal_bytes)?;
        replace_file_atomically(&checkpoint_path, &checkpoint_bytes)
    }

    /// Open a session while holding its exclusive lock for the returned
    /// daemon lifetime. Recovery validates the checkpoint before replaying
    /// strictly ordered, checksummed journal entries.
    pub(crate) fn open_session(&self, session: &str) -> Result<OpenedSession, StateStoreError> {
        let lock = self.lock_session(session)?;
        let loaded = self.load_session_while_locked(session)?;
        Ok(self.finish_open_session(session, loaded, lock))
    }

    /// Load checkpoint and journal bytes while the caller owns the session
    /// lock. Keeping the lock outside this helper lets explicit recovery
    /// revalidate and repair corrupt state in one cross-process transaction.
    fn load_session_while_locked(&self, session: &str) -> Result<LoadedSession, StateStoreError> {
        let checkpoint_path = self.session_path(session);
        let journal_path = self.journal_path(session);
        let (checkpoint, migrated) =
            self.load_or_create_checkpoint(session, &checkpoint_path, &journal_path)?;
        if migrated {
            replace_file_atomically(&journal_path, &[])?;
        }
        let replay = replay_journal(
            &journal_path,
            checkpoint.body.epoch,
            checkpoint.body.sequence,
            checkpoint.body.state,
            checkpoint.body.launch_attempts,
            self.limits,
        )?;
        Ok(LoadedSession { checkpoint_path, journal_path, replay })
    }

    fn finish_open_session(
        &self,
        session: &str,
        loaded: LoadedSession,
        lock: SessionLock,
    ) -> OpenedSession {
        let LoadedSession { checkpoint_path, journal_path, replay } = loaded;
        let mut launch_attempts = replay.launch_attempts;
        launch_attempts.iter_mut().for_each(PersistedLaunchAttempt::quarantine_for_recovery);
        OpenedSession {
            snapshot: replay.state.clone(),
            launch_attempts: launch_attempts.clone(),
            durable: DurableSession {
                checkpoint_path,
                journal_path,
                session: session.to_string(),
                session_id: replay.state.session_id,
                epoch: replay.epoch,
                sequence: replay.sequence,
                journal_records: replay.record_count,
                journal_bytes: replay.valid_bytes,
                latest: replay.state,
                latest_launch_attempts: launch_attempts,
                limits: self.limits,
                io: self.io.clone(),
                storage_circuit: StorageCircuit::Healthy,
                _lock: lock,
            },
            quarantined_tail: replay.quarantined_tail,
        }
    }

    /// Load an existing session identity or atomically create an empty
    /// version-3 session. This compatibility API releases the startup lock
    /// immediately; daemon code must use [`StateStore::open_session`].
    pub fn load_or_create_session(&self, session: &str) -> Result<SessionId, StateStoreError> {
        let opened = self.open_session(session)?;
        Ok(opened.snapshot.session_id)
    }

    /// Replace the complete durable session with a fresh empty checkpoint.
    pub fn replace_session(
        &self,
        session: &str,
        session_id: SessionId,
    ) -> Result<(), StateStoreError> {
        let _lock = self.lock_session(session)?;
        let state = PersistedSessionState::empty(session_id);
        write_checkpoint_atomic(&self.session_path(session), session, 1, 0, &state, self.limits)?;
        replace_file_atomically(&self.journal_path(session), &[])
    }

    /// Explicitly archive corrupt checkpoint/journal bytes and create a new
    /// empty session. Valid durable state is returned unchanged.
    pub fn recover_session(&self, session: &str) -> Result<StateRecovery, StateStoreError> {
        // The probe and any repair share one lock. Releasing between them lets
        // a second recovery replace the corrupt bytes, after which this caller
        // could archive that newly valid state and rotate the identity again.
        let _lock = self.lock_session(session)?;
        match self.load_session_while_locked(session) {
            Ok(loaded) => {
                return Ok(StateRecovery {
                    session_id: loaded.replay.state.session_id,
                    archived_corrupt_state: None,
                });
            }
            Err(StateStoreError::Io { path, source }) => {
                return Err(StateStoreError::Io { path, source });
            }
            Err(error @ StateStoreError::Unavailable { .. }) => return Err(error),
            Err(StateStoreError::Corrupt { .. }) => {}
        }

        let checkpoint = self.session_path(session);
        let journal = self.journal_path(session);
        let archive = checkpoint.with_extension(format!("corrupt-{}.json", Uuid::new_v4()));
        let archived_corrupt_state = archive_if_present(&checkpoint, &archive)?;
        let journal_archive = journal.with_extension(format!("corrupt-{}.journal", Uuid::new_v4()));
        let _ = archive_if_present(&journal, &journal_archive)?;
        let session_id = SessionId::new();
        let state = PersistedSessionState::empty(session_id);
        write_checkpoint_atomic(&checkpoint, session, 1, 0, &state, self.limits)?;
        replace_file_atomically(&journal, &[])?;
        Ok(StateRecovery { session_id, archived_corrupt_state })
    }

    fn load_or_create_checkpoint(
        &self,
        session: &str,
        path: &Path,
        journal_path: &Path,
    ) -> Result<(CheckpointEnvelope, bool), StateStoreError> {
        let bytes = match read_bounded(path, self.limits.max_checkpoint_bytes)? {
            Some(bytes) => bytes,
            None => {
                let state = PersistedSessionState::empty(SessionId::new());
                write_checkpoint_atomic(path, session, 1, 0, &state, self.limits)?;
                return Ok((checkpoint_envelope(session, 1, 0, &state)?, false));
            }
        };
        let value = serde_json::from_slice::<serde_json::Value>(&bytes).map_err(|error| {
            StateStoreError::corrupt(path, format!("invalid checkpoint JSON: {error}"))
        })?;
        let version = value
            .get("body")
            .and_then(|body| body.get("version"))
            .or_else(|| value.get("version"))
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| StateStoreError::corrupt(path, "missing integer checkpoint version"))?;
        if version == 1 {
            let stored = serde_json::from_value::<StoredSessionV1>(value).map_err(|error| {
                StateStoreError::corrupt(path, format!("invalid version-1 session: {error}"))
            })?;
            if stored.session != session {
                return Err(StateStoreError::corrupt(
                    path,
                    format!(
                        "session key collision: expected {session:?}, found {:?}",
                        stored.session
                    ),
                ));
            }
            let state = PersistedSessionState::empty(stored.session_id);
            write_checkpoint_atomic(path, session, 1, 0, &state, self.limits)?;
            return Ok((checkpoint_envelope(session, 1, 0, &state)?, true));
        }
        if version == 2 {
            let envelope =
                serde_json::from_value::<CheckpointEnvelopeV2>(value).map_err(|error| {
                    StateStoreError::corrupt(
                        path,
                        format!("invalid version-2 checkpoint envelope: {error}"),
                    )
                })?;
            validate_checkpoint_v2(path, session, &envelope)?;
            let replay = replay_journal_v2(
                journal_path,
                envelope.body.epoch,
                envelope.body.sequence,
                envelope.body.state.into(),
                self.limits,
            )?;
            let epoch = replay
                .epoch
                .checked_add(1)
                .ok_or_else(|| StateStoreError::corrupt(path, "checkpoint epoch exhausted"))?;
            let journal_bytes = read_bounded(
                journal_path,
                self.limits.max_journal_bytes.saturating_add(self.limits.max_journal_record_bytes),
            )?
            .unwrap_or_default();
            preserve_migration_backup(path, 2, &bytes)?;
            preserve_migration_backup(journal_path, 2, &journal_bytes)?;
            write_checkpoint_atomic(path, session, epoch, 0, &replay.state, self.limits)?;
            // The new checkpoint uses a later epoch. If the process exits
            // before this atomic reset, the v4 loader recognizes the older
            // v2 journal records as already compacted.
            replace_file_atomically(journal_path, &[])?;
            return Ok((checkpoint_envelope(session, epoch, 0, &replay.state)?, true));
        }
        if version == 3 {
            let envelope =
                serde_json::from_value::<CheckpointEnvelopeV3>(value).map_err(|error| {
                    StateStoreError::corrupt(
                        path,
                        format!("invalid version-3 checkpoint envelope: {error}"),
                    )
                })?;
            validate_checkpoint_v3(path, session, &envelope)?;
            let replay = replay_journal_v3(
                journal_path,
                envelope.body.epoch,
                envelope.body.sequence,
                envelope.body.state,
                self.limits,
            )?;
            let epoch = replay
                .epoch
                .checked_add(1)
                .ok_or_else(|| StateStoreError::corrupt(path, "checkpoint epoch exhausted"))?;
            let journal_bytes = read_bounded(
                journal_path,
                self.limits.max_journal_bytes.saturating_add(self.limits.max_journal_record_bytes),
            )?
            .unwrap_or_default();
            preserve_migration_backup(path, 3, &bytes)?;
            preserve_migration_backup(journal_path, 3, &journal_bytes)?;
            let launch_attempts = reconcile_legacy_launch_attempts(path, &replay.state, &[])?;
            match write_checkpoint_atomic_resolved(
                self.io.as_ref(),
                path,
                session,
                epoch,
                0,
                &replay.state,
                &launch_attempts,
                self.limits,
            ) {
                DurableIoOutcome::Committed => {}
                DurableIoOutcome::Rejected(failure)
                | DurableIoOutcome::CommitIndeterminate(failure) => return Err(failure.error),
            }
            // The later v4 epoch makes an older v3 journal replay-safe if the
            // process exits before the atomic reset.
            replace_file_atomically(journal_path, &[])?;
            return Ok((
                checkpoint_envelope_with_attempts(
                    session,
                    epoch,
                    0,
                    &replay.state,
                    &launch_attempts,
                )?,
                true,
            ));
        }
        if version != u64::from(STATE_STORE_VERSION) {
            return Err(StateStoreError::corrupt(
                path,
                format!("unsupported version {version}; expected {STATE_STORE_VERSION}"),
            ));
        }
        let envelope = serde_json::from_value::<CheckpointEnvelope>(value).map_err(|error| {
            StateStoreError::corrupt(path, format!("invalid checkpoint envelope: {error}"))
        })?;
        validate_checkpoint(path, session, &envelope)?;
        Ok((envelope, false))
    }

    fn lock_session(&self, session: &str) -> Result<SessionLock, StateStoreError> {
        let directory = self.root.join("locks");
        let path = directory.join(format!("{}.lock", session_key(session)));
        ensure_private_parent(&path)?;
        let file = open_private_state_file(&path, |options| {
            options.create(true).truncate(false).read(true).write(true);
        })
        .map_err(|error| StateStoreError::io(&path, error))?;
        fs2::FileExt::lock_exclusive(&file).map_err(|error| StateStoreError::io(&path, error))?;
        Ok(SessionLock(file))
    }
}

struct JournalReplay {
    state: PersistedSessionState,
    launch_attempts: Vec<PersistedLaunchAttempt>,
    epoch: u64,
    sequence: u64,
    record_count: usize,
    valid_bytes: usize,
    quarantined_tail: Option<PathBuf>,
}

struct LoadedSession {
    checkpoint_path: PathBuf,
    journal_path: PathBuf,
    replay: JournalReplay,
}

fn replay_journal(
    path: &Path,
    checkpoint_epoch: u64,
    checkpoint_sequence: u64,
    mut state: PersistedSessionState,
    mut launch_attempts: Vec<PersistedLaunchAttempt>,
    limits: StateStoreLimits,
) -> Result<JournalReplay, StateStoreError> {
    let Some(bytes) = read_bounded(
        path,
        limits.max_journal_bytes.saturating_add(limits.max_journal_record_bytes),
    )?
    else {
        replace_file_atomically(path, &[])?;
        return Ok(JournalReplay {
            state,
            launch_attempts,
            epoch: checkpoint_epoch,
            sequence: checkpoint_sequence,
            record_count: 0,
            valid_bytes: 0,
            quarantined_tail: None,
        });
    };
    let mut epoch = checkpoint_epoch;
    let mut sequence = checkpoint_sequence;
    let mut record_count = 0usize;
    let mut valid_bytes = 0usize;
    let mut seen = state
        .idempotency_results
        .iter()
        .map(|result| (result.key.clone(), result.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut cursor = 0usize;
    let mut invalid_tail = None;

    while cursor < bytes.len() {
        let line_end = bytes[cursor..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|offset| cursor + offset + 1);
        let Some(line_end) = line_end else {
            invalid_tail = Some(cursor);
            break;
        };
        let line = &bytes[cursor..line_end - 1];
        if line.is_empty() {
            if bytes[line_end..].iter().all(u8::is_ascii_whitespace) {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(path, "empty interior journal record"));
        }
        if line.len().saturating_add(1) > limits.max_journal_record_bytes {
            if line_end == bytes.len() {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(path, "oversized interior journal record"));
        }
        let stale_v2 = match stale_v2_journal_record(path, line) {
            Ok(record) => record,
            Err(error) if line_end == bytes.len() => {
                let _ = error;
                invalid_tail = Some(cursor);
                break;
            }
            Err(error) => return Err(error),
        };
        if let Some(record) = stale_v2 {
            if record.body.epoch < checkpoint_epoch
                || (record.body.epoch == checkpoint_epoch
                    && record.body.sequence <= checkpoint_sequence)
            {
                cursor = line_end;
                valid_bytes = line_end;
                continue;
            }
            return Err(StateStoreError::corrupt(
                path,
                "version-2 journal record is newer than the version-4 checkpoint",
            ));
        }
        let stale_v3 = match stale_v3_journal_record(path, line) {
            Ok(record) => record,
            Err(error) if line_end == bytes.len() => {
                let _ = error;
                invalid_tail = Some(cursor);
                break;
            }
            Err(error) => return Err(error),
        };
        if let Some(record) = stale_v3 {
            if record.body.epoch < checkpoint_epoch
                || (record.body.epoch == checkpoint_epoch
                    && record.body.sequence <= checkpoint_sequence)
            {
                cursor = line_end;
                valid_bytes = line_end;
                continue;
            }
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal record is newer than the version-4 checkpoint",
            ));
        }
        let envelope = match decode_journal(path, line) {
            Ok(envelope) => envelope,
            Err(error) if line_end == bytes.len() => {
                let _ = error;
                invalid_tail = Some(cursor);
                break;
            }
            Err(error) => return Err(error),
        };
        let body = envelope.body;
        if body.session_id != state.session_id {
            return Err(StateStoreError::corrupt(path, "journal session identity mismatch"));
        }
        if body.epoch < checkpoint_epoch
            || (body.epoch == checkpoint_epoch && body.sequence <= checkpoint_sequence)
        {
            // A crash after checkpoint rename but before atomic journal reset
            // can leave old compacted records behind.
            cursor = line_end;
            valid_bytes = line_end;
            continue;
        }
        if body.epoch != epoch || body.sequence != sequence.saturating_add(1) {
            return Err(StateStoreError::corrupt(
                path,
                format!(
                    "journal sequence gap: expected {epoch}/{}, found {}/{}",
                    sequence.saturating_add(1),
                    body.epoch,
                    body.sequence
                ),
            ));
        }
        if record_count >= limits.max_journal_records {
            return Err(StateStoreError::corrupt(
                path,
                "journal record count exceeds the compaction bound",
            ));
        }
        validate_snapshot(path, &body.state)?;
        validate_launch_attempts(path, &body.state, &body.launch_attempts)?;
        if body.state.session_id != state.session_id {
            return Err(StateStoreError::corrupt(path, "journal state changed session identity"));
        }
        if body.state.topology_revision < state.topology_revision {
            return Err(StateStoreError::corrupt(path, "journal topology revision moved backward"));
        }
        if body.state.activity_sequence < state.activity_sequence {
            return Err(StateStoreError::corrupt(path, "journal activity sequence moved backward"));
        }
        if let Some(existing) = seen.get(&body.idempotency_key) {
            if body.result.as_ref() != Some(existing)
                || body.state != state
                || body.launch_attempts != launch_attempts
            {
                return Err(StateStoreError::corrupt(
                    path,
                    "duplicate idempotency key changed its result or state",
                ));
            }
        } else {
            if let Some(result) = body.result.as_ref() {
                if result.key != body.idempotency_key {
                    return Err(StateStoreError::corrupt(
                        path,
                        "journal idempotency result key mismatch",
                    ));
                }
                seen.insert(result.key.clone(), result.clone());
            }
            state = body.state;
            launch_attempts = body.launch_attempts;
        }
        epoch = body.epoch;
        sequence = body.sequence;
        record_count += 1;
        cursor = line_end;
        valid_bytes = line_end;
    }

    let quarantined_tail = if let Some(start) = invalid_tail {
        Some(quarantine_tail(path, &bytes, start)?)
    } else {
        None
    };
    Ok(JournalReplay {
        state,
        launch_attempts,
        epoch,
        sequence,
        record_count,
        valid_bytes,
        quarantined_tail,
    })
}

fn replay_journal_v2(
    path: &Path,
    checkpoint_epoch: u64,
    checkpoint_sequence: u64,
    state: PersistedSessionState,
    limits: StateStoreLimits,
) -> Result<JournalReplay, StateStoreError> {
    let Some(bytes) = read_bounded(
        path,
        limits.max_journal_bytes.saturating_add(limits.max_journal_record_bytes),
    )?
    else {
        return Ok(JournalReplay {
            state,
            launch_attempts: Vec::new(),
            epoch: checkpoint_epoch,
            sequence: checkpoint_sequence,
            record_count: 0,
            valid_bytes: 0,
            quarantined_tail: None,
        });
    };
    replay_journal_v2_bytes(
        path,
        &bytes,
        checkpoint_epoch,
        checkpoint_sequence,
        state,
        limits,
        true,
    )
}

fn replay_journal_v3(
    path: &Path,
    checkpoint_epoch: u64,
    checkpoint_sequence: u64,
    state: PersistedSessionState,
    limits: StateStoreLimits,
) -> Result<JournalReplay, StateStoreError> {
    let Some(bytes) = read_bounded(
        path,
        limits.max_journal_bytes.saturating_add(limits.max_journal_record_bytes),
    )?
    else {
        return Ok(JournalReplay {
            state,
            launch_attempts: Vec::new(),
            epoch: checkpoint_epoch,
            sequence: checkpoint_sequence,
            record_count: 0,
            valid_bytes: 0,
            quarantined_tail: None,
        });
    };
    replay_journal_v3_bytes(
        path,
        &bytes,
        checkpoint_epoch,
        checkpoint_sequence,
        state,
        limits,
        true,
    )
}

fn replay_journal_v3_bytes(
    path: &Path,
    bytes: &[u8],
    checkpoint_epoch: u64,
    checkpoint_sequence: u64,
    mut state: PersistedSessionState,
    limits: StateStoreLimits,
    quarantine_invalid_tail: bool,
) -> Result<JournalReplay, StateStoreError> {
    let mut epoch = checkpoint_epoch;
    let mut sequence = checkpoint_sequence;
    let mut record_count = 0usize;
    let mut valid_bytes = 0usize;
    let mut seen = state
        .idempotency_results
        .iter()
        .map(|result| (result.key.clone(), result.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut cursor = 0usize;
    let mut invalid_tail = None;

    while cursor < bytes.len() {
        let line_end = bytes[cursor..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|offset| cursor + offset + 1);
        let Some(line_end) = line_end else {
            invalid_tail = Some(cursor);
            break;
        };
        let line = &bytes[cursor..line_end - 1];
        if line.is_empty() {
            if bytes[line_end..].iter().all(u8::is_ascii_whitespace) {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(path, "empty interior version-3 journal record"));
        }
        if line.len().saturating_add(1) > limits.max_journal_record_bytes {
            if line_end == bytes.len() {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(
                path,
                "oversized interior version-3 journal record",
            ));
        }
        let envelope = match decode_journal_v3(path, line) {
            Ok(envelope) => envelope,
            Err(error) if line_end == bytes.len() => {
                let _ = error;
                invalid_tail = Some(cursor);
                break;
            }
            Err(error) => return Err(error),
        };
        let body = envelope.body;
        if body.session_id != state.session_id {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal session identity mismatch",
            ));
        }
        if body.epoch < checkpoint_epoch
            || (body.epoch == checkpoint_epoch && body.sequence <= checkpoint_sequence)
        {
            cursor = line_end;
            valid_bytes = line_end;
            continue;
        }
        if body.epoch != epoch || body.sequence != sequence.saturating_add(1) {
            return Err(StateStoreError::corrupt(
                path,
                format!(
                    "version-3 journal sequence gap: expected {epoch}/{}, found {}/{}",
                    sequence.saturating_add(1),
                    body.epoch,
                    body.sequence
                ),
            ));
        }
        if record_count >= limits.max_journal_records {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal record count exceeds the compaction bound",
            ));
        }
        validate_snapshot(path, &body.state)?;
        if body.state.session_id != state.session_id {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal state changed session identity",
            ));
        }
        if body.state.topology_revision < state.topology_revision {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal topology revision moved backward",
            ));
        }
        if body.state.activity_sequence < state.activity_sequence {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 journal activity sequence moved backward",
            ));
        }
        if let Some(existing) = seen.get(&body.idempotency_key) {
            if body.result.as_ref() != Some(existing) || body.state != state {
                return Err(StateStoreError::corrupt(
                    path,
                    "duplicate version-3 idempotency key changed its result or state",
                ));
            }
        } else {
            if let Some(result) = body.result.as_ref() {
                if result.key != body.idempotency_key {
                    return Err(StateStoreError::corrupt(
                        path,
                        "version-3 journal idempotency result key mismatch",
                    ));
                }
                seen.insert(result.key.clone(), result.clone());
            }
            state = body.state;
        }
        epoch = body.epoch;
        sequence = body.sequence;
        record_count += 1;
        cursor = line_end;
        valid_bytes = line_end;
    }

    let quarantined_tail = if let Some(start) = invalid_tail {
        if !quarantine_invalid_tail {
            return Err(StateStoreError::corrupt(
                path,
                "version-3 backup journal has a truncated or invalid tail",
            ));
        }
        Some(quarantine_tail(path, bytes, start)?)
    } else {
        None
    };
    Ok(JournalReplay {
        state,
        launch_attempts: Vec::new(),
        epoch,
        sequence,
        record_count,
        valid_bytes,
        quarantined_tail,
    })
}

fn replay_journal_v2_bytes(
    path: &Path,
    bytes: &[u8],
    checkpoint_epoch: u64,
    checkpoint_sequence: u64,
    mut state: PersistedSessionState,
    limits: StateStoreLimits,
    quarantine_invalid_tail: bool,
) -> Result<JournalReplay, StateStoreError> {
    let mut epoch = checkpoint_epoch;
    let mut sequence = checkpoint_sequence;
    let mut record_count = 0usize;
    let mut valid_bytes = 0usize;
    let mut seen = state
        .idempotency_results
        .iter()
        .map(|result| (result.key.clone(), result.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut cursor = 0usize;
    let mut invalid_tail = None;

    while cursor < bytes.len() {
        let line_end = bytes[cursor..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|offset| cursor + offset + 1);
        let Some(line_end) = line_end else {
            invalid_tail = Some(cursor);
            break;
        };
        let line = &bytes[cursor..line_end - 1];
        if line.is_empty() {
            if bytes[line_end..].iter().all(u8::is_ascii_whitespace) {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(path, "empty interior version-2 journal record"));
        }
        if line.len().saturating_add(1) > limits.max_journal_record_bytes {
            if line_end == bytes.len() {
                invalid_tail = Some(cursor);
                break;
            }
            return Err(StateStoreError::corrupt(
                path,
                "oversized interior version-2 journal record",
            ));
        }
        let envelope = match decode_journal_v2(path, line) {
            Ok(envelope) => envelope,
            Err(error) if line_end == bytes.len() => {
                let _ = error;
                invalid_tail = Some(cursor);
                break;
            }
            Err(error) => return Err(error),
        };
        let body = envelope.body;
        if body.session_id != state.session_id {
            return Err(StateStoreError::corrupt(
                path,
                "version-2 journal session identity mismatch",
            ));
        }
        if body.epoch < checkpoint_epoch
            || (body.epoch == checkpoint_epoch && body.sequence <= checkpoint_sequence)
        {
            cursor = line_end;
            valid_bytes = line_end;
            continue;
        }
        if body.epoch != epoch || body.sequence != sequence.saturating_add(1) {
            return Err(StateStoreError::corrupt(
                path,
                format!(
                    "version-2 journal sequence gap: expected {epoch}/{}, found {}/{}",
                    sequence.saturating_add(1),
                    body.epoch,
                    body.sequence
                ),
            ));
        }
        if record_count >= limits.max_journal_records {
            return Err(StateStoreError::corrupt(
                path,
                "version-2 journal record count exceeds the compaction bound",
            ));
        }
        let next_state: PersistedSessionState = body.state.into();
        validate_snapshot(path, &next_state)?;
        if next_state.session_id != state.session_id {
            return Err(StateStoreError::corrupt(
                path,
                "version-2 journal state changed session identity",
            ));
        }
        if next_state.topology_revision < state.topology_revision {
            return Err(StateStoreError::corrupt(
                path,
                "version-2 journal topology revision moved backward",
            ));
        }
        if let Some(existing) = seen.get(&body.idempotency_key) {
            if body.result.as_ref() != Some(existing) || next_state != state {
                return Err(StateStoreError::corrupt(
                    path,
                    "duplicate version-2 idempotency key changed its result or state",
                ));
            }
        } else {
            if let Some(result) = body.result.as_ref() {
                if result.key != body.idempotency_key {
                    return Err(StateStoreError::corrupt(
                        path,
                        "version-2 journal idempotency result key mismatch",
                    ));
                }
                seen.insert(result.key.clone(), result.clone());
            }
            state = next_state;
        }
        epoch = body.epoch;
        sequence = body.sequence;
        record_count += 1;
        cursor = line_end;
        valid_bytes = line_end;
    }

    let quarantined_tail = if let Some(start) = invalid_tail {
        if !quarantine_invalid_tail {
            return Err(StateStoreError::corrupt(
                path,
                "version-2 backup journal has a truncated or invalid tail",
            ));
        }
        Some(quarantine_tail(path, bytes, start)?)
    } else {
        None
    };
    Ok(JournalReplay {
        state,
        launch_attempts: Vec::new(),
        epoch,
        sequence,
        record_count,
        valid_bytes,
        quarantined_tail,
    })
}

fn validate_checkpoint(
    path: &Path,
    session: &str,
    envelope: &CheckpointEnvelope,
) -> Result<(), StateStoreError> {
    if envelope.body.version != STATE_STORE_VERSION || envelope.body.format != CHECKPOINT_FORMAT {
        return Err(StateStoreError::corrupt(path, "checkpoint format/version mismatch"));
    }
    if envelope.body.session != session {
        return Err(StateStoreError::corrupt(
            path,
            format!(
                "session key collision: expected {session:?}, found {:?}",
                envelope.body.session
            ),
        ));
    }
    verify_checksum(path, &envelope.body, &envelope.checksum, "checkpoint")?;
    validate_snapshot(path, &envelope.body.state)?;
    validate_launch_attempts(path, &envelope.body.state, &envelope.body.launch_attempts)
}

fn validate_checkpoint_v3(
    path: &Path,
    session: &str,
    envelope: &CheckpointEnvelopeV3,
) -> Result<(), StateStoreError> {
    if envelope.body.version != 3 || envelope.body.format != CHECKPOINT_FORMAT {
        return Err(StateStoreError::corrupt(path, "version-3 checkpoint format mismatch"));
    }
    if envelope.body.session != session {
        return Err(StateStoreError::corrupt(
            path,
            format!(
                "session key collision: expected {session:?}, found {:?}",
                envelope.body.session
            ),
        ));
    }
    verify_checksum(path, &envelope.body, &envelope.checksum, "version-3 checkpoint")?;
    validate_snapshot(path, &envelope.body.state)
}

fn validate_checkpoint_v2(
    path: &Path,
    session: &str,
    envelope: &CheckpointEnvelopeV2,
) -> Result<(), StateStoreError> {
    if envelope.body.version != 2 || envelope.body.format != CHECKPOINT_FORMAT {
        return Err(StateStoreError::corrupt(path, "version-2 checkpoint format mismatch"));
    }
    if envelope.body.session != session {
        return Err(StateStoreError::corrupt(
            path,
            format!(
                "session key collision: expected {session:?}, found {:?}",
                envelope.body.session
            ),
        ));
    }
    verify_checksum(path, &envelope.body, &envelope.checksum, "version-2 checkpoint")?;
    let state = envelope.body.state.clone().into();
    validate_snapshot(path, &state)
}

fn validate_snapshot(path: &Path, state: &PersistedSessionState) -> Result<(), StateStoreError> {
    if state.session_id.as_uuid().is_nil() {
        return Err(StateStoreError::corrupt(path, "nil session identity"));
    }
    if state.workspaces.len() > MAX_PERSISTED_WORKSPACES
        || state.panes.len() > MAX_PERSISTED_PANES
        || state.surfaces.len() > MAX_PERSISTED_SURFACES
    {
        return Err(StateStoreError::corrupt(path, "persisted topology exceeds entity limits"));
    }
    if state.tombstones.len() > MAX_PERSISTED_TOMBSTONES
        || state.idempotency_results.len() > MAX_PERSISTED_IDEMPOTENCY_RESULTS
    {
        return Err(StateStoreError::corrupt(path, "bounded recovery metadata exceeds limits"));
    }

    let mut workspace_ids = BTreeSet::new();
    let mut screen_ids = BTreeSet::new();
    let mut pane_ids = BTreeSet::new();
    let mut surface_ids = BTreeSet::new();
    let mut referenced_panes = BTreeSet::new();
    let mut referenced_surfaces = BTreeSet::new();
    let mut screen_count = 0usize;

    for workspace in &state.workspaces {
        validate_uuid(path, workspace.uuid.as_uuid(), "workspace")?;
        validate_name(path, &workspace.name, "workspace name")?;
        if !workspace_ids.insert(workspace.uuid) {
            return Err(StateStoreError::corrupt(path, "duplicate workspace UUID"));
        }
        if workspace.screens.is_empty() || workspace.active_screen >= workspace.screens.len() {
            return Err(StateStoreError::corrupt(path, "invalid workspace active screen"));
        }
        screen_count = screen_count.saturating_add(workspace.screens.len());
        for screen in &workspace.screens {
            validate_uuid(path, screen.uuid.as_uuid(), "screen")?;
            if let Some(name) = &screen.name {
                validate_name(path, name, "screen name")?;
            }
            if !screen_ids.insert(screen.uuid) {
                return Err(StateStoreError::corrupt(path, "duplicate screen UUID"));
            }
            let mut screen_panes = BTreeSet::new();
            collect_node_panes(path, &screen.root, &mut screen_panes)?;
            if !screen_panes.contains(&screen.active_pane)
                || screen.zoomed_pane.is_some_and(|pane| !screen_panes.contains(&pane))
            {
                return Err(StateStoreError::corrupt(
                    path,
                    "screen focus references a pane outside its split tree",
                ));
            }
            for pane in screen_panes {
                if !referenced_panes.insert(pane) {
                    return Err(StateStoreError::corrupt(
                        path,
                        "pane appears in multiple screen split trees",
                    ));
                }
            }
        }
    }
    if screen_count > MAX_PERSISTED_SCREENS {
        return Err(StateStoreError::corrupt(path, "persisted screen count exceeds limit"));
    }
    match state.active_workspace {
        Some(active) if !workspace_ids.contains(&active) => {
            return Err(StateStoreError::corrupt(path, "active workspace UUID is missing"));
        }
        None if !state.workspaces.is_empty() => {
            return Err(StateStoreError::corrupt(
                path,
                "nonempty topology has no active workspace",
            ));
        }
        Some(_) if state.workspaces.is_empty() => {
            return Err(StateStoreError::corrupt(path, "empty topology has an active workspace"));
        }
        _ => {}
    }

    for pane in &state.panes {
        validate_uuid(path, pane.uuid.as_uuid(), "pane")?;
        if !pane_ids.insert(pane.uuid) {
            return Err(StateStoreError::corrupt(path, "duplicate pane UUID"));
        }
        if let Some(name) = &pane.name {
            validate_name(path, name, "pane name")?;
        }
        if pane.tabs.is_empty() || pane.active_tab >= pane.tabs.len() {
            return Err(StateStoreError::corrupt(path, "invalid pane active tab"));
        }
        for surface in &pane.tabs {
            if !referenced_surfaces.insert(*surface) {
                return Err(StateStoreError::corrupt(
                    path,
                    "surface appears in multiple tab slots",
                ));
            }
        }
    }
    if pane_ids != referenced_panes {
        return Err(StateStoreError::corrupt(
            path,
            "pane records and split-tree references differ",
        ));
    }

    for surface in &state.surfaces {
        validate_uuid(path, surface.uuid.as_uuid(), "surface")?;
        if !surface_ids.insert(surface.uuid) {
            return Err(StateStoreError::corrupt(path, "duplicate surface UUID"));
        }
        if let Some(name) = &surface.name {
            validate_name(path, name, "surface name")?;
        }
        match &surface.kind {
            PersistedSurfaceKind::Terminal { launch } => {
                validate_launch_recipe(path, launch)?;
            }
            PersistedSurfaceKind::ExternalTerminal {
                cols, rows, scrollback, provenance, ..
            } => {
                if *cols == 0 || *rows == 0 || *scrollback > 10_000_000 {
                    return Err(StateStoreError::corrupt(
                        path,
                        "invalid persisted external terminal recipe",
                    ));
                }
                if provenance.is_some_and(|provenance| provenance.validate().is_err()) {
                    return Err(StateStoreError::corrupt(
                        path,
                        "invalid persisted external terminal provenance",
                    ));
                }
            }
            PersistedSurfaceKind::Browser { .. } => {}
        }
    }
    if surface_ids != referenced_surfaces {
        return Err(StateStoreError::corrupt(
            path,
            "surface records and ordered tab references differ",
        ));
    }

    if state.activity_facts.len() > MAX_TERMINAL_ACTIVITY_FACTS {
        return Err(StateStoreError::corrupt(path, "terminal activity fact capacity exceeded"));
    }
    let mut activity_surfaces = BTreeSet::new();
    let mut activity_sequences = BTreeSet::new();
    for fact in &state.activity_facts {
        if !surface_ids.contains(&fact.surface_uuid)
            || fact.sequence == 0
            || fact.sequence > state.activity_sequence
            || fact.notification == 0
            || !activity_surfaces.insert(fact.surface_uuid)
            || !activity_sequences.insert(fact.sequence)
        {
            return Err(StateStoreError::corrupt(
                path,
                "invalid, duplicate, or out-of-order terminal activity fact",
            ));
        }
    }
    // `activity_sequence` may remain nonzero after deleting the last fact;
    // retaining the high-water mark prevents sequence reuse after recovery.
    let mut receipt_keys = BTreeSet::new();
    let mut activity_readers = BTreeSet::new();
    let mut stable_receipts = 0usize;
    for receipt in &state.activity_receipts {
        let fact =
            state.activity_facts.iter().find(|fact| fact.surface_uuid == receipt.surface_uuid);
        if receipt.reader_uuid.is_nil()
            || receipt.seen_sequence == 0
            || fact.is_none_or(|fact| receipt.seen_sequence > fact.sequence)
            || !receipt_keys.insert((receipt.reader_uuid, receipt.surface_uuid))
        {
            return Err(StateStoreError::corrupt(
                path,
                "invalid or duplicate terminal activity receipt",
            ));
        }
        activity_readers.insert(receipt.reader_uuid);
        if receipt.reader_uuid != LEGACY_TERMINAL_ACTIVITY_READER_UUID {
            stable_receipts = stable_receipts.saturating_add(1);
        }
    }
    if activity_readers.len() > MAX_TERMINAL_ACTIVITY_READERS
        || stable_receipts > MAX_TERMINAL_ACTIVITY_STABLE_RECEIPTS
        || state.activity_receipts.len()
            > MAX_TERMINAL_ACTIVITY_STABLE_RECEIPTS.saturating_add(MAX_TERMINAL_ACTIVITY_FACTS)
    {
        return Err(StateStoreError::corrupt(
            path,
            "terminal activity reader or receipt capacity exceeded",
        ));
    }

    let mut tombstone_keys = BTreeSet::new();
    for tombstone in &state.tombstones {
        validate_uuid(path, tombstone.uuid, "tombstone")?;
        if tombstone.removed_at_topology_revision > state.topology_revision
            || !tombstone_keys.insert((persisted_entity_kind_tag(tombstone.kind), tombstone.uuid))
        {
            return Err(StateStoreError::corrupt(path, "invalid or duplicate tombstone"));
        }
    }
    let mut idempotency_keys = BTreeSet::new();
    for result in &state.idempotency_results {
        validate_idempotency_key(path, &result.key)?;
        if !result.payload_digest.is_empty()
            && (result.payload_digest.len() != 64
                || !result
                    .payload_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')))
        {
            return Err(StateStoreError::corrupt(
                path,
                "invalid retained idempotency payload digest",
            ));
        }
        if result.committed_topology_revision > state.topology_revision
            || !idempotency_keys.insert(result.key.as_str())
        {
            return Err(StateStoreError::corrupt(path, "duplicate retained idempotency key"));
        }
        for uuid in result
            .workspaces
            .iter()
            .map(|uuid| uuid.as_uuid())
            .chain(result.screens.iter().map(|uuid| uuid.as_uuid()))
            .chain(result.panes.iter().map(|uuid| uuid.as_uuid()))
            .chain(result.surfaces.iter().map(|uuid| uuid.as_uuid()))
        {
            validate_uuid(path, uuid, "idempotency target")?;
        }
    }
    Ok(())
}

fn persisted_entity_kind_tag(kind: PersistedEntityKind) -> u8 {
    match kind {
        PersistedEntityKind::Workspace => 0,
        PersistedEntityKind::Screen => 1,
        PersistedEntityKind::Pane => 2,
        PersistedEntityKind::Surface => 3,
    }
}

fn reconcile_legacy_launch_attempts(
    path: &Path,
    state: &PersistedSessionState,
    previous: &[PersistedLaunchAttempt],
) -> Result<Vec<PersistedLaunchAttempt>, StateStoreError> {
    let mut attempts = previous
        .iter()
        .filter(|attempt| attempt.phase != PersistedLaunchAttemptPhase::Active)
        .cloned()
        .collect::<Vec<_>>();
    let reserved = attempts.iter().map(|attempt| attempt.surface_uuid).collect::<BTreeSet<_>>();
    for surface in &state.surfaces {
        let PersistedSurfaceKind::Terminal { launch } = &surface.kind else {
            continue;
        };
        if reserved.contains(&surface.uuid) {
            return Err(StateStoreError::corrupt(
                path,
                "legacy topology made a pending or quarantined launch visible",
            ));
        }
        attempts.push(active_launch_attempt(state.session_id, surface.uuid, launch)?);
    }
    attempts.sort_by_key(|attempt| attempt.attempt_id);
    validate_launch_attempts(path, state, &attempts)?;
    Ok(attempts)
}

fn active_launch_attempt(
    session_id: SessionId,
    surface_uuid: SurfaceUuid,
    launch: &PersistedLaunchRecipe,
) -> Result<PersistedLaunchAttempt, StateStoreError> {
    let encoded = serde_json::to_vec(&(session_id, surface_uuid, launch)).map_err(|error| {
        StateStoreError::corrupt(
            "launch-attempt",
            format!("could not encode active launch identity: {error}"),
        )
    })?;
    let payload_digest = format!("{:x}", Sha256::digest(&encoded));
    let mut identity = Vec::with_capacity(32 + payload_digest.len());
    identity.extend_from_slice(session_id.as_uuid().as_bytes());
    identity.extend_from_slice(surface_uuid.as_uuid().as_bytes());
    identity.extend_from_slice(payload_digest.as_bytes());
    Ok(PersistedLaunchAttempt {
        attempt_id: Uuid::new_v5(&LAUNCH_ATTEMPT_NAMESPACE, &identity),
        request_id: format!("legacy-active:{surface_uuid}:{payload_digest}"),
        payload_digest,
        surface_uuid,
        launch: launch.clone(),
        phase: PersistedLaunchAttemptPhase::Active,
    })
}

fn validate_launch_attempts(
    path: &Path,
    state: &PersistedSessionState,
    attempts: &[PersistedLaunchAttempt],
) -> Result<(), StateStoreError> {
    if attempts.len() > MAX_PERSISTED_LAUNCH_ATTEMPTS {
        return Err(StateStoreError::corrupt(path, "persisted launch attempt capacity exceeded"));
    }
    let terminal_surfaces = state
        .surfaces
        .iter()
        .filter_map(|surface| match &surface.kind {
            PersistedSurfaceKind::Terminal { launch } => Some((surface.uuid, launch)),
            PersistedSurfaceKind::ExternalTerminal { .. }
            | PersistedSurfaceKind::Browser { .. } => None,
        })
        .collect::<BTreeMap<_, _>>();
    let mut attempt_ids = BTreeSet::new();
    let mut request_ids = BTreeSet::new();
    let mut attempted_surfaces = BTreeSet::new();
    let mut active_surfaces = BTreeSet::new();
    for attempt in attempts {
        validate_uuid(path, attempt.attempt_id, "launch attempt")?;
        validate_uuid(path, attempt.surface_uuid.as_uuid(), "launch attempt surface")?;
        validate_idempotency_key(path, &attempt.request_id)?;
        validate_payload_digest(path, &attempt.payload_digest, "launch attempt")?;
        validate_launch_recipe(path, &attempt.launch)?;
        if !attempt_ids.insert(attempt.attempt_id)
            || !request_ids.insert(attempt.request_id.as_str())
            || !attempted_surfaces.insert(attempt.surface_uuid)
        {
            return Err(StateStoreError::corrupt(path, "duplicate persisted launch attempt"));
        }
        match attempt.phase {
            PersistedLaunchAttemptPhase::Active => {
                let Some(launch) = terminal_surfaces.get(&attempt.surface_uuid) else {
                    return Err(StateStoreError::corrupt(
                        path,
                        "active launch attempt has no visible terminal surface",
                    ));
                };
                if *launch != &attempt.launch || !active_surfaces.insert(attempt.surface_uuid) {
                    return Err(StateStoreError::corrupt(
                        path,
                        "active launch attempt recipe differs from visible terminal",
                    ));
                }
            }
            PersistedLaunchAttemptPhase::PendingActivation
            | PersistedLaunchAttemptPhase::Quarantined => {
                if state.surfaces.iter().any(|surface| surface.uuid == attempt.surface_uuid) {
                    return Err(StateStoreError::corrupt(
                        path,
                        "unactivated launch attempt appears in visible topology",
                    ));
                }
            }
        }
    }
    let expected_active = terminal_surfaces.keys().copied().collect::<BTreeSet<_>>();
    if active_surfaces != expected_active {
        return Err(StateStoreError::corrupt(
            path,
            "visible terminal surfaces and active launch attempts differ",
        ));
    }
    Ok(())
}

fn validate_payload_digest(path: &Path, digest: &str, kind: &str) -> Result<(), StateStoreError> {
    if digest.len() != 64
        || !digest.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        Err(StateStoreError::corrupt(path, format!("invalid {kind} payload digest")))
    } else {
        Ok(())
    }
}

fn validate_launch_recipe(
    path: &Path,
    launch: &PersistedLaunchRecipe,
) -> Result<(), StateStoreError> {
    if launch.argv.is_empty()
        || launch.argv.len() > MAX_ARGV_ITEMS
        || launch.argv.iter().any(|arg| arg.contains('\0'))
        || launch.argv.iter().map(String::len).sum::<usize>() > MAX_ARGV_BYTES
    {
        return Err(StateStoreError::corrupt(path, "invalid persisted argv"));
    }
    if launch.cwd.as_ref().is_some_and(|cwd| {
        cwd.len() > MAX_CWD_BYTES || cwd.contains('\0') || !Path::new(cwd).is_absolute()
    }) || launch.cols == 0
        || launch.rows == 0
        || launch.scrollback > 10_000_000
    {
        return Err(StateStoreError::corrupt(path, "invalid persisted terminal launch recipe"));
    }
    if launch.environment.len() > MAX_ENV_ITEMS
        || launch
            .environment
            .iter()
            .map(|variable| variable.name.len().saturating_add(variable.value.len()))
            .sum::<usize>()
            > MAX_ENV_BYTES
    {
        return Err(StateStoreError::corrupt(path, "persisted environment exceeds limits"));
    }
    let mut names = BTreeSet::new();
    for variable in &launch.environment {
        if !persisted_environment_name_allowed(&variable.name)
            || variable.name.contains(['=', '\0'])
            || variable.value.contains('\0')
            || !names.insert(variable.name.as_str())
        {
            return Err(StateStoreError::corrupt(
                path,
                "persisted environment is not strictly allowlisted",
            ));
        }
    }
    Ok(())
}

fn persisted_environment_name_allowed(name: &str) -> bool {
    matches!(
        name,
        "TERM"
            | "COLORTERM"
            | "LANG"
            | "LC_ALL"
            | "LC_ADDRESS"
            | "LC_COLLATE"
            | "LC_CTYPE"
            | "LC_IDENTIFICATION"
            | "LC_MEASUREMENT"
            | "LC_MESSAGES"
            | "LC_MONETARY"
            | "LC_NAME"
            | "LC_NUMERIC"
            | "LC_PAPER"
            | "LC_TELEPHONE"
            | "LC_TIME"
            | "TZ"
    )
}

fn collect_node_panes(
    path: &Path,
    node: &PersistedNode,
    panes: &mut BTreeSet<PaneUuid>,
) -> Result<(), StateStoreError> {
    match node {
        PersistedNode::Leaf { pane_uuid } => {
            validate_uuid(path, pane_uuid.as_uuid(), "pane")?;
            if !panes.insert(*pane_uuid) {
                return Err(StateStoreError::corrupt(path, "pane appears twice in split trees"));
            }
        }
        PersistedNode::Split { ratio, first, second, .. } => {
            if !ratio.is_finite() || !(0.01..=0.99).contains(ratio) {
                return Err(StateStoreError::corrupt(path, "invalid persisted split ratio"));
            }
            collect_node_panes(path, first, panes)?;
            collect_node_panes(path, second, panes)?;
        }
    }
    Ok(())
}

fn validate_uuid(path: &Path, uuid: Uuid, kind: &str) -> Result<(), StateStoreError> {
    if uuid.is_nil() {
        Err(StateStoreError::corrupt(path, format!("nil {kind} UUID")))
    } else {
        Ok(())
    }
}

fn validate_name(path: &Path, name: &str, kind: &str) -> Result<(), StateStoreError> {
    if name.len() > MAX_NAME_BYTES || name.contains('\0') {
        Err(StateStoreError::corrupt(path, format!("invalid {kind}")))
    } else {
        Ok(())
    }
}

fn validate_idempotency_key(path: &Path, key: &str) -> Result<(), StateStoreError> {
    if key.is_empty() || key.len() > 256 || key.contains('\0') {
        Err(StateStoreError::corrupt(path, "invalid idempotency key"))
    } else {
        Ok(())
    }
}

fn checkpoint_envelope(
    session: &str,
    epoch: u64,
    sequence: u64,
    state: &PersistedSessionState,
) -> Result<CheckpointEnvelope, StateStoreError> {
    let launch_attempts = reconcile_legacy_launch_attempts(Path::new("checkpoint"), state, &[])?;
    checkpoint_envelope_with_attempts(session, epoch, sequence, state, &launch_attempts)
}

fn checkpoint_envelope_with_attempts(
    session: &str,
    epoch: u64,
    sequence: u64,
    state: &PersistedSessionState,
    launch_attempts: &[PersistedLaunchAttempt],
) -> Result<CheckpointEnvelope, StateStoreError> {
    let body = CheckpointBody {
        version: STATE_STORE_VERSION,
        format: CHECKPOINT_FORMAT.to_string(),
        session: session.to_string(),
        epoch,
        sequence,
        state: state.clone(),
        launch_attempts: launch_attempts.to_vec(),
    };
    let checksum = checksum_json(&body).map_err(|error| {
        StateStoreError::corrupt("checkpoint", format!("could not checksum checkpoint: {error}"))
    })?;
    Ok(CheckpointEnvelope { body, checksum })
}

fn write_checkpoint_atomic(
    path: &Path,
    session: &str,
    epoch: u64,
    sequence: u64,
    state: &PersistedSessionState,
    limits: StateStoreLimits,
) -> Result<(), StateStoreError> {
    let launch_attempts = reconcile_legacy_launch_attempts(path, state, &[])?;
    match write_checkpoint_atomic_resolved(
        &SystemDurableIo,
        path,
        session,
        epoch,
        sequence,
        state,
        &launch_attempts,
        limits,
    ) {
        DurableIoOutcome::Committed => Ok(()),
        DurableIoOutcome::Rejected(failure) | DurableIoOutcome::CommitIndeterminate(failure) => {
            Err(failure.error)
        }
    }
}

fn write_checkpoint_atomic_resolved(
    io: &dyn DurableIo,
    path: &Path,
    session: &str,
    epoch: u64,
    sequence: u64,
    state: &PersistedSessionState,
    launch_attempts: &[PersistedLaunchAttempt],
    limits: StateStoreLimits,
) -> DurableIoOutcome {
    if let Err(error) = validate_snapshot(path, state) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error));
    }
    if let Err(error) = validate_launch_attempts(path, state, launch_attempts) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error));
    }
    let envelope =
        match checkpoint_envelope_with_attempts(session, epoch, sequence, state, launch_attempts) {
            Ok(envelope) => envelope,
            Err(error) => return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error)),
        };
    let bytes = serde_json::to_vec_pretty(&envelope).map_err(|error| {
        StateStoreError::corrupt(path, format!("could not encode checkpoint: {error}"))
    });
    let mut bytes = match bytes {
        Ok(bytes) => bytes,
        Err(error) => return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error)),
    };
    bytes.push(b'\n');
    if bytes.len() > limits.max_checkpoint_bytes {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(
            StateStoreError::corrupt(
                path,
                format!(
                    "checkpoint is {} bytes; limit is {}",
                    bytes.len(),
                    limits.max_checkpoint_bytes
                ),
            ),
        ));
    }
    replace_file_atomically_resolved(io, path, &bytes)
}

fn encode_journal(path: &Path, body: &JournalBody) -> Result<Vec<u8>, StateStoreError> {
    let checksum = checksum_json(body).map_err(|error| {
        StateStoreError::corrupt(path, format!("could not checksum journal record: {error}"))
    })?;
    let envelope = JournalEnvelope { body: body.clone(), checksum };
    let mut bytes = serde_json::to_vec(&envelope).map_err(|error| {
        StateStoreError::corrupt(path, format!("could not encode journal record: {error}"))
    })?;
    bytes.push(b'\n');
    Ok(bytes)
}

fn decode_journal(path: &Path, line: &[u8]) -> Result<JournalEnvelope, StateStoreError> {
    let envelope = serde_json::from_slice::<JournalEnvelope>(line).map_err(|error| {
        StateStoreError::corrupt(path, format!("invalid journal JSON: {error}"))
    })?;
    if envelope.body.version != STATE_STORE_VERSION || envelope.body.format != JOURNAL_FORMAT {
        return Err(StateStoreError::corrupt(path, "journal format/version mismatch"));
    }
    validate_idempotency_key(path, &envelope.body.idempotency_key)?;
    verify_checksum(path, &envelope.body, &envelope.checksum, "journal")?;
    Ok(envelope)
}

fn decode_journal_v3(path: &Path, line: &[u8]) -> Result<JournalEnvelopeV3, StateStoreError> {
    let envelope = serde_json::from_slice::<JournalEnvelopeV3>(line).map_err(|error| {
        StateStoreError::corrupt(path, format!("invalid version-3 journal JSON: {error}"))
    })?;
    if envelope.body.version != 3 || envelope.body.format != JOURNAL_FORMAT {
        return Err(StateStoreError::corrupt(path, "version-3 journal format mismatch"));
    }
    validate_idempotency_key(path, &envelope.body.idempotency_key)?;
    verify_checksum(path, &envelope.body, &envelope.checksum, "version-3 journal")?;
    Ok(envelope)
}

fn decode_journal_v2(path: &Path, line: &[u8]) -> Result<JournalEnvelopeV2, StateStoreError> {
    let envelope = serde_json::from_slice::<JournalEnvelopeV2>(line).map_err(|error| {
        StateStoreError::corrupt(path, format!("invalid version-2 journal JSON: {error}"))
    })?;
    if envelope.body.version != 2 || envelope.body.format != JOURNAL_FORMAT {
        return Err(StateStoreError::corrupt(path, "version-2 journal format mismatch"));
    }
    validate_idempotency_key(path, &envelope.body.idempotency_key)?;
    verify_checksum(path, &envelope.body, &envelope.checksum, "version-2 journal")?;
    Ok(envelope)
}

fn stale_v2_journal_record(
    path: &Path,
    line: &[u8],
) -> Result<Option<JournalEnvelopeV2>, StateStoreError> {
    let value = match serde_json::from_slice::<serde_json::Value>(line) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    if value.get("body").and_then(|body| body.get("version")).and_then(serde_json::Value::as_u64)
        != Some(2)
    {
        return Ok(None);
    }
    decode_journal_v2(path, line).map(Some)
}

fn stale_v3_journal_record(
    path: &Path,
    line: &[u8],
) -> Result<Option<JournalEnvelopeV3>, StateStoreError> {
    let value = match serde_json::from_slice::<serde_json::Value>(line) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    if value.get("body").and_then(|body| body.get("version")).and_then(serde_json::Value::as_u64)
        != Some(3)
    {
        return Ok(None);
    }
    decode_journal_v3(path, line).map(Some)
}

fn checksum_json(value: &impl Serialize) -> Result<String, serde_json::Error> {
    let bytes = serde_json::to_vec(value)?;
    Ok(format!("{:08x}", crc32(&bytes)))
}

fn verify_checksum(
    path: &Path,
    body: &impl Serialize,
    actual: &str,
    kind: &str,
) -> Result<(), StateStoreError> {
    let expected = checksum_json(body).map_err(|error| {
        StateStoreError::corrupt(path, format!("could not verify {kind} checksum: {error}"))
    })?;
    if expected != actual {
        Err(StateStoreError::corrupt(
            path,
            format!("{kind} checksum mismatch: expected {expected}, found {actual}"),
        ))
    } else {
        Ok(())
    }
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn append_record_resolved(io: &dyn DurableIo, path: &Path, bytes: &[u8]) -> DurableIoOutcome {
    if let Err(error) = ensure_private_parent(path) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error));
    }
    let mut file = match io.open_append(DurableIoPhase::JournalOpen, path) {
        Ok(file) => file,
        Err(error) => {
            return DurableIoOutcome::Rejected(DurableWriteFailure::io(
                DurableIoPhase::JournalOpen,
                DurableFailureResolution::Rejected,
                path,
                error,
            ));
        }
    };
    let original_len = match file.metadata() {
        Ok(metadata) => metadata.len(),
        Err(error) => {
            return DurableIoOutcome::Rejected(DurableWriteFailure::io(
                DurableIoPhase::JournalOpen,
                DurableFailureResolution::Rejected,
                path,
                error,
            ));
        }
    };
    if let Err(error) = write_all_with_io(io, DurableIoPhase::JournalWrite, &mut file, bytes) {
        if let Err(rollback_error) =
            io.set_len(DurableIoPhase::JournalRollbackTruncate, &file, original_len)
        {
            return DurableIoOutcome::CommitIndeterminate(DurableWriteFailure::io(
                DurableIoPhase::JournalRollbackTruncate,
                DurableFailureResolution::CommitIndeterminate,
                path,
                rollback_error,
            ));
        }
        if let Err(rollback_error) = io.sync_file(DurableIoPhase::JournalRollbackSync, &file) {
            return DurableIoOutcome::CommitIndeterminate(DurableWriteFailure::io(
                DurableIoPhase::JournalRollbackSync,
                DurableFailureResolution::CommitIndeterminate,
                path,
                rollback_error,
            ));
        }
        return DurableIoOutcome::Rejected(DurableWriteFailure::io(
            DurableIoPhase::JournalWrite,
            DurableFailureResolution::Rejected,
            path,
            error,
        ));
    }
    if let Err(first_error) = io.sync_file(DurableIoPhase::JournalSync, &file) {
        if let Err(resync_error) = io.sync_file(DurableIoPhase::JournalResync, &file) {
            return DurableIoOutcome::CommitIndeterminate(DurableWriteFailure::io(
                DurableIoPhase::JournalResync,
                DurableFailureResolution::CommitIndeterminate,
                path,
                std::io::Error::new(
                    resync_error.kind(),
                    format!(
                        "initial sync failed ({first_error}); exact-record resync failed ({resync_error})"
                    ),
                ),
            ));
        }
    }
    DurableIoOutcome::Committed
}

fn write_all_with_io(
    io: &dyn DurableIo,
    phase: DurableIoPhase,
    file: &mut File,
    mut bytes: &[u8],
) -> std::io::Result<()> {
    while !bytes.is_empty() {
        match io.write(phase, file, bytes) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "durable write returned zero bytes",
                ));
            }
            Ok(written) if written <= bytes.len() => bytes = &bytes[written..],
            Ok(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "durable writer reported more bytes than provided",
                ));
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn append_synced(path: &Path, bytes: &[u8]) -> Result<(), StateStoreError> {
    match append_record_resolved(&SystemDurableIo, path, bytes) {
        DurableIoOutcome::Committed => Ok(()),
        DurableIoOutcome::Rejected(failure) | DurableIoOutcome::CommitIndeterminate(failure) => {
            Err(failure.error)
        }
    }
}

fn migration_backup_path(path: &Path, version: u32) -> PathBuf {
    let file_name = path.file_name().and_then(OsStr::to_str).unwrap_or("state");
    path.with_file_name(format!("{file_name}.v{version}.backup"))
}

fn preserve_migration_backup(
    source_path: &Path,
    version: u32,
    bytes: &[u8],
) -> Result<(), StateStoreError> {
    let backup = migration_backup_path(source_path, version);
    if let Some(existing) = read_bounded(&backup, bytes.len().saturating_add(1))? {
        if existing != bytes {
            return Err(StateStoreError::corrupt(
                &backup,
                "immutable migration backup differs from the source state",
            ));
        }
        return Ok(());
    }
    replace_file_atomically(&backup, bytes)
}

fn replace_file_atomically_resolved(
    io: &dyn DurableIo,
    path: &Path,
    bytes: &[u8],
) -> DurableIoOutcome {
    if let Err(error) = ensure_private_parent(path) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error));
    }
    if let Err(error) = validate_existing_private_file(path) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::rejected(error));
    }
    let directory = path.parent().expect("state file has a parent");
    let temp_path = directory.join(format!(".state-{}.tmp", Uuid::new_v4()));
    let mut file = match io.open_temp(DurableIoPhase::AtomicTempOpen, &temp_path) {
        Ok(file) => file,
        Err(error) => {
            return DurableIoOutcome::Rejected(DurableWriteFailure::io(
                DurableIoPhase::AtomicTempOpen,
                DurableFailureResolution::Rejected,
                &temp_path,
                error,
            ));
        }
    };
    let mut temp = TempStateFile { path: temp_path.clone(), armed: true };
    if let Err(error) = write_all_with_io(io, DurableIoPhase::AtomicTempWrite, &mut file, bytes) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::io(
            DurableIoPhase::AtomicTempWrite,
            DurableFailureResolution::Rejected,
            &temp_path,
            error,
        ));
    }
    if let Err(error) = io.sync_file(DurableIoPhase::AtomicTempSync, &file) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::io(
            DurableIoPhase::AtomicTempSync,
            DurableFailureResolution::Rejected,
            &temp_path,
            error,
        ));
    }
    if let Err(error) = io.rename(DurableIoPhase::AtomicRename, &temp_path, path) {
        return DurableIoOutcome::Rejected(DurableWriteFailure::io(
            DurableIoPhase::AtomicRename,
            DurableFailureResolution::Rejected,
            path,
            error,
        ));
    }
    temp.disarm();
    if let Err(error) = io.sync_directory(DurableIoPhase::AtomicDirectorySync, directory) {
        return DurableIoOutcome::CommitIndeterminate(DurableWriteFailure::io(
            DurableIoPhase::AtomicDirectorySync,
            DurableFailureResolution::CommitIndeterminate,
            directory,
            error,
        ));
    }
    DurableIoOutcome::Committed
}

fn replace_file_atomically(path: &Path, bytes: &[u8]) -> Result<(), StateStoreError> {
    match replace_file_atomically_resolved(&SystemDurableIo, path, bytes) {
        DurableIoOutcome::Committed => Ok(()),
        DurableIoOutcome::Rejected(failure) | DurableIoOutcome::CommitIndeterminate(failure) => {
            Err(failure.error)
        }
    }
}

fn ensure_private_parent(path: &Path) -> Result<(), StateStoreError> {
    let directory = path.parent().expect("state file has a parent");
    let root = directory.parent().ok_or_else(|| StateStoreError::Unavailable {
        reason: format!("state file has no dedicated state root: {}", path.display()),
    })?;
    platform::ensure_private_directory(root).map_err(|error| StateStoreError::io(root, error))?;
    platform::ensure_private_directory(directory)
        .map_err(|error| StateStoreError::io(directory, error))?;
    Ok(())
}

fn read_bounded(path: &Path, limit: usize) -> Result<Option<Vec<u8>>, StateStoreError> {
    ensure_private_parent(path)?;
    let mut file = match open_private_state_file(path, |options| {
        options.read(true);
    }) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(StateStoreError::io(path, error)),
    };
    let length = file.metadata().map_err(|error| StateStoreError::io(path, error))?.len();
    if length > limit as u64 {
        return Err(StateStoreError::corrupt(
            path,
            format!("state file is {length} bytes; limit is {limit}"),
        ));
    }
    let mut bytes = Vec::with_capacity(length as usize);
    file.read_to_end(&mut bytes).map_err(|error| StateStoreError::io(path, error))?;
    Ok(Some(bytes))
}

fn quarantine_tail(path: &Path, bytes: &[u8], start: usize) -> Result<PathBuf, StateStoreError> {
    let archive = path.with_extension(format!("invalid-tail-{}.journal", Uuid::new_v4()));
    replace_file_atomically(&archive, &bytes[start..])?;
    let mut file = open_private_state_file(path, |options| {
        options.write(true);
    })
    .map_err(|error| StateStoreError::io(path, error))?;
    file.seek(SeekFrom::Start(start as u64))
        .and_then(|_| file.set_len(start as u64))
        .and_then(|()| file.sync_all())
        .map_err(|error| StateStoreError::io(path, error))?;
    sync_directory(path.parent().expect("journal has a parent"))?;
    Ok(archive)
}

fn archive_if_present(path: &Path, archive: &Path) -> Result<Option<PathBuf>, StateStoreError> {
    ensure_private_parent(path)?;
    match open_private_state_file(path, |options| {
        options.read(true);
    }) {
        Ok(file) => drop(file),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(StateStoreError::io(path, error)),
    }
    match fs::rename(path, archive) {
        Ok(()) => {
            sync_directory(path.parent().expect("state file has a parent"))?;
            Ok(Some(archive.to_path_buf()))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(StateStoreError::io(path, error)),
    }
}

fn open_private_state_file(
    path: &Path,
    configure: impl FnOnce(&mut OpenOptions),
) -> std::io::Result<File> {
    platform::reject_private_file_symlink(path)?;
    let mut options = platform::private_file_open_options();
    configure(&mut options);
    let file = options.open(path)?;
    platform::validate_private_file(path, &file)?;
    Ok(file)
}

fn validate_existing_private_file(path: &Path) -> Result<(), StateStoreError> {
    match open_private_state_file(path, |options| {
        options.read(true);
    }) {
        Ok(file) => drop(file),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(StateStoreError::io(path, error)),
    }
    Ok(())
}

fn session_key(session: &str) -> Uuid {
    Uuid::new_v5(&SESSION_PATH_NAMESPACE, session.as_bytes())
}

fn sync_directory(path: &Path) -> Result<(), StateStoreError> {
    sync_directory_io(path).map_err(|error| StateStoreError::io(path, error))
}

fn sync_directory_io(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        File::open(path).and_then(|directory| directory.sync_all())?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex;

    use super::*;

    struct TestDirectory(PathBuf);

    #[derive(Debug, Clone)]
    enum FaultAction {
        Fail,
        ShortWrite(usize),
    }

    #[derive(Debug, Clone)]
    struct FaultStep {
        phase: DurableIoPhase,
        action: FaultAction,
    }

    #[derive(Debug)]
    struct ScriptedDurableIo {
        steps: Mutex<VecDeque<FaultStep>>,
        system: SystemDurableIo,
    }

    impl ScriptedDurableIo {
        fn new(steps: impl IntoIterator<Item = FaultStep>) -> Arc<Self> {
            Arc::new(Self {
                steps: Mutex::new(steps.into_iter().collect()),
                system: SystemDurableIo,
            })
        }

        fn take(&self, phase: DurableIoPhase) -> Option<FaultAction> {
            let mut steps = self.steps.lock().unwrap();
            (steps.front().is_some_and(|step| step.phase == phase))
                .then(|| steps.pop_front().unwrap().action)
        }

        fn fail(phase: DurableIoPhase) -> std::io::Error {
            std::io::Error::other(format!("injected {} failure", phase.as_str()))
        }

        fn assert_consumed(&self) {
            assert!(self.steps.lock().unwrap().is_empty(), "unconsumed durable I/O fault steps");
        }
    }

    impl DurableIo for ScriptedDurableIo {
        fn open_append(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<File> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => panic!("short write cannot target open"),
                None => self.system.open_append(phase, path),
            }
        }

        fn open_temp(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<File> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => panic!("short write cannot target open"),
                None => self.system.open_temp(phase, path),
            }
        }

        fn write(
            &self,
            phase: DurableIoPhase,
            file: &mut File,
            bytes: &[u8],
        ) -> std::io::Result<usize> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(limit)) => {
                    self.system.write(phase, file, &bytes[..bytes.len().min(limit)])
                }
                None => self.system.write(phase, file, bytes),
            }
        }

        fn sync_file(&self, phase: DurableIoPhase, file: &File) -> std::io::Result<()> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => panic!("short write cannot target sync"),
                None => self.system.sync_file(phase, file),
            }
        }

        fn set_len(&self, phase: DurableIoPhase, file: &File, length: u64) -> std::io::Result<()> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => panic!("short write cannot target truncate"),
                None => self.system.set_len(phase, file, length),
            }
        }

        fn rename(&self, phase: DurableIoPhase, from: &Path, to: &Path) -> std::io::Result<()> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => panic!("short write cannot target rename"),
                None => self.system.rename(phase, from, to),
            }
        }

        fn sync_directory(&self, phase: DurableIoPhase, path: &Path) -> std::io::Result<()> {
            match self.take(phase) {
                Some(FaultAction::Fail) => Err(Self::fail(phase)),
                Some(FaultAction::ShortWrite(_)) => {
                    panic!("short write cannot target directory sync")
                }
                None => self.system.sync_directory(phase, path),
            }
        }
    }

    fn fail(phase: DurableIoPhase) -> FaultStep {
        FaultStep { phase, action: FaultAction::Fail }
    }

    fn short_write(phase: DurableIoPhase, bytes: usize) -> FaultStep {
        FaultStep { phase, action: FaultAction::ShortWrite(bytes) }
    }

    impl TestDirectory {
        fn new(name: &str) -> Self {
            Self(std::env::temp_dir().join(format!(
                "cmux-tui-state-{name}-{}-{}",
                std::process::id(),
                Uuid::new_v4()
            )))
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write_private_fixture(path: &Path, bytes: &[u8]) {
        ensure_private_parent(path).unwrap();
        let mut file = open_private_state_file(path, |options| {
            options.create(true).truncate(true).write(true);
        })
        .unwrap();
        file.write_all(bytes).unwrap();
        file.sync_all().unwrap();
    }

    fn result(key: &str, revision: u64) -> PersistedIdempotencyResult {
        PersistedIdempotencyResult {
            key: key.to_string(),
            payload_digest: String::new(),
            committed_topology_revision: revision,
            workspaces: Vec::new(),
            screens: Vec::new(),
            panes: Vec::new(),
            surfaces: Vec::new(),
        }
    }

    #[test]
    fn browser_presentation_mode_decodes_legacy_records_and_round_trips_native() {
        let legacy: PersistedSurfaceKind =
            serde_json::from_value(serde_json::json!({ "kind": "browser" })).unwrap();
        assert_eq!(
            legacy,
            PersistedSurfaceKind::Browser {
                presentation: PersistedBrowserPresentationMode::DaemonRendered,
            }
        );

        let native = PersistedSurfaceKind::Browser {
            presentation: PersistedBrowserPresentationMode::FrontendNative,
        };
        let encoded = serde_json::to_value(&native).unwrap();
        assert_eq!(encoded["kind"], "browser");
        assert_eq!(encoded["presentation"], "frontend-native");
        assert_eq!(serde_json::from_value::<PersistedSurfaceKind>(encoded).unwrap(), native);
    }

    fn state_with_terminal(session_id: SessionId) -> (PersistedSessionState, SurfaceUuid) {
        let surface_uuid = SurfaceUuid::new();
        let pane_uuid = PaneUuid::new();
        let screen_uuid = ScreenUuid::new();
        let workspace_uuid = WorkspaceUuid::new();
        let mut state = PersistedSessionState::empty(session_id);
        state.active_workspace = Some(workspace_uuid);
        state.workspaces.push(PersistedWorkspace {
            uuid: workspace_uuid,
            name: "1".to_string(),
            screens: vec![PersistedScreen {
                uuid: screen_uuid,
                name: None,
                root: PersistedNode::Leaf { pane_uuid },
                active_pane: pane_uuid,
                zoomed_pane: None,
            }],
            active_screen: 0,
        });
        state.panes.push(PersistedPane {
            uuid: pane_uuid,
            name: None,
            tabs: vec![surface_uuid],
            active_tab: 0,
            active_at: 1,
        });
        state.surfaces.push(PersistedSurface {
            uuid: surface_uuid,
            name: None,
            kind: PersistedSurfaceKind::Terminal {
                launch: PersistedLaunchRecipe::sanitized(
                    vec!["/bin/sh".to_string()],
                    Some("/tmp".to_string()),
                    Vec::new(),
                    80,
                    24,
                    10_000,
                    false,
                ),
            },
        });
        (state, surface_uuid)
    }

    fn append_revision(
        durable: &mut DurableSession,
        mut state: PersistedSessionState,
        key: &str,
        revision: u64,
    ) -> PersistedSessionState {
        state.topology_revision = revision;
        let outcome = result(key, revision);
        state.idempotency_results.push(outcome.clone());
        durable.append(state.clone(), key.to_string(), Some(outcome)).unwrap();
        state
    }

    fn revision(
        mut state: PersistedSessionState,
        key: &str,
        topology_revision: u64,
    ) -> (PersistedSessionState, PersistedIdempotencyResult) {
        state.topology_revision = topology_revision;
        let outcome = result(key, topology_revision);
        state.idempotency_results.push(outcome.clone());
        (state, outcome)
    }

    fn launch_attempt(
        surface_uuid: SurfaceUuid,
        phase: PersistedLaunchAttemptPhase,
    ) -> PersistedLaunchAttempt {
        PersistedLaunchAttempt {
            attempt_id: Uuid::new_v4(),
            request_id: format!("attempt-{surface_uuid}"),
            payload_digest: "a".repeat(64),
            surface_uuid,
            launch: PersistedLaunchRecipe::sanitized(
                vec!["/bin/sh".to_string()],
                Some("/tmp".to_string()),
                Vec::new(),
                80,
                24,
                10_000,
                false,
            ),
            phase,
        }
    }

    #[test]
    fn session_identity_survives_restart_but_daemon_identity_does_not() {
        let directory = TestDirectory::new("restart");
        let store = StateStore::new(&directory.0);
        let first_session = store.load_or_create_session("main").unwrap();
        let first_daemon = crate::DaemonInstanceId::new();
        let second_session = store.load_or_create_session("main").unwrap();
        let second_daemon = crate::DaemonInstanceId::new();

        assert_eq!(first_session, second_session);
        assert_ne!(first_daemon, second_daemon);
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(store.session_path("main")).unwrap()).unwrap();
        assert_eq!(value["body"]["version"], STATE_STORE_VERSION);
        assert_eq!(value["body"]["session"], "main");
        assert_eq!(value["body"]["state"]["session_id"], first_session.to_string());
        assert!(value["body"]["state"].get("pid").is_none());
        assert!(value["body"]["state"].get("terminal_output").is_none());
    }

    #[test]
    fn first_use_creates_private_durable_directories_and_reopens() {
        let directory = TestDirectory::new("first-use");
        let store = StateStore::new(directory.0.join("nested/state"));
        assert!(!store.root().exists());

        let opened = store.open_session("main").unwrap();
        let session_id = opened.snapshot.session_id;
        drop(opened.durable);

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot.session_id, session_id);
        drop(reopened.durable);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let sessions = store.root().join("sessions");
            let locks = store.root().join("locks");
            assert_eq!(fs::metadata(store.root()).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(fs::metadata(&sessions).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(fs::metadata(&locks).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(
                fs::metadata(store.session_path("main")).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(store.journal_path("main")).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn explicit_state_root_never_restricts_a_preexisting_shared_directory() {
        use std::os::unix::fs::PermissionsExt;

        let directory = TestDirectory::new("shared-root");
        fs::create_dir(&directory.0).unwrap();
        fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o755)).unwrap();

        let store = StateStore::new(&directory.0);
        let error = store.open_session("main").err().expect("shared root must be rejected");

        assert!(error.to_string().contains("private directory"));
        assert_eq!(fs::metadata(&directory.0).unwrap().permissions().mode() & 0o777, 0o755);
        assert!(!directory.0.join("locks").exists());
        assert!(!directory.0.join("sessions").exists());
    }

    #[cfg(unix)]
    #[test]
    fn creating_a_dedicated_state_root_preserves_its_existing_parent_mode() {
        use std::os::unix::fs::PermissionsExt;

        let directory = TestDirectory::new("shared-parent");
        fs::create_dir(&directory.0).unwrap();
        fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o755)).unwrap();
        let store = StateStore::new(directory.0.join("dedicated-state"));

        let opened = store.open_session("main").unwrap();
        drop(opened.durable);

        assert_eq!(fs::metadata(&directory.0).unwrap().permissions().mode() & 0o777, 0o755);
        assert_eq!(fs::metadata(store.root()).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[cfg(unix)]
    #[test]
    fn state_root_symlink_is_rejected_without_touching_its_target() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let directory = TestDirectory::new("root-symlink");
        fs::create_dir(&directory.0).unwrap();
        let target = directory.0.join("target");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
        let linked_root = directory.0.join("state-link");
        symlink(&target, &linked_root).unwrap();

        let error = StateStore::new(&linked_root)
            .open_session("main")
            .err()
            .expect("symlink root must be rejected");

        assert!(error.to_string().contains("symbolic link"));
        assert_eq!(fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o700);
        assert!(fs::read_dir(&target).unwrap().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn state_child_directory_symlink_is_rejected_without_writing_through_it() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let directory = TestDirectory::new("child-symlink");
        fs::create_dir(&directory.0).unwrap();
        fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o700)).unwrap();
        let target = directory.0.join("external-sessions");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
        symlink(&target, directory.0.join("sessions")).unwrap();

        let error = StateStore::new(&directory.0)
            .open_session("main")
            .err()
            .expect("symlink child must be rejected");

        assert!(error.to_string().contains("symbolic link"));
        assert!(fs::read_dir(&target).unwrap().next().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn state_file_symlink_is_rejected_without_reading_or_replacing_its_target() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let directory = TestDirectory::new("file-symlink");
        let store = StateStore::new(directory.0.join("state"));
        fs::create_dir_all(store.root().join("sessions")).unwrap();
        fs::set_permissions(store.root(), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(store.root().join("sessions"), fs::Permissions::from_mode(0o700))
            .unwrap();
        let target = directory.0.join("outside.json");
        let original = b"outside state must remain untouched";
        fs::write(&target, original).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&target, store.session_path("main")).unwrap();

        let error = store.open_session("main").err().expect("symlink state file must be rejected");

        assert!(error.to_string().contains("symbolic link"));
        assert_eq!(fs::read(&target).unwrap(), original);
        assert!(fs::symlink_metadata(store.session_path("main")).unwrap().file_type().is_symlink());
    }

    #[cfg(unix)]
    #[test]
    fn preexisting_state_file_with_broad_permissions_is_rejected_without_chmod() {
        use std::os::unix::fs::PermissionsExt;

        let directory = TestDirectory::new("broad-file");
        let store = StateStore::new(directory.0.join("state"));
        let opened = store.open_session("main").unwrap();
        drop(opened.durable);
        let checkpoint = store.session_path("main");
        fs::set_permissions(&checkpoint, fs::Permissions::from_mode(0o644)).unwrap();

        let error = store.open_session("main").err().expect("broad state file must be rejected");

        assert!(error.to_string().contains("private file"));
        assert_eq!(fs::metadata(checkpoint).unwrap().permissions().mode() & 0o777, 0o644);
    }

    #[test]
    fn journal_recovers_synced_mutation_without_checkpoint() {
        let directory = TestDirectory::new("append-before-checkpoint");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let expected = append_revision(&mut opened.durable, opened.snapshot, "one", 1);
        drop(opened.durable);

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, expected);
        assert!(fs::metadata(store.journal_path("main")).unwrap().len() > 0);
    }

    #[test]
    fn injected_partial_append_rolls_back_and_opens_rejected_storage_circuit() {
        let directory = TestDirectory::new("partial-append-rollback");
        let io = ScriptedDurableIo::new([
            short_write(DurableIoPhase::JournalWrite, 17),
            fail(DurableIoPhase::JournalWrite),
        ]);
        let store = StateStore::with_io(&directory.0, io.clone());
        let mut opened = store.open_session("main").unwrap();
        let original = fs::read(store.journal_path("main")).unwrap();
        let (state, outcome) = revision(opened.snapshot.clone(), "partial", 1);
        let append =
            opened.durable.append_resolved(state, Vec::new(), "partial".to_string(), Some(outcome));

        let DurableAppendOutcome::Rejected(failure) = append else {
            panic!("partial append must be a known rejection after rollback");
        };
        assert_eq!(failure.phase, DurableIoPhase::JournalWrite);
        assert_eq!(failure.resolution, DurableFailureResolution::Rejected);
        assert_eq!(opened.durable.sequence, 0);
        assert_eq!(fs::read(store.journal_path("main")).unwrap(), original);
        assert!(matches!(
            opened.durable.storage_circuit(),
            StorageCircuit::Degraded(StorageCircuitIncident {
                resolution: DurableFailureResolution::Rejected,
                ..
            })
        ));
        io.assert_consumed();
    }

    #[test]
    fn rollback_sync_failure_preserves_commit_uncertainty() {
        let directory = TestDirectory::new("partial-append-rollback-sync");
        let io = ScriptedDurableIo::new([
            short_write(DurableIoPhase::JournalWrite, 17),
            fail(DurableIoPhase::JournalWrite),
            fail(DurableIoPhase::JournalRollbackSync),
        ]);
        let store = StateStore::with_io(&directory.0, io.clone());
        let mut opened = store.open_session("main").unwrap();
        let (state, outcome) = revision(opened.snapshot.clone(), "rollback-sync", 1);
        let append = opened.durable.append_resolved(
            state,
            Vec::new(),
            "rollback-sync".to_string(),
            Some(outcome),
        );

        let DurableAppendOutcome::CommitIndeterminate(failure) = append else {
            panic!("an unsynced rollback cannot be reported as rejected");
        };
        assert_eq!(failure.phase, DurableIoPhase::JournalRollbackSync);
        assert_eq!(failure.resolution, DurableFailureResolution::CommitIndeterminate);
        assert_eq!(opened.durable.sequence, 0);
        io.assert_consumed();
    }

    #[test]
    fn injected_sync_failure_resyncs_the_exact_record_and_commits_once() {
        let directory = TestDirectory::new("append-resync");
        let io = ScriptedDurableIo::new([fail(DurableIoPhase::JournalSync)]);
        let store = StateStore::with_io(&directory.0, io.clone());
        let mut opened = store.open_session("main").unwrap();
        let (state, outcome) = revision(opened.snapshot.clone(), "resync", 1);
        let append = opened.durable.append_resolved(
            state.clone(),
            Vec::new(),
            "resync".to_string(),
            Some(outcome),
        );

        assert!(matches!(append, DurableAppendOutcome::Committed { sequence: 1, .. }));
        assert_eq!(opened.durable.sequence, 1);
        assert_eq!(opened.durable.storage_circuit(), &StorageCircuit::Healthy);
        io.assert_consumed();
        drop(opened.durable);
        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, state);
        assert_eq!(reopened.durable.sequence, 1);
        assert_eq!(fs::read_to_string(store.journal_path("main")).unwrap().lines().count(), 1);
    }

    #[test]
    fn double_sync_failure_is_commit_indeterminate_and_blocks_new_mutations() {
        let directory = TestDirectory::new("append-indeterminate");
        let io = ScriptedDurableIo::new([
            fail(DurableIoPhase::JournalSync),
            fail(DurableIoPhase::JournalResync),
        ]);
        let store = StateStore::with_io(&directory.0, io.clone());
        let mut opened = store.open_session("main").unwrap();
        let (state, outcome) = revision(opened.snapshot.clone(), "uncertain", 1);
        let append = opened.durable.append_resolved(
            state.clone(),
            Vec::new(),
            "uncertain".to_string(),
            Some(outcome.clone()),
        );

        let DurableAppendOutcome::CommitIndeterminate(failure) = append else {
            panic!("double sync failure must preserve commit uncertainty");
        };
        assert_eq!(failure.phase, DurableIoPhase::JournalResync);
        assert_eq!(opened.durable.sequence, 0);
        let blocked = opened.durable.append_resolved(
            state.clone(),
            Vec::new(),
            "uncertain".to_string(),
            Some(outcome),
        );
        assert!(matches!(
            blocked,
            DurableAppendOutcome::Rejected(DurableWriteFailure {
                phase: DurableIoPhase::CircuitOpen,
                ..
            })
        ));
        io.assert_consumed();
        drop(opened.durable);
        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, state);
        assert_eq!(reopened.durable.sequence, 1);
    }

    #[test]
    fn atomic_rename_failure_is_rejected_but_post_rename_sync_is_indeterminate() {
        for (phase, expected) in [
            (DurableIoPhase::AtomicRename, DurableFailureResolution::Rejected),
            (DurableIoPhase::AtomicDirectorySync, DurableFailureResolution::CommitIndeterminate),
        ] {
            let directory = TestDirectory::new(phase.as_str());
            let io = ScriptedDurableIo::new([fail(phase)]);
            let store = StateStore::with_limits_and_io(&directory.0, 0, 1024 * 1024, io.clone());
            let mut opened = store.open_session("main").unwrap();
            let (state, outcome) = revision(opened.snapshot.clone(), "compact", 1);
            let append = opened.durable.append_resolved(
                state,
                Vec::new(),
                "compact".to_string(),
                Some(outcome),
            );
            match (expected, append) {
                (DurableFailureResolution::Rejected, DurableAppendOutcome::Rejected(failure)) => {
                    assert_eq!(failure.phase, phase);
                }
                (
                    DurableFailureResolution::CommitIndeterminate,
                    DurableAppendOutcome::CommitIndeterminate(failure),
                ) => assert_eq!(failure.phase, phase),
                (_, other) => panic!("unexpected compaction result: {other:?}"),
            }
            io.assert_consumed();
        }
    }

    #[test]
    fn torn_tail_is_quarantined_and_only_valid_prefix_is_replayed() {
        let directory = TestDirectory::new("torn-tail");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let expected = append_revision(&mut opened.durable, opened.snapshot, "one", 1);
        drop(opened.durable);
        append_synced(&store.journal_path("main"), b"{\"body\":").unwrap();

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, expected);
        let archive = reopened.quarantined_tail.unwrap();
        assert_eq!(fs::read(archive).unwrap(), b"{\"body\":");
        assert!(fs::read(store.journal_path("main")).unwrap().ends_with(b"\n"));
    }

    #[test]
    fn final_checksum_mismatch_is_quarantined() {
        let directory = TestDirectory::new("tail-checksum");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        append_revision(&mut opened.durable, opened.snapshot.clone(), "one", 1);
        drop(opened.durable);
        let path = store.journal_path("main");
        let mut value: serde_json::Value =
            serde_json::from_slice(fs::read_to_string(&path).unwrap().trim().as_bytes()).unwrap();
        value["checksum"] = serde_json::Value::String("00000000".to_string());
        fs::write(&path, format!("{}\n", serde_json::to_string(&value).unwrap())).unwrap();

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot.topology_revision, 0);
        assert!(reopened.quarantined_tail.is_some());
    }

    #[test]
    fn interior_corruption_fails_closed_without_truncation() {
        let directory = TestDirectory::new("interior-corruption");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let state = append_revision(&mut opened.durable, opened.snapshot, "one", 1);
        append_revision(&mut opened.durable, state, "two", 2);
        drop(opened.durable);
        let path = store.journal_path("main");
        let mut bytes = fs::read(&path).unwrap();
        bytes[0] = b'!';
        fs::write(&path, &bytes).unwrap();

        let error = match store.open_session("main") {
            Ok(_) => panic!("interior corruption unexpectedly recovered"),
            Err(error) => error,
        };
        assert!(matches!(error, StateStoreError::Corrupt { .. }));
        assert_eq!(fs::read(path).unwrap(), bytes);
    }

    #[test]
    fn duplicate_idempotency_replay_keeps_original_result() {
        let directory = TestDirectory::new("duplicate-idempotency");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let state = append_revision(&mut opened.durable, opened.snapshot, "same", 1);
        let epoch = opened.durable.epoch;
        let sequence = opened.durable.sequence + 1;
        drop(opened.durable);
        let body = JournalBody {
            version: STATE_STORE_VERSION,
            format: JOURNAL_FORMAT.to_string(),
            session_id: state.session_id,
            epoch,
            sequence,
            idempotency_key: "same".to_string(),
            result: Some(result("same", 1)),
            state: state.clone(),
            launch_attempts: Vec::new(),
        };
        append_synced(
            &store.journal_path("main"),
            &encode_journal(&store.journal_path("main"), &body).unwrap(),
        )
        .unwrap();

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, state);
        assert_eq!(reopened.durable.sequence, sequence);
    }

    #[test]
    fn compaction_advances_epoch_and_atomically_bounds_journal() {
        let directory = TestDirectory::new("compaction");
        let store = StateStore::with_limits(&directory.0, 2, 1024 * 1024);
        let mut opened = store.open_session("main").unwrap();
        let state = append_revision(&mut opened.durable, opened.snapshot, "one", 1);
        let state = append_revision(&mut opened.durable, state, "two", 2);
        let expected = append_revision(&mut opened.durable, state, "three", 3);
        assert_eq!(opened.durable.epoch, 2);
        assert_eq!(opened.durable.sequence, 1);
        assert_eq!(opened.durable.journal_records, 1);
        drop(opened.durable);

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, expected);
        assert_eq!(reopened.durable.epoch, 2);
    }

    #[test]
    fn launch_environment_is_allowlisted_and_secrets_never_reach_disk() {
        let directory = TestDirectory::new("secret-redaction");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let recipe = PersistedLaunchRecipe::sanitized(
            vec!["/bin/sh".to_string()],
            Some("/tmp".to_string()),
            vec![
                ("LANG".to_string(), "en_US.UTF-8".to_string()),
                ("API_TOKEN".to_string(), "do-not-persist".to_string()),
                ("LC_TOKEN".to_string(), "locale-shaped-secret".to_string()),
                ("CMUX_SOCKET_PASSWORD".to_string(), "also-secret".to_string()),
            ],
            80,
            24,
            10_000,
            false,
        );
        assert_eq!(recipe.environment.len(), 1);
        let mut state = opened.snapshot;
        let surface_uuid = SurfaceUuid::new();
        let pane_uuid = PaneUuid::new();
        let screen_uuid = ScreenUuid::new();
        let workspace_uuid = WorkspaceUuid::new();
        state.active_workspace = Some(workspace_uuid);
        state.workspaces.push(PersistedWorkspace {
            uuid: workspace_uuid,
            name: "1".to_string(),
            screens: vec![PersistedScreen {
                uuid: screen_uuid,
                name: None,
                root: PersistedNode::Leaf { pane_uuid },
                active_pane: pane_uuid,
                zoomed_pane: None,
            }],
            active_screen: 0,
        });
        state.panes.push(PersistedPane {
            uuid: pane_uuid,
            name: None,
            tabs: vec![surface_uuid],
            active_tab: 0,
            active_at: 1,
        });
        state.surfaces.push(PersistedSurface {
            uuid: surface_uuid,
            name: None,
            kind: PersistedSurfaceKind::Terminal { launch: recipe },
        });
        state = append_revision(&mut opened.durable, state, "launch", 1);
        drop(opened.durable);
        let bytes = fs::read(store.journal_path("main")).unwrap();
        assert!(!bytes.windows(b"do-not-persist".len()).any(|window| window == b"do-not-persist"));
        assert!(!bytes.windows(b"also-secret".len()).any(|window| window == b"also-secret"));
        assert!(
            !bytes
                .windows(b"locale-shaped-secret".len())
                .any(|window| { window == b"locale-shaped-secret" })
        );
        assert_eq!(store.open_session("main").unwrap().snapshot, state);
    }

    #[test]
    fn terminal_activity_round_trips_without_notification_content() {
        let directory = TestDirectory::new("activity-round-trip");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let reader_uuid = Uuid::new_v4();
        let (mut state, surface_uuid) = state_with_terminal(opened.snapshot.session_id);
        state.activity_sequence = 7;
        state.activity_facts.push(TerminalActivityFact {
            surface_uuid,
            sequence: 7,
            kind: crate::TerminalActivityKind::Notification,
            notification: 41,
            level: crate::NotificationLevel::Warning,
        });
        state.activity_receipts.push(TerminalActivityReadReceipt {
            reader_uuid,
            surface_uuid,
            seen_sequence: 7,
        });
        opened.durable.append(state.clone(), "activity".to_string(), None).unwrap();
        drop(opened.durable);

        let bytes = fs::read(store.journal_path("main")).unwrap();
        assert!(!bytes.windows(b"private title".len()).any(|window| window == b"private title"));
        assert!(!bytes.windows(b"private body".len()).any(|window| window == b"private body"));
        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, state);
    }

    #[test]
    fn recovery_quarantines_pending_launches_without_making_them_visible() {
        let directory = TestDirectory::new("pending-launch-recovery");
        let store = StateStore::new(&directory.0);
        let mut opened = store.open_session("main").unwrap();
        let pending_surface = SurfaceUuid::new();
        let quarantined_surface = SurfaceUuid::new();
        let attempts = vec![
            launch_attempt(pending_surface, PersistedLaunchAttemptPhase::PendingActivation),
            launch_attempt(quarantined_surface, PersistedLaunchAttemptPhase::Quarantined),
        ];
        let state = opened.snapshot.clone();

        let append = opened.durable.append_resolved(
            state.clone(),
            attempts,
            "launch-attempts".to_string(),
            None,
        );
        assert!(matches!(append, DurableAppendOutcome::Committed { .. }));
        drop(opened.durable);

        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, state);
        assert!(reopened.snapshot.surfaces.is_empty());
        assert_eq!(reopened.launch_attempts.len(), 2);
        assert!(
            reopened
                .launch_attempts
                .iter()
                .all(|attempt| attempt.phase == PersistedLaunchAttemptPhase::Quarantined)
        );
        assert!(reopened.launch_attempts.iter().any(|attempt| {
            attempt.surface_uuid == pending_surface
                && attempt.phase == PersistedLaunchAttemptPhase::Quarantined
        }));
    }

    #[test]
    fn terminal_activity_validation_rejects_bad_references_order_and_reader_bounds() {
        let path = PathBuf::from("activity-validation");
        let (mut state, surface_uuid) = state_with_terminal(SessionId::new());
        state.activity_sequence = 2;
        state.activity_facts.push(TerminalActivityFact {
            surface_uuid,
            sequence: 2,
            kind: crate::TerminalActivityKind::Notification,
            notification: 1,
            level: crate::NotificationLevel::Info,
        });

        let mut unknown_surface = state.clone();
        unknown_surface.activity_facts[0].surface_uuid = SurfaceUuid::new();
        assert!(validate_snapshot(&path, &unknown_surface).is_err());

        let mut future_fact = state.clone();
        future_fact.activity_facts[0].sequence = 3;
        assert!(validate_snapshot(&path, &future_fact).is_err());

        let mut future_receipt = state.clone();
        future_receipt.activity_receipts.push(TerminalActivityReadReceipt {
            reader_uuid: Uuid::new_v4(),
            surface_uuid,
            seen_sequence: 3,
        });
        assert!(validate_snapshot(&path, &future_receipt).is_err());

        let mut too_many_readers = state;
        too_many_readers.activity_receipts = (0..=MAX_TERMINAL_ACTIVITY_READERS)
            .map(|index| TerminalActivityReadReceipt {
                reader_uuid: Uuid::from_u128(index as u128 + 1),
                surface_uuid,
                seen_sequence: 2,
            })
            .collect();
        let error = validate_snapshot(&path, &too_many_readers).unwrap_err();
        assert!(error.to_string().contains("reader or receipt capacity"));
    }

    #[test]
    fn recovery_metadata_is_strictly_bounded() {
        let directory = TestDirectory::new("bounded-metadata");
        let store = StateStore::new(&directory.0);
        let opened = store.open_session("main").unwrap();
        let mut state = opened.snapshot;
        drop(opened.durable);
        state.tombstones = (0..=MAX_PERSISTED_TOMBSTONES)
            .map(|index| PersistedTombstone {
                kind: PersistedEntityKind::Surface,
                uuid: Uuid::from_u128(index as u128 + 1),
                removed_at_topology_revision: index as u64,
            })
            .collect();
        let error = validate_snapshot(&store.session_path("main"), &state).unwrap_err();
        assert!(error.to_string().contains("bounded recovery metadata"));
    }

    #[test]
    fn corrupt_state_fails_closed_then_explicit_recovery_archives_it() {
        let directory = TestDirectory::new("corrupt");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        let corrupt = b"{ definitely-not-json";
        write_private_fixture(&path, corrupt);

        let error = store.load_or_create_session("main").unwrap_err();
        assert!(matches!(error, StateStoreError::Corrupt { .. }));
        assert_eq!(fs::read(&path).unwrap(), corrupt);

        let recovered = store.recover_session("main").unwrap();
        let archive = recovered.archived_corrupt_state.unwrap();
        assert_eq!(fs::read(archive).unwrap(), corrupt);
        assert_eq!(store.load_or_create_session("main").unwrap(), recovered.session_id);
    }

    #[test]
    fn concurrent_recovery_converges_without_archiving_valid_state() {
        use std::sync::Barrier;

        let directory = TestDirectory::new("concurrent-recovery");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        let corrupt = b"{ concurrently-corrupt";
        write_private_fixture(&path, corrupt);

        let start = Arc::new(Barrier::new(16));
        let workers = (0..16)
            .map(|_| {
                let store = store.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    store.recover_session("main").unwrap()
                })
            })
            .collect::<Vec<_>>();
        let recoveries =
            workers.into_iter().map(|worker| worker.join().unwrap()).collect::<Vec<_>>();

        let session_id = recoveries[0].session_id;
        assert!(recoveries.iter().all(|recovery| recovery.session_id == session_id));
        let archives = recoveries
            .iter()
            .filter_map(|recovery| recovery.archived_corrupt_state.as_ref())
            .collect::<Vec<_>>();
        assert_eq!(archives.len(), 1);
        assert_eq!(fs::read(archives[0]).unwrap(), corrupt);
        assert_eq!(store.load_or_create_session("main").unwrap(), session_id);
        assert_eq!(store.recover_session("main").unwrap().archived_corrupt_state, None);
    }

    #[test]
    fn version_one_identity_migrates_without_changing_session_id() {
        let directory = TestDirectory::new("v1-migration");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        let session_id = SessionId::new();
        write_private_fixture(
            &path,
            &serde_json::to_vec(&StoredSessionV1 {
                version: 1,
                session: "main".to_string(),
                session_id,
            })
            .unwrap(),
        );

        assert_eq!(store.load_or_create_session("main").unwrap(), session_id);
        let value: serde_json::Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
        assert_eq!(value["body"]["version"], STATE_STORE_VERSION);
    }

    #[test]
    fn version_three_migration_preserves_active_launches_and_exact_rollback_bytes() {
        let directory = TestDirectory::new("v3-migration");
        let store = StateStore::new(&directory.0);
        let checkpoint_path = store.session_path("main");
        let journal_path = store.journal_path("main");
        let session_id = SessionId::new();
        let (checkpoint_state, surface_uuid) = state_with_terminal(session_id);
        let checkpoint_body = CheckpointBodyV3 {
            version: 3,
            format: CHECKPOINT_FORMAT.to_string(),
            session: "main".to_string(),
            epoch: 7,
            sequence: 0,
            state: checkpoint_state.clone(),
        };
        let checkpoint = CheckpointEnvelopeV3 {
            checksum: checksum_json(&checkpoint_body).unwrap(),
            body: checkpoint_body,
        };
        let checkpoint_bytes = serde_json::to_vec_pretty(&checkpoint).unwrap();
        write_private_fixture(&checkpoint_path, &checkpoint_bytes);

        let mut journal_state = checkpoint_state;
        journal_state.topology_revision = 1;
        let journal_body = JournalBodyV3 {
            version: 3,
            format: JOURNAL_FORMAT.to_string(),
            session_id,
            epoch: 7,
            sequence: 1,
            idempotency_key: "v3-synced".to_string(),
            result: None,
            state: journal_state.clone(),
        };
        let journal = JournalEnvelopeV3 {
            checksum: checksum_json(&journal_body).unwrap(),
            body: journal_body,
        };
        let mut journal_bytes = serde_json::to_vec(&journal).unwrap();
        journal_bytes.push(b'\n');
        write_private_fixture(&journal_path, &journal_bytes);

        let opened = store.open_session("main").unwrap();
        assert_eq!(opened.snapshot, journal_state);
        assert_eq!(opened.launch_attempts.len(), 1);
        assert_eq!(opened.launch_attempts[0].surface_uuid, surface_uuid);
        assert_eq!(opened.launch_attempts[0].phase, PersistedLaunchAttemptPhase::Active);
        drop(opened.durable);
        assert!(fs::read(&journal_path).unwrap().is_empty());
        let migrated: CheckpointEnvelope =
            serde_json::from_slice(&fs::read(&checkpoint_path).unwrap()).unwrap();
        assert_eq!(migrated.body.version, STATE_STORE_VERSION);
        assert_eq!(migrated.body.epoch, 8);
        assert_eq!(migrated.body.launch_attempts.len(), 1);

        let (checkpoint_backup, journal_backup) = store.version_three_backup_paths("main");
        assert_eq!(fs::read(&checkpoint_backup).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_backup).unwrap(), journal_bytes);
        store.restore_version_three_backup("main").unwrap();
        assert_eq!(fs::read(&checkpoint_path).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_path).unwrap(), journal_bytes);

        // Retrying the migration consumes but never overwrites the same
        // immutable rollback point.
        let reopened = store.open_session("main").unwrap();
        assert_eq!(reopened.snapshot, journal_state);
        drop(reopened.durable);
        assert_eq!(fs::read(&checkpoint_backup).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_backup).unwrap(), journal_bytes);

        let active_checkpoint = fs::read(&checkpoint_path).unwrap();
        let active_journal = fs::read(&journal_path).unwrap();
        let mut tampered = journal_bytes.clone();
        tampered.extend_from_slice(b"truncated");
        fs::write(&journal_backup, &tampered).unwrap();
        let error = store.restore_version_three_backup("main").unwrap_err();
        assert!(error.to_string().contains("truncated or invalid tail"));
        assert_eq!(fs::read(&checkpoint_path).unwrap(), active_checkpoint);
        assert_eq!(fs::read(&journal_path).unwrap(), active_journal);
        assert_eq!(fs::read(&journal_backup).unwrap(), tampered);
    }

    #[test]
    fn version_three_migration_refuses_to_overwrite_a_different_backup() {
        let directory = TestDirectory::new("v3-migration-backup-mismatch");
        let store = StateStore::new(&directory.0);
        let checkpoint_path = store.session_path("main");
        let journal_path = store.journal_path("main");
        let body = CheckpointBodyV3 {
            version: 3,
            format: CHECKPOINT_FORMAT.to_string(),
            session: "main".to_string(),
            epoch: 1,
            sequence: 0,
            state: PersistedSessionState::empty(SessionId::new()),
        };
        let checkpoint = CheckpointEnvelopeV3 { checksum: checksum_json(&body).unwrap(), body };
        let checkpoint_bytes = serde_json::to_vec_pretty(&checkpoint).unwrap();
        write_private_fixture(&checkpoint_path, &checkpoint_bytes);
        write_private_fixture(&journal_path, &[]);
        let (checkpoint_backup, _) = store.version_three_backup_paths("main");
        write_private_fixture(&checkpoint_backup, b"different rollback point");

        let error = store.open_session("main").err().expect("migration must fail closed");
        assert!(error.to_string().contains("immutable migration backup differs"));
        assert_eq!(fs::read(&checkpoint_path).unwrap(), checkpoint_bytes);
        assert!(fs::read(&journal_path).unwrap().is_empty());
        assert_eq!(fs::read(&checkpoint_backup).unwrap(), b"different rollback point");
    }

    #[test]
    fn version_two_checkpoint_and_synced_journal_migrate_without_state_loss() {
        let directory = TestDirectory::new("v2-migration");
        let store = StateStore::new(&directory.0);
        let checkpoint_path = store.session_path("main");
        let journal_path = store.journal_path("main");
        let session_id = SessionId::new();
        let checkpoint_state = PersistedSessionStateV2 {
            session_id,
            topology_revision: 0,
            active_workspace: None,
            workspaces: Vec::new(),
            panes: Vec::new(),
            surfaces: Vec::new(),
            tombstones: Vec::new(),
            idempotency_results: Vec::new(),
        };
        let checkpoint_body = CheckpointBodyV2 {
            version: 2,
            format: CHECKPOINT_FORMAT.to_string(),
            session: "main".to_string(),
            epoch: 4,
            sequence: 0,
            state: checkpoint_state.clone(),
        };
        let checkpoint = CheckpointEnvelopeV2 {
            checksum: checksum_json(&checkpoint_body).unwrap(),
            body: checkpoint_body,
        };
        let checkpoint_bytes = serde_json::to_vec_pretty(&checkpoint).unwrap();
        write_private_fixture(&checkpoint_path, &checkpoint_bytes);

        let mut journal_state = checkpoint_state;
        journal_state.topology_revision = 1;
        let journal_body = JournalBodyV2 {
            version: 2,
            format: JOURNAL_FORMAT.to_string(),
            session_id,
            epoch: 4,
            sequence: 1,
            idempotency_key: "v2-synced".to_string(),
            result: None,
            state: journal_state,
        };
        let journal = JournalEnvelopeV2 {
            checksum: checksum_json(&journal_body).unwrap(),
            body: journal_body,
        };
        let mut journal_bytes = serde_json::to_vec(&journal).unwrap();
        journal_bytes.push(b'\n');
        write_private_fixture(&journal_path, &journal_bytes);

        let opened = store.open_session("main").unwrap();
        assert_eq!(opened.snapshot.session_id, session_id);
        assert_eq!(opened.snapshot.topology_revision, 1);
        assert_eq!(opened.snapshot.activity_sequence, 0);
        assert!(opened.snapshot.activity_facts.is_empty());
        assert!(opened.snapshot.activity_receipts.is_empty());
        drop(opened.durable);
        assert!(fs::read(&journal_path).unwrap().is_empty());
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(&checkpoint_path).unwrap()).unwrap();
        assert_eq!(value["body"]["version"], STATE_STORE_VERSION);
        assert_eq!(value["body"]["epoch"], 5);

        let (checkpoint_backup, journal_backup) = store.version_two_backup_paths("main");
        assert_eq!(fs::read(&checkpoint_backup).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_backup).unwrap(), journal_bytes);

        store.restore_version_two_backup("main").unwrap();
        assert_eq!(fs::read(&checkpoint_path).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_path).unwrap(), journal_bytes);
        let restored_checkpoint: CheckpointEnvelopeV2 =
            serde_json::from_slice(&fs::read(&checkpoint_path).unwrap()).unwrap();
        validate_checkpoint_v2(&checkpoint_path, "main", &restored_checkpoint).unwrap();
        let restored = replay_journal_v2(
            &journal_path,
            restored_checkpoint.body.epoch,
            restored_checkpoint.body.sequence,
            restored_checkpoint.body.state.into(),
            store.limits,
        )
        .unwrap();
        assert_eq!(restored.state.session_id, session_id);
        assert_eq!(restored.state.topology_revision, 1);

        // A retried upgrade consumes the same immutable backup instead of
        // overwriting the rollback point with already-migrated bytes.
        assert_eq!(store.load_or_create_session("main").unwrap(), session_id);
        assert_eq!(fs::read(checkpoint_backup).unwrap(), checkpoint_bytes);
        assert_eq!(fs::read(&journal_backup).unwrap(), journal_bytes);

        // Rollback validates backups without repairing or truncating them. A
        // tampered rollback point must leave the active version-3 state and
        // the forensic backup bytes untouched.
        let active_checkpoint = fs::read(&checkpoint_path).unwrap();
        let active_journal = fs::read(&journal_path).unwrap();
        let mut tampered_journal_backup = journal_bytes.clone();
        tampered_journal_backup.extend_from_slice(b"truncated");
        fs::write(&journal_backup, &tampered_journal_backup).unwrap();
        let error = store.restore_version_two_backup("main").unwrap_err();
        assert!(error.to_string().contains("truncated or invalid tail"));
        assert_eq!(fs::read(&checkpoint_path).unwrap(), active_checkpoint);
        assert_eq!(fs::read(&journal_path).unwrap(), active_journal);
        assert_eq!(fs::read(journal_backup).unwrap(), tampered_journal_backup);
    }

    #[test]
    fn version_two_migration_refuses_to_overwrite_a_different_backup() {
        let directory = TestDirectory::new("v2-migration-backup-mismatch");
        let store = StateStore::new(&directory.0);
        let checkpoint_path = store.session_path("main");
        let journal_path = store.journal_path("main");
        let session_id = SessionId::new();
        let body = CheckpointBodyV2 {
            version: 2,
            format: CHECKPOINT_FORMAT.to_string(),
            session: "main".to_string(),
            epoch: 1,
            sequence: 0,
            state: PersistedSessionStateV2 {
                session_id,
                topology_revision: 0,
                active_workspace: None,
                workspaces: Vec::new(),
                panes: Vec::new(),
                surfaces: Vec::new(),
                tombstones: Vec::new(),
                idempotency_results: Vec::new(),
            },
        };
        let checkpoint = CheckpointEnvelopeV2 { checksum: checksum_json(&body).unwrap(), body };
        let checkpoint_bytes = serde_json::to_vec_pretty(&checkpoint).unwrap();
        write_private_fixture(&checkpoint_path, &checkpoint_bytes);
        write_private_fixture(&journal_path, &[]);
        let (checkpoint_backup, _) = store.version_two_backup_paths("main");
        write_private_fixture(&checkpoint_backup, b"different rollback point");

        let error = match store.open_session("main") {
            Ok(_) => panic!("migration unexpectedly overwrote a different backup"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("immutable migration backup differs"));
        assert_eq!(fs::read(checkpoint_path).unwrap(), checkpoint_bytes);
        assert!(fs::read(journal_path).unwrap().is_empty());
        assert_eq!(fs::read(checkpoint_backup).unwrap(), b"different rollback point");
    }

    #[test]
    fn unknown_state_version_fails_closed() {
        let directory = TestDirectory::new("version");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        write_private_fixture(&path, b"{\"version\":999}");

        let error = store.load_or_create_session("main").unwrap_err();
        assert!(error.to_string().contains("unsupported version"));
    }

    #[test]
    fn checkpoint_checksum_mismatch_fails_closed_without_replacement() {
        let directory = TestDirectory::new("checkpoint-checksum");
        let store = StateStore::new(&directory.0);
        store.load_or_create_session("main").unwrap();
        let path = store.session_path("main");
        let mut value: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["checksum"] = serde_json::Value::String("00000000".to_string());
        let corrupt = serde_json::to_vec_pretty(&value).unwrap();
        fs::write(&path, &corrupt).unwrap();

        let error = store.load_or_create_session("main").unwrap_err();
        assert!(error.to_string().contains("checkpoint checksum mismatch"));
        assert_eq!(fs::read(path).unwrap(), corrupt);
    }

    #[test]
    fn opened_session_holds_exclusive_startup_lock_for_its_lifetime() {
        let directory = TestDirectory::new("daemon-lock");
        let store = StateStore::new(&directory.0);
        let opened = store.open_session("main").unwrap();
        let lock_path = store.root().join("locks").join(format!("{}.lock", session_key("main")));
        let contender = OpenOptions::new().read(true).write(true).open(&lock_path).unwrap();
        assert!(fs2::FileExt::try_lock_exclusive(&contender).is_err());
        drop(opened.durable);
        fs2::FileExt::try_lock_exclusive(&contender).unwrap();
        fs2::FileExt::unlock(&contender).unwrap();
    }

    #[test]
    fn crc32_matches_standard_test_vector() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }
}
