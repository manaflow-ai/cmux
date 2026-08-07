//! Durable, single-writer workspace registry.
//!
//! The mux owns one of these behind its workspace-commit mutex. A registry
//! transaction commits before the corresponding in-memory projection and
//! event are published, so durable order, reply order, and event order are the
//! same order. Runtime pane/surface ids deliberately never enter this store.

#[cfg(test)]
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::Context;
use fs4::FileExt;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::platform;
use crate::resource::{
    BrowserPublicId, ContentPublicId, MachinePublicId, PanePublicId, ScreenPublicId,
    SessionPublicId, SplitPublicId, TabPublicId, TerminalPublicId, WorkspacePublicId,
};
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostLiveness;

mod effect_store;
mod public_projection_store;
mod resource_store;
mod terminal_exit_store;

pub(crate) use effect_store::ResourceWorkspaceClose;
pub use effect_store::{
    ResourceCreationPreparation, ResourceCreationRecovery, ResourceEffectOutcome,
    ResourceEffectPreparation,
};
use effect_store::{
    create_resource_effect_schema, delete_legacy_sensitive_effect_receipts,
    initialize_resource_input_receipt_retention, prune_resource_events, recover_resource_effects,
};
pub use public_projection_store::RegistryPublicProjections;
#[cfg(test)]
pub use public_projection_store::{RegistryAgentProjection, RegistryNotificationProjection};
pub(crate) use resource_store::validate_registry_screen_projection;
#[allow(unused_imports)]
pub use resource_store::{
    RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserReconnect, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryTab,
    RegistryViewport, RegistryViewportColumn, ResourceChange, ResourceEventBatch,
    ResourceEventPage, ResourcePatch, ResourcePatchCommit, ResourceTopologySnapshot,
};
use resource_store::{
    apply_resource_patch, create_resource_schema, initialize_resource_mutation_retention,
    migrate_resource_agent_projections, migrate_resource_browser_metadata,
    migrate_resource_mutations_to_session_scope, migrate_resource_tabs_to_multiview,
    resource_tabs_has_legacy_content_uniqueness, validate_resource_invariants,
};

const SCHEMA_VERSION: i64 = 9;
const RESOURCE_EFFECT_PEPPER_SCHEMA_VERSION: i64 = 7;
const MAX_ID_LEN: usize = 128;
const MAX_WORKSPACE_KEY_LEN: usize = 256;
const MAX_PROJECTION_BYTES: usize = 1024 * 1024;
const MAX_LAUNCH_SPEC_BYTES: usize = 1024 * 1024;
const RESOURCE_EFFECT_PEPPER_BYTES: usize = 32;
const RESOURCE_EFFECT_PEPPER_FILE: &str = "resource-effect-pepper";
const RESOURCE_EFFECT_PEPPER_LOCK_FILE: &str = "resource-effect-pepper.lock";
const RESOURCE_EFFECT_PEPPER_META_KEY: &str = "resource_effect_pepper_id";
const RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY: &str = "resource_effect_pepper_cleanup_pending";
const RESOURCE_EFFECT_PEPPER_ID_DOMAIN: &[u8] = b"cmux.resource-effect-pepper-id.v1";
const RESOURCE_INPUT_RECEIPT_DOMAIN: &[u8] = b"cmux.resource-input-receipt.v2";
const WORKSPACE_REGISTRY_FILE: &str = "workspace-registry.sqlite3";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedWorkspaceRegistrySchema {
    found: i64,
    newest_supported: i64,
    database_path: Option<PathBuf>,
    registry_id: Option<String>,
}

impl UnsupportedWorkspaceRegistrySchema {
    pub fn found(&self) -> i64 {
        self.found
    }

    pub fn newest_supported(&self) -> i64 {
        self.newest_supported
    }

    pub fn database_path(&self) -> Option<&Path> {
        self.database_path.as_deref()
    }

    pub fn registry_id(&self) -> Option<&str> {
        self.registry_id.as_deref()
    }
}

impl std::fmt::Display for UnsupportedWorkspaceRegistrySchema {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "unsupported workspace registry schema {}; newest supported is {}",
            self.found, self.newest_supported
        )
    }
}

impl std::error::Error for UnsupportedWorkspaceRegistrySchema {}

struct ResourceEffectPepper(Zeroizing<[u8; RESOURCE_EFFECT_PEPPER_BYTES]>);

impl ResourceEffectPepper {
    fn random() -> anyhow::Result<Self> {
        let mut bytes = [0_u8; RESOURCE_EFFECT_PEPPER_BYTES];
        getrandom::fill(&mut bytes)
            .map_err(|_| crate::resource::ResourceError::allocation("resource receipt pepper"))?;
        anyhow::ensure!(bytes.iter().any(|byte| *byte != 0), "resource receipt pepper is invalid");
        Ok(Self(Zeroizing::new(bytes)))
    }

    fn from_bytes(mut bytes: Vec<u8>, path: &Path) -> anyhow::Result<Self> {
        anyhow::ensure!(
            bytes.len() == RESOURCE_EFFECT_PEPPER_BYTES,
            "resource receipt pepper is corrupt: {}",
            path.display()
        );
        let mut pepper = [0_u8; RESOURCE_EFFECT_PEPPER_BYTES];
        pepper.copy_from_slice(&bytes);
        bytes.zeroize();
        anyhow::ensure!(
            pepper.iter().any(|byte| *byte != 0),
            "resource receipt pepper is corrupt: {}",
            path.display()
        );
        Ok(Self(Zeroizing::new(pepper)))
    }

    fn identifier(&self) -> String {
        let mut hasher = Sha256::new();
        update_sha256_part(&mut hasher, RESOURCE_EFFECT_PEPPER_ID_DOMAIN);
        update_sha256_part(&mut hasher, self.0.as_ref());
        hex_sha256(hasher.finalize().into())
    }

    fn input_receipt_hmac(
        &self,
        idempotency_key: &str,
        operation: &str,
        canonical_fields: &[u8],
    ) -> [u8; 32] {
        const BLOCK_BYTES: usize = 64;
        let mut key_block = [0_u8; BLOCK_BYTES];
        key_block[..RESOURCE_EFFECT_PEPPER_BYTES].copy_from_slice(self.0.as_ref());
        let mut inner_pad = [0x36_u8; BLOCK_BYTES];
        let mut outer_pad = [0x5c_u8; BLOCK_BYTES];
        for index in 0..BLOCK_BYTES {
            inner_pad[index] ^= key_block[index];
            outer_pad[index] ^= key_block[index];
        }

        let mut inner = Sha256::new();
        inner.update(inner_pad);
        update_sha256_part(&mut inner, RESOURCE_INPUT_RECEIPT_DOMAIN);
        update_sha256_part(&mut inner, idempotency_key.as_bytes());
        update_sha256_part(&mut inner, operation.as_bytes());
        update_sha256_part(&mut inner, canonical_fields);
        let inner = inner.finalize();

        let mut outer = Sha256::new();
        outer.update(outer_pad);
        outer.update(inner);
        let digest = outer.finalize().into();
        key_block.zeroize();
        inner_pad.zeroize();
        outer_pad.zeroize();
        digest
    }
}

fn update_sha256_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    hasher.update(value);
}

fn hex_sha256(digest: [u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryWorkspace {
    pub id: u64,
    pub public_id: WorkspacePublicId,
    pub key: String,
    pub name: String,
    pub group_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistrySnapshot {
    pub registry_id: String,
    pub generation: String,
    pub revision: u64,
    pub resource_revision: u64,
    pub session_id: SessionPublicId,
    pub next_numeric_id: u64,
    pub workspaces: Vec<RegistryWorkspace>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutation {
    pub id: String,
    pub origin: String,
}

impl WorkspaceMutation {
    pub fn new(id: impl Into<String>, origin: impl Into<String>) -> anyhow::Result<Self> {
        let mutation = Self { id: id.into(), origin: origin.into() };
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        Ok(mutation)
    }

    pub fn local(origin: &str) -> Self {
        Self { id: new_uuid_v4(), origin: origin.to_string() }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegistryCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegistryEvent {
    pub revision: u64,
    pub kind: String,
    pub workspace_key: String,
    pub origin: String,
    pub mutation_id: String,
    pub result: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalLifecycle {
    Launching,
    Adopting,
    Running,
    Exited,
    Tombstoned,
}

impl TerminalLifecycle {
    fn as_str(self) -> &'static str {
        match self {
            Self::Launching => "launching",
            Self::Adopting => "adopting",
            Self::Running => "running",
            Self::Exited => "exited",
            Self::Tombstoned => "tombstoned",
        }
    }

    fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "launching" => Ok(Self::Launching),
            "adopting" => Ok(Self::Adopting),
            "running" => Ok(Self::Running),
            "exited" => Ok(Self::Exited),
            "tombstoned" => Ok(Self::Tombstoned),
            other => anyhow::bail!("invalid terminal lifecycle {other:?}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryTerminal {
    pub terminal_id: String,
    pub workspace_key: String,
    pub incarnation: Option<String>,
    pub lifecycle: TerminalLifecycle,
    pub launch_spec: Value,
    pub exit: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistrySnapshot {
    pub registry_id: String,
    pub generation: String,
    pub revision: u64,
    pub terminals: Vec<RegistryTerminal>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistryCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalBatchClose {
    pub revision: u64,
    pub closed: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistentSessionStateReset {
    pub session_dir: PathBuf,
    pub terminal_host_root: PathBuf,
    pub removed_session_state: bool,
    pub removed_terminal_hosts: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistentSessionStateResetPreview {
    pub state_root: PathBuf,
    pub session_dir: PathBuf,
    pub terminal_host_root: PathBuf,
    pub pending_reset_dirs: Vec<PathBuf>,
    pub requires_force: bool,
    pub confirm_reset: String,
}

/// Owns destructive persistent-state reset policy for one workspace state root.
///
/// Callers first ask this owner for a preview, then pass the preview's
/// confirmation token back to [`Self::reset`]. The token is tied to the root,
/// session directory, terminal-host directory, and current target contents.
#[derive(Debug, Clone)]
pub struct PersistentSessionStateResetter {
    state_root: PathBuf,
}

impl PersistentSessionStateResetter {
    /// Creates a reset owner for one durable workspace state root.
    pub fn new(state_root: impl Into<PathBuf>) -> Self {
        Self { state_root: state_root.into() }
    }

    /// Returns the workspace state root this reset owner can mutate.
    pub fn state_root(&self) -> &Path {
        &self.state_root
    }

    /// Returns the scoped persistent session directory for `session_name`.
    pub fn session_dir(&self, session_name: &str) -> PathBuf {
        persistent_session_state_dir(&self.state_root, session_name)
    }

    /// Builds a read-only reset preview for `session_name`.
    pub fn preview(
        &self,
        session_name: &str,
    ) -> anyhow::Result<PersistentSessionStateResetPreview> {
        let session_dir = self.session_dir(session_name);
        let terminal_host_root =
            crate::terminal_host_runtime::terminal_host_root(&self.state_root, session_name);
        let pending_reset_dirs = pending_session_reset_dirs(&self.state_root, session_name)?;
        let confirm_reset = reset_confirmation_token(
            &self.state_root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
        )?;
        Ok(PersistentSessionStateResetPreview {
            state_root: self.state_root.clone(),
            session_dir: session_dir.clone(),
            terminal_host_root: terminal_host_root.clone(),
            pending_reset_dirs,
            requires_force: true,
            confirm_reset,
        })
    }

    /// Removes the scoped saved state for `session_name` after confirmation.
    pub fn reset(
        &self,
        session_name: &str,
        confirm_reset: Option<&str>,
    ) -> anyhow::Result<PersistentSessionStateReset> {
        let root = &self.state_root;
        let session_dir = self.session_dir(session_name);
        let terminal_host_root =
            crate::terminal_host_runtime::terminal_host_root(root, session_name);
        let mut reset = PersistentSessionStateReset {
            session_dir: session_dir.clone(),
            terminal_host_root: terminal_host_root.clone(),
            removed_session_state: false,
            removed_terminal_hosts: false,
        };
        let root_metadata = match fs::symlink_metadata(root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(reset),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("inspect workspace state root {}", root.display()));
            }
        };
        if !root_metadata.file_type().is_dir() {
            anyhow::bail!("workspace state root is not a directory: {}", root.display());
        }
        let pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let terminal_host_root_exists = validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !session_dir_exists && !terminal_host_root_exists && pending_reset_dirs.is_empty() {
            return Ok(reset);
        }
        require_reset_confirmation(
            root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
            confirm_reset,
        )?;
        let session_guard = acquire_existing_session_guard(root, session_name)?;
        let pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let terminal_host_root_exists = validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !session_dir_exists && !terminal_host_root_exists && pending_reset_dirs.is_empty() {
            return Ok(reset);
        }
        require_reset_confirmation(
            root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
            confirm_reset,
        )?;
        if session_dir_exists {
            let db_path = session_dir.join(WORKSPACE_REGISTRY_FILE);
            if !db_path.is_file() {
                anyhow::bail!("workspace session state path has no registry");
            }
        }
        let lease = if session_dir_exists {
            platform::restrict_directory(&session_dir)?;
            Some(SessionLease::acquire(&session_dir.join("writer.lock"))?)
        } else {
            None
        };
        let mut pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let terminal_host_root_exists = validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !session_dir_exists && !terminal_host_root_exists && pending_reset_dirs.is_empty() {
            return Ok(reset);
        }
        require_reset_confirmation(
            root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
            confirm_reset,
        )?;
        let _terminal_host_reset_leases = if terminal_host_root_exists {
            prepare_terminal_host_root_for_reset(&terminal_host_root)?
        } else {
            Vec::new()
        };
        if terminal_host_root_exists {
            fs::remove_dir_all(&terminal_host_root).with_context(|| {
                format!("remove terminal host state {}", terminal_host_root.display())
            })?;
            reset.removed_terminal_hosts = true;
        }
        if session_dir_exists {
            pending_reset_dirs.push(rename_session_dir_for_reset(
                root,
                session_name,
                &session_dir,
            )?);
        }
        drop(lease);
        for reset_dir in pending_reset_dirs {
            fs::remove_dir_all(&reset_dir).with_context(|| {
                format!("remove workspace session state {}", reset_dir.display())
            })?;
            reset.removed_session_state = true;
        }
        cleanup_session_guard_after_reset(root, session_name, &session_guard);
        platform::sync_directory(root)
            .with_context(|| format!("sync workspace state root {}", root.display()))?;
        Ok(reset)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistryEvent {
    pub revision: u64,
    pub kind: String,
    pub terminal_id: String,
    pub workspace_key: String,
    pub origin: String,
    pub mutation_id: String,
    pub result: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrontendProjection {
    pub frontend: String,
    pub scope: String,
    pub subject_key: String,
    pub schema_version: u32,
    pub projection_revision: u64,
    pub projection: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProjectionCommit {
    pub projection: FrontendProjection,
    pub replayed: bool,
}

/// The sole durable writer for one session. The owning `Mux` serializes all
/// calls, and the OS lease prevents another daemon from opening the same
/// session concurrently.
pub struct WorkspaceRegistry {
    connection: Connection,
    registry_id: String,
    generation: String,
    session_name: String,
    machine_id: MachinePublicId,
    session_id: SessionPublicId,
    resource_effect_pepper: ResourceEffectPepper,
    #[cfg(test)]
    resource_patch_failures_remaining: Cell<u64>,
    _lease: Option<SessionLease>,
    _session_guard: Option<SessionLease>,
}

fn persistent_session_state_dir(root: &Path, session_name: &str) -> PathBuf {
    root.join(session_storage_component(session_name))
}

fn pending_session_reset_dirs(root: &Path, session_name: &str) -> anyhow::Result<Vec<PathBuf>> {
    let metadata = match fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("inspect workspace state root {}", root.display()));
        }
    };
    if !metadata.file_type().is_dir() {
        anyhow::bail!("workspace state root is not a directory: {}", root.display());
    }

    let storage_component = session_storage_component(session_name);
    let prefix = format!(".reset-{storage_component}-");
    let suffix = ".deleting";
    let mut reset_dirs = Vec::new();
    for entry in fs::read_dir(root)
        .with_context(|| format!("read workspace state root {}", root.display()))?
    {
        let entry = entry?;
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        if !file_name.starts_with(&prefix) || !file_name.ends_with(suffix) {
            continue;
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("inspect private reset path {}", path.display()))?;
        if !metadata.file_type().is_dir() {
            anyhow::bail!("private reset path is not a directory: {}", path.display());
        }
        reset_dirs.push(path);
    }
    reset_dirs.sort();
    Ok(reset_dirs)
}

fn validate_session_reset_dir(path: &Path) -> anyhow::Result<bool> {
    validate_reset_child_dir(path, "workspace session state path")
}

fn validate_terminal_host_reset_dir(path: &Path) -> anyhow::Result<bool> {
    validate_reset_child_dir(path, "terminal host state path")
}

fn validate_reset_child_dir(path: &Path, label: &str) -> anyhow::Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(error).with_context(|| format!("inspect {label} {}", path.display()));
        }
    };
    if !metadata.file_type().is_dir() {
        anyhow::bail!("{label} is not a directory: {}", path.display());
    }
    Ok(true)
}

fn rename_session_dir_for_reset(
    root: &Path,
    session_name: &str,
    session_dir: &Path,
) -> anyhow::Result<PathBuf> {
    let storage_component = session_storage_component(session_name);
    for _ in 0..16 {
        let candidate =
            root.join(format!(".reset-{storage_component}-{}.deleting", try_new_uuid_v4()?));
        match fs::rename(session_dir, &candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "move workspace session state {} to private reset path {}",
                        session_dir.display(),
                        candidate.display()
                    )
                });
            }
        }
    }
    anyhow::bail!(
        "could not allocate private reset path for workspace session state {}",
        session_dir.display()
    )
}

fn require_reset_confirmation(
    state_root: &Path,
    session_name: &str,
    session_dir: &Path,
    terminal_host_root: &Path,
    pending_reset_dirs: &[PathBuf],
    confirm_reset: Option<&str>,
) -> anyhow::Result<()> {
    let confirmation = reset_confirmation_token(
        state_root,
        session_name,
        session_dir,
        terminal_host_root,
        pending_reset_dirs,
    )?;
    if confirm_reset == Some(confirmation.as_str()) {
        return Ok(());
    }
    anyhow::bail!("reset confirmation is required");
}

fn reset_confirmation_token(
    state_root: &Path,
    session_name: &str,
    session_dir: &Path,
    terminal_host_root: &Path,
    pending_reset_dirs: &[PathBuf],
) -> anyhow::Result<String> {
    let mut hash = Sha256::new();
    update_reset_confirmation_part(&mut hash, "cmux-session-reset-v1");
    update_reset_confirmation_part(&mut hash, session_name);
    update_reset_confirmation_part(&mut hash, &canonical_reset_path(state_root));
    update_reset_confirmation_part(&mut hash, &canonical_reset_path(session_dir));
    update_reset_confirmation_part(&mut hash, &canonical_reset_path(terminal_host_root));
    update_reset_confirmation_part(&mut hash, &session_reset_target_fingerprint(session_dir)?);
    update_reset_confirmation_part(
        &mut hash,
        &reset_dir_fingerprint("terminal-hosts", terminal_host_root)?,
    );
    for reset_dir in pending_reset_dirs {
        update_reset_confirmation_part(&mut hash, &canonical_reset_path(reset_dir));
        update_reset_confirmation_part(&mut hash, &reset_dir_fingerprint("pending", reset_dir)?);
    }
    let digest = hash.finalize();
    Ok(digest[..12].iter().map(|byte| format!("{byte:02x}")).collect())
}

fn update_reset_confirmation_part(hash: &mut Sha256, value: &str) {
    hash.update(value.len().to_le_bytes());
    hash.update(value.as_bytes());
}

fn canonical_reset_path(path: &Path) -> String {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf()).display().to_string()
}

fn session_reset_target_fingerprint(session_dir: &Path) -> anyhow::Result<String> {
    let mut fingerprint = reset_dir_fingerprint("session", session_dir)?;
    let database_path = session_dir.join(WORKSPACE_REGISTRY_FILE);
    fingerprint.push_str(";registry_file=");
    fingerprint.push_str(&reset_path_metadata_fingerprint(&database_path)?);
    Ok(fingerprint)
}

fn reset_dir_fingerprint(label: &str, path: &Path) -> anyhow::Result<String> {
    let mut entries = Vec::new();
    collect_reset_path_fingerprints(path, Path::new("."), &mut entries)?;
    entries.sort();
    Ok(format!("{label}:{}", entries.join(",")))
}

fn collect_reset_path_fingerprints(
    path: &Path,
    relative_path: &Path,
    entries: &mut Vec<String>,
) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            entries.push(format!("{}=missing", relative_path.display()));
            return Ok(());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("inspect reset path {}", path.display()));
        }
    };
    entries.push(format!(
        "{}={}",
        relative_path.display(),
        reset_path_fingerprint(path, &metadata)?
    ));
    if !metadata.file_type().is_dir() {
        return Ok(());
    }
    let mut child_paths = Vec::new();
    for entry in
        fs::read_dir(path).with_context(|| format!("read reset path {}", path.display()))?
    {
        child_paths.push(entry?.path());
    }
    child_paths.sort();
    for child_path in child_paths {
        let child_name = child_path.file_name().ok_or_else(|| {
            anyhow::anyhow!("reset path has no file name: {}", child_path.display())
        })?;
        collect_reset_path_fingerprints(
            &child_path,
            &relative_path.join(Path::new(child_name)),
            entries,
        )?;
    }
    Ok(())
}

fn reset_path_metadata_fingerprint(path: &Path) -> anyhow::Result<String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok("missing".into()),
        Err(error) => {
            return Err(error).with_context(|| format!("inspect reset path {}", path.display()));
        }
    };
    reset_path_fingerprint(path, &metadata)
}

fn reset_path_fingerprint(path: &Path, metadata: &fs::Metadata) -> anyhow::Result<String> {
    let mut fingerprint = reset_metadata_fingerprint(metadata);
    if metadata.file_type().is_file() {
        fingerprint.push_str(";sha256=");
        fingerprint.push_str(&reset_file_content_sha256(path, metadata)?);
    }
    Ok(fingerprint)
}

fn reset_metadata_fingerprint(metadata: &fs::Metadata) -> String {
    let kind = if metadata.file_type().is_dir() {
        "dir"
    } else if metadata.file_type().is_file() {
        "file"
    } else if metadata.file_type().is_symlink() {
        "symlink"
    } else {
        "other"
    };
    format!("{kind}:{}", metadata_identity(metadata))
}

fn reset_file_content_sha256(path: &Path, expected: &fs::Metadata) -> anyhow::Result<String> {
    let mut file = open_reset_fingerprint_file(path)
        .with_context(|| format!("open reset file {}", path.display()))?;
    let opened =
        file.metadata().with_context(|| format!("inspect reset file {}", path.display()))?;
    if reset_metadata_fingerprint(&opened) != reset_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", path.display());
    }
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .with_context(|| format!("read reset file for fingerprint {}", path.display()))?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    let current = fs::symlink_metadata(path)
        .with_context(|| format!("inspect reset file {}", path.display()))?;
    if reset_metadata_fingerprint(&current) != reset_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", path.display());
    }
    Ok(hex_sha256(hash.finalize().into()))
}

#[cfg(unix)]
fn open_reset_fingerprint_file(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new().read(true).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW).open(path)
}

#[cfg(not(unix))]
fn open_reset_fingerprint_file(path: &Path) -> std::io::Result<File> {
    File::open(path)
}

#[cfg(unix)]
fn metadata_identity(metadata: &fs::Metadata) -> String {
    use std::os::unix::fs::MetadataExt;

    format!(
        "dev={},ino={},mode={},len={},mtime={}.{}",
        metadata.dev(),
        metadata.ino(),
        metadata.mode(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec()
    )
}

#[cfg(not(unix))]
fn metadata_identity(metadata: &fs::Metadata) -> String {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| format!("{}.{}", duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or_else(|| "unknown".into());
    format!(
        "readonly={},len={},modified={modified}",
        metadata.permissions().readonly(),
        metadata.len()
    )
}

impl std::fmt::Debug for WorkspaceRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkspaceRegistry")
            .field("registry_id", &self.registry_id)
            .field("generation", &self.generation)
            .field("session_name", &self.session_name)
            .finish_non_exhaustive()
    }
}

impl WorkspaceRegistry {
    pub fn in_memory(session_name: &str) -> anyhow::Result<Self> {
        let connection = Connection::open_in_memory()?;
        Self::initialize(
            connection,
            session_name.to_string(),
            MachinePublicId::random()?,
            ResourceEffectPepper::random()?,
            None,
            None,
            None,
        )
    }

    pub fn open(root: &Path, session_name: &str) -> anyhow::Result<Self> {
        let session_guard = acquire_session_guard(root, session_name)?;
        let machine_id = load_or_create_machine_id(root)?;
        let resource_effect_pepper = load_or_create_resource_effect_pepper(root)?;
        let session_dir = root.join(session_storage_component(session_name));
        fs::create_dir_all(&session_dir).with_context(|| {
            format!("create workspace state directory {}", session_dir.display())
        })?;
        platform::restrict_directory(&session_dir)?;
        let db_path = session_dir.join(WORKSPACE_REGISTRY_FILE);
        if db_path.is_file()
            && let Some(error) = preflight_unsupported_schema(&db_path)
        {
            return Err(error.into());
        }
        let lease = SessionLease::acquire(&session_dir.join("writer.lock"))?;
        let connection = Connection::open(&db_path)
            .with_context(|| format!("open workspace registry {}", db_path.display()))?;
        platform::restrict_file(&db_path)?;
        Self::initialize(
            connection,
            session_name.to_string(),
            machine_id,
            resource_effect_pepper,
            Some(session_guard),
            Some(lease),
            Some(db_path),
        )
    }

    fn initialize(
        connection: Connection,
        session_name: String,
        machine_id: MachinePublicId,
        resource_effect_pepper: ResourceEffectPepper,
        session_guard: Option<SessionLease>,
        lease: Option<SessionLease>,
        database_path: Option<PathBuf>,
    ) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA fullfsync=ON;
             PRAGMA wal_autocheckpoint=1000;
             CREATE TABLE IF NOT EXISTS meta (
               key TEXT PRIMARY KEY NOT NULL,
               value TEXT NOT NULL
             );",
        )?;

        let stored_schema = meta_value(&connection, "schema_version")?;
        let stored_schema = stored_schema
            .as_deref()
            .map(str::parse::<i64>)
            .transpose()
            .context("workspace registry schema is invalid")?;
        // Existing registries may carry the pre-multiview terminal-to-workspace
        // foreign key even when a development build already stamped the
        // current schema number. Revalidate and normalize every existing DB.
        let migrate_existing_registry = stored_schema.is_some();
        if migrate_existing_registry {
            connection.execute_batch("PRAGMA foreign_keys=OFF;")?;
        }
        let cleanup_pending =
            match meta_value(&connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)?.as_deref() {
                None => false,
                Some("1") => true,
                Some(_) => anyhow::bail!("resource receipt pepper cleanup state is invalid"),
            };
        let needs_sensitive_receipt_cleanup = cleanup_pending
            || stored_schema.is_some_and(|schema| schema < RESOURCE_EFFECT_PEPPER_SCHEMA_VERSION);
        if needs_sensitive_receipt_cleanup {
            connection.execute_batch("PRAGMA secure_delete=ON;")?;
        }
        let resource_effect_pepper_id = resource_effect_pepper.identifier();
        match stored_schema {
            Some(value) if value > SCHEMA_VERSION => {
                return Err(UnsupportedWorkspaceRegistrySchema {
                    found: value,
                    newest_supported: SCHEMA_VERSION,
                    registry_id: meta_value(&connection, "registry_id")?,
                    database_path,
                }
                .into());
            }
            Some(value) if value == SCHEMA_VERSION => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(8) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(6) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(7) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(5) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(4) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(3) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                migrate_resource_mutations_to_session_scope(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(1 | 2) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                migrate_resource_tabs_to_multiview(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(value) => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; expected 1 through {SCHEMA_VERSION}"
                );
            }
            None => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.execute("INSERT INTO meta(key, value) VALUES('revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('terminal_revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('resource_revision', '0')", [])?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('session_name', ?1)",
                    [&session_name],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('registry_id', ?1)",
                    [try_new_uuid_v4()?],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES(?1, ?2)",
                    params![RESOURCE_EFFECT_PEPPER_META_KEY, resource_effect_pepper_id],
                )?;
                ensure_session_public_id(&tx)?;
                tx.commit()?;
            }
        }
        if migrate_existing_registry && resource_tabs_has_legacy_content_uniqueness(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_resource_tabs_to_multiview(&tx)?;
            tx.commit()?;
        }
        if terminal_hosts_has_workspace_foreign_key(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_terminal_hosts_to_session_ownership(&tx)?;
            tx.commit()?;
        }
        if migrate_existing_registry {
            connection.execute_batch("PRAGMA foreign_keys=ON;")?;
            let violation = connection
                .query_row(
                    "SELECT \"table\", rowid, parent, fkid
                     FROM pragma_foreign_key_check
                     LIMIT 1",
                    [],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<i64>>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, i64>(3)?,
                        ))
                    },
                )
                .optional()?;
            if violation.is_some() {
                anyhow::bail!(
                    "saved session data could not be loaded; start a new session or restore this session from a backup"
                );
            }
        }
        if needs_sensitive_receipt_cleanup {
            checkpoint_and_truncate_wal(&connection)?;
            connection.execute_batch("VACUUM;")?;
            checkpoint_and_truncate_wal(&connection)?;
            let tx = connection.unchecked_transaction()?;
            tx.execute(
                "DELETE FROM meta WHERE key = ?1",
                [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
            )?;
            tx.commit()?;
        }
        {
            let tx = connection.unchecked_transaction()?;
            create_resource_effect_schema(&tx)?;
            recover_resource_effects(&tx)?;
            initialize_resource_input_receipt_retention(&tx)?;
            initialize_resource_mutation_retention(&tx)?;
            tx.commit()?;
        }
        let stored_name = required_meta(&connection, "session_name")?;
        if stored_name != session_name {
            anyhow::bail!(
                "workspace registry belongs to session {stored_name:?}, not {session_name:?}"
            );
        }
        let registry_id = required_meta(&connection, "registry_id")?;
        validate_identifier("registry id", &registry_id)?;
        let session_id = SessionPublicId::parse(required_meta(&connection, "session_public_id")?)?;
        let quick_check: String =
            connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if quick_check != "ok" {
            anyhow::bail!("workspace registry integrity check failed: {quick_check}");
        }
        {
            let tx = connection.unchecked_transaction()?;
            initialize_compatibility_active_workspace(&tx)?;
            validate_resource_invariants(&tx)?;
            tx.commit()?;
        }
        Ok(Self {
            connection,
            registry_id,
            generation: try_new_uuid_v4()?,
            session_name,
            machine_id,
            session_id,
            resource_effect_pepper,
            #[cfg(test)]
            resource_patch_failures_remaining: Cell::new(0),
            _session_guard: session_guard,
            _lease: lease,
        })
    }

    pub(crate) fn resource_input_receipt_hmac(
        &self,
        idempotency_key: &str,
        operation: &str,
        canonical_fields: &[u8],
    ) -> [u8; 32] {
        self.resource_effect_pepper.input_receipt_hmac(idempotency_key, operation, canonical_fields)
    }

    pub fn snapshot(&self) -> anyhow::Result<RegistrySnapshot> {
        let revision = current_revision(&self.connection)?;
        let resource_revision = current_resource_revision(&self.connection)?;
        let max_numeric_id = self.connection.query_row(
            "SELECT COALESCE(MAX(numeric_id), 0) FROM workspaces",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let next_numeric_id = u64::try_from(max_numeric_id)
            .context("stored workspace id is negative")?
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("workspace id space exhausted"))?;
        let mut statement = self.connection.prepare(
            "SELECT w.numeric_id, w.workspace_key, w.name, w.group_key, rw.public_id
             FROM workspaces w
             JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position ASC",
        )?;
        let workspaces = statement
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                Ok((id, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
            })?
            .map(|row| {
                let (id, key, name, group_key, public_id): (i64, String, String, String, String) =
                    row?;
                Ok::<RegistryWorkspace, anyhow::Error>(RegistryWorkspace {
                    id: u64::try_from(id).context("stored workspace id is negative")?,
                    public_id: WorkspacePublicId::parse(public_id)?,
                    key,
                    name,
                    group_key,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(RegistrySnapshot {
            registry_id: self.registry_id.clone(),
            generation: self.generation.clone(),
            revision,
            resource_revision,
            session_id: self.session_id.clone(),
            next_numeric_id,
            workspaces,
        })
    }

    /// Read the resource cursor without materializing the workspace graph.
    pub(crate) fn resource_revision(&self) -> anyhow::Result<u64> {
        current_resource_revision(&self.connection)
    }

    /// Internal workspaces staged by an interrupted correlated creation.
    ///
    /// These rows are intentionally absent from the public resource tables
    /// until the recovered effect can publish its complete topology in one
    /// revision. The daemon rehydrates them only during startup so terminal
    /// host adoption can finish that transaction.
    pub(crate) fn interrupted_resource_workspaces(
        &self,
    ) -> anyhow::Result<Vec<(usize, RegistryWorkspace)>> {
        let mut statement = self.connection.prepare(
            "SELECT w.position, w.numeric_id, w.workspace_key, w.name, w.group_key,
                    json_extract(
                      creation.intent_json,
                      '$.workspace_reservation.workspace_public_id'
                    )
             FROM workspaces w
             JOIN resource_creation_receipts creation
               ON json_extract(
                    creation.intent_json,
                    '$.workspace_reservation.workspace_key'
                  ) = w.workspace_key
             LEFT JOIN resource_workspaces rw
               ON rw.workspace_key = w.workspace_key AND rw.deleted_revision IS NULL
             WHERE w.tombstoned = 0
               AND rw.public_id IS NULL
               AND creation.execution_kind = 'effect'
               AND creation.state = 'executing'
             ORDER BY w.position ASC, creation.correlation_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })?
            .map(|row| {
                let (position, id, key, name, group_key, public_id) = row?;
                let public_id = public_id.with_context(|| {
                    format!("interrupted workspace {key} omitted its reserved public id")
                })?;
                Ok((
                    usize::try_from(position).context("staged workspace position is negative")?,
                    RegistryWorkspace {
                        id: u64::try_from(id).context("staged workspace id is negative")?,
                        public_id: WorkspacePublicId::parse(public_id)?,
                        key,
                        name,
                        group_key,
                    },
                ))
            })
            .collect()
    }

    pub fn registry_id(&self) -> &str {
        &self.registry_id
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn session_id(&self) -> &SessionPublicId {
        &self.session_id
    }

    pub fn machine_id(&self) -> &MachinePublicId {
        &self.machine_id
    }

    /// Returns the canonical, non-tombstoned terminal placement projection.
    /// Runtime surface ids and renderer process ids are intentionally absent.
    pub fn terminal_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        let revision = current_terminal_revision(&self.connection)?;
        let mut statement = self.connection.prepare(
            "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                    launch_spec_json, exit_json
             FROM terminal_hosts
             WHERE lifecycle != 'tombstoned'
             ORDER BY created_revision ASC, terminal_id ASC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })?;
        let terminals =
            rows.map(|row| terminal_from_stored(row?)).collect::<anyhow::Result<Vec<_>>>()?;
        Ok(TerminalRegistrySnapshot {
            registry_id: self.registry_id.clone(),
            generation: self.generation.clone(),
            revision,
            terminals,
        })
    }

    /// Includes tombstones and is intended for reconciliation and idempotent
    /// close handling, not frontend materialization.
    pub fn terminal_record(&self, terminal_id: &str) -> anyhow::Result<Option<RegistryTerminal>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        read_terminal(&self.connection, terminal_id)
    }

    pub fn replay_terminal(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<TerminalRegistryCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        terminal_replay(&self.connection, mutation, &fingerprint)
    }

    /// Commits one terminal state transition and its event in a single SQLite
    /// transaction. Callers reserve a stable id in `launching` before spawning
    /// a host, then advance it through `adopting`/`running` only after the host
    /// record is durable. A tombstoned id can never be resurrected.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_terminal(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        terminal: &RegistryTerminal,
        result: &Value,
    ) -> anyhow::Result<TerminalRegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("terminal event kind", event_kind)?;
        validate_terminal(terminal)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let launch_spec_json = canonical_json(&terminal.launch_spec)?;
        if launch_spec_json.len() > MAX_LAUNCH_SPEC_BYTES {
            anyhow::bail!("terminal launch spec exceeds {MAX_LAUNCH_SPEC_BYTES} bytes");
        }
        let exit_json = terminal.exit.as_ref().map(canonical_json).transpose()?;
        let tx = self.connection.transaction()?;

        if let Some(replay) = terminal_replay(&tx, mutation, &fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "terminal generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current_revision = transaction_terminal_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != current_revision
        {
            anyhow::bail!(
                "terminal revision conflict: expected {expected}, current {current_revision}"
            );
        }
        let existing = read_terminal(&tx, &terminal.terminal_id)?;
        if let Some(existing) = existing.as_ref()
            && existing.lifecycle == TerminalLifecycle::Exited
            && terminal.lifecycle == TerminalLifecycle::Exited
        {
            if existing.incarnation != terminal.incarnation {
                anyhow::bail!("terminal_incarnation_mismatch");
            }
            // Process exit is a latch: the first observed reason/status is
            // authoritative. Reader EOF, child wait, and reconnect failure can
            // race, but later observations neither rewrite metadata nor mint a
            // new durable revision/event.
            tx.commit()?;
            return Ok(TerminalRegistryCommit {
                revision: current_revision,
                result: result.clone(),
                replayed: true,
            });
        }
        validate_terminal_transition(existing.as_ref(), terminal)?;
        if terminal.lifecycle != TerminalLifecycle::Tombstoned
            && existing.as_ref().is_none_or(|stored| stored.workspace_key != terminal.workspace_key)
        {
            require_live_workspace(&tx, &terminal.workspace_key)?;
        }

        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        tx.execute(
            "INSERT INTO terminal_hosts(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8)
             ON CONFLICT(terminal_id) DO UPDATE SET
               workspace_key=excluded.workspace_key,
               incarnation=excluded.incarnation,
               lifecycle=excluded.lifecycle,
               launch_spec_json=excluded.launch_spec_json,
               exit_json=excluded.exit_json,
               updated_revision=excluded.updated_revision,
               deleted_revision=excluded.deleted_revision",
            params![
                terminal.terminal_id,
                terminal.workspace_key,
                terminal.incarnation,
                terminal.lifecycle.as_str(),
                launch_spec_json,
                exit_json,
                sqlite_revision,
                (terminal.lifecycle == TerminalLifecycle::Tombstoned).then_some(sqlite_revision),
            ],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO terminal_mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
        )?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                sqlite_revision,
                event_kind,
                terminal.terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
        tx.commit()?;
        Ok(TerminalRegistryCommit { revision, result: result.clone(), replayed: false })
    }

    /// Durably tombstones a terminal before the caller signals its host. This
    /// makes a repeated close safe even if the first success reply was lost.
    pub fn close_terminal(
        &mut self,
        mutation: &WorkspaceMutation,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
    ) -> anyhow::Result<TerminalRegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_terminal_identity("terminal id", terminal_id)?;
        if let Some(incarnation) = expected_incarnation {
            validate_terminal_identity("terminal incarnation", incarnation)?;
        }
        let fingerprint_value = serde_json::json!({
            "op": "close-terminal",
            "terminal_id": terminal_id,
            "incarnation": expected_incarnation,
        });
        let fingerprint = canonical_json(&fingerprint_value)?;
        let tx = self.connection.transaction()?;
        if let Some(replay) = terminal_replay(&tx, mutation, &fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "terminal generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current_revision = transaction_terminal_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != current_revision
        {
            anyhow::bail!(
                "terminal revision conflict: expected {expected}, current {current_revision}"
            );
        }
        let Some(terminal) = read_terminal(&tx, terminal_id)? else {
            anyhow::bail!("unknown terminal {terminal_id}; it may not have been adopted yet");
        };
        if let Some(expected) = expected_incarnation
            && terminal.incarnation.as_deref() != Some(expected)
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }

        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            let result = serde_json::json!({
                "terminal_id": terminal_id,
                "incarnation": terminal.incarnation,
                "closed": true,
                "already_closed": true,
            });
            let result_json = canonical_json(&result)?;
            tx.execute(
                "INSERT INTO terminal_mutations(
                   origin, mutation_id, fingerprint, result_json, committed_revision
                 ) VALUES(?1, ?2, ?3, ?4, ?5)",
                params![
                    mutation.origin,
                    mutation.id,
                    fingerprint,
                    result_json,
                    i64::try_from(current_revision)
                        .context("terminal revision exceeds SQLite integer range")?,
                ],
            )?;
            tx.commit()?;
            return Ok(TerminalRegistryCommit {
                revision: current_revision,
                result,
                replayed: false,
            });
        }

        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let result = serde_json::json!({
            "terminal_id": terminal_id,
            "incarnation": terminal.incarnation,
            "closed": true,
            "already_closed": false,
        });
        let result_json = canonical_json(&result)?;
        tx.execute(
            "UPDATE terminal_hosts
             SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
             WHERE terminal_id = ?2",
            params![sqlite_revision, terminal_id],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO terminal_mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
        )?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, 'terminal-closed', ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_revision,
                terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
        tx.commit()?;
        Ok(TerminalRegistryCommit { revision, result, replayed: false })
    }

    /// Tombstone every hosted tab in one pane/screen as one SQLite unit. All
    /// identities and incarnations are validated before the first update, and
    /// any later SQLite failure rolls the entire set back. Hosts are signaled
    /// only after this method commits successfully.
    pub fn close_terminals_atomically(
        &mut self,
        mutation: &WorkspaceMutation,
        terminals: &[(String, Option<String>)],
    ) -> anyhow::Result<TerminalBatchClose> {
        validate_terminal_batch_close(mutation, terminals)?;
        let tx = self.connection.transaction()?;
        let result = close_terminals_in_transaction(&tx, mutation, terminals, "topology-closed")?;
        tx.commit()?;
        Ok(result)
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_hosts
                 BEGIN SELECT RAISE(ABORT, 'forced terminal close failure'); END;",
            )?;
        } else {
            self.connection
                .execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_terminal_close")?;
        }
        Ok(())
    }

    pub fn terminal_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<Vec<TerminalRegistryEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             FROM terminal_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let rows = statement.query_map([sqlite_revision], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
            ))
        })?;
        rows.map(|row| {
            let (revision, kind, terminal_id, workspace_key, origin, mutation_id, result) = row?;
            Ok(TerminalRegistryEvent {
                revision: u64::try_from(revision).context("terminal event revision is negative")?,
                kind,
                terminal_id,
                workspace_key,
                origin,
                mutation_id,
                result: serde_json::from_str(&result)?,
            })
        })
        .collect()
    }

    /// Look up an already-committed mutation before resolving any live
    /// workspace selector. This is what lets a lost-response retry of a
    /// successful close return the original result after the workspace has
    /// become a tombstone.
    pub fn replay(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<RegistryCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        let stored = self
            .connection
            .query_row(
                "SELECT fingerprint, result_json, committed_revision
                 FROM mutations WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
                },
            )
            .optional()?;
        let Some((stored_fingerprint, stored_result, revision)) = stored else {
            return Ok(None);
        };
        if stored_fingerprint != fingerprint {
            anyhow::bail!(
                "mutation {} from {} was retried with a different payload",
                mutation.id,
                mutation.origin
            );
        }
        Ok(Some(RegistryCommit {
            revision: u64::try_from(revision).context("stored mutation revision is negative")?,
            result: serde_json::from_str(&stored_result)?,
            replayed: true,
        }))
    }

    /// Atomically replace the live ordered registry and record the mutation.
    /// Duplicate lookup intentionally precedes revision validation: a retry of
    /// a committed command must return its original result even after newer
    /// commands have advanced the registry.
    #[allow(clippy::too_many_arguments)]
    pub fn commit(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        let active_workspace = self
            .connection
            .query_row("SELECT value FROM meta WHERE key = 'active_workspace_id'", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
            .filter(|active| {
                workspaces.iter().any(|workspace| workspace.public_id.as_str() == active)
            })
            .map(WorkspacePublicId::parse)
            .transpose()?
            .or_else(|| {
                workspaces
                    .iter()
                    .find(|workspace| workspace.key == workspace_key)
                    .map(|workspace| workspace.public_id.clone())
            });
        self.commit_with_active_workspace(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace.as_ref(),
            result,
        )
    }

    /// Atomically replace the live ordered registry, including its selected
    /// workspace, and record the mutation plus its public resource event.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_with_active_workspace(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        self.commit_workspace_registry(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace,
            result,
            true,
        )
    }

    /// Stage a legacy workspace row inside a prepared resource effect.
    ///
    /// The outer effect must subsequently commit a full resource projection.
    /// This stage deliberately leaves the public revision and event stream
    /// untouched so one logical creation produces one public batch.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_for_resource_effect(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        self.commit_workspace_registry(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace,
            result,
            false,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_workspace_registry(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        project_resource: bool,
    ) -> anyhow::Result<RegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let previous_topology =
            project_resource.then(|| self.resource_topology_snapshot()).transpose()?;
        let tx = self.connection.transaction()?;

        if let Some((stored_fingerprint, stored_result, revision)) = tx
            .query_row(
                "SELECT fingerprint, result_json, committed_revision
                 FROM mutations WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
                },
            )
            .optional()?
        {
            if stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            return Ok(RegistryCommit {
                revision: u64::try_from(revision)
                    .context("stored mutation revision is negative")?,
                result: serde_json::from_str(&stored_result)?,
                replayed: true,
            });
        }

        validate_workspace_key(workspace_key)?;
        validate_registry(workspaces)?;
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "workspace generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        if let Some(active_workspace) = active_workspace {
            anyhow::ensure!(
                workspaces.iter().any(|workspace| &workspace.public_id == active_workspace),
                "active workspace is absent from the desired registry: {active_workspace}"
            );
        }
        let (revision, _) = commit_workspace_registry_in_transaction(
            &tx,
            mutation,
            &fingerprint,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            &result_json,
        )?;
        let previous_resource_revision =
            project_resource.then(|| transaction_resource_revision(&tx)).transpose()?;
        let resource_revision = previous_resource_revision
            .map(|revision| {
                revision
                    .checked_add(1)
                    .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))
            })
            .transpose()?;
        let sqlite_resource_revision = resource_revision
            .map(|revision| {
                i64::try_from(revision).context("resource revision exceeds SQLite integer range")
            })
            .transpose()?;
        if let (Some(previous_topology), Some(sqlite_resource_revision)) =
            (previous_topology.as_ref(), sqlite_resource_revision)
        {
            let active_screens =
                previous_topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
            let live_workspace_ids = workspaces
                .iter()
                .map(|workspace| workspace.public_id.clone())
                .collect::<HashSet<_>>();
            let mut resource_changes = workspaces
                .iter()
                .enumerate()
                .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
                    workspace: workspace.clone(),
                    position,
                    active_screen: active_screens.get(&workspace.public_id).cloned().flatten(),
                })
                .collect::<Vec<_>>();
            resource_changes.extend(
                previous_topology
                    .active_screens
                    .iter()
                    .filter(|(workspace_id, _)| !live_workspace_ids.contains(workspace_id))
                    .map(|(workspace_id, _)| ResourceChange::TombstoneWorkspace {
                        workspace_id: workspace_id.clone(),
                    }),
            );
            resource_changes.push(ResourceChange::SetWorkspaceOrder {
                workspace_ids: workspaces
                    .iter()
                    .map(|workspace| workspace.public_id.clone())
                    .collect(),
            });
            resource_changes.push(ResourceChange::SetActiveWorkspace {
                workspace_id: active_workspace.cloned(),
            });
            apply_resource_patch(
                &tx,
                &ResourcePatch { changes: resource_changes },
                sqlite_resource_revision,
            )?;
        }
        if project_resource {
            if let Some(active_workspace) = active_workspace {
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
                     ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    [active_workspace.as_str()],
                )?;
            } else {
                tx.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
            }
        }
        if let Some(resource_revision) = resource_revision {
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [resource_revision.to_string()],
            )?;
        }
        if let (
            Some(previous_topology),
            Some(previous_resource_revision),
            Some(sqlite_resource_revision),
        ) = (previous_topology.as_ref(), previous_resource_revision, sqlite_resource_revision)
        {
            tx.execute(
                "INSERT INTO resource_mutations(
                   origin, idempotency_key, operation, fingerprint, result_json, committed_revision
                 ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    mutation.origin,
                    mutation.id,
                    event_kind,
                    fingerprint,
                    result_json,
                    sqlite_resource_revision,
                ],
            )?;
            let resource_deltas = normalized_workspace_resource_deltas(
                &self.session_id,
                workspaces,
                active_workspace.map(WorkspacePublicId::as_str),
                previous_topology,
            )?;
            tx.execute(
                "INSERT INTO resource_events(
                   revision, previous_revision, origin, idempotency_key, deltas_json
                 ) VALUES(?1, ?2, ?3, ?4, ?5)",
                params![
                    sqlite_resource_revision,
                    i64::try_from(previous_resource_revision)
                        .context("resource revision exceeds SQLite integer range")?,
                    mutation.origin,
                    mutation.id,
                    canonical_json(&resource_deltas)?,
                ],
            )?;
            prune_resource_events(&tx)?;
        }
        tx.commit()?;
        Ok(RegistryCommit { revision, result: result.clone(), replayed: false })
    }

    pub fn events_after(&self, revision: u64) -> anyhow::Result<Vec<RegistryEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT revision, kind, workspace_key, origin, mutation_id, result_json
             FROM workspace_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let sqlite_revision =
            i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
        let rows = statement.query_map([sqlite_revision], |row| {
            let result: String = row.get(5)?;
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, result))
        })?;
        rows.map(|row| {
            let (revision, kind, workspace_key, origin, mutation_id, result): (
                i64,
                String,
                String,
                String,
                String,
                String,
            ) = row?;
            Ok(RegistryEvent {
                revision: u64::try_from(revision)
                    .context("workspace event revision is negative")?,
                kind,
                workspace_key,
                origin,
                mutation_id,
                result: serde_json::from_str(&result)?,
            })
        })
        .collect()
    }

    pub fn get_frontend_projection(
        &self,
        frontend: &str,
        scope: &str,
        subject_key: &str,
    ) -> anyhow::Result<Option<FrontendProjection>> {
        validate_identifier("frontend", frontend)?;
        validate_identifier("projection scope", scope)?;
        validate_identifier("projection subject", subject_key)?;
        let stored = self
            .connection
            .query_row(
                "SELECT schema_version, projection_revision, payload
                 FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
            )
            .optional()?;
        stored
            .map(|(schema_version, projection_revision, payload)| {
                Ok(FrontendProjection {
                    frontend: frontend.to_string(),
                    scope: scope.to_string(),
                    subject_key: subject_key.to_string(),
                    schema_version: u32::try_from(schema_version)
                        .context("projection schema version is invalid")?,
                    projection_revision: u64::try_from(projection_revision)
                        .context("projection revision is negative")?,
                    projection: serde_json::from_str(&payload)?,
                })
            })
            .transpose()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_frontend_projection(
        &mut self,
        mutation: &WorkspaceMutation,
        frontend: &str,
        scope: &str,
        subject_key: &str,
        schema_version: u32,
        expected_projection_revision: Option<u64>,
        projection: &Value,
    ) -> anyhow::Result<ProjectionCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("frontend", frontend)?;
        validate_identifier("projection scope", scope)?;
        validate_identifier("projection subject", subject_key)?;
        let payload = canonical_json(projection)?;
        if payload.len() > MAX_PROJECTION_BYTES {
            anyhow::bail!("frontend projection exceeds {MAX_PROJECTION_BYTES} bytes");
        }
        let fingerprint = canonical_json(&serde_json::json!({
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "schema_version": schema_version,
            "projection": projection,
        }))?;
        let tx = self.connection.transaction()?;
        if let Some((stored_fingerprint, result_json)) = tx
            .query_row(
                "SELECT fingerprint, result_json FROM projection_mutations
                 WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
        {
            if stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            let stored: FrontendProjection = serde_json::from_str(&result_json)?;
            return Ok(ProjectionCommit { projection: stored, replayed: true });
        }
        let current = tx
            .query_row(
                "SELECT projection_revision FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()
            .context("projection revision is negative")?
            .unwrap_or(0);
        if let Some(expected) = expected_projection_revision
            && expected != current
        {
            anyhow::bail!("projection revision conflict: expected {expected}, current {current}");
        }
        let projection_revision = current
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("projection revision exhausted"))?;
        tx.execute(
            "INSERT INTO frontend_projections(
               frontend, scope, subject_key, schema_version, projection_revision, payload
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(frontend, scope, subject_key) DO UPDATE SET
               schema_version=excluded.schema_version,
               projection_revision=excluded.projection_revision,
               payload=excluded.payload",
            params![
                frontend,
                scope,
                subject_key,
                i64::from(schema_version),
                i64::try_from(projection_revision)
                    .context("projection revision exceeds SQLite range")?,
                payload
            ],
        )?;
        let stored = FrontendProjection {
            frontend: frontend.to_string(),
            scope: scope.to_string(),
            subject_key: subject_key.to_string(),
            schema_version,
            projection_revision,
            projection: projection.clone(),
        };
        tx.execute(
            "INSERT INTO projection_mutations(origin, mutation_id, fingerprint, result_json)
             VALUES(?1, ?2, ?3, ?4)",
            params![
                mutation.origin,
                mutation.id,
                fingerprint,
                canonical_json(&serde_json::to_value(&stored)?)?
            ],
        )?;
        tx.commit()?;
        Ok(ProjectionCommit { projection: stored, replayed: false })
    }
}

fn require_resource_effect_pepper_id(
    transaction: &Transaction<'_>,
    expected: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [RESOURCE_EFFECT_PEPPER_META_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    anyhow::ensure!(
        stored.as_deref() == Some(expected),
        "resource receipt pepper does not match this registry"
    );
    Ok(())
}

fn migrate_resource_effect_pepper(
    transaction: &Transaction<'_>,
    identifier: &str,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
    )?;
    delete_legacy_sensitive_effect_receipts(transaction)?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![RESOURCE_EFFECT_PEPPER_META_KEY, identifier],
    )?;
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
        [SCHEMA_VERSION.to_string()],
    )?;
    Ok(())
}

fn checkpoint_and_truncate_wal(connection: &Connection) -> anyhow::Result<()> {
    let (busy, _, _): (i64, i64, i64) =
        connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?;
    anyhow::ensure!(busy == 0, "resource receipt cleanup could not truncate the SQLite WAL");
    Ok(())
}

fn create_workspace_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           numeric_id INTEGER UNIQUE NOT NULL,
           name TEXT NOT NULL,
           group_key TEXT NOT NULL,
           position INTEGER,
           tombstoned INTEGER NOT NULL DEFAULT 0 CHECK(tombstoned IN (0,1)),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_workspace_position
           ON workspaces(position) WHERE tombstoned = 0;
         CREATE TABLE IF NOT EXISTS mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS workspace_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS frontend_projections (
           frontend TEXT NOT NULL,
           scope TEXT NOT NULL,
           subject_key TEXT NOT NULL,
           schema_version INTEGER NOT NULL,
           projection_revision INTEGER NOT NULL,
           payload TEXT NOT NULL,
           PRIMARY KEY(frontend, scope, subject_key)
         );
         CREATE TABLE IF NOT EXISTS projection_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );",
    )?;
    Ok(())
}

fn create_terminal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let legacy_exists: bool = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'terminal_placements'
         )",
        [],
        |row| row.get(0),
    )?;
    let hosts_exist: bool = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'terminal_hosts'
         )",
        [],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        !(legacy_exists && hosts_exist),
        "workspace registry contains both legacy terminal placements and terminal hosts"
    );
    if legacy_exists {
        transaction.execute_batch("ALTER TABLE terminal_placements RENAME TO terminal_hosts;")?;
    }
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_hosts (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL,
           incarnation TEXT,
           lifecycle TEXT NOT NULL CHECK(
             lifecycle IN ('launching','adopting','running','exited','tombstoned')
           ),
           launch_spec_json TEXT NOT NULL,
           exit_json TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS terminal_incarnation
           ON terminal_hosts(incarnation) WHERE incarnation IS NOT NULL;
         CREATE INDEX IF NOT EXISTS live_terminals_by_workspace
           ON terminal_hosts(workspace_key, updated_revision)
           WHERE lifecycle != 'tombstoned';
         CREATE TABLE IF NOT EXISTS terminal_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS terminal_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           terminal_id TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS terminal_events_by_terminal
           ON terminal_events(terminal_id, revision);",
    )?;
    Ok(())
}

fn terminal_hosts_has_workspace_foreign_key(connection: &Connection) -> anyhow::Result<bool> {
    let mut statement = connection.prepare("PRAGMA foreign_key_list(terminal_hosts)")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let table = row.get::<_, String>(2)?;
        let from = row.get::<_, String>(3)?;
        if table == "workspaces" && from == "workspace_key" {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Remove the legacy ownership edge from terminals to workspaces. The
/// workspace key remains useful placement history, but terminal lifetime is
/// session-owned and therefore survives removal of every view.
fn migrate_terminal_hosts_to_session_ownership(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "DROP INDEX IF EXISTS terminal_incarnation;
         DROP INDEX IF EXISTS live_terminals_by_workspace;
         CREATE TABLE terminal_hosts_session_owned (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL,
           incarnation TEXT,
           lifecycle TEXT NOT NULL CHECK(
             lifecycle IN ('launching','adopting','running','exited','tombstoned')
           ),
           launch_spec_json TEXT NOT NULL,
           exit_json TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         INSERT INTO terminal_hosts_session_owned(
           terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
           exit_json, created_revision, updated_revision, deleted_revision
         )
         SELECT terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
                exit_json, created_revision, updated_revision, deleted_revision
         FROM terminal_hosts;
         DROP TABLE terminal_hosts;
         ALTER TABLE terminal_hosts_session_owned RENAME TO terminal_hosts;
         CREATE UNIQUE INDEX terminal_incarnation
           ON terminal_hosts(incarnation) WHERE incarnation IS NOT NULL;
         CREATE INDEX live_terminals_by_workspace
           ON terminal_hosts(workspace_key, updated_revision)
           WHERE lifecycle != 'tombstoned';",
    )?;
    Ok(())
}

fn ensure_session_public_id(transaction: &Transaction<'_>) -> anyhow::Result<SessionPublicId> {
    let stored = transaction
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    if let Some(stored) = stored {
        return Ok(SessionPublicId::parse(stored)?);
    }
    let session_id = SessionPublicId::random()?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES('session_public_id', ?1)",
        [session_id.as_str()],
    )?;
    Ok(session_id)
}

fn backfill_workspace_public_ids(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT workspace_key, created_revision, updated_revision, deleted_revision
             FROM workspaces
             WHERE workspace_key NOT IN (SELECT workspace_key FROM resource_workspaces)
               AND NOT EXISTS (
                 SELECT 1
                 FROM resource_creation_receipts creation
                 WHERE creation.execution_kind = 'effect'
                   AND creation.state = 'executing'
                   AND json_extract(
                         creation.intent_json,
                         '$.workspace_reservation.workspace_key'
                       ) = workspaces.workspace_key
               )
             ORDER BY created_revision ASC, workspace_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (workspace_key, created_revision, updated_revision, deleted_revision) in rows {
        let public_id = WorkspacePublicId::random()?;
        transaction.execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'workspace', ?2, ?3, ?4)",
            params![public_id.as_str(), created_revision, updated_revision, deleted_revision],
        )?;
        transaction.execute(
            "INSERT INTO resource_workspaces(
               public_id, workspace_key, active_screen_id,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, NULL, ?3, ?4, ?5)",
            params![
                public_id.as_str(),
                workspace_key,
                created_revision,
                updated_revision,
                deleted_revision
            ],
        )?;
    }
    Ok(())
}

/// Seed the shared compatibility default after legacy workspace backfill.
///
/// Frontends keep their actual focus in client-local state. The registry still
/// exposes one default for legacy commands and initial placement, and older
/// registries can have live public workspaces without that metadata. Preserve
/// any stored value so invariant validation still rejects dangling selections.
fn initialize_compatibility_active_workspace(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if meta_value(transaction, "active_workspace_id")?.is_some() {
        return Ok(());
    }
    let active_workspace = transaction
        .query_row(
            "SELECT rw.public_id
             FROM workspaces w
             JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position ASC, w.workspace_key ASC
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(active_workspace) = active_workspace {
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)",
            [active_workspace],
        )?;
    }
    Ok(())
}

fn upsert_workspace_resource(
    transaction: &Transaction<'_>,
    workspace: &RegistryWorkspace,
    revision: i64,
) -> anyhow::Result<()> {
    if transaction
        .query_row(
            "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        == Some(1)
    {
        anyhow::bail!("tombstoned workspace key cannot be reused: {}", workspace.key);
    }
    if let Some((stored_id, deleted_revision)) = transaction
        .query_row(
            "SELECT public_id, deleted_revision
             FROM resource_workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_id != workspace.public_id.as_str() {
            anyhow::bail!(
                "workspace key {} is already bound to public id {}",
                workspace.key,
                stored_id
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((stored_key, deleted_revision)) = transaction
        .query_row(
            "SELECT workspace_key, deleted_revision
             FROM resource_workspaces WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_key != workspace.key {
            anyhow::bail!(
                "workspace public id {} is already bound to key {}",
                workspace.public_id,
                stored_key
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((kind, deleted_revision)) = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if kind != "workspace" {
            anyhow::bail!("public id {} has resource kind {kind}", workspace.public_id);
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'workspace', ?2, ?2, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), revision],
    )?;
    transaction.execute(
        "INSERT INTO resource_workspaces(
           public_id, workspace_key, active_screen_id,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, NULL, ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), workspace.key, revision],
    )?;
    Ok(())
}

fn normalized_workspace_resource_deltas(
    session_id: &SessionPublicId,
    workspaces: &[RegistryWorkspace],
    active_workspace: Option<&str>,
    before: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let mut deltas = workspaces
        .iter()
        .enumerate()
        .map(|(index, workspace)| {
            Ok(serde_json::json!({
                "kind":"upsert",
                "sequence":index,
                "resource":"workspace",
                "id":workspace.public_id,
                "value":{
                    "id":workspace.public_id,
                    "session_id":session_id,
                    "name":workspace.name,
                    "index":u32::try_from(index)
                        .context("workspace index exceeds public uint32 range")?,
                    "focused":active_workspace == Some(workspace.public_id.as_str()),
                },
            }))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let live_workspaces =
        workspaces.iter().map(|workspace| workspace.public_id.clone()).collect::<HashSet<_>>();
    let removed_workspaces = before
        .active_screens
        .iter()
        .filter(|(workspace, _)| !live_workspaces.contains(workspace))
        .map(|(workspace, _)| workspace.clone())
        .collect::<Vec<_>>();
    let removed_workspace_ids = removed_workspaces.iter().cloned().collect::<HashSet<_>>();
    let removed_screens = before
        .screens
        .iter()
        .filter(|screen| removed_workspace_ids.contains(&screen.workspace_id))
        .map(|screen| screen.public_id.clone())
        .collect::<Vec<_>>();
    let removed_screen_ids = removed_screens.iter().cloned().collect::<HashSet<_>>();
    let removed_panes = before
        .panes
        .iter()
        .filter(|pane| removed_screen_ids.contains(&pane.screen_id))
        .map(|pane| pane.public_id.clone())
        .collect::<Vec<_>>();
    let removed_pane_ids = removed_panes.iter().cloned().collect::<HashSet<_>>();
    let removed_tabs = before
        .tabs
        .iter()
        .filter(|tab| removed_pane_ids.contains(&tab.pane_id))
        .collect::<Vec<_>>();
    let mut push_delete = |resource: &str, id: &str| {
        let sequence = deltas.len();
        deltas.push(serde_json::json!({
            "kind":"delete",
            "sequence":sequence,
            "resource":resource,
            "id":id,
        }));
    };
    for tab in &removed_tabs {
        match &tab.content_id {
            ContentPublicId::Terminal(id) => push_delete("terminal", id.as_str()),
            ContentPublicId::Browser(id) => push_delete("browser", id.as_str()),
        }
        push_delete("tab", tab.public_id.as_str());
    }
    for pane in &removed_panes {
        push_delete("pane", pane.as_str());
    }
    for screen in &removed_screens {
        push_delete("screen", screen.as_str());
    }
    for workspace in &removed_workspaces {
        push_delete("workspace", workspace.as_str());
    }
    Ok(Value::Array(deltas))
}

fn validate_terminal_batch_close(
    mutation: &WorkspaceMutation,
    terminals: &[(String, Option<String>)],
) -> anyhow::Result<()> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    let mut unique = HashSet::with_capacity(terminals.len());
    for (terminal_id, incarnation) in terminals {
        validate_terminal_identity("terminal id", terminal_id)?;
        if let Some(incarnation) = incarnation {
            validate_terminal_identity("terminal incarnation", incarnation)?;
        }
        anyhow::ensure!(
            unique.insert(terminal_id.as_str()),
            "duplicate terminal in batch close: {terminal_id}"
        );
    }
    Ok(())
}

fn close_terminals_in_transaction(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    terminals: &[(String, Option<String>)],
    reason: &str,
) -> anyhow::Result<TerminalBatchClose> {
    let mut rows = Vec::with_capacity(terminals.len());
    for (terminal_id, expected_incarnation) in terminals {
        let terminal = read_terminal(transaction, terminal_id)?.ok_or_else(|| {
            anyhow::anyhow!("unknown terminal {terminal_id}; it may not have been adopted yet")
        })?;
        if let Some(expected) = expected_incarnation
            && terminal.incarnation.as_deref() != Some(expected)
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }
        rows.push(terminal);
    }

    let mut revision = transaction_terminal_revision(transaction)?;
    let mut closed = 0usize;
    for terminal in rows {
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            continue;
        }
        revision = revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let result_json = canonical_json(&serde_json::json!({
            "terminal_id": terminal.terminal_id,
            "workspace_key": terminal.workspace_key,
            "incarnation": terminal.incarnation,
            "closed": true,
            "reason": reason,
        }))?;
        transaction.execute(
            "UPDATE terminal_hosts
             SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
             WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
            params![sqlite_revision, terminal.terminal_id],
        )?;
        transaction.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, 'terminal-closed', ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_revision,
                terminal.terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
        closed += 1;
    }
    if closed != 0 {
        transaction.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
    }
    Ok(TerminalBatchClose { revision, closed })
}

#[allow(clippy::too_many_arguments)]
fn commit_workspace_registry_in_transaction(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    expected_revision: Option<u64>,
    event_kind: &str,
    workspace_key: &str,
    workspaces: &[RegistryWorkspace],
    result_json: &str,
) -> anyhow::Result<(u64, TerminalBatchClose)> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    validate_workspace_key(workspace_key)?;
    validate_registry(workspaces)?;
    let current = transaction_revision(transaction)?;
    if let Some(expected) = expected_revision
        && expected != current
    {
        anyhow::bail!("workspace revision conflict: expected {expected}, current {current}");
    }
    let revision =
        current.checked_add(1).ok_or_else(|| anyhow::anyhow!("workspace revision exhausted"))?;
    let sqlite_revision =
        i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
    for workspace in workspaces {
        let was_tombstoned = transaction
            .query_row(
                "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
                [&workspace.key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        anyhow::ensure!(
            was_tombstoned != Some(1),
            "tombstoned workspace key cannot be reused: {}",
            workspace.key
        );
    }

    // Terminals are session-owned. Their workspace_key records their latest
    // canonical placement but is intentionally allowed to outlive that
    // workspace, so closing a workspace removes views without terminating the
    // underlying terminal.
    let terminal_batch =
        TerminalBatchClose { revision: transaction_terminal_revision(transaction)?, closed: 0 };
    transaction.execute(
        "UPDATE workspaces SET tombstoned = 1, position = NULL,
         updated_revision = ?1, deleted_revision = ?1
         WHERE tombstoned = 0",
        [sqlite_revision],
    )?;
    // Tombstone first to release the partial unique position index, then
    // upsert the complete desired order in this same transaction.
    for (position, workspace) in workspaces.iter().enumerate() {
        transaction.execute(
            "INSERT INTO workspaces(
               workspace_key, numeric_id, name, group_key, position, tombstoned,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL)
             ON CONFLICT(workspace_key) DO UPDATE SET
               numeric_id=excluded.numeric_id,
               name=excluded.name,
               group_key=excluded.group_key,
               position=excluded.position,
               tombstoned=0,
               updated_revision=excluded.updated_revision,
               deleted_revision=NULL",
            params![
                workspace.key,
                i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
                workspace.name,
                workspace.group_key,
                i64::try_from(position).context("workspace position exceeds SQLite range")?,
                sqlite_revision
            ],
        )?;
    }
    transaction
        .execute("UPDATE meta SET value = ?1 WHERE key = 'revision'", [revision.to_string()])?;
    transaction.execute(
        "INSERT INTO mutations(
           origin, mutation_id, fingerprint, result_json, committed_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5)",
        params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
    )?;
    transaction.execute(
        "INSERT INTO workspace_events(
           revision, kind, workspace_key, origin, mutation_id, result_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            sqlite_revision,
            event_kind,
            workspace_key,
            mutation.origin,
            mutation.id,
            result_json
        ],
    )?;
    Ok((revision, terminal_batch))
}

fn validate_registry(workspaces: &[RegistryWorkspace]) -> anyhow::Result<()> {
    let mut keys = HashSet::new();
    let mut public_ids = HashSet::new();
    for workspace in workspaces {
        validate_workspace_key(&workspace.key)?;
        validate_identifier("workspace group key", &workspace.group_key)?;
        if workspace.id == 0 {
            anyhow::bail!("workspace id cannot be zero");
        }
        if !keys.insert(&workspace.key) {
            anyhow::bail!("workspace key already exists: {}", workspace.key);
        }
        if !public_ids.insert(workspace.public_id.as_str()) {
            anyhow::bail!("workspace public id already exists: {}", workspace.public_id);
        }
    }
    Ok(())
}

fn validate_terminal(terminal: &RegistryTerminal) -> anyhow::Result<()> {
    validate_terminal_identity("terminal id", &terminal.terminal_id)?;
    validate_workspace_key(&terminal.workspace_key)?;
    if let Some(incarnation) = &terminal.incarnation {
        validate_terminal_identity("terminal incarnation", incarnation)?;
    }
    match terminal.lifecycle {
        TerminalLifecycle::Launching if terminal.incarnation.is_some() => {
            anyhow::bail!("launching terminal cannot have an incarnation before host adoption");
        }
        TerminalLifecycle::Adopting | TerminalLifecycle::Running
            if terminal.incarnation.is_none() =>
        {
            anyhow::bail!("{:?} terminal requires a host incarnation", terminal.lifecycle);
        }
        _ => {}
    }
    if terminal.lifecycle != TerminalLifecycle::Exited && terminal.exit.is_some() {
        anyhow::bail!("only an exited terminal can carry exit metadata");
    }
    Ok(())
}

fn validate_terminal_identity(label: &str, value: &str) -> anyhow::Result<()> {
    if value.len() != 32
        || !value.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        || value.as_bytes()[12] != b'4'
        || !matches!(value.as_bytes()[16], b'8'..=b'b')
    {
        anyhow::bail!("{label} must be a 32-character lowercase UUIDv4 hex value");
    }
    Ok(())
}

fn validate_terminal_transition(
    existing: Option<&RegistryTerminal>,
    desired: &RegistryTerminal,
) -> anyhow::Result<()> {
    let Some(existing) = existing else {
        if desired.lifecycle != TerminalLifecycle::Launching {
            anyhow::bail!("new terminal must be reserved in launching state before host spawn");
        }
        return Ok(());
    };
    if existing.lifecycle == TerminalLifecycle::Tombstoned {
        anyhow::bail!("tombstoned terminal id cannot be reused: {}", desired.terminal_id);
    }
    let allowed = matches!(
        (existing.lifecycle, desired.lifecycle),
        (TerminalLifecycle::Launching, TerminalLifecycle::Launching)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Running)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Running)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Running, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Running, TerminalLifecycle::Running)
            | (TerminalLifecycle::Running, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Running, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Exited, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Exited, TerminalLifecycle::Tombstoned)
    );
    if !allowed {
        anyhow::bail!(
            "invalid terminal transition {:?} -> {:?}",
            existing.lifecycle,
            desired.lifecycle
        );
    }
    if matches!(existing.lifecycle, TerminalLifecycle::Adopting | TerminalLifecycle::Running)
        && matches!(desired.lifecycle, TerminalLifecycle::Adopting | TerminalLifecycle::Running)
        && existing.incarnation != desired.incarnation
    {
        anyhow::bail!("live terminal incarnation cannot change without an exit transition");
    }
    if existing.lifecycle != TerminalLifecycle::Exited
        && existing.launch_spec != desired.launch_spec
    {
        anyhow::bail!("terminal launch spec cannot change during a live incarnation");
    }
    Ok(())
}

fn require_live_workspace(connection: &Connection, workspace_key: &str) -> anyhow::Result<()> {
    let live = connection
        .query_row(
            "SELECT 1 FROM workspaces WHERE workspace_key = ?1 AND tombstoned = 0",
            [workspace_key],
            |_| Ok(()),
        )
        .optional()?;
    if live.is_none() {
        anyhow::bail!("terminal workspace is missing or closed: {workspace_key}");
    }
    Ok(())
}

type StoredTerminal = (String, String, Option<String>, String, String, Option<String>);

fn terminal_from_stored(stored: StoredTerminal) -> anyhow::Result<RegistryTerminal> {
    let (terminal_id, workspace_key, incarnation, lifecycle, launch_spec, exit) = stored;
    Ok(RegistryTerminal {
        terminal_id,
        workspace_key,
        incarnation,
        lifecycle: TerminalLifecycle::parse(&lifecycle)?,
        launch_spec: serde_json::from_str(&launch_spec)?,
        exit: exit.map(|value| serde_json::from_str(&value)).transpose()?,
    })
}

fn read_terminal(
    connection: &Connection,
    terminal_id: &str,
) -> anyhow::Result<Option<RegistryTerminal>> {
    let stored = connection
        .query_row(
            "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                    launch_spec_json, exit_json
             FROM terminal_hosts WHERE terminal_id = ?1",
            [terminal_id],
            |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
            },
        )
        .optional()?;
    stored.map(terminal_from_stored).transpose()
}

fn terminal_replay(
    connection: &Connection,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
) -> anyhow::Result<Option<TerminalRegistryCommit>> {
    let stored = connection
        .query_row(
            "SELECT fingerprint, result_json, committed_revision
             FROM terminal_mutations WHERE origin = ?1 AND mutation_id = ?2",
            params![mutation.origin, mutation.id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    let Some((stored_fingerprint, stored_result, revision)) = stored else {
        return Ok(None);
    };
    if stored_fingerprint != fingerprint {
        anyhow::bail!(
            "terminal mutation {} from {} was retried with a different payload",
            mutation.id,
            mutation.origin
        );
    }
    Ok(Some(TerminalRegistryCommit {
        revision: u64::try_from(revision).context("stored terminal revision is negative")?,
        result: serde_json::from_str(&stored_result)?,
        replayed: true,
    }))
}

fn validate_identifier(label: &str, value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        anyhow::bail!("{label} cannot be empty");
    }
    if value.len() > MAX_ID_LEN {
        anyhow::bail!("{label} exceeds {MAX_ID_LEN} bytes");
    }
    if value.chars().any(char::is_control) {
        anyhow::bail!("{label} contains a control character");
    }
    Ok(())
}

fn validate_workspace_key(value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        anyhow::bail!("workspace key cannot be empty");
    }
    if value.len() > MAX_WORKSPACE_KEY_LEN {
        anyhow::bail!("workspace key exceeds {MAX_WORKSPACE_KEY_LEN} bytes");
    }
    if value.chars().any(char::is_control) {
        anyhow::bail!("workspace key contains a control character");
    }
    Ok(())
}

fn canonical_json(value: &Value) -> anyhow::Result<String> {
    fn write(value: &Value, output: &mut String) -> anyhow::Result<()> {
        match value {
            Value::Object(map) => {
                output.push('{');
                let mut entries = map.iter().collect::<Vec<_>>();
                entries.sort_by_key(|(key, _)| *key);
                for (index, (key, value)) in entries.into_iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    output.push_str(&serde_json::to_string(key)?);
                    output.push(':');
                    write(value, output)?;
                }
                output.push('}');
            }
            Value::Array(values) => {
                output.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    write(value, output)?;
                }
                output.push(']');
            }
            primitive => output.push_str(&serde_json::to_string(primitive)?),
        }
        Ok(())
    }
    let mut output = String::new();
    write(value, &mut output)?;
    Ok(output)
}

fn preflight_unsupported_schema(
    database_path: &Path,
) -> Option<UnsupportedWorkspaceRegistrySchema> {
    // This probe only improves a writer-conflict error. Initialization remains
    // authoritative, so read-only I/O and SQL failures must not block startup.
    try_preflight_unsupported_schema(database_path).ok().flatten()
}

fn try_preflight_unsupported_schema(
    database_path: &Path,
) -> anyhow::Result<Option<UnsupportedWorkspaceRegistrySchema>> {
    let connection = Connection::open_with_flags(database_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection.busy_timeout(std::time::Duration::from_millis(500))?;
    let has_meta: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |row| row.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let Some(found) = meta_value(&connection, "schema_version")? else {
        return Ok(None);
    };
    let found = found.parse::<i64>().context("workspace registry schema is invalid")?;
    if found <= SCHEMA_VERSION {
        return Ok(None);
    }
    Ok(Some(UnsupportedWorkspaceRegistrySchema {
        found,
        newest_supported: SCHEMA_VERSION,
        database_path: Some(database_path.to_path_buf()),
        registry_id: meta_value(&connection, "registry_id")?,
    }))
}

fn meta_value(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

fn required_meta(connection: &Connection, key: &str) -> anyhow::Result<String> {
    meta_value(connection, key)?
        .ok_or_else(|| anyhow::anyhow!("workspace registry is missing {key}"))
}

fn current_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "revision")?.parse().context("workspace registry revision is invalid")
}

fn transaction_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String =
        transaction
            .query_row("SELECT value FROM meta WHERE key = 'revision'", [], |row| row.get(0))?;
    value.parse().context("workspace registry revision is invalid")
}

fn current_terminal_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "terminal_revision")?
        .parse()
        .context("terminal registry revision is invalid")
}

fn current_resource_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "resource_revision")?.parse().context("resource revision is invalid")
}

fn transaction_resource_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'resource_revision'",
        [],
        |row| row.get(0),
    )?;
    value.parse().context("resource revision is invalid")
}

fn transaction_terminal_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'terminal_revision'",
        [],
        |row| row.get(0),
    )?;
    value.parse().context("terminal registry revision is invalid")
}

const MACHINE_ID_FILE: &str = "machine-id";
const MACHINE_ID_LOCK_FILE: &str = "machine-id.lock";
const SESSION_GUARD_DIR: &str = "session-locks";
const SESSION_GUARD_COORDINATOR_FILE: &str = ".coordinator.lock";
const SESSION_GUARD_COORDINATOR_TIMEOUT: std::time::Duration =
    std::time::Duration::from_millis(250);
const SESSION_GUARD_COORDINATOR_RETRY: std::time::Duration = std::time::Duration::from_millis(5);

fn acquire_session_guard(root: &Path, session_name: &str) -> anyhow::Result<SessionLease> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    acquire_existing_session_guard(root, session_name)
}

fn acquire_existing_session_guard(root: &Path, session_name: &str) -> anyhow::Result<SessionLease> {
    platform::restrict_directory(root)?;
    let lock_dir = prepare_session_guard_dir(root)?;
    let _coordinator =
        SessionLease::acquire_coordinator(&session_guard_coordinator_path(&lock_dir))
            .with_context(|| format!("coordinate session lock directory {}", lock_dir.display()))?;
    let lock_path = session_guard_lock_path(&lock_dir, session_name);
    SessionLease::acquire(&lock_path)
}

fn prepare_session_guard_dir(root: &Path) -> anyhow::Result<PathBuf> {
    let lock_dir = root.join(SESSION_GUARD_DIR);
    match fs::symlink_metadata(&lock_dir) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => anyhow::bail!("session lock directory is not a directory: {}", lock_dir.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match fs::create_dir(&lock_dir) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let metadata = fs::symlink_metadata(&lock_dir)?;
                    if !metadata.file_type().is_dir() {
                        anyhow::bail!(
                            "session lock directory is not a directory: {}",
                            lock_dir.display()
                        );
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(error) => return Err(error.into()),
    }
    platform::restrict_directory(&lock_dir)?;
    Ok(lock_dir)
}

fn session_guard_lock_path(lock_dir: &Path, session_name: &str) -> PathBuf {
    lock_dir.join(format!("{}.lock", session_storage_component(session_name)))
}

fn session_guard_coordinator_path(lock_dir: &Path) -> PathBuf {
    lock_dir.join(SESSION_GUARD_COORDINATOR_FILE)
}

fn cleanup_session_guard_after_reset(
    root: &Path,
    session_name: &str,
    session_guard: &SessionLease,
) {
    let lock_dir = root.join(SESSION_GUARD_DIR);
    let expected = session_guard_lock_path(&lock_dir, session_name);
    if session_guard.path != expected {
        return;
    }
    let Ok(_coordinator) =
        SessionLease::acquire_coordinator(&session_guard_coordinator_path(&lock_dir))
    else {
        return;
    };
    match fs::remove_file(&expected) {
        Ok(()) => {
            let _ = platform::sync_directory(&lock_dir);
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => {}
    }
}

#[cfg(unix)]
fn prepare_terminal_host_root_for_reset(
    root: &Path,
) -> anyhow::Result<Vec<TerminalHostLiveMarkerLease>> {
    use std::os::unix::fs::MetadataExt;

    let records = crate::terminal_host_runtime::load_terminal_host_records(root)?;
    let expected_uid = fs::metadata(root)?.uid();
    let mut live_marker_leases = Vec::new();
    let expected_live_markers = records
        .iter()
        .map(|(record_path, record)| terminal_host_live_marker_path(record_path, record))
        .collect::<HashSet<_>>();
    for entry in fs::read_dir(root)
        .with_context(|| format!("read terminal host state {}", root.display()))?
    {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("live")
            && !expected_live_markers.contains(&path)
        {
            let Some(lease) = lock_verified_dead_live_marker(&path, expected_uid, false)? else {
                anyhow::bail!("terminal host state still has live or unverified hosts");
            };
            live_marker_leases.push(lease);
        }
    }
    for (record_path, record) in &records {
        match crate::terminal_host_runtime::terminal_host_record_liveness(&record_path, &record)? {
            TerminalHostLiveness::Dead => {
                if record.record_version >= 2 {
                    let marker = terminal_host_live_marker_path(record_path, record);
                    let Some(lease) = lock_verified_dead_live_marker(&marker, expected_uid, true)?
                    else {
                        anyhow::bail!("terminal host state still has live or unverified hosts");
                    };
                    live_marker_leases.push(lease);
                }
            }
            TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {
                anyhow::bail!("terminal host state still has live or unverified hosts");
            }
        }
    }
    Ok(live_marker_leases)
}

#[cfg(unix)]
fn terminal_host_live_marker_path(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> PathBuf {
    record_path.with_extension(format!("{}-{}.live", record.incarnation, record.host_start_nonce))
}

#[cfg(unix)]
struct TerminalHostLiveMarkerLease {
    _file: File,
}

#[cfg(unix)]
fn lock_verified_dead_live_marker(
    path: &Path,
    expected_uid: u32,
    create_if_missing: bool,
) -> anyhow::Result<Option<TerminalHostLiveMarkerLease>> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && !create_if_missing => {
            return Ok(None);
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                .open(path)
            {
                Ok(file) => file,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    return lock_verified_dead_live_marker(path, expected_uid, false);
                }
                Err(_) => return Ok(None),
            }
        }
        Err(_) => return Ok(None),
    };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.uid() != expected_uid
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
    {
        return Ok(None);
    }
    loop {
        // SAFETY: flock only observes/changes the advisory lock on this valid file descriptor.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            let current = match fs::symlink_metadata(path) {
                Ok(current) => current,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => return Err(error.into()),
            };
            if current.dev() != metadata.dev() || current.ino() != metadata.ino() {
                return Ok(None);
            }
            return Ok(Some(TerminalHostLiveMarkerLease { _file: file }));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Ok(None);
    }
}

#[cfg(not(unix))]
struct OrphanLiveMarkerLease;

#[cfg(not(unix))]
fn prepare_terminal_host_root_for_reset(
    _root: &Path,
) -> anyhow::Result<Vec<OrphanLiveMarkerLease>> {
    anyhow::bail!("terminal host liveness cannot be verified on this platform");
}

fn load_or_create_resource_effect_pepper(root: &Path) -> anyhow::Result<ResourceEffectPepper> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(root)?;
    let lock_path = root.join(RESOURCE_EFFECT_PEPPER_LOCK_FILE);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open resource receipt pepper lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::lock(&lock)
        .with_context(|| format!("lock resource receipt pepper {}", lock_path.display()))?;

    let path = root.join(RESOURCE_EFFECT_PEPPER_FILE);
    let result = match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            anyhow::ensure!(
                metadata.file_type().is_file(),
                "resource receipt pepper is corrupt: {}",
                path.display()
            );
            platform::restrict_file(&path)?;
            let bytes = fs::read(&path)
                .with_context(|| format!("read resource receipt pepper {}", path.display()))?;
            ResourceEffectPepper::from_bytes(bytes, &path)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ensure_missing_pepper_can_migrate(root, &path)?;
            let pepper = ResourceEffectPepper::random()?;
            let mut options = OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&path)
                .with_context(|| format!("create resource receipt pepper {}", path.display()))?;
            platform::restrict_file(&path)?;
            file.write_all(pepper.0.as_ref())
                .with_context(|| format!("write resource receipt pepper {}", path.display()))?;
            file.sync_all()
                .with_context(|| format!("sync resource receipt pepper {}", path.display()))?;
            File::open(root)
                .and_then(|directory| directory.sync_all())
                .with_context(|| format!("sync state root {}", root.display()))?;
            Ok(pepper)
        }
        Err(error) => {
            Err(error).with_context(|| format!("read resource receipt pepper {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

fn ensure_missing_pepper_can_migrate(root: &Path, pepper_path: &Path) -> anyhow::Result<()> {
    for entry in
        fs::read_dir(root).with_context(|| format!("read state root {}", root.display()))?
    {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let database = entry.path().join(WORKSPACE_REGISTRY_FILE);
        if !database.try_exists()? {
            continue;
        }
        let connection = Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .with_context(|| {
            format!("inspect registry before recreating missing pepper {}", database.display())
        })?;
        let schema = meta_value(&connection, "schema_version")?
            .ok_or_else(|| anyhow::anyhow!("registry schema is missing: {}", database.display()))?;
        let schema: i64 = schema
            .parse()
            .with_context(|| format!("registry schema is invalid: {}", database.display()))?;
        anyhow::ensure!(
            schema < SCHEMA_VERSION,
            "resource receipt pepper is missing for an existing registry: {}",
            pepper_path.display()
        );
    }
    Ok(())
}

fn load_or_create_machine_id(root: &Path) -> anyhow::Result<MachinePublicId> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(root)?;
    let lock_path = root.join(MACHINE_ID_LOCK_FILE);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open machine identity lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::lock(&lock)
        .with_context(|| format!("lock machine identity {}", lock_path.display()))?;

    let path = root.join(MACHINE_ID_FILE);
    let result = match fs::read(&path) {
        Ok(bytes) => {
            platform::restrict_file(&path)?;
            parse_machine_id_file(&path, &bytes)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let id = MachinePublicId::random()?;
            let mut options = OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&path)
                .with_context(|| format!("create machine identity {}", path.display()))?;
            platform::restrict_file(&path)?;
            file.write_all(id.as_str().as_bytes())
                .and_then(|()| file.write_all(b"\n"))
                .with_context(|| format!("write machine identity {}", path.display()))?;
            file.sync_all().with_context(|| format!("sync machine identity {}", path.display()))?;
            File::open(root)
                .and_then(|directory| directory.sync_all())
                .with_context(|| format!("sync state root {}", root.display()))?;
            Ok(id)
        }
        Err(error) => {
            Err(error).with_context(|| format!("read machine identity {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

fn parse_machine_id_file(path: &Path, bytes: &[u8]) -> anyhow::Result<MachinePublicId> {
    let content = std::str::from_utf8(bytes)
        .with_context(|| format!("machine identity is not UTF-8: {}", path.display()))?;
    let value = content.strip_suffix('\n').unwrap_or(content);
    anyhow::ensure!(
        !value.is_empty()
            && !value.contains('\n')
            && !value.contains('\r')
            && value.trim() == value,
        "machine identity file is corrupt: {}",
        path.display()
    );
    MachinePublicId::parse(value)
        .with_context(|| format!("machine identity file is corrupt: {}", path.display()))
}

fn session_storage_component(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf29ce484222325u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
        if readable.len() < 48 && (byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')) {
            readable.push(char::from(byte));
        } else if readable.len() < 48 {
            readable.push('_');
        }
    }
    if readable.is_empty() {
        readable.push_str("session");
    }
    format!("{readable}-{hash:016x}")
}

pub(crate) fn new_uuid_v4() -> String {
    try_new_uuid_v4().expect("operating system randomness unavailable")
}

pub(crate) fn try_new_uuid_v4() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| crate::resource::ResourceError::allocation("uuid"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    ))
}

pub(crate) fn is_canonical_workspace_key(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                matches!(*byte, b'0'..=b'9' | b'a'..=b'f')
            }
        })
}

struct SessionLease {
    file: File,
    path: PathBuf,
}

impl SessionLease {
    fn acquire(path: &Path) -> anyhow::Result<Self> {
        let file = open_session_lock_file(path)?;
        restrict_session_lock_file(path, &file)?;
        validate_session_lock_file(path, &file)?;
        FileExt::try_lock(&file).with_context(|| {
            format!("workspace session is already owned by another daemon: {}", path.display())
        })?;
        Ok(Self { file, path: path.to_path_buf() })
    }

    fn acquire_coordinator(path: &Path) -> anyhow::Result<Self> {
        let file = open_session_lock_file(path)?;
        restrict_session_lock_file(path, &file)?;
        validate_session_lock_file(path, &file)?;
        let deadline = std::time::Instant::now() + SESSION_GUARD_COORDINATOR_TIMEOUT;
        loop {
            match FileExt::try_lock(&file) {
                Ok(()) => break,
                Err(fs4::TryLockError::WouldBlock) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(SESSION_GUARD_COORDINATOR_RETRY);
                }
                Err(fs4::TryLockError::WouldBlock) => {
                    return Err(std::io::Error::from(std::io::ErrorKind::WouldBlock)).with_context(
                        || format!("workspace session coordinator is busy: {}", path.display()),
                    );
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("lock workspace session coordinator: {}", path.display())
                    });
                }
            }
        }
        Ok(Self { file, path: path.to_path_buf() })
    }
}

fn open_session_lock_file(path: &Path) -> anyhow::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    validate_session_lock_file(path, &file)?;
    Ok(file)
}

fn validate_session_lock_file(path: &Path, file: &File) -> anyhow::Result<()> {
    let path_metadata = fs::symlink_metadata(path)?;
    if !path_metadata.file_type().is_file() {
        anyhow::bail!("session lock path is not a file: {}", path.display());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let file_metadata = file.metadata()?;
        if path_metadata.dev() != file_metadata.dev() || path_metadata.ino() != file_metadata.ino()
        {
            anyhow::bail!("session lock path changed while opening: {}", path.display());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn restrict_session_lock_file(_path: &Path, file: &File) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict_session_lock_file(path: &Path, _file: &File) -> anyhow::Result<()> {
    platform::restrict_file(path)?;
    Ok(())
}

impl Drop for SessionLease {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.file);
        let _ = &self.path;
    }
}

#[cfg(test)]
mod tests;
