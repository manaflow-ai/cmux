//! Durable, single-writer workspace registry.
//!
//! The mux owns one of these behind its workspace-commit mutex. A registry transaction
//! commits before the corresponding in-memory projection and event are published, so durable,
//! reply and event order are the same. Runtime pane/surface ids never enter this store.

mod open;
mod schema;
mod session_guard;
mod session_reset;

#[cfg(any(windows, test))]
pub(crate) use session_guard::session_guard_component;
#[cfg(unix)]
pub(crate) use session_guard::session_guard_components;
#[cfg(all(windows, test))]
use session_guard::session_guard_coordinator_waiter_dir;
#[cfg(test)]
pub(crate) use session_guard::start_session_guard_for_test;
use session_guard::{
    SESSION_GUARD_DIR, acquire_existing_session_guard, acquire_existing_session_reset_guard,
    acquire_session_guard, open_session_lock_file, session_guard_lock_path,
    validate_session_lock_file,
};
#[cfg(test)]
use session_guard::{
    SessionCoordinatorWaiter, prepare_session_guard_dir, session_guard_coordinator_path,
};
pub(crate) use session_guard::{
    SessionLease, SessionOwnerPeek, SessionOwnerProbe, peek_session_owner, probe_session_owner,
    session_owner_last_active, session_owner_mark, stored_terminal_references,
};

pub(crate) use schema::{AutoVacuumMigration, first_state_foreign_key_violation};
use schema::{
    backfill_workspace_public_ids, check_registry_integrity, checkpoint_and_truncate_wal,
    create_terminal_schema, create_workspace_schema, ensure_session_public_id,
    initialize_compatibility_active_workspace, mark_journal_auto_vacuum_migrated,
    migrate_journal_auto_vacuum, migrate_resource_agent_hook_state_add_ended_at,
    migrate_resource_effect_pepper, migrate_terminal_hosts_add_on_exit,
    migrate_terminal_hosts_to_session_ownership, normalize_journal_multiview_schema,
    normalized_workspace_resource_deltas, require_resource_effect_pepper_id,
    resource_agent_hook_state_has_ended_at_column, terminal_hosts_has_on_exit_column,
    terminal_hosts_has_workspace_foreign_key, upsert_workspace_resource,
    vacuum_with_file_temp_store, workspace_upsert_delta,
};
mod terminal_snapshot_read;
use session_reset::*;
// For the rollback's check (`store_schemas`): the exact name of the folder
// that a reset left.
mod reset_dir_name;
pub(crate) use reset_dir_name::is_pending_reset_dir_name;

pub(crate) use open::{
    open_registry_database, open_registry_database_read_only, open_registry_database_with_flags,
    truncate_wal_after_delete,
};
use std::borrow::Cow;
#[cfg(test)]
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
pub(crate) use terminal_snapshot_read::{SessionRows, read_session_rows};

use anyhow::Context;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::platform;
use crate::resource::{
    BrowserPublicId, ContentPublicId, FrontendProjectionPublicId, MachinePublicId, PanePublicId,
    ScreenPublicId, SessionPublicId, SplitPublicId, TabPublicId, TerminalPublicId,
    WorkspacePublicId,
};
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostLiveness;
pub use open_guard::RegistryQuarantined;
use open_guard::preflight_unsupported_schema;

pub(crate) mod agent_cli_intents;
mod compact;
mod detached_terminals;
pub(crate) use detached_terminals::DETACHED_TERMINAL_WORKSPACE_KEY;
use detached_terminals::require_live_workspace;
mod effect_store;
pub(crate) mod feed_local_store;
pub use compact::{RegistryCompactError, RegistryCompaction, compact_registry};
mod browser_profile_proxy;
pub(crate) mod history_check;
mod idle_policy_store;
mod journal_extensions;
mod mutation_ledger;
pub(crate) mod mutation_ledger_retention;
mod open_guard;
pub(crate) mod output_cleanup;
pub(crate) mod personal_bookmarks;
mod personal_browser_profiles;
pub(crate) mod personal_mutations;
mod personal_session_icon;
pub(crate) mod personal_store;
pub(crate) mod premigrate;
mod projection_size;
use projection_size::{
    MAX_PROJECTION_BYTES, MAX_RESOURCE_API_PROJECTION_BYTES, note_projection_size,
};
mod host_identity;
pub(crate) use host_identity::StoredIds;
mod identity_load;
mod personal_terminals;
pub(crate) mod presentation_store;
mod public_fold;
pub(crate) use public_fold::volatile_fields;
mod public_projection_store;
mod receipt_env;
pub(crate) mod registry_connection;
mod root_identity;
use identity_load::{load_or_create_machine_id, load_or_create_resource_effect_pepper};
pub(crate) mod segment_codec;
pub(crate) mod terminal_end_prefetch;
pub(crate) mod wal_durability;
pub(crate) use registry_connection::RegistryConnection;
mod registry_intent;
pub(crate) use registry_intent::{OwnedTransactionWrite, RegistryIntent, RegistryReceipt};
mod terminal_commit_intent;
pub(crate) use terminal_commit_intent::TerminalCommitIntent;
mod workspace_commit_intent;
mod workspace_rows_commit;
use workspace_rows_commit::{
    commit_workspace_registry_in_transaction, commit_workspace_rows_in_transaction,
    insert_workspace_row_in_transaction,
};
pub(crate) mod workspace_name_store;
pub(crate) use workspace_commit_intent::{
    WorkspaceCommitIntent, WorkspaceCommitReceipt, WorkspaceInsert,
};
pub(crate) mod relaunch_store;
mod resource_effect_commit;
pub(crate) mod resource_store;
pub(crate) mod screen_store;
pub(crate) mod session_journal;
pub mod synth;
pub(crate) mod terminal_archive_store;
mod terminal_exit_store;
mod terminal_keep_store;
mod terminal_resource_close_store;
pub(crate) mod terminal_state_end;
pub use terminal_state_end::EndedTerminalState;
pub(crate) mod terminal_respawn_store;
pub(crate) mod terminal_resume_store;
mod terminal_unplaced_store;
mod topology_close_store;

pub use crate::state::kept_tab_store::KeptTabRecord;
pub use crate::state::tab_state_store::TabAttentionRecord;
pub(crate) use effect_store::{
    EffectCommitFinish, EffectCommitIntent, EffectCommitReceipt, ResourceWorkspaceClose,
};
pub use effect_store::{
    ResourceCreationPreparation, ResourceCreationRecovery, ResourceEffectOutcome,
    ResourceEffectPreparation,
};
use effect_store::{
    create_resource_effect_schema, delete_legacy_sensitive_effect_receipts,
    initialize_resource_input_receipt_retention, recover_resource_effects,
};
pub(crate) use journal_extensions::JOURNAL_CHECKPOINTS_KEPT;
use journal_extensions::create_journal_extensions_schema;
pub use journal_extensions::{
    JournalAppendCommit, JournalCheckpoint, JournalContentRef, JournalEventSchema,
    JournalHookDeliveryPolicy, JournalHookExec, JournalHookFilter, JournalHookManifest,
    JournalHookRegex, JournalHookRetry, JournalIngress, JournalProducerManifest, JournalSegment,
};
pub(crate) use journal_extensions::{
    JournalCheckpointCommit, JournalCheckpointSummary, JournalContentBlob, JournalHookAttempt,
    JournalHookDelivery, JournalHookDeliveryResult, JournalHookScan, JournalHookState,
    JournalSegmentSealCommit, JournalSegmentSealStart,
};
pub(crate) use mutation_ledger::insert_resource_mutation;
pub use mutation_ledger::{Actor, WorkspaceMutation};
pub use personal_browser_profiles::{BrowserProfileInput, BrowserProfileUpdate};
pub use personal_mutations::{PersonalWorkspaceUpdate, ProfileInput, ProfileUpdate};
pub use personal_store::{DEFAULT_PROFILE_ID, PersonalSnapshot};
pub use presentation_store::{
    FrontendBrowserRecord, PresentationSnapshot, SavedTabGroupRecord, SavedTabMember,
    TAB_GROUP_NO_COLOR, TabGroupRecord, TabGroupState, WorkspaceGroupRecord,
    WorkspacePresentationUpdate, new_saved_tab_group_id, new_tab_group_id, new_workspace_group_id,
    validate_presentation_color, validate_tab_group_color, validate_tab_group_name,
    validate_workspace_group_id,
};
pub use public_projection_store::RegistryPublicProjections;
pub(crate) use public_projection_store::agent_projection_extra;
#[cfg(test)]
pub use public_projection_store::{RegistryAgentProjection, RegistryNotificationProjection};
#[cfg(test)]
pub(crate) use public_projection_store::{
    agent_hook_fence_rows_read_on_this_thread, agent_projection_rows_read_on_this_thread,
};
#[cfg(test)]
pub(crate) use resource_store::AGENT_HOOK_MAX_ATTEMPTS;
pub(crate) use resource_store::validate_registry_screen_projection;
pub(crate) use resource_store::{
    AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE, AgentHookPendingFailure, AgentHookProjectionState,
    AgentHookRetryClass,
};
#[allow(unused_imports)]
pub use resource_store::{
    RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserReconnect, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryLayoutNode, RegistryPane, RegistryRow, RegistryScreen,
    RegistryTab, RegistryViewport, RegistryViewportColumn, ResourceChange, ResourceEventBatch,
    ResourceEventPage, ResourcePatch, ResourcePatchCommit, ResourceTopologySnapshot,
    ResourceWorkspaceLedger,
};
use resource_store::{
    apply_resource_patch, complete_terminal_close_patch, create_resource_schema,
    initialize_resource_mutation_retention, migrate_resource_agent_projections,
    migrate_resource_browser_metadata, migrate_resource_mutations_to_session_scope,
    migrate_resource_tabs_to_multiview, repair_resources_at_open,
    resource_tabs_needs_multiview_normalization, validate_resource_invariants,
};
pub(crate) use resource_store::{
    load_live_terminal_resource_ids, load_resource_topology_scoped, load_session_panes,
    load_session_tabs, load_terminal_tabs, load_topology_frame,
};
pub use screen_store::{
    SavedScreenGroupRecord, SavedScreenMember, ScreenGroupRecord, ScreenPresentationRecord,
    ScreenPresentationState, new_saved_screen_group_id, new_screen_group_id,
};
pub use session_journal::{
    JournalAuthority, JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity,
    JournalSubject, SessionJournalPage, SessionJournalRecord,
};
use session_journal::{
    ResourceEffectJournalState, append_resource_effect_journal_record,
    append_resource_journal_record, create_session_journal_schema,
    migrate_resource_events_to_session_journal,
};
pub(crate) use session_journal::{SessionJournalReader, unix_epoch_ms};
pub(crate) use terminal_snapshot_read::load_terminal_rows;
pub(crate) use topology_close_store::TopologyCloseCommit;

// Schema 9 shipped independently on the journal and multiview development
// branches. Schema 10 shipped the journal extensions. Version 11 is the first
// schema that requires both, and its migration probes the actual table/index
// shape instead of assuming that a colliding development version identifies
// one branch. Version 12 scopes receipts by origin. Version 13 adds immutable
// binary content to journal rows. Version 14 gives resource API frontend
// projections one owned envelope instead of storing anonymous projection JSON.
// Version 15 normalizes legacy terminal exits to the exact public receipt shape.
pub(crate) const SCHEMA_VERSION: i64 = 15;
pub(crate) const RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION: u32 = 2;
/// The registry runs with `synchronous=NORMAL` in WAL mode
/// (`wal_durability.rs`): a commit is in the WAL when it returns, which a
/// crash, kill or restart of the daemon keeps; only a power loss or kernel
/// panic can take acknowledged commits back, always a suffix. `fullfsync`
/// makes the syncs SQLite still does (each WAL checkpoint, and the close)
/// flush the device cache on macOS (F_FULLFSYNC), so a checkpoint never
/// copies frames into the database before they are on the disk. Unit tests
/// open hundreds of throwaway registries in one process and never cut power:
/// there, a plain fsync keeps every ordering and restart result they check,
/// while F_FULLFSYNC serialized the device across all test threads
/// (notification_reads_survive_restart_and_eviction_prunes_them: 19.3 s on a
/// fleet Mac, 0.18 s on Linux). Daemon binaries, including every integration
/// test's daemon, keep F_FULLFSYNC.
#[cfg(not(test))]
const REGISTRY_FULLFSYNC_PRAGMA: &str = "PRAGMA fullfsync=ON;";
#[cfg(test)]
const REGISTRY_FULLFSYNC_PRAGMA: &str = "PRAGMA fullfsync=OFF;";

const RESOURCE_EFFECT_PEPPER_SCHEMA_VERSION: i64 = 7;
const MAX_ID_LEN: usize = 128;
const MAX_WORKSPACE_KEY_LEN: usize = 256;
const MAX_LAUNCH_SPEC_BYTES: usize = 1024 * 1024;
#[cfg(not(test))]
const MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES: usize = 100_000;
#[cfg(test)]
const MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES: usize = 64;
#[cfg(not(test))]
const MAX_RESET_CONFIRMATION_FINGERPRINT_BYTES: u64 = 512 * 1024 * 1024;
// A fresh test registry is already close to 1 MiB (one page per table and
// index); the test bound leaves room for new tables.
#[cfg(test)]
const MAX_RESET_CONFIRMATION_FINGERPRINT_BYTES: u64 = 2 * 1024 * 1024;
#[cfg(not(test))]
const MAX_RESET_CONFIRMATION_FINGERPRINT_MANIFEST_BYTES: usize = 16 * 1024 * 1024;
#[cfg(test)]
const MAX_RESET_CONFIRMATION_FINGERPRINT_MANIFEST_BYTES: usize = 1024;
const RESOURCE_EFFECT_PEPPER_BYTES: usize = 32;
const RESOURCE_EFFECT_PEPPER_FILE: &str = "resource-effect-pepper";
const RESOURCE_EFFECT_PEPPER_LOCK_FILE: &str = "resource-effect-pepper.lock";
const RESOURCE_EFFECT_PEPPER_META_KEY: &str = "resource_effect_pepper_id";
const RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY: &str = "resource_effect_pepper_cleanup_pending";
const JOURNAL_PLUGIN_GENERATION_META_KEY: &str = "journal_plugin_generation";
const JOURNAL_AUTO_VACUUM_META_KEY: &str = "journal_auto_vacuum_migrated";
const RESOURCE_EFFECT_PEPPER_ID_DOMAIN: &[u8] = b"cmux.resource-effect-pepper-id.v1";
const RESOURCE_INPUT_RECEIPT_DOMAIN: &[u8] = b"cmux.resource-input-receipt.v2";
pub(crate) const WORKSPACE_REGISTRY_FILE: &str = "workspace-registry.sqlite3";
/// The first part and the last part of the name that a reset gives a session
/// folder before it deletes it: `.reset-NAME-KIND-UUID.deleting`, a direct
/// child of the state root (session_reset.rs). The rollback check reads each
/// folder with such a name (store_schemas.rs).
pub(crate) const RESET_DIR_HEAD: &str = ".reset-";
pub(crate) const RESET_DIR_TAIL: &str = ".deleting";

/// An extra write that runs inside a workspace-registry commit transaction.
pub(crate) type RegistryTransactionWrite<'a> = &'a dyn Fn(&Transaction<'_>) -> anyhow::Result<()>;

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
    /// Who chose `name`; an older registry or intent without it is user-owned.
    #[serde(default)]
    pub name_source: crate::resource_name::NameSource,
    /// Advances on every rename of this workspace (an automatic rename's fence).
    #[serde(default)]
    pub name_revision: u64,
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

/// Per-terminal policy for the terminal's views when its hosted process
/// exits. `Close` (the default) detaches every view and drops the runtime
/// surface, leaving only the durable exit receipt. `Keep` retains the tabs
/// and the live screen surface next to that receipt while the daemon runs;
/// after a daemon restart the in-memory VT is gone, so a kept-exited
/// terminal degrades to the normal detach during reconciliation. `Shell`
/// keeps the tabs like `Keep`, then drops them into a new shell under the
/// same terminal id (the manual restart's worker, `terminal_respawn/manual.rs`);
/// that shell's own exit closes them, as `Close` does.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalOnExit {
    #[default]
    Close,
    Keep,
    Shell,
}

/// The `launch_spec_json` key that marks a `shell` policy. The `on_exit`
/// column stores `keep` for it, which every older build accepts (its CHECK
/// allows only close and keep), so such a build degrades it to keep.
const SHELL_ON_EXIT_MARKER: &str = "on_exit";

impl TerminalOnExit {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Close => "close",
            Self::Keep => "keep",
            Self::Shell => "shell",
        }
    }

    pub fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "close" => Ok(Self::Close),
            "keep" => Ok(Self::Keep),
            "shell" => Ok(Self::Shell),
            other => anyhow::bail!("invalid terminal on-exit policy {other:?}"),
        }
    }

    /// The `terminal_hosts.on_exit` column value.
    pub(crate) fn column(self) -> &'static str {
        match self {
            Self::Shell => "keep",
            policy => policy.as_str(),
        }
    }

    /// Whether the tabs stay with the final screen after the process ends.
    pub(crate) fn keeps_views(self) -> bool {
        matches!(self, Self::Keep | Self::Shell)
    }
}

/// The `launch_spec_json` stored for `terminal`: its launch spec, plus the
/// `shell` policy marker.
pub(crate) fn durable_launch_spec(terminal: &RegistryTerminal) -> Value {
    let mut launch_spec = terminal.launch_spec.clone();
    if terminal.on_exit == TerminalOnExit::Shell
        && let Some(object) = launch_spec.as_object_mut()
    {
        object.insert(SHELL_ON_EXIT_MARKER.into(), Value::String("shell".into()));
    }
    launch_spec
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryTerminal {
    pub terminal_id: String,
    pub workspace_key: String,
    pub incarnation: Option<String>,
    pub lifecycle: TerminalLifecycle,
    pub launch_spec: Value,
    pub exit: Option<Value>,
    /// Defaults on decode so durable JSON written before the policy existed
    /// (stored intents, journal changes) keeps deserializing as close.
    #[serde(default)]
    pub on_exit: TerminalOnExit,
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

/// A replay cannot acquire a cross-domain side effect that was not part of
/// its original transaction. Keep the receipt source explicit so the mux can
/// reconcile only the revision owned by that receipt.
pub(crate) enum TerminalResourceCloseCommit {
    TerminalReplay(TerminalRegistryCommit),
    ResourceReplay {
        terminal: TerminalRegistryCommit,
        resource: ResourcePatchCommit,
    },
    /// `workspace_revision`: the workspace the close emptied closed too.
    Committed {
        terminal: TerminalRegistryCommit,
        resource: ResourcePatchCommit,
        workspace_revision: Option<u64>,
    },
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
        Self { state_root: platform::normalize_filesystem_path(state_root.into()) }
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
        let confirmation = reset_confirmation_snapshot(
            &self.state_root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
        )?;
        let pending_reset_dir_paths =
            pending_reset_dirs.iter().map(|pending| pending.path.clone()).collect();
        Ok(PersistentSessionStateResetPreview {
            state_root: self.state_root.clone(),
            session_dir,
            terminal_host_root,
            pending_reset_dirs: pending_reset_dir_paths,
            requires_force: true,
            confirm_reset: confirmation.confirm_reset,
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
        if !workspace_state_root_exists(root)? {
            return Ok(reset);
        }
        let initial_pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let initial_session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let initial_terminal_host_root_exists =
            validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !initial_session_dir_exists
            && !initial_terminal_host_root_exists
            && initial_pending_reset_dirs.is_empty()
        {
            return Ok(reset);
        }
        require_reset_confirmation(
            root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &initial_pending_reset_dirs,
            confirm_reset,
        )?;
        ensure_checked_reset_deletion_supported(root)?;
        let _session_guard = acquire_existing_session_reset_guard(root, session_name)?;
        let lock_pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let lock_session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let lock_terminal_host_root_exists = validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !lock_session_dir_exists
            && !lock_terminal_host_root_exists
            && lock_pending_reset_dirs.is_empty()
        {
            return Ok(reset);
        }
        let lease = if lock_session_dir_exists {
            let lock_path =
                platform::normalize_filesystem_path(session_dir.join(SESSION_WRITER_LOCK_FILE));
            Some(SessionLease::acquire(&lock_path)?)
        } else {
            None
        };
        let _terminal_host_reset_lock = if lock_terminal_host_root_exists {
            crate::terminal_host_runtime::acquire_terminal_host_reset_lock(&terminal_host_root)?
        } else {
            None
        };
        let _terminal_host_reset_leases = if lock_terminal_host_root_exists {
            prepare_terminal_host_root_for_reset(&terminal_host_root)?
        } else {
            Vec::new()
        };
        let pending_reset_dirs = pending_session_reset_dirs(root, session_name)?;
        let session_dir_exists = validate_session_reset_dir(&session_dir)?;
        let terminal_host_root_exists = validate_terminal_host_reset_dir(&terminal_host_root)?;
        if !session_dir_exists && !terminal_host_root_exists && pending_reset_dirs.is_empty() {
            return Ok(reset);
        }
        let confirmation = require_reset_confirmation(
            root,
            session_name,
            &session_dir,
            &terminal_host_root,
            &pending_reset_dirs,
            confirm_reset,
        )?;
        if pending_reset_dirs.len() != confirmation.pending_reset_dir_fingerprints.len() {
            anyhow::bail!("reset path changed during reset: {}", root.display());
        }
        for (reset_dir, expected_fingerprint) in
            pending_reset_dirs.iter().zip(&confirmation.pending_reset_dir_fingerprints)
        {
            ensure_reset_dir_fingerprint(&reset_dir.path, "pending", expected_fingerprint)?;
        }
        if let Some(lease) = &lease {
            validate_session_lock_file(&lease.path, lease.file())?;
        }
        let session_reset_dir = if session_dir_exists {
            Some(rename_session_dir_for_reset(
                root,
                session_name,
                &session_dir,
                &confirmation.session_fingerprint,
            )?)
        } else {
            None
        };
        let terminal_host_reset_dir = if terminal_host_root_exists {
            Some(rename_terminal_host_dir_for_reset(
                root,
                session_name,
                &terminal_host_root,
                &confirmation.terminal_host_fingerprint,
            )?)
        } else {
            None
        };
        #[cfg(test)]
        inject_reset_recreated_session_dir_after_staging(&session_dir)?;
        drop(lease);
        for (reset_dir, expected_fingerprint) in
            pending_reset_dirs.iter().zip(&confirmation.pending_reset_dir_fingerprints)
        {
            let label = match reset_dir.kind {
                PendingSessionResetKind::Session => "workspace session state",
                PendingSessionResetKind::TerminalHosts => "terminal host state",
            };
            remove_reset_dir_all(&reset_dir.path, label, "pending", expected_fingerprint)?;
            match reset_dir.kind {
                PendingSessionResetKind::Session => reset.removed_session_state = true,
                PendingSessionResetKind::TerminalHosts => reset.removed_terminal_hosts = true,
            }
        }
        if let Some(reset_dir) = session_reset_dir {
            remove_reset_dir_all(
                &reset_dir,
                "workspace session state",
                "session",
                &confirmation.session_fingerprint,
            )?;
            reset.removed_session_state = true;
        }
        if reset.removed_session_state && validate_session_reset_dir(&session_dir)? {
            anyhow::bail!("reset path changed during reset: {}", session_dir.display());
        }
        if let Some(reset_dir) = terminal_host_reset_dir {
            remove_reset_dir_all(
                &reset_dir,
                "terminal host state",
                "terminal-hosts",
                &confirmation.terminal_host_fingerprint,
            )?;
            reset.removed_terminal_hosts = true;
        }
        if reset.removed_terminal_hosts && validate_terminal_host_reset_dir(&terminal_host_root)? {
            anyhow::bail!("reset path changed during reset: {}", terminal_host_root.display());
        }
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
    /// No change: a retry of a recorded mutation, or the stored body again.
    pub replayed: bool,
    /// The commit added a `projection_mutations` ledger row (a new mutation,
    /// changed or not), which journal maintenance bounds.
    pub recorded: bool,
}

/// The sole durable writer for one session. The owning `Mux` serializes all
/// calls, and the OS lease prevents another daemon from opening the same
/// session concurrently.
pub struct WorkspaceRegistry {
    /// Behind its own lock; lock order rules: see `registry_connection`.
    pub(crate) connection: std::sync::Arc<RegistryConnection>,
    database_path: Option<PathBuf>,
    /// How long each step of this registry's open took (the owner's
    /// `startup-timings.jsonl`); taken once by the owner's start.
    open_timings: crate::startup_timings::StartupTimings,
    registry_id: String,
    generation: String,
    session_name: String,
    machine_id: MachinePublicId,
    session_id: SessionPublicId,
    resource_effect_pepper: ResourceEffectPepper,
    /// The topology state the resource journal states (see `public_fold`).
    public_fold: Option<public_fold::PublicTopologyFold>,
    /// Projection and commit spans for `server-stats`; the mux keeps a clone.
    resource_projection_stats: std::sync::Arc<crate::diagnostics::ResourceProjectionStats>,
    #[cfg(test)]
    resource_patch_failures_remaining: Cell<u64>,
    /// How many next topology snapshot reads fail (tests).
    #[cfg(test)]
    topology_snapshot_failures_remaining: Cell<u64>,
    pub(crate) lease: Option<SessionLease>,
    pub(crate) session_guard: Option<SessionLease>,
    /// This open swapped in a registry without stored output.
    output_cleanup_swapped: bool,
    /// The client whose idle stop raised the fence
    /// ([`Self::set_idle_stop_fence`]), while it is raised.
    idle_stop_fence: Option<u64>,
}

/// What a terminal write gets while an idle stop's fence is raised
/// ([`WorkspaceRegistry::set_idle_stop_fence`]). No quote: it sits in SQL.
pub(crate) const IDLE_STOP_FENCE_ERROR: &str =
    "the daemon is stopping because it was idle; no terminal may start until it stops";

/// Prepared statements each registry connection keeps compiled
/// (`Connection::prepare_cached`, least recently used out first). The journal
/// append, hook and journal read paths run the same few dozen statements for
/// every agent hook; compiling them each time was about a fifth of the
/// daemon's SQLite time on that path. A statement costs a few KiB.
pub(crate) const REGISTRY_STATEMENT_CACHE_CAPACITY: usize = 128;

impl WorkspaceRegistry {
    pub fn snapshot(&self) -> anyhow::Result<RegistrySnapshot> {
        registry_snapshot_in(
            &self.connection.get(),
            &self.registry_id,
            &self.generation,
            &self.session_id,
        )
    }

    /// Read the resource cursor without materializing the workspace graph.
    pub(crate) fn resource_revision(&self) -> anyhow::Result<u64> {
        current_resource_revision(&self.connection.get())
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
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT w.position, w.numeric_id, w.workspace_key, w.name, w.group_key,
                    json_extract(
                      creation.intent_json,
                      '$.workspace_reservation.workspace_public_id'
                    ),
                    w.name_source, w.name_revision
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
                    (row.get::<_, String>(6)?, row.get::<_, i64>(7)?),
                ))
            })?
            .map(|row| {
                let (position, id, key, name, group_key, public_id, (source, revision)) = row?;
                let (name_source, name_revision) =
                    workspace_name_store::stored_name_provenance(&source, revision)?;
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
                        name_source,
                        name_revision,
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

    pub(crate) fn resource_projection_stats(
        &self,
    ) -> &std::sync::Arc<crate::diagnostics::ResourceProjectionStats> {
        &self.resource_projection_stats
    }

    /// The current terminal registry revision alone. Lookups that only need to
    /// stamp their answer read this instead of materializing every terminal
    /// row while holding the registry lock.
    pub fn terminal_revision(&self) -> anyhow::Result<u64> {
        current_terminal_revision(&self.connection.get())
    }

    /// Includes tombstones and is intended for reconciliation and idempotent
    /// close handling, not frontend materialization.
    pub fn terminal_record(&self, terminal_id: &str) -> anyhow::Result<Option<RegistryTerminal>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        read_terminal(&self.connection.get(), terminal_id)
    }

    pub fn replay_terminal(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<TerminalRegistryCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        terminal_replay(&self.connection.get(), mutation, &fingerprint)
    }

    /// Raises (for `owner`, the client whose idle stop raised it) or lowers
    /// the idle-stop fence. An idle stop (`shutdown-daemon` with `if_idle`,
    /// server/stop_if_idle.rs) raises it under this registry's lock once it
    /// found no live terminal, while its handoff reservation is pending;
    /// `Mux::settle_idle_stop_fence` lowers it once that reservation is gone.
    /// While raised, no terminal may become launching, adopting or running,
    /// so none starts between the check and the stop. It is two TEMP
    /// triggers on this registry's one connection (every write to
    /// `terminal_hosts` goes through it): a creation, adoption, respawn,
    /// restore or resource projection is refused at its write, whatever
    /// path it takes.
    pub(crate) fn set_idle_stop_fence(&mut self, owner: Option<u64>) -> anyhow::Result<()> {
        const LIVE: &str = "('launching', 'adopting', 'running')";
        let sql = if owner.is_some() {
            format!(
                "CREATE TEMP TRIGGER IF NOT EXISTS cmux_idle_stop_fence_insert
                   BEFORE INSERT ON terminal_hosts WHEN NEW.lifecycle IN {LIVE}
                 BEGIN SELECT RAISE(ABORT, '{IDLE_STOP_FENCE_ERROR}'); END;
                 CREATE TEMP TRIGGER IF NOT EXISTS cmux_idle_stop_fence_update
                   BEFORE UPDATE OF lifecycle ON terminal_hosts
                   WHEN NEW.lifecycle IN {LIVE} AND OLD.lifecycle NOT IN {LIVE}
                 BEGIN SELECT RAISE(ABORT, '{IDLE_STOP_FENCE_ERROR}'); END;"
            )
        } else {
            "DROP TRIGGER IF EXISTS temp.cmux_idle_stop_fence_insert;
             DROP TRIGGER IF EXISTS temp.cmux_idle_stop_fence_update;"
                .to_owned()
        };
        self.connection.get().execute_batch(&sql)?;
        self.idle_stop_fence = owner;
        Ok(())
    }

    /// The client whose idle stop raised the fence, while it is raised.
    pub(crate) fn idle_stop_fence_owner(&self) -> Option<u64> {
        self.idle_stop_fence
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
        // Through the journal writer batch when it runs (terminal_commit_intent).
        let intent = self.prepare_terminal_commit(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            terminal,
            result,
        )?;
        self.commit_registry_intent(RegistryIntent::Terminal(intent))?.into_terminal()
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
        let fingerprint = terminal_close_fingerprint(mutation, terminal_id, expected_incarnation)?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let commit = close_terminal_in_transaction(
            &tx,
            &self.generation,
            mutation,
            &fingerprint,
            expected_generation,
            expected_revision,
            terminal_id,
            expected_incarnation,
        )?;
        tx.commit()?;
        Ok(commit)
    }

    pub(crate) fn replay_terminal_close(
        &self,
        mutation: &WorkspaceMutation,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
    ) -> anyhow::Result<Option<TerminalRegistryCommit>> {
        let fingerprint = terminal_close_fingerprint(mutation, terminal_id, expected_incarnation)?;
        terminal_replay(&self.connection.get(), mutation, &fingerprint)
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
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let result = close_terminals_in_transaction(&tx, mutation, terminals, "topology-closed")?;
        tx.commit()?;
        Ok(result)
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.get().execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_hosts
                 BEGIN SELECT RAISE(ABORT, 'forced terminal close failure'); END;",
            )?;
        } else {
            self.connection
                .get()
                .execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_terminal_close")?;
        }
        Ok(())
    }

    pub fn terminal_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<Vec<TerminalRegistryEvent>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             FROM terminal_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let ids = StoredIds::load(&db)?;
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
            let result = ids.text(result);
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
            .get()
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
        let ids = StoredIds::load(&self.connection.get())?;
        if ids.fingerprint(stored_fingerprint)? != fingerprint {
            anyhow::bail!(
                "mutation {} from {} was retried with a different payload",
                mutation.id,
                mutation.origin
            );
        }
        let stored_result = ids.text(stored_result);
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
            .get()
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
            None,
        )
    }

    /// Commit a workspace-registry revision that also writes one workspace's
    /// presentation row in the same transaction. The desired registry may be
    /// unchanged (metadata only) or reordered (a group move). A replayed
    /// mutation returns its original result and writes nothing.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_workspace_presentation(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        update: &WorkspacePresentationUpdate,
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        update.validate()?;
        let write = |tx: &Transaction<'_>| {
            presentation_store::write_workspace_presentation(tx, workspace_key, update)
        };
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
            Some(&write),
        )
    }

    /// `(origin, mutation_id)` of the event at `revision`, if there is one.
    pub fn event_mutation(&self, revision: u64) -> anyhow::Result<Option<(String, String)>> {
        let Ok(revision) = i64::try_from(revision) else { return Ok(None) };
        let db = self.connection.get();
        let mut statement =
            db.prepare("SELECT origin, mutation_id FROM workspace_events WHERE revision = ?1")?;
        Ok(statement.query_row([revision], |row| Ok((row.get(0)?, row.get(1)?))).optional()?)
    }

    pub fn events_after(&self, revision: u64) -> anyhow::Result<Vec<RegistryEvent>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT revision, kind, workspace_key, origin, mutation_id, result_json
             FROM workspace_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let ids = StoredIds::load(&db)?;
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
                result: serde_json::from_str(&ids.text(result))?,
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
            .get()
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
            anyhow::bail!(
                "frontend projection {frontend}/{scope}/{subject_key} is {} bytes, over {MAX_PROJECTION_BYTES}",
                payload.len()
            );
        }
        let fingerprint = canonical_json(&serde_json::json!({
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "schema_version": schema_version,
            "projection": projection,
        }))?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        // The ledger keeps a digest of the request and its result without the body: a replay is
        // proven to carry the same body (the digest matches), so the body is not stored twice more
        // per save (`projection_size`). Rows written before hold the full text and body.
        let fingerprint_digest = projection_size::fingerprint_digest(&fingerprint);
        if let Some((stored_fingerprint, result_json)) = tx
            .query_row(
                "SELECT fingerprint, result_json FROM projection_mutations
                 WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
        {
            let ids = StoredIds::load(&tx)?;
            let stored_fingerprint = ids.fingerprint(stored_fingerprint)?;
            let result_json = ids.text(result_json);
            if stored_fingerprint != fingerprint_digest && stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            let mut stored: FrontendProjection = serde_json::from_str(&result_json)?;
            stored.projection = projection.clone();
            return Ok(ProjectionCommit { projection: stored, replayed: true, recorded: false });
        }
        let stored_now = tx
            .query_row(
                "SELECT projection_revision, octet_length(payload),
                        schema_version = ?4 AND payload = ?5
                 FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key, i64::from(schema_version), &payload],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, bool>(2)?)),
            )
            .optional()?;
        let current = stored_now
            .map(|(revision, _, _)| u64::try_from(revision))
            .transpose()
            .context("projection revision is negative")?
            .unwrap_or(0);
        if let Some(expected) = expected_projection_revision
            && expected != current
        {
            anyhow::bail!("projection revision conflict: expected {expected}, current {current}");
        }
        // The same body (canonical, so key order does not count) and schema
        // as stored is no change: the row and its revision stay, and the
        // commit is `replayed`, so the caller emits no change event. The app
        // saves its documents again on many events with nothing changed, and
        // each save woke every subscriber and the launch snapshot of an idle
        // owner. The ledger still records the mutation, so a retry of it
        // after another mutation's change replays this answer instead of
        // writing the old body again.
        let unchanged = stored_now.is_some_and(|(_, _, same)| same);
        let projection_revision = if unchanged {
            current
        } else {
            let previous_bytes = stored_now.and_then(|(_, bytes, _)| usize::try_from(bytes).ok());
            note_projection_size(frontend, scope, subject_key, previous_bytes, payload.len());
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
            projection_revision
        };
        let stored = FrontendProjection {
            frontend: frontend.to_string(),
            scope: scope.to_string(),
            subject_key: subject_key.to_string(),
            schema_version,
            projection_revision,
            projection: projection.clone(),
        };
        tx.execute(
            "INSERT INTO projection_mutations(origin, mutation_id, fingerprint, result_json, actor)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                mutation.origin,
                mutation.id,
                fingerprint_digest,
                canonical_json(&serde_json::to_value(FrontendProjection {
                    projection: Value::Null,
                    ..stored.clone()
                })?)?,
                mutation.actor.wire(),
            ],
        )?;
        tx.commit()?;
        Ok(ProjectionCommit { projection: stored, replayed: unchanged, recorded: true })
    }
}

fn terminal_close_fingerprint(
    mutation: &WorkspaceMutation,
    terminal_id: &str,
    expected_incarnation: Option<&str>,
) -> anyhow::Result<String> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    validate_terminal_identity("terminal id", terminal_id)?;
    if let Some(incarnation) = expected_incarnation {
        validate_terminal_identity("terminal incarnation", incarnation)?;
    }
    canonical_json(&serde_json::json!({
        "op": "close-terminal",
        "terminal_id": terminal_id,
        "incarnation": expected_incarnation,
    }))
}

#[allow(clippy::too_many_arguments)]
fn close_terminal_in_transaction(
    transaction: &Transaction<'_>,
    generation: &str,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    expected_generation: Option<&str>,
    expected_revision: Option<u64>,
    terminal_id: &str,
    expected_incarnation: Option<&str>,
) -> anyhow::Result<TerminalRegistryCommit> {
    if let Some(replay) = terminal_replay(transaction, mutation, fingerprint)? {
        return Ok(replay);
    }
    if let Some(expected) = expected_generation
        && expected != generation
    {
        anyhow::bail!("terminal generation conflict: expected {expected}, current {generation}");
    }
    let current_revision = transaction_terminal_revision(transaction)?;
    if let Some(expected) = expected_revision
        && expected != current_revision
    {
        anyhow::bail!(
            "terminal revision conflict: expected {expected}, current {current_revision}"
        );
    }
    let Some(terminal) = read_terminal(transaction, terminal_id)? else {
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
        let revision = i64::try_from(current_revision)
            .context("terminal revision exceeds SQLite integer range")?;
        let ledger = mutation_ledger::KeyedLedger::Terminal;
        mutation_ledger::insert_keyed_mutation(
            transaction,
            ledger,
            mutation,
            fingerprint,
            &result_json,
            revision,
        )?;
        return Ok(TerminalRegistryCommit { revision: current_revision, result, replayed: false });
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
    transaction.execute(
        "UPDATE terminal_hosts
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE terminal_id = ?2",
        params![sqlite_revision, terminal_id],
    )?;
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
        [revision.to_string()],
    )?;
    let ledger = mutation_ledger::KeyedLedger::Terminal;
    let row = (fingerprint, result_json.as_str(), sqlite_revision);
    mutation_ledger::insert_keyed_mutation(transaction, ledger, mutation, row.0, row.1, row.2)?;
    transaction.execute(
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
    Ok(TerminalRegistryCommit { revision, result, replayed: false })
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
    if terminal.lifecycle == TerminalLifecycle::Exited {
        let exit = terminal.exit.as_ref().context("exited terminal requires exit metadata")?;
        terminal_exit_store::validate_terminal_exit_receipt(exit)?;
    } else if terminal.exit.is_some() {
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
    if existing.on_exit != desired.on_exit {
        anyhow::bail!("terminal on-exit policy is fixed at reservation");
    }
    Ok(())
}

type StoredTerminal = (String, String, Option<String>, String, String, Option<String>, String);

fn terminal_from_stored(stored: StoredTerminal) -> anyhow::Result<RegistryTerminal> {
    let (terminal_id, workspace_key, incarnation, lifecycle, launch_spec, exit, on_exit) = stored;
    let mut launch_spec: Value = serde_json::from_str(&launch_spec)?;
    let marked = launch_spec
        .as_object_mut()
        .and_then(|object| object.remove(SHELL_ON_EXIT_MARKER))
        .is_some_and(|marker| marker == "shell");
    let on_exit = match TerminalOnExit::parse(&on_exit)? {
        TerminalOnExit::Keep if marked => TerminalOnExit::Shell,
        policy => policy,
    };
    Ok(RegistryTerminal {
        terminal_id,
        workspace_key,
        incarnation,
        lifecycle: TerminalLifecycle::parse(&lifecycle)?,
        launch_spec,
        exit: exit.map(|value| serde_json::from_str(&value)).transpose()?,
        on_exit,
    })
}

fn read_terminal(
    connection: &Connection,
    terminal_id: &str,
) -> anyhow::Result<Option<RegistryTerminal>> {
    let stored = connection
        .query_row(
            "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                    launch_spec_json, exit_json, on_exit
             FROM terminal_hosts WHERE terminal_id = ?1",
            [terminal_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
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
    let ids = StoredIds::load(connection)?;
    let stored_result = ids.text(stored_result);
    if ids.fingerprint(stored_fingerprint)? != fingerprint {
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

pub(crate) fn validate_identifier(label: &str, value: &str) -> anyhow::Result<()> {
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

pub(crate) fn canonical_json(value: &Value) -> anyhow::Result<String> {
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

pub(crate) fn meta_value(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

pub(crate) fn required_meta(connection: &Connection, key: &str) -> anyhow::Result<String> {
    meta_value(connection, key)?
        .ok_or_else(|| anyhow::anyhow!("workspace registry is missing {key}"))
}

/// [`WorkspaceRegistry::snapshot`] on `connection`: the registry's own
/// connection under its lock, or its read-only connection for a read that
/// must not wait for a writer (`resource_api::read_committed_registry`).
pub(crate) fn registry_snapshot_in(
    connection: &Connection,
    registry_id: &str,
    generation: &str,
    session_id: &SessionPublicId,
) -> anyhow::Result<RegistrySnapshot> {
    let revision = current_revision(connection)?;
    let resource_revision = current_resource_revision(connection)?;
    let max_numeric_id =
        connection.query_row("SELECT COALESCE(MAX(numeric_id), 0) FROM workspaces", [], |row| {
            row.get::<_, i64>(0)
        })?;
    let next_numeric_id = u64::try_from(max_numeric_id)
        .context("stored workspace id is negative")?
        .checked_add(1)
        .ok_or_else(|| anyhow::anyhow!("workspace id space exhausted"))?;
    let mut statement = connection.prepare(
        "SELECT w.numeric_id, w.workspace_key, w.name, w.group_key, rw.public_id,
                w.name_source, w.name_revision
         FROM workspaces w
         JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
         WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
         ORDER BY w.position ASC",
    )?;
    let workspaces = statement
        .query_map([], |row| {
            let id: i64 = row.get(0)?;
            let provenance: (String, i64) = (row.get(5)?, row.get(6)?);
            Ok((id, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, provenance))
        })?
        .map(|row| {
            let (id, key, name, group_key, public_id, (source, revision)): (
                i64,
                String,
                String,
                String,
                String,
                (String, i64),
            ) = row?;
            let (name_source, name_revision) =
                workspace_name_store::stored_name_provenance(&source, revision)?;
            Ok::<RegistryWorkspace, anyhow::Error>(RegistryWorkspace {
                id: u64::try_from(id).context("stored workspace id is negative")?,
                public_id: WorkspacePublicId::parse(public_id)?,
                key,
                name,
                name_source,
                name_revision,
                group_key,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(RegistrySnapshot {
        registry_id: registry_id.to_string(),
        generation: generation.to_string(),
        revision,
        resource_revision,
        session_id: session_id.clone(),
        next_numeric_id,
        workspaces,
    })
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

pub(crate) fn current_terminal_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "terminal_revision")?
        .parse()
        .context("terminal registry revision is invalid")
}

fn current_resource_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "resource_revision")?.parse().context("resource revision is invalid")
}

pub(crate) fn transaction_resource_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
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
const SESSION_WRITER_LOCK_FILE: &str = "writer.lock";
const TERMINAL_HOST_PUBLICATION_LOCK_FILE: &str = ".publication.lock";
#[cfg(test)]
static RESET_RENAME_SYNC_FAILURE_ROOT: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static RESET_DELETE_AFTER_MANIFEST_FILE: std::sync::Mutex<Option<(PathBuf, PathBuf)>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
static RESET_DELETE_AFTER_CHILD_VERIFY_FILE: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
static RESET_REMOVE_LEGACY_HOST_RECORD_BEFORE_LIVENESS: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static RESET_UNSUPPORTED_CHECKED_DELETION_ROOT: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
static RESET_RECREATE_SESSION_DIR_AFTER_STAGING: std::sync::Mutex<Option<PathBuf>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
mod session_owner_probe_tests {
    use super::*;

    #[test]
    fn a_held_probe_lease_keeps_the_session_from_starting_and_a_missing_guard_is_no_lease() {
        let root = std::env::temp_dir().join(format!("owner-probe-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let component = session_guard_component("cmux-app-gone");
        assert!(matches!(probe_session_owner(&root, &component), SessionOwnerProbe::NoGuard));

        // The session ran once: its guard file exists and is free.
        drop(acquire_session_guard(&root, "cmux-app-gone").unwrap());
        let SessionOwnerProbe::Unowned(lease) = probe_session_owner(&root, &component) else {
            panic!("a free guard was not taken");
        };
        // A daemon starting now cannot take the session (and adopt its hosts).
        assert!(acquire_session_guard(&root, "cmux-app-gone").is_err());
        drop(lease);
        // A running daemon's guard is never taken.
        let owner = acquire_session_guard(&root, "cmux-app-gone").unwrap();
        assert!(matches!(probe_session_owner(&root, &component), SessionOwnerProbe::Owned));
        drop(owner);
        let _ = fs::remove_dir_all(&root);
    }

    /// Windows: a held guard renamed away and replaced by another file at
    /// its path no longer guards the session.
    #[cfg(windows)]
    #[test]
    fn a_guard_replaced_while_held_no_longer_guards_on_windows() {
        let root = std::env::temp_dir().join(format!("owner-probe-win-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        drop(start_session_guard_for_test(&root, "cmux-app-gone").unwrap());
        let component = session_guard_component("cmux-app-gone");
        let SessionOwnerProbe::Unowned(lease) = probe_session_owner(&root, &component) else {
            panic!("a free guard was not taken");
        };
        assert!(lease.still_guards(), "the held guard does not guard");
        let guard = lease.path.clone();
        fs::rename(&guard, guard.with_extension("old")).unwrap();
        fs::write(&guard, b"").unwrap();
        assert!(!lease.still_guards(), "a replaced guard still counts as held");
        drop(lease);
        let _ = fs::remove_dir_all(&root);
    }
}

#[cfg(unix)]
fn prepare_terminal_host_root_for_reset(
    root: &Path,
) -> anyhow::Result<Vec<TerminalHostLiveMarkerLease>> {
    use std::os::unix::fs::MetadataExt;

    let records = crate::terminal_host_runtime::load_terminal_host_records_for_reset(root)
        .context("terminal host state still has live or unverified hosts")?;
    let expected_uid = fs::metadata(root)?.uid();
    let mut live_marker_leases = Vec::new();
    let expected_live_markers = records
        .iter()
        .filter(|(_, record)| record.record_version >= 2)
        .map(|(record_path, record)| terminal_host_live_marker_path(record_path, record))
        .collect::<HashSet<_>>();
    crate::terminal_host_runtime::sweep_released_pty_locks(root);
    for entry in fs::read_dir(root)
        .with_context(|| format!("read terminal host state {}", root.display()))?
    {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("live")
            && !expected_live_markers.contains(&path)
        {
            match lock_verified_dead_live_marker(&path, expected_uid)? {
                TerminalHostLiveMarkerLock::Locked(lease) => live_marker_leases.push(lease),
                TerminalHostLiveMarkerLock::Missing => {}
                TerminalHostLiveMarkerLock::Unsafe => {
                    anyhow::bail!("terminal host state still has live or unverified hosts");
                }
            }
        }
    }
    #[cfg(test)]
    inject_legacy_terminal_host_record_removal_before_liveness(root)?;
    for (record_path, record) in &records {
        match crate::terminal_host_runtime::terminal_host_record_liveness(record_path, record)? {
            TerminalHostLiveness::Dead => {
                if record.record_version >= 2 {
                    let marker = terminal_host_live_marker_path(record_path, record);
                    match lock_verified_dead_live_marker(&marker, expected_uid)? {
                        TerminalHostLiveMarkerLock::Locked(lease) => live_marker_leases.push(lease),
                        TerminalHostLiveMarkerLock::Missing => {}
                        TerminalHostLiveMarkerLock::Unsafe => {
                            anyhow::bail!("terminal host state still has live or unverified hosts");
                        }
                    }
                }
            }
            TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {
                anyhow::bail!("terminal host state still has live or unverified hosts");
            }
        }
    }
    Ok(live_marker_leases)
}

#[cfg(all(unix, test))]
fn inject_legacy_terminal_host_record_removal_before_liveness(root: &Path) -> anyhow::Result<()> {
    let mut record = RESET_REMOVE_LEGACY_HOST_RECORD_BEFORE_LIVENESS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(path) = record.as_ref() else {
        return Ok(());
    };
    if path.parent() != Some(root) {
        return Ok(());
    }
    let Some(path) = record.take() else {
        return Ok(());
    };
    fs::remove_file(&path)
        .with_context(|| format!("remove injected terminal-host record {}", path.display()))?;
    Ok(())
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
enum TerminalHostLiveMarkerLock {
    Locked(TerminalHostLiveMarkerLease),
    Missing,
    Unsafe,
}

#[cfg(unix)]
fn lock_verified_dead_live_marker(
    path: &Path,
    expected_uid: u32,
) -> anyhow::Result<TerminalHostLiveMarkerLock> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(TerminalHostLiveMarkerLock::Missing);
        }
        Err(_) => return Ok(TerminalHostLiveMarkerLock::Unsafe),
    };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.uid() != expected_uid
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
    {
        return Ok(TerminalHostLiveMarkerLock::Unsafe);
    }
    loop {
        // SAFETY: flock only observes/changes the advisory lock on this valid file descriptor.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            let current = match fs::symlink_metadata(path) {
                Ok(current) => current,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    return Ok(TerminalHostLiveMarkerLock::Missing);
                }
                Err(error) => return Err(error.into()),
            };
            if current.dev() != metadata.dev() || current.ino() != metadata.ino() {
                return Ok(TerminalHostLiveMarkerLock::Unsafe);
            }
            return Ok(TerminalHostLiveMarkerLock::Locked(TerminalHostLiveMarkerLease {
                _file: file,
            }));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Ok(TerminalHostLiveMarkerLock::Unsafe);
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

/// Fails when a registry under `root` is at `schema` or later.
fn ensure_no_registry_at(root: &Path, pepper_path: &Path, schema_floor: i64) -> anyhow::Result<()> {
    for entry in
        fs::read_dir(root).with_context(|| format!("read state root {}", root.display()))?
    {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let database =
            platform::normalize_filesystem_path(entry.path().join(WORKSPACE_REGISTRY_FILE));
        if !database.try_exists()? {
            continue;
        }
        let connection = open_registry_database_read_only(&database).with_context(|| {
            format!("inspect registry before recreating missing pepper {}", database.display())
        })?;
        let schema = meta_value(&connection, "schema_version")?
            .ok_or_else(|| anyhow::anyhow!("registry schema is missing: {}", database.display()))?;
        let schema: i64 = schema
            .parse()
            .with_context(|| format!("registry schema is invalid: {}", database.display()))?;
        anyhow::ensure!(
            schema < schema_floor,
            "resource receipt pepper is missing for an existing registry: {}",
            pepper_path.display()
        );
    }
    Ok(())
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

#[cfg(test)]
mod tests;

#[cfg(test)]
mod receipt_env_tests;

#[cfg(test)]
mod open_cost_tests;

#[cfg(test)]
mod open_invariants_tests;

#[cfg(test)]
mod temp_store_tests;

#[cfg(test)]
mod personal_tests;

#[cfg(test)]
mod actor_migration_tests;

#[cfg(test)]
mod workspace_name_tests;

#[cfg(test)]
mod projection_size_tests;
