//! Daemon-lifetime per-window navigation state for protocol-v9 frontends.
//!
//! Canonical topology owns entity existence and ancestry. This registry owns
//! only frontend-window choices within that topology. Mutations and explicit
//! releases carry request UUIDs. A bounded replay ledger returns the exact
//! original response for an ambiguous retry and rejects UUID reuse with a
//! different request body.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::fmt;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{DaemonInstanceId, PaneUuid, ScreenUuid, SessionId, SurfaceUuid, WorkspaceUuid};

pub(crate) const PROJECTION_NAVIGATION_SCHEMA_VERSION: u8 = 2;

const MAX_RECORDS_PER_CLIENT: usize = 64;
const MAX_RECORDS_GLOBAL: usize = 1_024;
const MAX_WORKSPACES_PER_RECORD: usize = 4_096;
const MAX_WORKSPACE_BINDINGS_GLOBAL: usize = 65_536;
const MAX_SCREEN_PREFERENCES_PER_RECORD: usize = 16_384;
const MAX_PANE_PREFERENCES_PER_RECORD: usize = 16_384;
const MAX_SCREEN_PREFERENCES_GLOBAL: usize = 262_144;
const MAX_PANE_PREFERENCES_GLOBAL: usize = 262_144;
const MAX_OPERATIONS_PER_RECORD: usize = 4_096;
const MAX_OPERATIONS_PER_BATCH: usize = 16_384;
const MAX_RECORDS_PER_BATCH: usize = 64;
const MAX_SCHEMA_FLOORS_PER_CLIENT: usize = 1;
const MAX_SCHEMA_FLOORS_GLOBAL: usize = 65_536;
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_REPLAY_RECEIPTS_PER_CLIENT: usize = 32;
const MAX_REPLAY_RECEIPTS_GLOBAL: usize = 256;
const MAX_REPLAY_RECEIPT_BYTES_PER_CLIENT: usize = 32 * 1024 * 1024;
const MAX_REPLAY_RECEIPT_BYTES_GLOBAL: usize = 128 * 1024 * 1024;

/// A borrowed, indexed view of one exact canonical topology revision.
///
/// The eventual `Mux` adapter must hold the canonical state mutex for the
/// complete registry call. UUID ancestry methods are expected to be O(1), and
/// order slices must use canonical workspace, screen, layout-leaf, and tab
/// order respectively.
pub(crate) trait ProjectionNavigationTopology {
    fn daemon_instance_id(&self) -> DaemonInstanceId;
    fn session_id(&self) -> SessionId;
    fn revision(&self) -> u64;
    fn workspace_order(&self) -> &[WorkspaceUuid];
    fn screen_order(&self, workspace: WorkspaceUuid) -> Option<&[ScreenUuid]>;
    fn pane_order(&self, screen: ScreenUuid) -> Option<&[PaneUuid]>;
    fn surface_order(&self, pane: PaneUuid) -> Option<&[SurfaceUuid]>;
    fn workspace_rank(&self, workspace: WorkspaceUuid) -> Option<usize>;
    fn screen_rank(&self, screen: ScreenUuid) -> Option<usize>;
    fn pane_rank(&self, pane: PaneUuid) -> Option<usize>;
    fn surface_rank(&self, surface: SurfaceUuid) -> Option<usize>;
    fn workspace_for_screen(&self, screen: ScreenUuid) -> Option<WorkspaceUuid>;
    fn screen_for_pane(&self, pane: PaneUuid) -> Option<ScreenUuid>;
    fn pane_for_surface(&self, surface: SurfaceUuid) -> Option<PaneUuid>;

    /// Legacy selection is read only while assigning a workspace or promoting
    /// a v1 record. Reconciliation after that point uses canonical-order
    /// fallback and writes the fallback back into the v2 record.
    fn legacy_selected_screen(&self, workspace: WorkspaceUuid) -> Option<ScreenUuid>;
    fn legacy_active_pane(&self, screen: ScreenUuid) -> Option<PaneUuid>;
    fn legacy_zoomed_pane(&self, screen: ScreenUuid) -> Option<PaneUuid>;
    fn legacy_selected_surface(&self, pane: PaneUuid) -> Option<SurfaceUuid>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) struct ProjectionNavigationClaimant {
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
    pub(crate) connection_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationTopologyExpectation {
    pub(crate) daemon_instance_id: DaemonInstanceId,
    pub(crate) session_id: SessionId,
    pub(crate) expected_topology_revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationListCursor {
    pub(crate) client_revision: u64,
    pub(crate) after_logical_presentation_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationPaneState {
    pub(crate) pane_uuid: PaneUuid,
    pub(crate) selected_surface_uuid: SurfaceUuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationScreenState {
    pub(crate) screen_uuid: ScreenUuid,
    pub(crate) active_pane_uuid: PaneUuid,
    pub(crate) zoomed_pane_uuid: Option<PaneUuid>,
    pub(crate) panes: Vec<ProjectionNavigationPaneState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationWorkspaceState {
    pub(crate) workspace_uuid: WorkspaceUuid,
    pub(crate) selected_screen_uuid: ScreenUuid,
    pub(crate) screens: Vec<ProjectionNavigationScreenState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationState {
    pub(crate) schema_version: u8,
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) generation: u64,
    pub(crate) claim_id: Option<Uuid>,
    pub(crate) claimed_process_instance_uuid: Option<Uuid>,
    pub(crate) reconciled_topology_revision: u64,
    pub(crate) selected_workspace_uuid: Option<WorkspaceUuid>,
    pub(crate) workspaces: Vec<ProjectionNavigationWorkspaceState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub(crate) enum ProjectionNavigationOperation {
    AssignWorkspace {
        workspace_uuid: WorkspaceUuid,
    },
    UnassignWorkspace {
        workspace_uuid: WorkspaceUuid,
    },
    SelectWorkspace {
        workspace_uuid: Option<WorkspaceUuid>,
    },
    SelectScreen {
        workspace_uuid: WorkspaceUuid,
        screen_uuid: ScreenUuid,
    },
    ActivatePane {
        workspace_uuid: WorkspaceUuid,
        screen_uuid: ScreenUuid,
        pane_uuid: PaneUuid,
    },
    SetZoomedPane {
        workspace_uuid: WorkspaceUuid,
        screen_uuid: ScreenUuid,
        pane_uuid: Option<PaneUuid>,
    },
    SelectSurface {
        workspace_uuid: WorkspaceUuid,
        screen_uuid: ScreenUuid,
        pane_uuid: PaneUuid,
        surface_uuid: SurfaceUuid,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationMutation {
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) claim_id: Uuid,
    pub(crate) expected_generation: u64,
    pub(crate) operations: Vec<ProjectionNavigationOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationMutationBatch {
    pub(crate) request_id: Uuid,
    pub(crate) projections: Vec<ProjectionNavigationMutation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationReleaseRequest {
    pub(crate) request_id: Uuid,
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) claim_id: Uuid,
    pub(crate) expected_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ProjectionNavigationEntityKind {
    LogicalPresentation,
    Workspace,
    Screen,
    Pane,
    Surface,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ProjectionNavigationLimit {
    RecordsPerClient,
    RecordsGlobal,
    RecordsPerBatch,
    WorkspacesPerRecord,
    WorkspaceBindingsGlobal,
    ScreenPreferencesPerRecord,
    ScreenPreferencesGlobal,
    PanePreferencesPerRecord,
    PanePreferencesGlobal,
    OperationsPerRecord,
    OperationsPerBatch,
    SchemaFloorsPerClient,
    SchemaFloorsGlobal,
    ResponseBytes,
    ReplayReceiptsPerClient,
    ReplayReceiptsGlobal,
    ReplayReceiptBytesPerClient,
    ReplayReceiptBytesGlobal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", rename_all = "kebab-case")]
pub(crate) enum ProjectionNavigationConflict {
    StaleTopology {
        expected_daemon_instance_id: DaemonInstanceId,
        current_daemon_instance_id: DaemonInstanceId,
        expected_session_id: SessionId,
        current_session_id: SessionId,
        expected_revision: u64,
        current_revision: u64,
    },
    StaleGeneration {
        logical_presentation_id: Uuid,
        expected: u64,
        current: u64,
        current_state: Box<ProjectionNavigationState>,
    },
    LegacyStaleGeneration {
        logical_presentation_id: Uuid,
        expected: u64,
        current: u64,
        current_state: Box<ProjectionNavigationV1State>,
    },
    ClaimLost {
        logical_presentation_id: Uuid,
        claimed_process_instance_uuid: Option<Uuid>,
    },
    WorkspaceOwned {
        workspace_uuid: WorkspaceUuid,
        owner_logical_presentation_id: Uuid,
    },
    EntityMissing {
        entity_kind: ProjectionNavigationEntityKind,
        entity_uuid: Uuid,
    },
    AncestryMismatch {
        entity_kind: ProjectionNavigationEntityKind,
        entity_uuid: Uuid,
        parent_kind: ProjectionNavigationEntityKind,
        expected_parent_uuid: Uuid,
        actual_parent_uuid: Option<Uuid>,
    },
    SchemaPromoted {
        logical_presentation_id: Uuid,
        required_capability: &'static str,
    },
    ClientSchemaPromoted {
        required_capability: &'static str,
    },
    LimitExceeded {
        limit: ProjectionNavigationLimit,
        maximum: usize,
        attempted: usize,
    },
    DuplicateTarget {
        entity_kind: ProjectionNavigationEntityKind,
        entity_uuid: Uuid,
    },
    InvalidSelection {
        entity_kind: ProjectionNavigationEntityKind,
        reason: &'static str,
    },
    InvalidIdentity {
        field: &'static str,
    },
    RequestIdReused {
        request_id: Uuid,
    },
    StaleListCursor {
        expected_client_revision: u64,
        current_client_revision: u64,
    },
    InvalidListCursor {
        after_logical_presentation_id: Uuid,
    },
    ListCursorRestartRequired {
        current_client_revision: u64,
    },
    ClientRevisionExhausted,
    GenerationExhausted {
        logical_presentation_id: Uuid,
    },
}

impl fmt::Display for ProjectionNavigationConflict {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match serde_json::to_string(self) {
            Ok(value) => formatter.write_str(&value),
            Err(_) => formatter.write_str("projection navigation conflict"),
        }
    }
}

impl std::error::Error for ProjectionNavigationConflict {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub(crate) enum ProjectionNavigationResponse {
    Applied {
        topology_revision: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        client_revision: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        next_cursor: Option<ProjectionNavigationListCursor>,
        states: Vec<ProjectionNavigationState>,
    },
    Conflict {
        conflict: ProjectionNavigationConflict,
    },
}

impl ProjectionNavigationResponse {
    fn conflict(conflict: ProjectionNavigationConflict) -> Self {
        Self::Conflict { conflict }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationV1Workspace {
    pub(crate) workspace_uuid: WorkspaceUuid,
    pub(crate) selected_screen_uuid: ScreenUuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationV1Update {
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) claim_id: Uuid,
    pub(crate) expected_generation: u64,
    pub(crate) workspaces: Vec<ProjectionNavigationV1Workspace>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionNavigationV1State {
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) generation: u64,
    pub(crate) claim_id: Option<Uuid>,
    pub(crate) claimed_process_instance_uuid: Option<Uuid>,
    pub(crate) workspaces: Vec<ProjectionNavigationV1Workspace>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProjectionNavigationV1Seed {
    pub(crate) client_uuid: Uuid,
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) generation: u64,
    pub(crate) workspaces: Vec<ProjectionNavigationV1Workspace>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ProjectionNavigationLimits {
    pub(crate) records_per_client: usize,
    pub(crate) records_global: usize,
    pub(crate) workspaces_per_record: usize,
    pub(crate) workspace_bindings_global: usize,
    pub(crate) screen_preferences_per_record: usize,
    pub(crate) screen_preferences_global: usize,
    pub(crate) pane_preferences_per_record: usize,
    pub(crate) pane_preferences_global: usize,
    pub(crate) operations_per_record: usize,
    pub(crate) operations_per_batch: usize,
    pub(crate) records_per_batch: usize,
    pub(crate) schema_floors_per_client: usize,
    pub(crate) schema_floors_global: usize,
    pub(crate) response_bytes: usize,
    pub(crate) replay_receipts_per_client: usize,
    pub(crate) replay_receipts_global: usize,
    pub(crate) replay_receipt_bytes_per_client: usize,
    pub(crate) replay_receipt_bytes_global: usize,
}

impl Default for ProjectionNavigationLimits {
    fn default() -> Self {
        Self {
            records_per_client: MAX_RECORDS_PER_CLIENT,
            records_global: MAX_RECORDS_GLOBAL,
            workspaces_per_record: MAX_WORKSPACES_PER_RECORD,
            workspace_bindings_global: MAX_WORKSPACE_BINDINGS_GLOBAL,
            screen_preferences_per_record: MAX_SCREEN_PREFERENCES_PER_RECORD,
            screen_preferences_global: MAX_SCREEN_PREFERENCES_GLOBAL,
            pane_preferences_per_record: MAX_PANE_PREFERENCES_PER_RECORD,
            pane_preferences_global: MAX_PANE_PREFERENCES_GLOBAL,
            operations_per_record: MAX_OPERATIONS_PER_RECORD,
            operations_per_batch: MAX_OPERATIONS_PER_BATCH,
            records_per_batch: MAX_RECORDS_PER_BATCH,
            schema_floors_per_client: MAX_SCHEMA_FLOORS_PER_CLIENT,
            schema_floors_global: MAX_SCHEMA_FLOORS_GLOBAL,
            response_bytes: MAX_RESPONSE_BYTES,
            replay_receipts_per_client: MAX_REPLAY_RECEIPTS_PER_CLIENT,
            replay_receipts_global: MAX_REPLAY_RECEIPTS_GLOBAL,
            replay_receipt_bytes_per_client: MAX_REPLAY_RECEIPT_BYTES_PER_CLIENT,
            replay_receipt_bytes_global: MAX_REPLAY_RECEIPT_BYTES_GLOBAL,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ProjectionNavigationScaleCounters {
    pub(crate) records_touched: usize,
    pub(crate) global_record_scans: usize,
    pub(crate) workspace_owner_lookups: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
struct ProjectionKey {
    client_uuid: Uuid,
    logical_presentation_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct ReplayKey {
    client_uuid: Uuid,
    request_id: Uuid,
}

#[derive(Debug, Clone)]
struct ReplayReceipt {
    request_digest: [u8; 32],
    response: ProjectionNavigationResponse,
    response_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActiveClaim {
    id: Uuid,
    claimant: ProjectionNavigationClaimant,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredV1 {
    workspaces: BTreeMap<WorkspaceUuid, ScreenUuid>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct StoredV2 {
    selected_workspace_uuid: Option<WorkspaceUuid>,
    workspaces: BTreeSet<WorkspaceUuid>,
    selected_screen_by_workspace: HashMap<WorkspaceUuid, ScreenUuid>,
    active_pane_by_screen: HashMap<ScreenUuid, PaneUuid>,
    zoomed_pane_by_screen: HashMap<ScreenUuid, PaneUuid>,
    selected_surface_by_pane: HashMap<PaneUuid, SurfaceUuid>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum StoredPayload {
    V1(StoredV1),
    V2(StoredV2),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredRecord {
    generation: u64,
    claim: Option<ActiveClaim>,
    reconciled_topology_revision: u64,
    payload: StoredPayload,
}

#[derive(Debug, Clone, Copy, Default)]
struct PayloadCounts {
    workspaces: usize,
    screens: usize,
    panes: usize,
}

impl StoredRecord {
    fn counts(&self) -> PayloadCounts {
        match &self.payload {
            StoredPayload::V1(value) => {
                PayloadCounts { workspaces: value.workspaces.len(), ..PayloadCounts::default() }
            }
            StoredPayload::V2(value) => PayloadCounts {
                workspaces: value.workspaces.len(),
                screens: value.active_pane_by_screen.len(),
                panes: value.selected_surface_by_pane.len(),
            },
        }
    }

    fn workspaces(&self) -> Vec<WorkspaceUuid> {
        match &self.payload {
            StoredPayload::V1(value) => value.workspaces.keys().copied().collect(),
            StoredPayload::V2(value) => value.workspaces.iter().copied().collect(),
        }
    }
}

#[derive(Default)]
struct RegistryInner {
    records: HashMap<ProjectionKey, StoredRecord>,
    logical_presentations_by_client: HashMap<Uuid, BTreeSet<Uuid>>,
    claims_by_connection: HashMap<Uuid, BTreeSet<ProjectionKey>>,
    workspace_owner: HashMap<(Uuid, WorkspaceUuid), ProjectionKey>,
    v2_schema_floor_clients: HashSet<Uuid>,
    client_revisions: HashMap<Uuid, u64>,
    list_snapshot_revisions: HashMap<Uuid, u64>,
    workspace_bindings: usize,
    screen_preferences: usize,
    pane_preferences: usize,
    replay_receipts: HashMap<ReplayKey, ReplayReceipt>,
    replay_order_by_client: HashMap<Uuid, VecDeque<Uuid>>,
    replay_order_global: VecDeque<ReplayKey>,
    replay_bytes_by_client: HashMap<Uuid, usize>,
    replay_bytes_global: usize,
    counters: ProjectionNavigationScaleCounters,
}

pub(crate) struct ProjectionNavigationRegistry {
    inner: Mutex<RegistryInner>,
    limits: ProjectionNavigationLimits,
}

impl ProjectionNavigationRegistry {
    pub(crate) fn new() -> Self {
        Self::new_with_limits(ProjectionNavigationLimits::default())
    }

    pub(crate) fn new_with_limits(limits: ProjectionNavigationLimits) -> Self {
        Self { inner: Mutex::new(RegistryInner::default()), limits }
    }

    /// Imports an already-validated v1 record. Integration calls this while
    /// moving the old registry into the versioned registry; it is not a socket
    /// mutation surface.
    pub(crate) fn install_v1(
        &self,
        seed: ProjectionNavigationV1Seed,
    ) -> Result<(), ProjectionNavigationConflict> {
        validate_uuid(seed.client_uuid, "client_uuid")?;
        validate_uuid(seed.logical_presentation_id, "logical_presentation_id")?;
        let key = ProjectionKey {
            client_uuid: seed.client_uuid,
            logical_presentation_id: seed.logical_presentation_id,
        };
        let mut normalized = BTreeMap::new();
        for workspace in seed.workspaces {
            validate_uuid(workspace.workspace_uuid.as_uuid(), "workspaces.workspace_uuid")?;
            validate_uuid(
                workspace.selected_screen_uuid.as_uuid(),
                "workspaces.selected_screen_uuid",
            )?;
            if normalized.insert(workspace.workspace_uuid, workspace.selected_screen_uuid).is_some()
            {
                return Err(ProjectionNavigationConflict::DuplicateTarget {
                    entity_kind: ProjectionNavigationEntityKind::Workspace,
                    entity_uuid: workspace.workspace_uuid.as_uuid(),
                });
            }
        }
        let record = StoredRecord {
            generation: seed.generation,
            claim: None,
            reconciled_topology_revision: 0,
            payload: StoredPayload::V1(StoredV1 { workspaces: normalized }),
        };
        let mut inner = self.inner.lock().unwrap();
        if has_client_schema_floor(&inner, key.client_uuid) {
            return Err(ProjectionNavigationConflict::SchemaPromoted {
                logical_presentation_id: key.logical_presentation_id,
                required_capability: "projection-navigation-v2",
            });
        }
        if inner.records.contains_key(&key) {
            return Err(ProjectionNavigationConflict::DuplicateTarget {
                entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                entity_uuid: key.logical_presentation_id,
            });
        }
        self.validate_new_record_limits(&inner, key.client_uuid)?;
        self.validate_candidate_budgets(&inner, &[(key, record.clone())])?;
        self.validate_candidate_owners(&mut inner, &[(key, record.clone())])?;
        let revision = prospective_client_revision(&inner, key.client_uuid, true)?;
        insert_record(&mut inner, key, record);
        set_client_revision(&mut inner, key.client_uuid, revision);
        Ok(())
    }

    pub(crate) fn legacy_claim<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        logical_presentation_id: Uuid,
        topology: &T,
    ) -> Result<ProjectionNavigationV1State, ProjectionNavigationConflict> {
        validate_claimant(claimant)?;
        validate_uuid(logical_presentation_id, "logical_presentation_id")?;
        let key = ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
        let mut inner = self.inner.lock().unwrap();
        inner.counters.records_touched += 1;
        if has_client_schema_floor(&inner, key.client_uuid) {
            return Err(schema_promoted(logical_presentation_id));
        }
        let is_new = !inner.records.contains_key(&key);
        if is_new {
            self.validate_new_record_limits(&inner, claimant.client_uuid)?;
        }
        let mut candidate = inner.records.get(&key).cloned().unwrap_or(StoredRecord {
            generation: 0,
            claim: None,
            reconciled_topology_revision: 0,
            payload: StoredPayload::V1(StoredV1 { workspaces: BTreeMap::new() }),
        });
        if matches!(candidate.payload, StoredPayload::V2(_)) {
            return Err(schema_promoted(logical_presentation_id));
        }
        let before = candidate.clone();
        normalize_v1_record(&mut candidate, topology)?;
        if !candidate.claim.as_ref().is_some_and(|claim| claim.claimant == claimant) {
            candidate.claim = Some(ActiveClaim { id: Uuid::new_v4(), claimant });
        }
        if is_new || candidate != before {
            candidate.generation = next_generation(before.generation, logical_presentation_id)?;
        }
        let state_changed = is_new || candidate != before;
        self.validate_candidate_budgets(&inner, &[(key, candidate.clone())])?;
        self.validate_candidate_owners(&mut inner, &[(key, candidate.clone())])?;
        let state = wire_v1_state(key, &candidate, claimant);
        self.validate_serialized_bytes(&state)?;
        let revision = prospective_client_revision(&inner, claimant.client_uuid, state_changed)?;
        if is_new {
            insert_record(&mut inner, key, candidate);
        } else if candidate != before {
            replace_records(&mut inner, &[(key, candidate)]);
        }
        if state_changed {
            set_client_revision(&mut inner, claimant.client_uuid, revision);
        }
        Ok(state)
    }

    pub(crate) fn legacy_update<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        update: ProjectionNavigationV1Update,
        topology: &T,
    ) -> Result<ProjectionNavigationV1State, ProjectionNavigationConflict> {
        let mut states = self.legacy_update_many(claimant, vec![update], topology)?;
        Ok(states.remove(0))
    }

    pub(crate) fn legacy_update_many<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        updates: Vec<ProjectionNavigationV1Update>,
        topology: &T,
    ) -> Result<Vec<ProjectionNavigationV1State>, ProjectionNavigationConflict> {
        validate_claimant(claimant)?;
        if updates.is_empty() {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                reason: "legacy update must contain at least one logical presentation",
            });
        }
        if updates.len() > self.limits.records_per_batch {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerBatch,
                maximum: self.limits.records_per_batch,
                attempted: updates.len(),
            });
        }
        let mut seen = HashSet::new();
        let mut normalized_updates = Vec::with_capacity(updates.len());
        for update in updates {
            validate_uuid(update.logical_presentation_id, "projections.logical_presentation_id")?;
            validate_uuid(update.claim_id, "projections.claim_id")?;
            if !seen.insert(update.logical_presentation_id) {
                return Err(ProjectionNavigationConflict::DuplicateTarget {
                    entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                    entity_uuid: update.logical_presentation_id,
                });
            }
            let workspaces = self.validate_v1_workspaces(update.workspaces, topology)?;
            normalized_updates.push((
                update.logical_presentation_id,
                update.claim_id,
                update.expected_generation,
                workspaces,
            ));
        }

        let mut inner = self.inner.lock().unwrap();
        inner.counters.records_touched += normalized_updates.len();
        if has_client_schema_floor(&inner, claimant.client_uuid) {
            return Err(schema_promoted(normalized_updates[0].0));
        }
        let mut candidates = Vec::with_capacity(normalized_updates.len());
        let mut changed_keys = HashSet::new();
        for (logical_presentation_id, claim_id, expected_generation, workspaces) in
            &normalized_updates
        {
            let key = ProjectionKey {
                client_uuid: claimant.client_uuid,
                logical_presentation_id: *logical_presentation_id,
            };
            let Some(record) = inner.records.get(&key) else {
                return Err(ProjectionNavigationConflict::EntityMissing {
                    entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                    entity_uuid: *logical_presentation_id,
                });
            };
            if matches!(record.payload, StoredPayload::V2(_)) {
                return Err(schema_promoted(*logical_presentation_id));
            }
            if !record
                .claim
                .as_ref()
                .is_some_and(|claim| claim.id == *claim_id && claim.claimant == claimant)
            {
                return Err(ProjectionNavigationConflict::ClaimLost {
                    logical_presentation_id: *logical_presentation_id,
                    claimed_process_instance_uuid: record
                        .claim
                        .as_ref()
                        .map(|claim| claim.claimant.process_instance_uuid),
                });
            }
            if record.generation != *expected_generation {
                return Err(ProjectionNavigationConflict::LegacyStaleGeneration {
                    logical_presentation_id: *logical_presentation_id,
                    expected: *expected_generation,
                    current: record.generation,
                    current_state: Box::new(wire_v1_state(key, record, claimant)),
                });
            }
            let before = record.clone();
            let mut candidate = before.clone();
            normalize_v1_record(&mut candidate, topology)?;
            let StoredPayload::V1(payload) = &mut candidate.payload else {
                unreachable!("legacy schema checked before update")
            };
            payload.workspaces = workspaces.clone();
            if candidate.payload != before.payload {
                candidate.generation =
                    next_generation(before.generation, *logical_presentation_id)?;
                changed_keys.insert(key);
            }
            candidates.push((key, candidate));
        }
        self.validate_candidate_budgets(&inner, &candidates)?;
        self.validate_candidate_owners(&mut inner, &candidates)?;
        let states = candidates
            .iter()
            .map(|(key, record)| wire_v1_state(*key, record, claimant))
            .collect::<Vec<_>>();
        self.validate_serialized_bytes(&states)?;
        let replacements = candidates
            .into_iter()
            .filter(|(key, _)| changed_keys.contains(key))
            .collect::<Vec<_>>();
        let revision =
            prospective_client_revision(&inner, claimant.client_uuid, !replacements.is_empty())?;
        replace_records(&mut inner, &replacements);
        if !replacements.is_empty() {
            set_client_revision(&mut inner, claimant.client_uuid, revision);
        }
        Ok(states)
    }

    pub(crate) fn legacy_release(
        &self,
        claimant: ProjectionNavigationClaimant,
        logical_presentation_id: Uuid,
        claim_id: Uuid,
        expected_generation: u64,
    ) -> Result<(), ProjectionNavigationConflict> {
        validate_claimant(claimant)?;
        validate_uuid(logical_presentation_id, "logical_presentation_id")?;
        validate_uuid(claim_id, "claim_id")?;
        let key = ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
        let mut inner = self.inner.lock().unwrap();
        inner.counters.records_touched += 1;
        if has_client_schema_floor(&inner, key.client_uuid) {
            return Err(schema_promoted(logical_presentation_id));
        }
        let Some(record) = inner.records.get(&key) else {
            return Err(ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                entity_uuid: logical_presentation_id,
            });
        };
        if matches!(record.payload, StoredPayload::V2(_)) {
            return Err(schema_promoted(logical_presentation_id));
        }
        if !record
            .claim
            .as_ref()
            .is_some_and(|claim| claim.id == claim_id && claim.claimant == claimant)
        {
            return Err(ProjectionNavigationConflict::ClaimLost {
                logical_presentation_id,
                claimed_process_instance_uuid: record
                    .claim
                    .as_ref()
                    .map(|claim| claim.claimant.process_instance_uuid),
            });
        }
        if record.generation != expected_generation {
            return Err(ProjectionNavigationConflict::LegacyStaleGeneration {
                logical_presentation_id,
                expected: expected_generation,
                current: record.generation,
                current_state: Box::new(wire_v1_state(key, record, claimant)),
            });
        }
        let revision = prospective_client_revision(&inner, claimant.client_uuid, true)?;
        remove_record(&mut inner, key);
        set_client_revision(&mut inner, claimant.client_uuid, revision);
        Ok(())
    }

    pub(crate) fn legacy_list<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        topology: &T,
    ) -> Result<Vec<ProjectionNavigationV1State>, ProjectionNavigationConflict> {
        validate_claimant(claimant)?;
        let mut inner = self.inner.lock().unwrap();
        if has_client_schema_floor(&inner, claimant.client_uuid) {
            return Err(client_schema_promoted());
        }
        let keys = inner
            .logical_presentations_by_client
            .get(&claimant.client_uuid)
            .map(|identifiers| {
                identifiers
                    .iter()
                    .map(|logical_presentation_id| ProjectionKey {
                        client_uuid: claimant.client_uuid,
                        logical_presentation_id: *logical_presentation_id,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        inner.counters.records_touched += keys.len();
        let mut candidates = Vec::with_capacity(keys.len());
        let mut changed_keys = HashSet::new();
        for key in keys {
            let record =
                inner.records.get(&key).expect("client index references projection record");
            if matches!(record.payload, StoredPayload::V2(_)) {
                return Err(schema_promoted(key.logical_presentation_id));
            }
            let before = record.clone();
            let mut candidate = before.clone();
            if normalize_v1_record(&mut candidate, topology)? {
                candidate.generation =
                    next_generation(before.generation, key.logical_presentation_id)?;
                changed_keys.insert(key);
            }
            candidates.push((key, candidate));
        }
        self.validate_candidate_budgets(&inner, &candidates)?;
        self.validate_candidate_owners(&mut inner, &candidates)?;
        let states = candidates
            .iter()
            .map(|(key, record)| wire_v1_state(*key, record, claimant))
            .collect::<Vec<_>>();
        self.validate_serialized_bytes(&states)?;
        let replacements = candidates
            .into_iter()
            .filter(|(key, _)| changed_keys.contains(key))
            .collect::<Vec<_>>();
        let revision =
            prospective_client_revision(&inner, claimant.client_uuid, !replacements.is_empty())?;
        replace_records(&mut inner, &replacements);
        if !replacements.is_empty() {
            set_client_revision(&mut inner, claimant.client_uuid, revision);
        }
        Ok(states)
    }

    /// Lets the legacy command lane fail closed after this stable client has
    /// crossed the one-way v2 schema floor.
    pub(crate) fn legacy_access(
        &self,
        client_uuid: Uuid,
        logical_presentation_id: Uuid,
    ) -> Result<ProjectionNavigationV1Seed, ProjectionNavigationConflict> {
        validate_uuid(client_uuid, "client_uuid")?;
        validate_uuid(logical_presentation_id, "logical_presentation_id")?;
        let key = ProjectionKey { client_uuid, logical_presentation_id };
        let inner = self.inner.lock().unwrap();
        if has_client_schema_floor(&inner, client_uuid) {
            return Err(schema_promoted(logical_presentation_id));
        }
        let Some(record) = inner.records.get(&key) else {
            return Err(ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                entity_uuid: logical_presentation_id,
            });
        };
        let StoredPayload::V1(value) = &record.payload else {
            return Err(ProjectionNavigationConflict::SchemaPromoted {
                logical_presentation_id,
                required_capability: "projection-navigation-v2",
            });
        };
        Ok(ProjectionNavigationV1Seed {
            client_uuid,
            logical_presentation_id,
            generation: record.generation,
            workspaces: value
                .workspaces
                .iter()
                .map(|(workspace_uuid, selected_screen_uuid)| ProjectionNavigationV1Workspace {
                    workspace_uuid: *workspace_uuid,
                    selected_screen_uuid: *selected_screen_uuid,
                })
                .collect(),
        })
    }

    pub(crate) fn claim<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        logical_presentation_id: Uuid,
        expectation: ProjectionNavigationTopologyExpectation,
        topology: &T,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) = validate_claimant(claimant)
            .and_then(|()| validate_uuid(logical_presentation_id, "logical_presentation_id"))
            .and_then(|()| validate_expectation(expectation))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Some(conflict) = topology_conflict(expectation, topology) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let key = ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
        let mut inner = self.inner.lock().unwrap();
        inner.counters.records_touched += 1;
        let is_new = !inner.records.contains_key(&key);
        if is_new {
            if let Err(conflict) = self.validate_new_record_limits(&inner, key.client_uuid) {
                return ProjectionNavigationResponse::conflict(conflict);
            }
        }
        let mut candidate = inner.records.get(&key).cloned().unwrap_or(StoredRecord {
            generation: 0,
            claim: None,
            reconciled_topology_revision: topology.revision(),
            payload: StoredPayload::V2(StoredV2::default()),
        });
        let needs_schema_floor = !has_client_schema_floor(&inner, key.client_uuid);
        if needs_schema_floor {
            if let Err(conflict) = self.validate_schema_floor_growth(&inner, key.client_uuid, 1) {
                return ProjectionNavigationResponse::conflict(conflict);
            }
        }
        let mut changed = is_new;
        match promote_record(&mut candidate, topology) {
            Ok(promoted) => changed |= promoted,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        }
        match normalize_record(&mut candidate, topology) {
            Ok(normalized) => changed |= normalized,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        }
        let same_claim = candidate.claim.as_ref().is_some_and(|claim| claim.claimant == claimant);
        if !same_claim {
            candidate.claim = Some(ActiveClaim { id: Uuid::new_v4(), claimant });
            changed = true;
        }
        if changed {
            let Some(generation) = candidate.generation.checked_add(1) else {
                return ProjectionNavigationResponse::conflict(
                    ProjectionNavigationConflict::GenerationExhausted { logical_presentation_id },
                );
            };
            candidate.generation = generation;
        }
        if let Err(conflict) = self.validate_candidate_budgets(&inner, &[(key, candidate.clone())])
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Err(conflict) =
            self.validate_candidate_owners(&mut inner, &[(key, candidate.clone())])
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let response = ProjectionNavigationResponse::Applied {
            topology_revision: topology.revision(),
            client_revision: None,
            next_cursor: None,
            states: vec![wire_state(key, &candidate, claimant, topology)],
        };
        if let Err(conflict) = self.validate_response_bytes(&response) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let state_changed = changed || needs_schema_floor;
        let revision =
            match prospective_client_revision(&inner, claimant.client_uuid, state_changed) {
                Ok(revision) => revision,
                Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
            };
        if is_new {
            insert_record(&mut inner, key, candidate.clone());
        } else if changed {
            replace_records(&mut inner, &[(key, candidate.clone())]);
        }
        if needs_schema_floor {
            establish_schema_floor(&mut inner, key.client_uuid);
        }
        if state_changed {
            set_client_revision(&mut inner, claimant.client_uuid, revision);
        }
        response
    }

    /// Lists and normalizes one logical client's records. Any v1 records are
    /// promoted as one transaction before returning, making list-then-claim a
    /// complete migration path for the existing Swift hydration flow.
    pub(crate) fn list<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        topology: &T,
    ) -> ProjectionNavigationResponse {
        self.list_page(claimant, expectation, None, topology)
    }

    pub(crate) fn list_page<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        cursor: Option<ProjectionNavigationListCursor>,
        topology: &T,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) =
            validate_claimant(claimant).and_then(|()| validate_expectation(expectation))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Some(conflict) = topology_conflict(expectation, topology) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let mut inner = self.inner.lock().unwrap();
        let current_client_revision = client_revision(&inner, claimant.client_uuid);
        if let Some(cursor) = cursor
            && cursor.client_revision != current_client_revision
        {
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::StaleListCursor {
                    expected_client_revision: cursor.client_revision,
                    current_client_revision,
                },
            );
        }
        if let Some(cursor) = cursor
            && inner.list_snapshot_revisions.get(&claimant.client_uuid).copied()
                != Some(cursor.client_revision)
        {
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::ListCursorRestartRequired { current_client_revision },
            );
        }
        let keys = inner
            .logical_presentations_by_client
            .get(&claimant.client_uuid)
            .map(|identifiers| {
                identifiers
                    .iter()
                    .map(|logical_presentation_id| ProjectionKey {
                        client_uuid: claimant.client_uuid,
                        logical_presentation_id: *logical_presentation_id,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let start = match cursor {
            Some(cursor) => {
                let Some(index) = keys.iter().position(|key| {
                    key.logical_presentation_id == cursor.after_logical_presentation_id
                }) else {
                    return ProjectionNavigationResponse::conflict(
                        ProjectionNavigationConflict::InvalidListCursor {
                            after_logical_presentation_id: cursor.after_logical_presentation_id,
                        },
                    );
                };
                index + 1
            }
            None => 0,
        };
        inner.counters.records_touched += keys.len().saturating_sub(start);
        let mut candidates = Vec::with_capacity(keys.len());
        let mut changed_keys = HashSet::new();
        let needs_schema_floor =
            cursor.is_none() && !has_client_schema_floor(&inner, claimant.client_uuid);
        if let Err(conflict) = self.validate_schema_floor_growth(
            &inner,
            claimant.client_uuid,
            usize::from(needs_schema_floor),
        ) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        for key in &keys {
            let mut candidate =
                inner.records.get(key).expect("client index references projection record").clone();
            if cursor.is_none() {
                let mut changed = match promote_record(&mut candidate, topology) {
                    Ok(changed) => changed,
                    Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
                };
                match normalize_record(&mut candidate, topology) {
                    Ok(normalized) => changed |= normalized,
                    Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
                }
                if changed {
                    let Some(generation) = candidate.generation.checked_add(1) else {
                        return ProjectionNavigationResponse::conflict(
                            ProjectionNavigationConflict::GenerationExhausted {
                                logical_presentation_id: key.logical_presentation_id,
                            },
                        );
                    };
                    candidate.generation = generation;
                    changed_keys.insert(*key);
                }
            }
            candidates.push((*key, candidate));
        }
        if let Err(conflict) = self.validate_candidate_budgets(&inner, &candidates) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Err(conflict) = self.validate_candidate_owners(&mut inner, &candidates) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let state_changed = !changed_keys.is_empty() || needs_schema_floor;
        let next_client_revision =
            match prospective_client_revision(&inner, claimant.client_uuid, state_changed) {
                Ok(revision) => revision,
                Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
            };
        let response = match self.build_list_page(
            claimant,
            topology,
            next_client_revision,
            &candidates,
            start,
        ) {
            Ok(response) => response,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        };
        let replacements = candidates
            .iter()
            .filter(|(key, _)| changed_keys.contains(key))
            .cloned()
            .collect::<Vec<_>>();
        replace_records(&mut inner, &replacements);
        if needs_schema_floor {
            establish_schema_floor(&mut inner, claimant.client_uuid);
        }
        if state_changed {
            set_client_revision(&mut inner, claimant.client_uuid, next_client_revision);
        }
        if cursor.is_none() {
            inner.list_snapshot_revisions.insert(claimant.client_uuid, next_client_revision);
        }
        response
    }

    fn build_list_page<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        topology: &T,
        client_revision: u64,
        candidates: &[(ProjectionKey, StoredRecord)],
        start: usize,
    ) -> Result<ProjectionNavigationResponse, ProjectionNavigationConflict> {
        let remaining = candidates.get(start..).unwrap_or_default();
        if remaining.is_empty() {
            let response = ProjectionNavigationResponse::Applied {
                topology_revision: topology.revision(),
                client_revision: Some(client_revision),
                next_cursor: None,
                states: Vec::new(),
            };
            self.validate_response_bytes(&response)?;
            return Ok(response);
        }

        let placeholder_cursor = ProjectionNavigationListCursor {
            client_revision,
            after_logical_presentation_id: remaining[0].0.logical_presentation_id,
        };
        let response_with_cursor_overhead =
            serialized_response_bytes(&ProjectionNavigationResponse::Applied {
                topology_revision: topology.revision(),
                client_revision: Some(client_revision),
                next_cursor: Some(placeholder_cursor),
                states: Vec::new(),
            });
        let mut states = Vec::new();
        let mut projected_bytes = response_with_cursor_overhead;
        for (key, record) in remaining {
            let state = wire_state(*key, record, claimant, topology);
            let state_bytes = serde_json::to_vec(&state)
                .expect("projection navigation state serialization is infallible")
                .len();
            let separator = usize::from(!states.is_empty());
            if projected_bytes.saturating_add(separator).saturating_add(state_bytes)
                > self.limits.response_bytes
            {
                break;
            }
            projected_bytes += separator + state_bytes;
            states.push(state);
        }
        if states.is_empty() {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::ResponseBytes,
                maximum: self.limits.response_bytes,
                attempted: projected_bytes.saturating_add(1),
            });
        }
        let consumed_all = states.len() == remaining.len();
        let next_cursor = (!consumed_all).then(|| ProjectionNavigationListCursor {
            client_revision,
            after_logical_presentation_id: states
                .last()
                .expect("nonempty list page has a final state")
                .logical_presentation_id,
        });
        let response = ProjectionNavigationResponse::Applied {
            topology_revision: topology.revision(),
            client_revision: Some(client_revision),
            next_cursor,
            states,
        };
        // Serialization stays under the canonical+registry guards, but work
        // is proportional to this bounded page rather than all client state.
        self.validate_response_bytes(&response)?;
        Ok(response)
    }

    pub(crate) fn mutate<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        batch: ProjectionNavigationMutationBatch,
        topology: &T,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) = validate_claimant(claimant)
            .and_then(|()| validate_expectation(expectation))
            .and_then(|()| self.validate_batch_shape(&batch))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let request_digest = mutation_request_digest(claimant, expectation, &batch);
        let replay_key =
            ReplayKey { client_uuid: claimant.client_uuid, request_id: batch.request_id };
        let mut inner = self.inner.lock().unwrap();
        if let Some(receipt) = inner.replay_receipts.get(&replay_key) {
            if receipt.request_digest == request_digest {
                return receipt.response.clone();
            }
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::RequestIdReused { request_id: batch.request_id },
            );
        }
        let mut response = self.mutate_locked(claimant, expectation, &batch, topology, &mut inner);
        let response_bytes = match self.validate_response_bytes(&response) {
            Ok(bytes) => bytes,
            Err(conflict) => {
                response = ProjectionNavigationResponse::conflict(conflict);
                serialized_response_bytes(&response)
            }
        };
        if let Err(conflict) = self.validate_single_replay_receipt(response_bytes) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        store_replay_receipt(
            &mut inner,
            replay_key,
            ReplayReceipt { request_digest, response: response.clone(), response_bytes },
            self.limits,
        );
        response
    }

    pub(crate) fn release<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        request: ProjectionNavigationReleaseRequest,
        topology: &T,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) = validate_claimant(claimant)
            .and_then(|()| validate_uuid(request.request_id, "request_id"))
            .and_then(|()| {
                validate_uuid(request.logical_presentation_id, "logical_presentation_id")
            })
            .and_then(|()| validate_uuid(request.claim_id, "claim_id"))
            .and_then(|()| validate_expectation(expectation))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let request_digest = release_request_digest(claimant, expectation, &request);
        let replay_key =
            ReplayKey { client_uuid: claimant.client_uuid, request_id: request.request_id };
        let mut inner = self.inner.lock().unwrap();
        if let Some(receipt) = inner.replay_receipts.get(&replay_key) {
            if receipt.request_digest == request_digest {
                return receipt.response.clone();
            }
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::RequestIdReused { request_id: request.request_id },
            );
        }
        let mut response =
            self.release_locked(claimant, expectation, &request, topology, &mut inner);
        let response_bytes = match self.validate_response_bytes(&response) {
            Ok(bytes) => bytes,
            Err(conflict) => {
                response = ProjectionNavigationResponse::conflict(conflict);
                serialized_response_bytes(&response)
            }
        };
        if let Err(conflict) = self.validate_single_replay_receipt(response_bytes) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        store_replay_receipt(
            &mut inner,
            replay_key,
            ReplayReceipt { request_digest, response: response.clone(), response_bytes },
            self.limits,
        );
        response
    }

    fn mutate_locked<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        batch: &ProjectionNavigationMutationBatch,
        topology: &T,
        inner: &mut RegistryInner,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) = validate_claimant(claimant)
            .and_then(|()| validate_expectation(expectation))
            .and_then(|()| self.validate_batch_shape(batch))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Some(conflict) = topology_conflict(expectation, topology) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        inner.counters.records_touched += batch.projections.len();

        let mut candidates = Vec::with_capacity(batch.projections.len());
        let mut changed_keys = HashSet::new();
        for mutation in &batch.projections {
            let key = ProjectionKey {
                client_uuid: claimant.client_uuid,
                logical_presentation_id: mutation.logical_presentation_id,
            };
            let Some(record) = inner.records.get(&key) else {
                return ProjectionNavigationResponse::conflict(
                    ProjectionNavigationConflict::ClaimLost {
                        logical_presentation_id: key.logical_presentation_id,
                        claimed_process_instance_uuid: None,
                    },
                );
            };
            if matches!(record.payload, StoredPayload::V1(_)) {
                return ProjectionNavigationResponse::conflict(
                    ProjectionNavigationConflict::SchemaPromoted {
                        logical_presentation_id: key.logical_presentation_id,
                        required_capability: "projection-navigation-v2",
                    },
                );
            }
            let visible_process =
                record.claim.as_ref().map(|claim| claim.claimant.process_instance_uuid);
            let owns_claim = record
                .claim
                .as_ref()
                .is_some_and(|claim| claim.id == mutation.claim_id && claim.claimant == claimant);
            if !owns_claim {
                return ProjectionNavigationResponse::conflict(
                    ProjectionNavigationConflict::ClaimLost {
                        logical_presentation_id: mutation.logical_presentation_id,
                        claimed_process_instance_uuid: visible_process,
                    },
                );
            }
            if record.generation != mutation.expected_generation {
                return ProjectionNavigationResponse::conflict(
                    ProjectionNavigationConflict::StaleGeneration {
                        logical_presentation_id: mutation.logical_presentation_id,
                        expected: mutation.expected_generation,
                        current: record.generation,
                        current_state: Box::new(wire_state(key, record, claimant, topology)),
                    },
                );
            }

            let before = record.clone();
            let mut candidate = before.clone();
            if let Err(conflict) = normalize_record(&mut candidate, topology) {
                return ProjectionNavigationResponse::conflict(conflict);
            }
            if let Err(conflict) = apply_operations(
                &mut candidate,
                mutation.logical_presentation_id,
                &mutation.operations,
                topology,
            ) {
                return ProjectionNavigationResponse::conflict(conflict);
            }
            if let Err(conflict) = normalize_record(&mut candidate, topology) {
                return ProjectionNavigationResponse::conflict(conflict);
            }
            if candidate.payload != before.payload
                || candidate.reconciled_topology_revision != before.reconciled_topology_revision
            {
                let Some(generation) = before.generation.checked_add(1) else {
                    return ProjectionNavigationResponse::conflict(
                        ProjectionNavigationConflict::GenerationExhausted {
                            logical_presentation_id: key.logical_presentation_id,
                        },
                    );
                };
                candidate.generation = generation;
                changed_keys.insert(key);
            }
            candidates.push((key, candidate));
        }
        if let Err(conflict) = self.validate_candidate_budgets(inner, &candidates) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Err(conflict) = self.validate_candidate_owners(inner, &candidates) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let response = ProjectionNavigationResponse::Applied {
            topology_revision: topology.revision(),
            client_revision: None,
            next_cursor: None,
            states: candidates
                .iter()
                .map(|(key, record)| wire_state(*key, record, claimant, topology))
                .collect(),
        };
        let response_bytes = match self.validate_response_bytes(&response) {
            Ok(bytes) => bytes,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        };
        if let Err(conflict) = self.validate_single_replay_receipt(response_bytes) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let replacements = candidates
            .iter()
            .filter(|(key, _)| changed_keys.contains(key))
            .cloned()
            .collect::<Vec<_>>();
        let revision = match prospective_client_revision(
            inner,
            claimant.client_uuid,
            !replacements.is_empty(),
        ) {
            Ok(revision) => revision,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        };
        replace_records(inner, &replacements);
        if !replacements.is_empty() {
            set_client_revision(inner, claimant.client_uuid, revision);
        }
        response
    }

    fn release_locked<T: ProjectionNavigationTopology>(
        &self,
        claimant: ProjectionNavigationClaimant,
        expectation: ProjectionNavigationTopologyExpectation,
        request: &ProjectionNavigationReleaseRequest,
        topology: &T,
        inner: &mut RegistryInner,
    ) -> ProjectionNavigationResponse {
        if let Err(conflict) = validate_claimant(claimant)
            .and_then(|()| validate_uuid(request.request_id, "request_id"))
            .and_then(|()| {
                validate_uuid(request.logical_presentation_id, "logical_presentation_id")
            })
            .and_then(|()| validate_uuid(request.claim_id, "claim_id"))
            .and_then(|()| validate_expectation(expectation))
        {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        if let Some(conflict) = topology_conflict(expectation, topology) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let key = ProjectionKey {
            client_uuid: claimant.client_uuid,
            logical_presentation_id: request.logical_presentation_id,
        };
        let needs_schema_floor = !has_client_schema_floor(inner, claimant.client_uuid);
        if let Err(conflict) = self.validate_schema_floor_growth(
            inner,
            claimant.client_uuid,
            usize::from(needs_schema_floor),
        ) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        inner.counters.records_touched += 1;
        let Some(record) = inner.records.get(&key) else {
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::ClaimLost {
                    logical_presentation_id: request.logical_presentation_id,
                    claimed_process_instance_uuid: None,
                },
            );
        };
        if !record
            .claim
            .as_ref()
            .is_some_and(|claim| claim.id == request.claim_id && claim.claimant == claimant)
        {
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::ClaimLost {
                    logical_presentation_id: request.logical_presentation_id,
                    claimed_process_instance_uuid: record
                        .claim
                        .as_ref()
                        .map(|claim| claim.claimant.process_instance_uuid),
                },
            );
        }
        if record.generation != request.expected_generation {
            let current_state = match v2_wire_state(key, record, claimant, topology) {
                Ok(state) => state,
                Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
            };
            return ProjectionNavigationResponse::conflict(
                ProjectionNavigationConflict::StaleGeneration {
                    logical_presentation_id: request.logical_presentation_id,
                    expected: request.expected_generation,
                    current: record.generation,
                    current_state: Box::new(current_state),
                },
            );
        }
        let response = ProjectionNavigationResponse::Applied {
            topology_revision: topology.revision(),
            client_revision: None,
            next_cursor: None,
            states: Vec::new(),
        };
        let response_bytes = match self.validate_response_bytes(&response) {
            Ok(bytes) => bytes,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        };
        if let Err(conflict) = self.validate_single_replay_receipt(response_bytes) {
            return ProjectionNavigationResponse::conflict(conflict);
        }
        let revision = match prospective_client_revision(inner, claimant.client_uuid, true) {
            Ok(revision) => revision,
            Err(conflict) => return ProjectionNavigationResponse::conflict(conflict),
        };
        remove_record(inner, key);
        if needs_schema_floor {
            establish_schema_floor(inner, claimant.client_uuid);
        }
        set_client_revision(inner, claimant.client_uuid, revision);
        response
    }

    /// Clears only connection-owned claims. The projection payload remains for
    /// the next Swift process with the same logical client UUID.
    pub(crate) fn release_connection(
        &self,
        connection_id: Uuid,
    ) -> Result<(), ProjectionNavigationConflict> {
        validate_uuid(connection_id, "connection_id")?;
        let mut inner = self.inner.lock().unwrap();
        let keys = inner.claims_by_connection.get(&connection_id).cloned().unwrap_or_default();
        inner.counters.records_touched += keys.len();
        let mut replacements = Vec::with_capacity(keys.len());
        for key in keys {
            let mut candidate =
                inner.records.get(&key).expect("claim index references projection record").clone();
            if candidate
                .claim
                .as_ref()
                .is_some_and(|claim| claim.claimant.connection_id == connection_id)
            {
                let Some(generation) = candidate.generation.checked_add(1) else {
                    return Err(ProjectionNavigationConflict::GenerationExhausted {
                        logical_presentation_id: key.logical_presentation_id,
                    });
                };
                candidate.claim = None;
                candidate.generation = generation;
                replacements.push((key, candidate));
            }
        }
        let changed_clients =
            replacements.iter().map(|(key, _)| key.client_uuid).collect::<HashSet<_>>();
        let revisions = changed_clients
            .iter()
            .map(|client_uuid| {
                prospective_client_revision(&inner, *client_uuid, true)
                    .map(|revision| (*client_uuid, revision))
            })
            .collect::<Result<Vec<_>, _>>()?;
        replace_records(&mut inner, &replacements);
        for (client_uuid, revision) in revisions {
            set_client_revision(&mut inner, client_uuid, revision);
        }
        Ok(())
    }

    pub(crate) fn state_count(&self) -> usize {
        self.inner.lock().unwrap().records.len()
    }

    pub(crate) fn scale_counters(&self) -> ProjectionNavigationScaleCounters {
        self.inner.lock().unwrap().counters
    }

    pub(crate) fn reset_scale_counters(&self) {
        self.inner.lock().unwrap().counters = ProjectionNavigationScaleCounters::default();
    }

    fn validate_response_bytes(
        &self,
        response: &ProjectionNavigationResponse,
    ) -> Result<usize, ProjectionNavigationConflict> {
        let attempted = serialized_response_bytes(response);
        if attempted > self.limits.response_bytes {
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::ResponseBytes,
                maximum: self.limits.response_bytes,
                attempted,
            })
        } else {
            Ok(attempted)
        }
    }

    fn validate_serialized_bytes<T: Serialize>(
        &self,
        value: &T,
    ) -> Result<usize, ProjectionNavigationConflict> {
        let attempted = serde_json::to_vec(value)
            .expect("projection navigation wire serialization is infallible")
            .len();
        if attempted > self.limits.response_bytes {
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::ResponseBytes,
                maximum: self.limits.response_bytes,
                attempted,
            })
        } else {
            Ok(attempted)
        }
    }

    fn validate_v1_workspaces<T: ProjectionNavigationTopology>(
        &self,
        workspaces: Vec<ProjectionNavigationV1Workspace>,
        topology: &T,
    ) -> Result<BTreeMap<WorkspaceUuid, ScreenUuid>, ProjectionNavigationConflict> {
        if workspaces.len() > self.limits.workspaces_per_record {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::WorkspacesPerRecord,
                maximum: self.limits.workspaces_per_record,
                attempted: workspaces.len(),
            });
        }
        let mut normalized = BTreeMap::new();
        for workspace in workspaces {
            validate_uuid(workspace.workspace_uuid.as_uuid(), "workspaces.workspace_uuid")?;
            validate_uuid(
                workspace.selected_screen_uuid.as_uuid(),
                "workspaces.selected_screen_uuid",
            )?;
            if topology.screen_order(workspace.workspace_uuid).is_none() {
                return Err(ProjectionNavigationConflict::EntityMissing {
                    entity_kind: ProjectionNavigationEntityKind::Workspace,
                    entity_uuid: workspace.workspace_uuid.as_uuid(),
                });
            }
            if topology.workspace_for_screen(workspace.selected_screen_uuid)
                != Some(workspace.workspace_uuid)
            {
                return Err(ProjectionNavigationConflict::AncestryMismatch {
                    entity_kind: ProjectionNavigationEntityKind::Screen,
                    entity_uuid: workspace.selected_screen_uuid.as_uuid(),
                    parent_kind: ProjectionNavigationEntityKind::Workspace,
                    expected_parent_uuid: workspace.workspace_uuid.as_uuid(),
                    actual_parent_uuid: topology
                        .workspace_for_screen(workspace.selected_screen_uuid)
                        .map(WorkspaceUuid::as_uuid),
                });
            }
            if normalized.insert(workspace.workspace_uuid, workspace.selected_screen_uuid).is_some()
            {
                return Err(ProjectionNavigationConflict::DuplicateTarget {
                    entity_kind: ProjectionNavigationEntityKind::Workspace,
                    entity_uuid: workspace.workspace_uuid.as_uuid(),
                });
            }
        }
        Ok(normalized)
    }

    fn validate_single_replay_receipt(
        &self,
        response_bytes: usize,
    ) -> Result<(), ProjectionNavigationConflict> {
        for (maximum, limit) in [
            (
                self.limits.replay_receipts_per_client,
                ProjectionNavigationLimit::ReplayReceiptsPerClient,
            ),
            (self.limits.replay_receipts_global, ProjectionNavigationLimit::ReplayReceiptsGlobal),
        ] {
            if maximum == 0 {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit,
                    maximum,
                    attempted: 1,
                });
            }
        }
        for (maximum, limit) in [
            (
                self.limits.replay_receipt_bytes_per_client,
                ProjectionNavigationLimit::ReplayReceiptBytesPerClient,
            ),
            (
                self.limits.replay_receipt_bytes_global,
                ProjectionNavigationLimit::ReplayReceiptBytesGlobal,
            ),
        ] {
            if response_bytes > maximum {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit,
                    maximum,
                    attempted: response_bytes,
                });
            }
        }
        Ok(())
    }

    fn validate_new_record_limits(
        &self,
        inner: &RegistryInner,
        client_uuid: Uuid,
    ) -> Result<(), ProjectionNavigationConflict> {
        let client_count =
            inner.logical_presentations_by_client.get(&client_uuid).map_or(0, BTreeSet::len);
        if client_count >= self.limits.records_per_client {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerClient,
                maximum: self.limits.records_per_client,
                attempted: client_count.saturating_add(1),
            });
        }
        if inner.records.len() >= self.limits.records_global {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsGlobal,
                maximum: self.limits.records_global,
                attempted: inner.records.len().saturating_add(1),
            });
        }
        Ok(())
    }

    fn validate_schema_floor_growth(
        &self,
        inner: &RegistryInner,
        client_uuid: Uuid,
        additional: usize,
    ) -> Result<(), ProjectionNavigationConflict> {
        let client_count = usize::from(inner.v2_schema_floor_clients.contains(&client_uuid));
        let attempted_client = client_count.saturating_add(additional);
        if attempted_client > self.limits.schema_floors_per_client {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::SchemaFloorsPerClient,
                maximum: self.limits.schema_floors_per_client,
                attempted: attempted_client,
            });
        }
        let attempted_global = inner.v2_schema_floor_clients.len().saturating_add(additional);
        if attempted_global > self.limits.schema_floors_global {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::SchemaFloorsGlobal,
                maximum: self.limits.schema_floors_global,
                attempted: attempted_global,
            });
        }
        Ok(())
    }

    fn validate_batch_shape(
        &self,
        batch: &ProjectionNavigationMutationBatch,
    ) -> Result<(), ProjectionNavigationConflict> {
        validate_uuid(batch.request_id, "request_id")?;
        if batch.projections.is_empty() {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                reason: "mutation batch must contain at least one logical presentation",
            });
        }
        if batch.projections.len() > self.limits.records_per_batch {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerBatch,
                maximum: self.limits.records_per_batch,
                attempted: batch.projections.len(),
            });
        }
        let mut seen = HashSet::new();
        let mut operations = 0_usize;
        for mutation in &batch.projections {
            validate_uuid(mutation.logical_presentation_id, "projections.logical_presentation_id")?;
            validate_uuid(mutation.claim_id, "projections.claim_id")?;
            if !seen.insert(mutation.logical_presentation_id) {
                return Err(ProjectionNavigationConflict::DuplicateTarget {
                    entity_kind: ProjectionNavigationEntityKind::LogicalPresentation,
                    entity_uuid: mutation.logical_presentation_id,
                });
            }
            if mutation.operations.len() > self.limits.operations_per_record {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit: ProjectionNavigationLimit::OperationsPerRecord,
                    maximum: self.limits.operations_per_record,
                    attempted: mutation.operations.len(),
                });
            }
            for operation in &mutation.operations {
                validate_operation_identities(operation)?;
            }
            operations = operations.saturating_add(mutation.operations.len());
        }
        if operations > self.limits.operations_per_batch {
            return Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::OperationsPerBatch,
                maximum: self.limits.operations_per_batch,
                attempted: operations,
            });
        }
        Ok(())
    }

    fn validate_candidate_budgets(
        &self,
        inner: &RegistryInner,
        candidates: &[(ProjectionKey, StoredRecord)],
    ) -> Result<(), ProjectionNavigationConflict> {
        let mut workspaces = inner.workspace_bindings;
        let mut screens = inner.screen_preferences;
        let mut panes = inner.pane_preferences;
        for (key, candidate) in candidates {
            let old = inner.records.get(key).map(StoredRecord::counts).unwrap_or_default();
            let next = candidate.counts();
            if next.workspaces > self.limits.workspaces_per_record {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit: ProjectionNavigationLimit::WorkspacesPerRecord,
                    maximum: self.limits.workspaces_per_record,
                    attempted: next.workspaces,
                });
            }
            if next.screens > self.limits.screen_preferences_per_record {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit: ProjectionNavigationLimit::ScreenPreferencesPerRecord,
                    maximum: self.limits.screen_preferences_per_record,
                    attempted: next.screens,
                });
            }
            if next.panes > self.limits.pane_preferences_per_record {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit: ProjectionNavigationLimit::PanePreferencesPerRecord,
                    maximum: self.limits.pane_preferences_per_record,
                    attempted: next.panes,
                });
            }
            workspaces = workspaces.saturating_sub(old.workspaces).saturating_add(next.workspaces);
            screens = screens.saturating_sub(old.screens).saturating_add(next.screens);
            panes = panes.saturating_sub(old.panes).saturating_add(next.panes);
        }
        for (attempted, maximum, limit) in [
            (
                workspaces,
                self.limits.workspace_bindings_global,
                ProjectionNavigationLimit::WorkspaceBindingsGlobal,
            ),
            (
                screens,
                self.limits.screen_preferences_global,
                ProjectionNavigationLimit::ScreenPreferencesGlobal,
            ),
            (
                panes,
                self.limits.pane_preferences_global,
                ProjectionNavigationLimit::PanePreferencesGlobal,
            ),
        ] {
            if attempted > maximum {
                return Err(ProjectionNavigationConflict::LimitExceeded {
                    limit,
                    maximum,
                    attempted,
                });
            }
        }
        Ok(())
    }

    fn validate_candidate_owners(
        &self,
        inner: &mut RegistryInner,
        candidates: &[(ProjectionKey, StoredRecord)],
    ) -> Result<(), ProjectionNavigationConflict> {
        let touched = candidates.iter().map(|(key, _)| *key).collect::<HashSet<_>>();
        let mut final_owners = HashMap::new();
        for (key, candidate) in candidates {
            for workspace_uuid in candidate.workspaces() {
                inner.counters.workspace_owner_lookups += 1;
                if let Some(owner) = inner.workspace_owner.get(&(key.client_uuid, workspace_uuid))
                    && !touched.contains(owner)
                {
                    return Err(ProjectionNavigationConflict::WorkspaceOwned {
                        workspace_uuid,
                        owner_logical_presentation_id: owner.logical_presentation_id,
                    });
                }
                if let Some(owner) = final_owners.insert((key.client_uuid, workspace_uuid), *key) {
                    return Err(ProjectionNavigationConflict::WorkspaceOwned {
                        workspace_uuid,
                        owner_logical_presentation_id: owner.logical_presentation_id,
                    });
                }
            }
        }
        Ok(())
    }
}

fn validate_uuid(value: Uuid, field: &'static str) -> Result<(), ProjectionNavigationConflict> {
    if value.is_nil() {
        Err(ProjectionNavigationConflict::InvalidIdentity { field })
    } else {
        Ok(())
    }
}

fn validate_claimant(
    claimant: ProjectionNavigationClaimant,
) -> Result<(), ProjectionNavigationConflict> {
    validate_uuid(claimant.client_uuid, "client_uuid")?;
    validate_uuid(claimant.process_instance_uuid, "process_instance_uuid")?;
    validate_uuid(claimant.connection_id, "connection_id")
}

fn validate_expectation(
    expectation: ProjectionNavigationTopologyExpectation,
) -> Result<(), ProjectionNavigationConflict> {
    validate_uuid(expectation.daemon_instance_id.as_uuid(), "daemon_instance_id")?;
    validate_uuid(expectation.session_id.as_uuid(), "session_id")
}

fn validate_operation_identities(
    operation: &ProjectionNavigationOperation,
) -> Result<(), ProjectionNavigationConflict> {
    match operation {
        ProjectionNavigationOperation::AssignWorkspace { workspace_uuid }
        | ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid } => {
            validate_uuid(workspace_uuid.as_uuid(), "operations.workspace_uuid")
        }
        ProjectionNavigationOperation::SelectWorkspace { workspace_uuid } => workspace_uuid
            .map(WorkspaceUuid::as_uuid)
            .map_or(Ok(()), |value| validate_uuid(value, "operations.workspace_uuid")),
        ProjectionNavigationOperation::SelectScreen { workspace_uuid, screen_uuid } => {
            validate_uuid(workspace_uuid.as_uuid(), "operations.workspace_uuid")?;
            validate_uuid(screen_uuid.as_uuid(), "operations.screen_uuid")
        }
        ProjectionNavigationOperation::ActivatePane { workspace_uuid, screen_uuid, pane_uuid } => {
            validate_uuid(workspace_uuid.as_uuid(), "operations.workspace_uuid")?;
            validate_uuid(screen_uuid.as_uuid(), "operations.screen_uuid")?;
            validate_uuid(pane_uuid.as_uuid(), "operations.pane_uuid")
        }
        ProjectionNavigationOperation::SetZoomedPane { workspace_uuid, screen_uuid, pane_uuid } => {
            validate_uuid(workspace_uuid.as_uuid(), "operations.workspace_uuid")?;
            validate_uuid(screen_uuid.as_uuid(), "operations.screen_uuid")?;
            pane_uuid
                .map(PaneUuid::as_uuid)
                .map_or(Ok(()), |value| validate_uuid(value, "operations.pane_uuid"))
        }
        ProjectionNavigationOperation::SelectSurface {
            workspace_uuid,
            screen_uuid,
            pane_uuid,
            surface_uuid,
        } => {
            validate_uuid(workspace_uuid.as_uuid(), "operations.workspace_uuid")?;
            validate_uuid(screen_uuid.as_uuid(), "operations.screen_uuid")?;
            validate_uuid(pane_uuid.as_uuid(), "operations.pane_uuid")?;
            validate_uuid(surface_uuid.as_uuid(), "operations.surface_uuid")
        }
    }
}

fn topology_conflict<T: ProjectionNavigationTopology>(
    expectation: ProjectionNavigationTopologyExpectation,
    topology: &T,
) -> Option<ProjectionNavigationConflict> {
    (expectation.daemon_instance_id != topology.daemon_instance_id()
        || expectation.session_id != topology.session_id()
        || expectation.expected_topology_revision != topology.revision())
    .then(|| ProjectionNavigationConflict::StaleTopology {
        expected_daemon_instance_id: expectation.daemon_instance_id,
        current_daemon_instance_id: topology.daemon_instance_id(),
        expected_session_id: expectation.session_id,
        current_session_id: topology.session_id(),
        expected_revision: expectation.expected_topology_revision,
        current_revision: topology.revision(),
    })
}

fn schema_promoted(logical_presentation_id: Uuid) -> ProjectionNavigationConflict {
    ProjectionNavigationConflict::SchemaPromoted {
        logical_presentation_id,
        required_capability: "projection-navigation-v2",
    }
}

fn client_schema_promoted() -> ProjectionNavigationConflict {
    ProjectionNavigationConflict::ClientSchemaPromoted {
        required_capability: "projection-navigation-v2",
    }
}

fn next_generation(
    generation: u64,
    logical_presentation_id: Uuid,
) -> Result<u64, ProjectionNavigationConflict> {
    generation
        .checked_add(1)
        .ok_or(ProjectionNavigationConflict::GenerationExhausted { logical_presentation_id })
}

fn normalize_v1_record<T: ProjectionNavigationTopology>(
    record: &mut StoredRecord,
    topology: &T,
) -> Result<bool, ProjectionNavigationConflict> {
    let StoredPayload::V1(stored) = &mut record.payload else {
        unreachable!("legacy normalization requires a v1 record")
    };
    let before = stored.clone();
    stored.workspaces.retain(|workspace_uuid, screen_uuid| {
        topology.screen_order(*workspace_uuid).is_some()
            && topology.workspace_for_screen(*screen_uuid) == Some(*workspace_uuid)
    });
    Ok(*stored != before)
}

fn wire_v1_state(
    key: ProjectionKey,
    record: &StoredRecord,
    claimant: ProjectionNavigationClaimant,
) -> ProjectionNavigationV1State {
    let StoredPayload::V1(stored) = &record.payload else {
        unreachable!("v2 records cannot be serialized on the legacy lane")
    };
    let visible_claim = record.claim.as_ref().filter(|claim| claim.claimant == claimant);
    ProjectionNavigationV1State {
        logical_presentation_id: key.logical_presentation_id,
        generation: record.generation,
        claim_id: visible_claim.map(|claim| claim.id),
        claimed_process_instance_uuid: visible_claim
            .map(|claim| claim.claimant.process_instance_uuid),
        workspaces: stored
            .workspaces
            .iter()
            .map(|(workspace_uuid, selected_screen_uuid)| ProjectionNavigationV1Workspace {
                workspace_uuid: *workspace_uuid,
                selected_screen_uuid: *selected_screen_uuid,
            })
            .collect(),
    }
}

fn promote_record<T: ProjectionNavigationTopology>(
    record: &mut StoredRecord,
    topology: &T,
) -> Result<bool, ProjectionNavigationConflict> {
    let StoredPayload::V1(legacy) = &record.payload else {
        return Ok(false);
    };
    let legacy = legacy.clone();
    let mut promoted = StoredV2::default();
    let mut workspaces = legacy.workspaces.keys().copied().collect::<Vec<_>>();
    workspaces.retain(|workspace_uuid| topology.workspace_rank(*workspace_uuid).is_some());
    workspaces.sort_unstable_by_key(|workspace_uuid| {
        (topology.workspace_rank(*workspace_uuid).unwrap_or(usize::MAX), workspace_uuid.as_uuid())
    });
    for workspace_uuid in workspaces {
        let selected_screen_uuid = legacy.workspaces[&workspace_uuid];
        seed_workspace(&mut promoted, workspace_uuid, Some(selected_screen_uuid), topology)?;
    }
    promoted.selected_workspace_uuid =
        promoted.workspaces.iter().copied().min_by_key(|workspace_uuid| {
            (
                topology.workspace_rank(*workspace_uuid).unwrap_or(usize::MAX),
                workspace_uuid.as_uuid(),
            )
        });
    record.payload = StoredPayload::V2(promoted);
    record.claim = None;
    record.reconciled_topology_revision = topology.revision();
    Ok(true)
}

fn seed_workspace<T: ProjectionNavigationTopology>(
    stored: &mut StoredV2,
    workspace_uuid: WorkspaceUuid,
    selected_override: Option<ScreenUuid>,
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    let screens = topology.screen_order(workspace_uuid).ok_or_else(|| {
        ProjectionNavigationConflict::EntityMissing {
            entity_kind: ProjectionNavigationEntityKind::Workspace,
            entity_uuid: workspace_uuid.as_uuid(),
        }
    })?;
    let viable_screens = screens
        .iter()
        .copied()
        .filter(|screen_uuid| {
            topology.pane_order(*screen_uuid).is_some_and(|panes| !panes.is_empty())
        })
        .collect::<Vec<_>>();
    let Some(first_screen) = viable_screens.first().copied() else {
        return Err(ProjectionNavigationConflict::InvalidSelection {
            entity_kind: ProjectionNavigationEntityKind::Screen,
            reason: "assigned workspace has no presentable screen",
        });
    };
    stored.workspaces.insert(workspace_uuid);
    let selected = selected_override
        .filter(|screen_uuid| viable_screens.contains(screen_uuid))
        .or_else(|| {
            topology
                .legacy_selected_screen(workspace_uuid)
                .filter(|screen_uuid| viable_screens.contains(screen_uuid))
        })
        .unwrap_or(first_screen);
    stored.selected_screen_by_workspace.insert(workspace_uuid, selected);
    if stored.selected_workspace_uuid.is_none() {
        stored.selected_workspace_uuid = Some(workspace_uuid);
    }
    seed_screen(stored, selected, true, topology)?;
    Ok(())
}

fn seed_screen<T: ProjectionNavigationTopology>(
    stored: &mut StoredV2,
    screen_uuid: ScreenUuid,
    use_legacy: bool,
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    let panes = topology.pane_order(screen_uuid).ok_or_else(|| {
        ProjectionNavigationConflict::EntityMissing {
            entity_kind: ProjectionNavigationEntityKind::Screen,
            entity_uuid: screen_uuid.as_uuid(),
        }
    })?;
    let Some(first_pane) = panes.first().copied() else {
        return Err(ProjectionNavigationConflict::InvalidSelection {
            entity_kind: ProjectionNavigationEntityKind::Pane,
            reason: "visited screen has no pane",
        });
    };
    let legacy_zoom = use_legacy
        .then(|| topology.legacy_zoomed_pane(screen_uuid))
        .flatten()
        .filter(|pane_uuid| panes.contains(pane_uuid));
    let active = legacy_zoom
        .or_else(|| {
            stored
                .active_pane_by_screen
                .get(&screen_uuid)
                .copied()
                .filter(|pane_uuid| panes.contains(pane_uuid))
        })
        .or_else(|| {
            use_legacy
                .then(|| topology.legacy_active_pane(screen_uuid))
                .flatten()
                .filter(|pane_uuid| panes.contains(pane_uuid))
        })
        .unwrap_or(first_pane);
    stored.active_pane_by_screen.insert(screen_uuid, active);
    if let Some(zoomed) = legacy_zoom {
        stored.zoomed_pane_by_screen.insert(screen_uuid, zoomed);
    }
    if let Some(zoomed) = stored.zoomed_pane_by_screen.get(&screen_uuid).copied() {
        if panes.contains(&zoomed) {
            stored.active_pane_by_screen.insert(screen_uuid, zoomed);
        } else {
            stored.zoomed_pane_by_screen.remove(&screen_uuid);
        }
    }
    for pane_uuid in panes {
        let surfaces = topology.surface_order(*pane_uuid).ok_or_else(|| {
            ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::Pane,
                entity_uuid: pane_uuid.as_uuid(),
            }
        })?;
        let Some(first_surface) = surfaces.first().copied() else {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::Surface,
                reason: "canonical pane has no surface",
            });
        };
        let selected = stored
            .selected_surface_by_pane
            .get(pane_uuid)
            .copied()
            .filter(|surface_uuid| surfaces.contains(surface_uuid))
            .or_else(|| {
                use_legacy
                    .then(|| topology.legacy_selected_surface(*pane_uuid))
                    .flatten()
                    .filter(|surface_uuid| surfaces.contains(surface_uuid))
            })
            .unwrap_or(first_surface);
        stored.selected_surface_by_pane.insert(*pane_uuid, selected);
    }
    Ok(())
}

fn normalize_record<T: ProjectionNavigationTopology>(
    record: &mut StoredRecord,
    topology: &T,
) -> Result<bool, ProjectionNavigationConflict> {
    if record.reconciled_topology_revision == topology.revision() {
        return Ok(false);
    }
    let StoredPayload::V2(stored) = &mut record.payload else {
        return Ok(false);
    };
    let before = stored.clone();
    let before_revision = record.reconciled_topology_revision;
    let previously_visited = stored.active_pane_by_screen.keys().copied().collect::<BTreeSet<_>>();
    let live_workspaces = stored
        .workspaces
        .iter()
        .copied()
        .filter(|workspace_uuid| {
            topology.screen_order(*workspace_uuid).is_some_and(|screens| {
                screens.iter().any(|screen_uuid| {
                    topology.pane_order(*screen_uuid).is_some_and(|panes| !panes.is_empty())
                })
            })
        })
        .collect::<BTreeSet<_>>();
    stored.workspaces = live_workspaces;
    stored.selected_screen_by_workspace.retain(|workspace_uuid, screen_uuid| {
        stored.workspaces.contains(workspace_uuid)
            && topology.workspace_for_screen(*screen_uuid) == Some(*workspace_uuid)
            && topology.pane_order(*screen_uuid).is_some_and(|panes| !panes.is_empty())
    });
    stored.active_pane_by_screen.retain(|screen_uuid, pane_uuid| {
        topology.screen_for_pane(*pane_uuid) == Some(*screen_uuid)
            && topology
                .workspace_for_screen(*screen_uuid)
                .is_some_and(|workspace_uuid| stored.workspaces.contains(&workspace_uuid))
    });
    stored.zoomed_pane_by_screen.retain(|screen_uuid, pane_uuid| {
        topology.screen_for_pane(*pane_uuid) == Some(*screen_uuid)
            && topology
                .workspace_for_screen(*screen_uuid)
                .is_some_and(|workspace_uuid| stored.workspaces.contains(&workspace_uuid))
    });
    stored.selected_surface_by_pane.retain(|pane_uuid, surface_uuid| {
        topology.pane_for_surface(*surface_uuid) == Some(*pane_uuid)
            && topology
                .screen_for_pane(*pane_uuid)
                .and_then(|screen_uuid| topology.workspace_for_screen(screen_uuid))
                .is_some_and(|workspace_uuid| stored.workspaces.contains(&workspace_uuid))
    });

    let mut screens_to_seed = BTreeSet::new();
    let mut retained_workspaces = stored.workspaces.iter().copied().collect::<Vec<_>>();
    retained_workspaces.sort_unstable_by_key(|workspace_uuid| {
        (topology.workspace_rank(*workspace_uuid).unwrap_or(usize::MAX), workspace_uuid.as_uuid())
    });
    for workspace_uuid in retained_workspaces {
        let screens = topology
            .screen_order(workspace_uuid)
            .expect("retained canonical workspace has screens");
        let first_screen = screens.iter().copied().find(|screen_uuid| {
            topology.pane_order(*screen_uuid).is_some_and(|panes| !panes.is_empty())
        });
        let Some(first_screen) = first_screen else {
            continue;
        };
        stored.selected_screen_by_workspace.entry(workspace_uuid).or_insert(first_screen);
        screens_to_seed.insert(
            *stored
                .selected_screen_by_workspace
                .get(&workspace_uuid)
                .expect("retained workspace has selected screen"),
        );
    }
    screens_to_seed.extend(previously_visited.into_iter().filter(|screen_uuid| {
        topology
            .workspace_for_screen(*screen_uuid)
            .is_some_and(|workspace_uuid| stored.workspaces.contains(&workspace_uuid))
            && topology.pane_order(*screen_uuid).is_some_and(|panes| !panes.is_empty())
    }));
    for screen_uuid in screens_to_seed {
        seed_screen(stored, screen_uuid, false, topology)?;
    }
    if !stored
        .selected_workspace_uuid
        .is_some_and(|workspace_uuid| stored.workspaces.contains(&workspace_uuid))
    {
        stored.selected_workspace_uuid =
            stored.workspaces.iter().copied().min_by_key(|workspace_uuid| {
                (
                    topology.workspace_rank(*workspace_uuid).unwrap_or(usize::MAX),
                    workspace_uuid.as_uuid(),
                )
            });
    }
    record.reconciled_topology_revision = topology.revision();
    Ok(*stored != before || before_revision != topology.revision())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum OperationTarget {
    WorkspaceBinding(WorkspaceUuid),
    SelectedWorkspace,
    SelectedScreen(WorkspaceUuid),
    ActivePane(ScreenUuid),
    ZoomedPane(ScreenUuid),
    SelectedSurface(PaneUuid),
}

fn apply_operations<T: ProjectionNavigationTopology>(
    record: &mut StoredRecord,
    logical_presentation_id: Uuid,
    operations: &[ProjectionNavigationOperation],
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    let StoredPayload::V2(stored) = &mut record.payload else {
        return Err(ProjectionNavigationConflict::SchemaPromoted {
            logical_presentation_id,
            required_capability: "projection-navigation-v2",
        });
    };
    let mut targets = HashSet::new();
    for operation in operations {
        let target = operation_target(operation);
        if !targets.insert(target) {
            let (entity_kind, entity_uuid) = operation_target_identity(target);
            return Err(ProjectionNavigationConflict::DuplicateTarget { entity_kind, entity_uuid });
        }
        match operation {
            ProjectionNavigationOperation::AssignWorkspace { workspace_uuid } => {
                if stored.workspaces.contains(workspace_uuid) {
                    continue;
                }
                seed_workspace(stored, *workspace_uuid, None, topology)?;
            }
            ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid } => {
                remove_workspace(stored, *workspace_uuid, topology);
            }
            ProjectionNavigationOperation::SelectWorkspace { workspace_uuid } => {
                if let Some(workspace_uuid) = workspace_uuid {
                    require_assigned_workspace(stored, *workspace_uuid, logical_presentation_id)?;
                    stored.selected_workspace_uuid = Some(*workspace_uuid);
                } else if stored.workspaces.is_empty() {
                    stored.selected_workspace_uuid = None;
                } else {
                    return Err(ProjectionNavigationConflict::InvalidSelection {
                        entity_kind: ProjectionNavigationEntityKind::Workspace,
                        reason: "a non-empty logical presentation must select a workspace",
                    });
                }
            }
            ProjectionNavigationOperation::SelectScreen { workspace_uuid, screen_uuid } => {
                require_screen(
                    stored,
                    *workspace_uuid,
                    *screen_uuid,
                    logical_presentation_id,
                    topology,
                )?;
                seed_screen(stored, *screen_uuid, false, topology)?;
                stored.selected_screen_by_workspace.insert(*workspace_uuid, *screen_uuid);
            }
            ProjectionNavigationOperation::ActivatePane {
                workspace_uuid,
                screen_uuid,
                pane_uuid,
            } => {
                require_pane(
                    stored,
                    *workspace_uuid,
                    *screen_uuid,
                    *pane_uuid,
                    logical_presentation_id,
                    topology,
                )?;
                seed_screen(stored, *screen_uuid, false, topology)?;
                stored.active_pane_by_screen.insert(*screen_uuid, *pane_uuid);
                if stored.zoomed_pane_by_screen.get(screen_uuid) != Some(pane_uuid) {
                    stored.zoomed_pane_by_screen.remove(screen_uuid);
                }
            }
            ProjectionNavigationOperation::SetZoomedPane {
                workspace_uuid,
                screen_uuid,
                pane_uuid,
            } => {
                require_screen(
                    stored,
                    *workspace_uuid,
                    *screen_uuid,
                    logical_presentation_id,
                    topology,
                )?;
                seed_screen(stored, *screen_uuid, false, topology)?;
                if let Some(pane_uuid) = pane_uuid {
                    require_pane(
                        stored,
                        *workspace_uuid,
                        *screen_uuid,
                        *pane_uuid,
                        logical_presentation_id,
                        topology,
                    )?;
                    stored.zoomed_pane_by_screen.insert(*screen_uuid, *pane_uuid);
                    stored.active_pane_by_screen.insert(*screen_uuid, *pane_uuid);
                } else {
                    stored.zoomed_pane_by_screen.remove(screen_uuid);
                }
            }
            ProjectionNavigationOperation::SelectSurface {
                workspace_uuid,
                screen_uuid,
                pane_uuid,
                surface_uuid,
            } => {
                require_pane(
                    stored,
                    *workspace_uuid,
                    *screen_uuid,
                    *pane_uuid,
                    logical_presentation_id,
                    topology,
                )?;
                seed_screen(stored, *screen_uuid, false, topology)?;
                if topology.pane_for_surface(*surface_uuid) != Some(*pane_uuid) {
                    return Err(ProjectionNavigationConflict::AncestryMismatch {
                        entity_kind: ProjectionNavigationEntityKind::Surface,
                        entity_uuid: surface_uuid.as_uuid(),
                        parent_kind: ProjectionNavigationEntityKind::Pane,
                        expected_parent_uuid: pane_uuid.as_uuid(),
                        actual_parent_uuid: topology
                            .pane_for_surface(*surface_uuid)
                            .map(PaneUuid::as_uuid),
                    });
                }
                stored.selected_surface_by_pane.insert(*pane_uuid, *surface_uuid);
            }
        }
    }
    validate_v2_invariants(stored, logical_presentation_id, topology)
}

fn operation_target(operation: &ProjectionNavigationOperation) -> OperationTarget {
    match operation {
        ProjectionNavigationOperation::AssignWorkspace { workspace_uuid }
        | ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid } => {
            OperationTarget::WorkspaceBinding(*workspace_uuid)
        }
        ProjectionNavigationOperation::SelectWorkspace { .. } => OperationTarget::SelectedWorkspace,
        ProjectionNavigationOperation::SelectScreen { workspace_uuid, .. } => {
            OperationTarget::SelectedScreen(*workspace_uuid)
        }
        ProjectionNavigationOperation::ActivatePane { screen_uuid, .. } => {
            OperationTarget::ActivePane(*screen_uuid)
        }
        ProjectionNavigationOperation::SetZoomedPane { screen_uuid, .. } => {
            OperationTarget::ZoomedPane(*screen_uuid)
        }
        ProjectionNavigationOperation::SelectSurface { pane_uuid, .. } => {
            OperationTarget::SelectedSurface(*pane_uuid)
        }
    }
}

fn operation_target_identity(target: OperationTarget) -> (ProjectionNavigationEntityKind, Uuid) {
    match target {
        OperationTarget::WorkspaceBinding(workspace_uuid)
        | OperationTarget::SelectedScreen(workspace_uuid) => {
            (ProjectionNavigationEntityKind::Workspace, workspace_uuid.as_uuid())
        }
        OperationTarget::SelectedWorkspace => {
            (ProjectionNavigationEntityKind::LogicalPresentation, Uuid::nil())
        }
        OperationTarget::ActivePane(screen_uuid) | OperationTarget::ZoomedPane(screen_uuid) => {
            (ProjectionNavigationEntityKind::Screen, screen_uuid.as_uuid())
        }
        OperationTarget::SelectedSurface(pane_uuid) => {
            (ProjectionNavigationEntityKind::Pane, pane_uuid.as_uuid())
        }
    }
}

fn require_assigned_workspace(
    stored: &StoredV2,
    workspace_uuid: WorkspaceUuid,
    logical_presentation_id: Uuid,
) -> Result<(), ProjectionNavigationConflict> {
    if stored.workspaces.contains(&workspace_uuid) {
        Ok(())
    } else {
        Err(ProjectionNavigationConflict::AncestryMismatch {
            entity_kind: ProjectionNavigationEntityKind::Workspace,
            entity_uuid: workspace_uuid.as_uuid(),
            parent_kind: ProjectionNavigationEntityKind::LogicalPresentation,
            expected_parent_uuid: logical_presentation_id,
            actual_parent_uuid: None,
        })
    }
}

fn require_screen<T: ProjectionNavigationTopology>(
    stored: &StoredV2,
    workspace_uuid: WorkspaceUuid,
    screen_uuid: ScreenUuid,
    logical_presentation_id: Uuid,
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    require_assigned_workspace(stored, workspace_uuid, logical_presentation_id)?;
    if topology.workspace_for_screen(screen_uuid) == Some(workspace_uuid) {
        Ok(())
    } else {
        Err(ProjectionNavigationConflict::AncestryMismatch {
            entity_kind: ProjectionNavigationEntityKind::Screen,
            entity_uuid: screen_uuid.as_uuid(),
            parent_kind: ProjectionNavigationEntityKind::Workspace,
            expected_parent_uuid: workspace_uuid.as_uuid(),
            actual_parent_uuid: topology
                .workspace_for_screen(screen_uuid)
                .map(WorkspaceUuid::as_uuid),
        })
    }
}

fn require_pane<T: ProjectionNavigationTopology>(
    stored: &StoredV2,
    workspace_uuid: WorkspaceUuid,
    screen_uuid: ScreenUuid,
    pane_uuid: PaneUuid,
    logical_presentation_id: Uuid,
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    require_screen(stored, workspace_uuid, screen_uuid, logical_presentation_id, topology)?;
    if topology.screen_for_pane(pane_uuid) == Some(screen_uuid) {
        Ok(())
    } else {
        Err(ProjectionNavigationConflict::AncestryMismatch {
            entity_kind: ProjectionNavigationEntityKind::Pane,
            entity_uuid: pane_uuid.as_uuid(),
            parent_kind: ProjectionNavigationEntityKind::Screen,
            expected_parent_uuid: screen_uuid.as_uuid(),
            actual_parent_uuid: topology.screen_for_pane(pane_uuid).map(ScreenUuid::as_uuid),
        })
    }
}

fn validate_v2_invariants<T: ProjectionNavigationTopology>(
    stored: &StoredV2,
    logical_presentation_id: Uuid,
    topology: &T,
) -> Result<(), ProjectionNavigationConflict> {
    match stored.selected_workspace_uuid {
        Some(workspace_uuid) => {
            require_assigned_workspace(stored, workspace_uuid, logical_presentation_id)?;
        }
        None if !stored.workspaces.is_empty() => {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::Workspace,
                reason: "a non-empty logical presentation must select a workspace",
            });
        }
        None => {}
    }
    for workspace_uuid in &stored.workspaces {
        let Some(selected_screen_uuid) =
            stored.selected_screen_by_workspace.get(workspace_uuid).copied()
        else {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::Screen,
                reason: "an assigned workspace must select a screen",
            });
        };
        require_screen(
            stored,
            *workspace_uuid,
            selected_screen_uuid,
            logical_presentation_id,
            topology,
        )?;
        if !stored.active_pane_by_screen.contains_key(&selected_screen_uuid) {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::Pane,
                reason: "a selected screen must have an active pane",
            });
        }
    }
    for (screen_uuid, pane_uuid) in &stored.active_pane_by_screen {
        let Some(workspace_uuid) = topology.workspace_for_screen(*screen_uuid) else {
            return Err(ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::Screen,
                entity_uuid: screen_uuid.as_uuid(),
            });
        };
        require_pane(
            stored,
            workspace_uuid,
            *screen_uuid,
            *pane_uuid,
            logical_presentation_id,
            topology,
        )?;
    }
    for (screen_uuid, pane_uuid) in &stored.zoomed_pane_by_screen {
        if stored.active_pane_by_screen.get(screen_uuid) != Some(pane_uuid) {
            return Err(ProjectionNavigationConflict::InvalidSelection {
                entity_kind: ProjectionNavigationEntityKind::Pane,
                reason: "a zoomed pane must also be active",
            });
        }
    }
    for (pane_uuid, surface_uuid) in &stored.selected_surface_by_pane {
        if topology.pane_for_surface(*surface_uuid) != Some(*pane_uuid) {
            return Err(ProjectionNavigationConflict::AncestryMismatch {
                entity_kind: ProjectionNavigationEntityKind::Surface,
                entity_uuid: surface_uuid.as_uuid(),
                parent_kind: ProjectionNavigationEntityKind::Pane,
                expected_parent_uuid: pane_uuid.as_uuid(),
                actual_parent_uuid: topology.pane_for_surface(*surface_uuid).map(PaneUuid::as_uuid),
            });
        }
        let Some(screen_uuid) = topology.screen_for_pane(*pane_uuid) else {
            return Err(ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::Pane,
                entity_uuid: pane_uuid.as_uuid(),
            });
        };
        let Some(workspace_uuid) = topology.workspace_for_screen(screen_uuid) else {
            return Err(ProjectionNavigationConflict::EntityMissing {
                entity_kind: ProjectionNavigationEntityKind::Screen,
                entity_uuid: screen_uuid.as_uuid(),
            });
        };
        require_assigned_workspace(stored, workspace_uuid, logical_presentation_id)?;
    }
    Ok(())
}

fn remove_workspace<T: ProjectionNavigationTopology>(
    stored: &mut StoredV2,
    workspace_uuid: WorkspaceUuid,
    topology: &T,
) {
    stored.workspaces.remove(&workspace_uuid);
    stored.selected_screen_by_workspace.remove(&workspace_uuid);
    stored.active_pane_by_screen.retain(|screen_uuid, _| {
        topology.workspace_for_screen(*screen_uuid) != Some(workspace_uuid)
    });
    stored.zoomed_pane_by_screen.retain(|screen_uuid, _| {
        topology.workspace_for_screen(*screen_uuid) != Some(workspace_uuid)
    });
    stored.selected_surface_by_pane.retain(|pane_uuid, _| {
        topology
            .screen_for_pane(*pane_uuid)
            .and_then(|screen_uuid| topology.workspace_for_screen(screen_uuid))
            != Some(workspace_uuid)
    });
    if stored.selected_workspace_uuid == Some(workspace_uuid) {
        stored.selected_workspace_uuid =
            stored.workspaces.iter().copied().min_by_key(|candidate| {
                (topology.workspace_rank(*candidate).unwrap_or(usize::MAX), candidate.as_uuid())
            });
    }
}

fn wire_state<T: ProjectionNavigationTopology>(
    key: ProjectionKey,
    record: &StoredRecord,
    claimant: ProjectionNavigationClaimant,
    topology: &T,
) -> ProjectionNavigationState {
    let StoredPayload::V2(stored) = &record.payload else {
        unreachable!("v1 state must be promoted before v2 serialization")
    };
    let mut workspace_order = stored.workspaces.iter().copied().collect::<Vec<_>>();
    workspace_order.sort_unstable_by_key(|workspace_uuid| {
        (topology.workspace_rank(*workspace_uuid).unwrap_or(usize::MAX), workspace_uuid.as_uuid())
    });
    let mut screens_by_workspace = HashMap::<WorkspaceUuid, Vec<ScreenUuid>>::new();
    for screen_uuid in stored.active_pane_by_screen.keys().copied() {
        if let Some(workspace_uuid) = topology.workspace_for_screen(screen_uuid)
            && stored.workspaces.contains(&workspace_uuid)
        {
            screens_by_workspace.entry(workspace_uuid).or_default().push(screen_uuid);
        }
    }
    for screens in screens_by_workspace.values_mut() {
        screens.sort_unstable_by_key(|screen_uuid| {
            (topology.screen_rank(*screen_uuid).unwrap_or(usize::MAX), screen_uuid.as_uuid())
        });
    }
    let mut panes_by_screen = HashMap::<ScreenUuid, Vec<PaneUuid>>::new();
    for pane_uuid in stored.selected_surface_by_pane.keys().copied() {
        if let Some(screen_uuid) = topology.screen_for_pane(pane_uuid)
            && stored.active_pane_by_screen.contains_key(&screen_uuid)
        {
            panes_by_screen.entry(screen_uuid).or_default().push(pane_uuid);
        }
    }
    for panes in panes_by_screen.values_mut() {
        panes.sort_unstable_by_key(|pane_uuid| {
            (topology.pane_rank(*pane_uuid).unwrap_or(usize::MAX), pane_uuid.as_uuid())
        });
    }
    let workspaces = workspace_order
        .into_iter()
        .filter_map(|workspace_uuid| {
            let selected_screen_uuid = *stored.selected_screen_by_workspace.get(&workspace_uuid)?;
            let screens = screens_by_workspace
                .remove(&workspace_uuid)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|screen_uuid| {
                    let active_pane_uuid = *stored.active_pane_by_screen.get(&screen_uuid)?;
                    let panes = panes_by_screen
                        .remove(&screen_uuid)
                        .unwrap_or_default()
                        .into_iter()
                        .filter_map(|pane_uuid| {
                            let selected_surface_uuid =
                                *stored.selected_surface_by_pane.get(&pane_uuid)?;
                            Some(ProjectionNavigationPaneState { pane_uuid, selected_surface_uuid })
                        })
                        .collect();
                    Some(ProjectionNavigationScreenState {
                        screen_uuid,
                        active_pane_uuid,
                        zoomed_pane_uuid: stored.zoomed_pane_by_screen.get(&screen_uuid).copied(),
                        panes,
                    })
                })
                .collect();
            Some(ProjectionNavigationWorkspaceState {
                workspace_uuid,
                selected_screen_uuid,
                screens,
            })
        })
        .collect();
    let visible_claim = record.claim.as_ref().filter(|claim| claim.claimant == claimant);
    ProjectionNavigationState {
        schema_version: PROJECTION_NAVIGATION_SCHEMA_VERSION,
        logical_presentation_id: key.logical_presentation_id,
        generation: record.generation,
        claim_id: visible_claim.map(|claim| claim.id),
        claimed_process_instance_uuid: visible_claim
            .map(|claim| claim.claimant.process_instance_uuid),
        reconciled_topology_revision: record.reconciled_topology_revision,
        selected_workspace_uuid: stored.selected_workspace_uuid,
        workspaces,
    }
}

fn v2_wire_state<T: ProjectionNavigationTopology>(
    key: ProjectionKey,
    record: &StoredRecord,
    claimant: ProjectionNavigationClaimant,
    topology: &T,
) -> Result<ProjectionNavigationState, ProjectionNavigationConflict> {
    if matches!(record.payload, StoredPayload::V2(_)) {
        return Ok(wire_state(key, record, claimant, topology));
    }
    let mut promoted = record.clone();
    let claim = promoted.claim.clone();
    promote_record(&mut promoted, topology)?;
    // Release validates the legacy claim before this response-only promotion.
    // Preserve its visibility in a stale-generation conflict without
    // committing a partial schema conversion.
    promoted.claim = claim;
    Ok(wire_state(key, &promoted, claimant, topology))
}

fn insert_record(inner: &mut RegistryInner, key: ProjectionKey, record: StoredRecord) {
    inner
        .logical_presentations_by_client
        .entry(key.client_uuid)
        .or_default()
        .insert(key.logical_presentation_id);
    add_record_indexes(inner, key, &record);
    let previous = inner.records.insert(key, record);
    debug_assert!(previous.is_none());
}

fn has_client_schema_floor(inner: &RegistryInner, client_uuid: Uuid) -> bool {
    inner.v2_schema_floor_clients.contains(&client_uuid)
}

fn establish_schema_floor(inner: &mut RegistryInner, client_uuid: Uuid) {
    inner.v2_schema_floor_clients.insert(client_uuid);
}

fn client_revision(inner: &RegistryInner, client_uuid: Uuid) -> u64 {
    inner.client_revisions.get(&client_uuid).copied().unwrap_or(0)
}

fn prospective_client_revision(
    inner: &RegistryInner,
    client_uuid: Uuid,
    changed: bool,
) -> Result<u64, ProjectionNavigationConflict> {
    let current = client_revision(inner, client_uuid);
    if changed {
        current.checked_add(1).ok_or(ProjectionNavigationConflict::ClientRevisionExhausted)
    } else {
        Ok(current)
    }
}

fn set_client_revision(inner: &mut RegistryInner, client_uuid: Uuid, revision: u64) {
    inner.client_revisions.insert(client_uuid, revision);
    inner.list_snapshot_revisions.remove(&client_uuid);
}

fn replace_records(inner: &mut RegistryInner, replacements: &[(ProjectionKey, StoredRecord)]) {
    if replacements.is_empty() {
        return;
    }
    for (key, _) in replacements {
        if let Some(old) = inner.records.get(key).cloned() {
            remove_record_indexes(inner, *key, &old);
        }
    }
    for (key, replacement) in replacements {
        add_record_indexes(inner, *key, replacement);
        inner.records.insert(*key, replacement.clone());
    }
}

fn remove_record(inner: &mut RegistryInner, key: ProjectionKey) {
    let Some(record) = inner.records.remove(&key) else {
        return;
    };
    remove_record_indexes(inner, key, &record);
    if let Some(identifiers) = inner.logical_presentations_by_client.get_mut(&key.client_uuid) {
        identifiers.remove(&key.logical_presentation_id);
        if identifiers.is_empty() {
            inner.logical_presentations_by_client.remove(&key.client_uuid);
        }
    }
}

fn add_record_indexes(inner: &mut RegistryInner, key: ProjectionKey, record: &StoredRecord) {
    if let Some(claim) = &record.claim {
        inner.claims_by_connection.entry(claim.claimant.connection_id).or_default().insert(key);
    }
    for workspace_uuid in record.workspaces() {
        let previous = inner.workspace_owner.insert((key.client_uuid, workspace_uuid), key);
        debug_assert!(previous.is_none() || previous == Some(key));
    }
    let counts = record.counts();
    inner.workspace_bindings += counts.workspaces;
    inner.screen_preferences += counts.screens;
    inner.pane_preferences += counts.panes;
}

fn remove_record_indexes(inner: &mut RegistryInner, key: ProjectionKey, record: &StoredRecord) {
    if let Some(claim) = &record.claim
        && let Some(keys) = inner.claims_by_connection.get_mut(&claim.claimant.connection_id)
    {
        keys.remove(&key);
        if keys.is_empty() {
            inner.claims_by_connection.remove(&claim.claimant.connection_id);
        }
    }
    for workspace_uuid in record.workspaces() {
        if inner.workspace_owner.get(&(key.client_uuid, workspace_uuid)) == Some(&key) {
            inner.workspace_owner.remove(&(key.client_uuid, workspace_uuid));
        }
    }
    let counts = record.counts();
    inner.workspace_bindings = inner.workspace_bindings.saturating_sub(counts.workspaces);
    inner.screen_preferences = inner.screen_preferences.saturating_sub(counts.screens);
    inner.pane_preferences = inner.pane_preferences.saturating_sub(counts.panes);
}

fn mutation_request_digest(
    claimant: ProjectionNavigationClaimant,
    expectation: ProjectionNavigationTopologyExpectation,
    batch: &ProjectionNavigationMutationBatch,
) -> [u8; 32] {
    request_digest("mutate-projection-navigation-v2", claimant, expectation, batch)
}

fn release_request_digest(
    claimant: ProjectionNavigationClaimant,
    expectation: ProjectionNavigationTopologyExpectation,
    request: &ProjectionNavigationReleaseRequest,
) -> [u8; 32] {
    request_digest("release-projection-navigation-v2", claimant, expectation, request)
}

fn request_digest<T: Serialize>(
    command: &'static str,
    claimant: ProjectionNavigationClaimant,
    expectation: ProjectionNavigationTopologyExpectation,
    request: &T,
) -> [u8; 32] {
    let bytes = serde_json::to_vec(&(command, claimant, expectation, request))
        .expect("projection navigation request serialization is infallible");
    let digest = Sha256::digest(bytes);
    let mut result = [0_u8; 32];
    result.copy_from_slice(&digest);
    result
}

fn serialized_response_bytes(response: &ProjectionNavigationResponse) -> usize {
    serde_json::to_vec(response)
        .expect("projection navigation response serialization is infallible")
        .len()
}

fn store_replay_receipt(
    inner: &mut RegistryInner,
    key: ReplayKey,
    receipt: ReplayReceipt,
    limits: ProjectionNavigationLimits,
) {
    while inner
        .replay_order_by_client
        .get(&key.client_uuid)
        .is_some_and(|order| order.len() >= limits.replay_receipts_per_client)
        || inner
            .replay_bytes_by_client
            .get(&key.client_uuid)
            .copied()
            .unwrap_or(0)
            .saturating_add(receipt.response_bytes)
            > limits.replay_receipt_bytes_per_client
    {
        let oldest = inner
            .replay_order_by_client
            .get(&key.client_uuid)
            .and_then(|order| order.front().copied())
            .expect("validated replay receipt must fit an empty per-client ledger");
        remove_replay_receipt(
            inner,
            ReplayKey { client_uuid: key.client_uuid, request_id: oldest },
        );
    }
    while inner.replay_order_global.len() >= limits.replay_receipts_global
        || inner.replay_bytes_global.saturating_add(receipt.response_bytes)
            > limits.replay_receipt_bytes_global
    {
        let oldest = *inner
            .replay_order_global
            .front()
            .expect("validated replay receipt must fit an empty global ledger");
        remove_replay_receipt(inner, oldest);
    }

    inner.replay_order_by_client.entry(key.client_uuid).or_default().push_back(key.request_id);
    inner.replay_order_global.push_back(key);
    *inner.replay_bytes_by_client.entry(key.client_uuid).or_default() += receipt.response_bytes;
    inner.replay_bytes_global += receipt.response_bytes;
    let previous = inner.replay_receipts.insert(key, receipt);
    debug_assert!(previous.is_none());
}

fn remove_replay_receipt(inner: &mut RegistryInner, key: ReplayKey) {
    let Some(receipt) = inner.replay_receipts.remove(&key) else {
        return;
    };
    let remove_client_order =
        if let Some(order) = inner.replay_order_by_client.get_mut(&key.client_uuid) {
            order.retain(|request_id| *request_id != key.request_id);
            order.is_empty()
        } else {
            false
        };
    if remove_client_order {
        inner.replay_order_by_client.remove(&key.client_uuid);
    }
    inner.replay_order_global.retain(|candidate| *candidate != key);
    let remove_client_bytes =
        if let Some(bytes) = inner.replay_bytes_by_client.get_mut(&key.client_uuid) {
            *bytes = bytes.saturating_sub(receipt.response_bytes);
            *bytes == 0
        } else {
            false
        };
    if remove_client_bytes {
        inner.replay_bytes_by_client.remove(&key.client_uuid);
    }
    inner.replay_bytes_global = inner.replay_bytes_global.saturating_sub(receipt.response_bytes);
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

    use super::*;

    #[derive(Clone)]
    struct FixtureTopology {
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        revision: u64,
        workspace_order: Vec<WorkspaceUuid>,
        workspace_rank: HashMap<WorkspaceUuid, usize>,
        screens: HashMap<WorkspaceUuid, Vec<ScreenUuid>>,
        screen_rank: HashMap<ScreenUuid, usize>,
        panes: HashMap<ScreenUuid, Vec<PaneUuid>>,
        pane_rank: HashMap<PaneUuid, usize>,
        surfaces: HashMap<PaneUuid, Vec<SurfaceUuid>>,
        surface_rank: HashMap<SurfaceUuid, usize>,
        workspace_by_screen: HashMap<ScreenUuid, WorkspaceUuid>,
        screen_by_pane: HashMap<PaneUuid, ScreenUuid>,
        pane_by_surface: HashMap<SurfaceUuid, PaneUuid>,
        legacy_selected_screen: HashMap<WorkspaceUuid, ScreenUuid>,
        legacy_active_pane: HashMap<ScreenUuid, PaneUuid>,
        legacy_zoomed_pane: HashMap<ScreenUuid, PaneUuid>,
        legacy_selected_surface: HashMap<PaneUuid, SurfaceUuid>,
    }

    impl FixtureTopology {
        fn empty() -> Self {
            Self {
                daemon_instance_id: daemon(1),
                session_id: session(2),
                revision: 1,
                workspace_order: Vec::new(),
                workspace_rank: HashMap::new(),
                screens: HashMap::new(),
                screen_rank: HashMap::new(),
                panes: HashMap::new(),
                pane_rank: HashMap::new(),
                surfaces: HashMap::new(),
                surface_rank: HashMap::new(),
                workspace_by_screen: HashMap::new(),
                screen_by_pane: HashMap::new(),
                pane_by_surface: HashMap::new(),
                legacy_selected_screen: HashMap::new(),
                legacy_active_pane: HashMap::new(),
                legacy_zoomed_pane: HashMap::new(),
                legacy_selected_surface: HashMap::new(),
            }
        }

        fn two_workspaces() -> Self {
            let w1 = workspace(101);
            let w2 = workspace(102);
            let s1 = screen(201);
            let s2 = screen(202);
            let s3 = screen(203);
            let p1 = pane(301);
            let p2 = pane(302);
            let p3 = pane(303);
            let p4 = pane(304);
            let f1 = surface(401);
            let f2 = surface(402);
            let f3 = surface(403);
            let f4 = surface(404);
            let f5 = surface(405);
            let mut topology = Self::empty();
            topology.workspace_order = vec![w1, w2];
            topology.screens.insert(w1, vec![s1, s2]);
            topology.screens.insert(w2, vec![s3]);
            topology.panes.insert(s1, vec![p1, p2]);
            topology.panes.insert(s2, vec![p3]);
            topology.panes.insert(s3, vec![p4]);
            topology.surfaces.insert(p1, vec![f1, f2]);
            topology.surfaces.insert(p2, vec![f3]);
            topology.surfaces.insert(p3, vec![f5]);
            topology.surfaces.insert(p4, vec![f4]);
            topology.workspace_by_screen = HashMap::from([(s1, w1), (s2, w1), (s3, w2)]);
            topology.screen_by_pane = HashMap::from([(p1, s1), (p2, s1), (p3, s2), (p4, s3)]);
            topology.pane_by_surface =
                HashMap::from([(f1, p1), (f2, p1), (f3, p2), (f4, p4), (f5, p3)]);
            topology.legacy_selected_screen = HashMap::from([(w1, s2), (w2, s3)]);
            topology.legacy_active_pane = HashMap::from([(s1, p2), (s2, p3), (s3, p4)]);
            topology.legacy_zoomed_pane = HashMap::from([(s1, p2)]);
            topology.legacy_selected_surface =
                HashMap::from([(p1, f2), (p2, f3), (p3, f5), (p4, f4)]);
            topology.rebuild_ranks();
            topology
        }

        fn many_screens(count: usize) -> Self {
            let workspace_uuid = workspace(10_000);
            let mut topology = Self::empty();
            topology.workspace_order.push(workspace_uuid);
            let mut screens = Vec::with_capacity(count);
            for index in 0..count as u128 {
                let screen_uuid = screen(20_000 + index);
                let pane_uuid = pane(30_000 + index);
                let surface_uuid = surface(40_000 + index);
                screens.push(screen_uuid);
                topology.panes.insert(screen_uuid, vec![pane_uuid]);
                topology.surfaces.insert(pane_uuid, vec![surface_uuid]);
                topology.workspace_by_screen.insert(screen_uuid, workspace_uuid);
                topology.screen_by_pane.insert(pane_uuid, screen_uuid);
                topology.pane_by_surface.insert(surface_uuid, pane_uuid);
                topology.legacy_active_pane.insert(screen_uuid, pane_uuid);
                topology.legacy_selected_surface.insert(pane_uuid, surface_uuid);
            }
            topology.screens.insert(workspace_uuid, screens.clone());
            if let Some(selected) = screens.last().copied() {
                topology.legacy_selected_screen.insert(workspace_uuid, selected);
            }
            topology.rebuild_ranks();
            topology
        }

        fn many_workspaces(count: usize) -> Self {
            let mut topology = Self::empty();
            for index in 0..count as u128 {
                let workspace_uuid = workspace(100_000 + index);
                let screen_uuid = screen(200_000 + index);
                let pane_uuid = pane(300_000 + index);
                let surface_uuid = surface(400_000 + index);
                topology.workspace_order.push(workspace_uuid);
                topology.screens.insert(workspace_uuid, vec![screen_uuid]);
                topology.panes.insert(screen_uuid, vec![pane_uuid]);
                topology.surfaces.insert(pane_uuid, vec![surface_uuid]);
                topology.workspace_by_screen.insert(screen_uuid, workspace_uuid);
                topology.screen_by_pane.insert(pane_uuid, screen_uuid);
                topology.pane_by_surface.insert(surface_uuid, pane_uuid);
                topology.legacy_selected_screen.insert(workspace_uuid, screen_uuid);
                topology.legacy_active_pane.insert(screen_uuid, pane_uuid);
                topology.legacy_selected_surface.insert(pane_uuid, surface_uuid);
            }
            topology.rebuild_ranks();
            topology
        }

        fn many_large_workspaces(workspace_count: usize, panes_per_workspace: usize) -> Self {
            let mut topology = Self::empty();
            for workspace_index in 0..workspace_count as u128 {
                let workspace_uuid = workspace(1_000_000 + workspace_index);
                let screen_uuid = screen(2_000_000 + workspace_index);
                topology.workspace_order.push(workspace_uuid);
                topology.screens.insert(workspace_uuid, vec![screen_uuid]);
                topology.workspace_by_screen.insert(screen_uuid, workspace_uuid);
                topology.legacy_selected_screen.insert(workspace_uuid, screen_uuid);
                let mut panes = Vec::with_capacity(panes_per_workspace);
                for pane_index in 0..panes_per_workspace as u128 {
                    let ordinal = workspace_index * panes_per_workspace as u128 + pane_index;
                    let pane_uuid = pane(3_000_000 + ordinal);
                    let surface_uuid = surface(6_000_000 + ordinal);
                    panes.push(pane_uuid);
                    topology.surfaces.insert(pane_uuid, vec![surface_uuid]);
                    topology.screen_by_pane.insert(pane_uuid, screen_uuid);
                    topology.pane_by_surface.insert(surface_uuid, pane_uuid);
                    topology.legacy_selected_surface.insert(pane_uuid, surface_uuid);
                }
                if let Some(active) = panes.first().copied() {
                    topology.legacy_active_pane.insert(screen_uuid, active);
                }
                topology.panes.insert(screen_uuid, panes);
            }
            topology.rebuild_ranks();
            topology
        }

        fn rebuild_ranks(&mut self) {
            self.workspace_rank.clear();
            self.screen_rank.clear();
            self.pane_rank.clear();
            self.surface_rank.clear();
            for (rank, workspace_uuid) in self.workspace_order.iter().copied().enumerate() {
                self.workspace_rank.insert(workspace_uuid, rank);
            }
            for screens in self.screens.values() {
                for (rank, screen_uuid) in screens.iter().copied().enumerate() {
                    self.screen_rank.insert(screen_uuid, rank);
                }
            }
            for panes in self.panes.values() {
                for (rank, pane_uuid) in panes.iter().copied().enumerate() {
                    self.pane_rank.insert(pane_uuid, rank);
                }
            }
            for surfaces in self.surfaces.values() {
                for (rank, surface_uuid) in surfaces.iter().copied().enumerate() {
                    self.surface_rank.insert(surface_uuid, rank);
                }
            }
        }

        fn move_pane(&mut self, pane: PaneUuid, from: ScreenUuid, to: ScreenUuid) {
            self.panes.get_mut(&from).unwrap().retain(|candidate| *candidate != pane);
            self.panes.get_mut(&to).unwrap().push(pane);
            self.screen_by_pane.insert(pane, to);
            self.rebuild_ranks();
            self.revision += 1;
        }

        fn move_surface(&mut self, value: SurfaceUuid, from: PaneUuid, to: PaneUuid) {
            self.surfaces.get_mut(&from).unwrap().retain(|candidate| *candidate != value);
            self.surfaces.get_mut(&to).unwrap().push(value);
            self.pane_by_surface.insert(value, to);
            self.rebuild_ranks();
            self.revision += 1;
        }

        fn reorder_workspaces(&mut self, order: Vec<WorkspaceUuid>) {
            self.workspace_order = order;
            self.rebuild_ranks();
            self.revision += 1;
        }

        fn remove_workspace(&mut self, workspace_uuid: WorkspaceUuid) {
            self.workspace_order.retain(|candidate| *candidate != workspace_uuid);
            for screen_uuid in self.screens.remove(&workspace_uuid).unwrap_or_default() {
                self.workspace_by_screen.remove(&screen_uuid);
            }
            self.rebuild_ranks();
            self.revision += 1;
        }

        fn empty_workspace(&mut self, workspace_uuid: WorkspaceUuid) {
            for screen_uuid in self.screens.get(&workspace_uuid).cloned().unwrap_or_default() {
                for pane_uuid in self.panes.insert(screen_uuid, Vec::new()).unwrap_or_default() {
                    self.screen_by_pane.remove(&pane_uuid);
                }
            }
            self.rebuild_ranks();
            self.revision += 1;
        }
    }

    impl ProjectionNavigationTopology for FixtureTopology {
        fn daemon_instance_id(&self) -> DaemonInstanceId {
            self.daemon_instance_id
        }

        fn session_id(&self) -> SessionId {
            self.session_id
        }

        fn revision(&self) -> u64 {
            self.revision
        }

        fn workspace_order(&self) -> &[WorkspaceUuid] {
            &self.workspace_order
        }

        fn screen_order(&self, workspace: WorkspaceUuid) -> Option<&[ScreenUuid]> {
            self.screens.get(&workspace).map(Vec::as_slice)
        }

        fn pane_order(&self, screen: ScreenUuid) -> Option<&[PaneUuid]> {
            self.panes.get(&screen).map(Vec::as_slice)
        }

        fn surface_order(&self, pane: PaneUuid) -> Option<&[SurfaceUuid]> {
            self.surfaces.get(&pane).map(Vec::as_slice)
        }

        fn workspace_rank(&self, workspace: WorkspaceUuid) -> Option<usize> {
            self.workspace_rank.get(&workspace).copied()
        }

        fn screen_rank(&self, screen: ScreenUuid) -> Option<usize> {
            self.screen_rank.get(&screen).copied()
        }

        fn pane_rank(&self, pane: PaneUuid) -> Option<usize> {
            self.pane_rank.get(&pane).copied()
        }

        fn surface_rank(&self, surface: SurfaceUuid) -> Option<usize> {
            self.surface_rank.get(&surface).copied()
        }

        fn workspace_for_screen(&self, screen: ScreenUuid) -> Option<WorkspaceUuid> {
            self.workspace_by_screen.get(&screen).copied()
        }

        fn screen_for_pane(&self, pane: PaneUuid) -> Option<ScreenUuid> {
            self.screen_by_pane.get(&pane).copied()
        }

        fn pane_for_surface(&self, surface: SurfaceUuid) -> Option<PaneUuid> {
            self.pane_by_surface.get(&surface).copied()
        }

        fn legacy_selected_screen(&self, workspace: WorkspaceUuid) -> Option<ScreenUuid> {
            self.legacy_selected_screen.get(&workspace).copied()
        }

        fn legacy_active_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.legacy_active_pane.get(&screen).copied()
        }

        fn legacy_zoomed_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.legacy_zoomed_pane.get(&screen).copied()
        }

        fn legacy_selected_surface(&self, pane: PaneUuid) -> Option<SurfaceUuid> {
            self.legacy_selected_surface.get(&pane).copied()
        }
    }

    #[derive(Default)]
    struct TopologyAccessCounts {
        workspace_order_items: AtomicUsize,
        screen_order_items: AtomicUsize,
        pane_order_items: AtomicUsize,
        surface_order_items: AtomicUsize,
        rank_lookups: AtomicUsize,
        ancestry_lookups: AtomicUsize,
    }

    struct CountingTopology {
        inner: FixtureTopology,
        counts: Arc<TopologyAccessCounts>,
    }

    impl ProjectionNavigationTopology for CountingTopology {
        fn daemon_instance_id(&self) -> DaemonInstanceId {
            self.inner.daemon_instance_id()
        }

        fn session_id(&self) -> SessionId {
            self.inner.session_id()
        }

        fn revision(&self) -> u64 {
            self.inner.revision()
        }

        fn workspace_order(&self) -> &[WorkspaceUuid] {
            self.counts
                .workspace_order_items
                .fetch_add(self.inner.workspace_order.len(), Ordering::Relaxed);
            self.inner.workspace_order()
        }

        fn screen_order(&self, workspace: WorkspaceUuid) -> Option<&[ScreenUuid]> {
            let value = self.inner.screen_order(workspace);
            self.counts
                .screen_order_items
                .fetch_add(value.map_or(0, |items| items.len()), Ordering::Relaxed);
            value
        }

        fn pane_order(&self, screen: ScreenUuid) -> Option<&[PaneUuid]> {
            let value = self.inner.pane_order(screen);
            self.counts
                .pane_order_items
                .fetch_add(value.map_or(0, |items| items.len()), Ordering::Relaxed);
            value
        }

        fn surface_order(&self, pane: PaneUuid) -> Option<&[SurfaceUuid]> {
            let value = self.inner.surface_order(pane);
            self.counts
                .surface_order_items
                .fetch_add(value.map_or(0, |items| items.len()), Ordering::Relaxed);
            value
        }

        fn workspace_rank(&self, workspace: WorkspaceUuid) -> Option<usize> {
            self.counts.rank_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.workspace_rank(workspace)
        }

        fn screen_rank(&self, screen: ScreenUuid) -> Option<usize> {
            self.counts.rank_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.screen_rank(screen)
        }

        fn pane_rank(&self, pane: PaneUuid) -> Option<usize> {
            self.counts.rank_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.pane_rank(pane)
        }

        fn surface_rank(&self, surface: SurfaceUuid) -> Option<usize> {
            self.counts.rank_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.surface_rank(surface)
        }

        fn workspace_for_screen(&self, screen: ScreenUuid) -> Option<WorkspaceUuid> {
            self.counts.ancestry_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.workspace_for_screen(screen)
        }

        fn screen_for_pane(&self, pane: PaneUuid) -> Option<ScreenUuid> {
            self.counts.ancestry_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.screen_for_pane(pane)
        }

        fn pane_for_surface(&self, surface: SurfaceUuid) -> Option<PaneUuid> {
            self.counts.ancestry_lookups.fetch_add(1, Ordering::Relaxed);
            self.inner.pane_for_surface(surface)
        }

        fn legacy_selected_screen(&self, workspace: WorkspaceUuid) -> Option<ScreenUuid> {
            self.inner.legacy_selected_screen(workspace)
        }

        fn legacy_active_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.inner.legacy_active_pane(screen)
        }

        fn legacy_zoomed_pane(&self, screen: ScreenUuid) -> Option<PaneUuid> {
            self.inner.legacy_zoomed_pane(screen)
        }

        fn legacy_selected_surface(&self, pane: PaneUuid) -> Option<SurfaceUuid> {
            self.inner.legacy_selected_surface(pane)
        }
    }

    #[test]
    fn operation_wire_names_are_distinct_v2_absolute_setters() {
        let operations = vec![
            ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(1) },
            ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid: workspace(2) },
            ProjectionNavigationOperation::SelectWorkspace { workspace_uuid: Some(workspace(3)) },
            ProjectionNavigationOperation::SelectScreen {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
            },
            ProjectionNavigationOperation::ActivatePane {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: pane(5),
            },
            ProjectionNavigationOperation::SetZoomedPane {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: None,
            },
            ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(3),
                screen_uuid: screen(4),
                pane_uuid: pane(5),
                surface_uuid: surface(6),
            },
        ];

        let names = operations
            .iter()
            .map(|operation| serde_json::to_value(operation).unwrap()["type"].clone())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            [
                "assign-workspace",
                "unassign-workspace",
                "select-workspace",
                "select-screen",
                "activate-pane",
                "set-zoomed-pane",
                "select-surface",
            ]
        );
    }

    #[test]
    fn wire_expectation_and_request_ids_have_frozen_v2_keys() {
        let topology = FixtureTopology::empty();
        let owner = claimant(1, 2, 3);
        let expectation = expectation(&topology);
        let expectation_json = serde_json::to_value(expectation).unwrap();
        assert_eq!(expectation_json["expected_topology_revision"], 1);
        assert!(expectation_json.get("expected_revision").is_none());

        let batch =
            ProjectionNavigationMutationBatch { request_id: request_id(), projections: Vec::new() };
        let mutation_json = serde_json::to_value(&batch).unwrap();
        assert_eq!(mutation_json["request_id"], batch.request_id.to_string());
        let release = ProjectionNavigationReleaseRequest {
            request_id: request_id(),
            logical_presentation_id: uuid(10),
            claim_id: uuid(11),
            expected_generation: 12,
        };
        let release_json = serde_json::to_value(&release).unwrap();
        assert_eq!(release_json["request_id"], release.request_id.to_string());
        assert_ne!(
            mutation_request_digest(owner, expectation, &batch),
            release_request_digest(owner, expectation, &release)
        );
    }

    #[test]
    fn assignment_stores_only_the_selected_screen_until_another_is_visited() {
        let topology = FixtureTopology::many_screens(100);
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace {
                workspace_uuid: workspace(10_000),
            }],
            &topology,
        );

        assert_eq!(assigned.workspaces.len(), 1);
        assert_eq!(assigned.workspaces[0].screens.len(), 1);
        assert_eq!(assigned.workspaces[0].screens[0].panes.len(), 1);
        assert_eq!(assigned.workspaces[0].selected_screen_uuid, screen(20_099));
        let inner = registry.inner.lock().unwrap();
        let record = inner
            .records
            .get(&ProjectionKey {
                client_uuid: owner.client_uuid,
                logical_presentation_id: uuid(10),
            })
            .unwrap();
        assert_eq!(record.counts().screens, 1);
        assert_eq!(record.counts().panes, 1);
    }

    #[test]
    fn unchanged_revision_sparse_mutation_does_not_scan_a_thousand_workspace_topology() {
        let counts = Arc::new(TopologyAccessCounts::default());
        let topology = CountingTopology {
            inner: FixtureTopology::many_workspaces(1_000),
            counts: counts.clone(),
        };
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace {
                workspace_uuid: workspace(100_500),
            }],
            &topology,
        );
        counts.workspace_order_items.store(0, Ordering::Relaxed);
        counts.screen_order_items.store(0, Ordering::Relaxed);
        counts.pane_order_items.store(0, Ordering::Relaxed);
        counts.surface_order_items.store(0, Ordering::Relaxed);
        counts.rank_lookups.store(0, Ordering::Relaxed);
        counts.ancestry_lookups.store(0, Ordering::Relaxed);

        let selected = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(100_500),
                screen_uuid: screen(200_500),
                pane_uuid: pane(300_500),
                surface_uuid: surface(400_500),
            }],
            &topology,
        );
        assert_eq!(selected.workspaces.len(), 1);
        assert_eq!(counts.workspace_order_items.load(Ordering::Relaxed), 0);
        assert!(counts.screen_order_items.load(Ordering::Relaxed) <= 1);
        assert!(counts.pane_order_items.load(Ordering::Relaxed) <= 2);
        assert!(counts.surface_order_items.load(Ordering::Relaxed) <= 1);
        assert!(counts.rank_lookups.load(Ordering::Relaxed) <= 8);
        assert!(counts.ancestry_lookups.load(Ordering::Relaxed) <= 32);
    }

    #[test]
    fn list_promotes_v1_and_imports_canonical_navigation_once() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let logical = uuid(10);
        registry
            .install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: logical,
                generation: 7,
                workspaces: vec![
                    ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(102),
                        selected_screen_uuid: screen(203),
                    },
                    ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    },
                ],
            })
            .unwrap();

        let promoted = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(promoted.len(), 1);
        let state = &promoted[0];
        assert_eq!(state.schema_version, 2);
        assert_eq!(state.generation, 8);
        assert_eq!(state.selected_workspace_uuid, Some(workspace(101)));
        assert_eq!(
            state.workspaces.iter().map(|item| item.workspace_uuid).collect::<Vec<_>>(),
            [workspace(101), workspace(102)]
        );
        assert_eq!(state.workspaces[0].selected_screen_uuid, screen(201));
        assert_eq!(state.workspaces[0].screens[0].active_pane_uuid, pane(302));
        assert_eq!(state.workspaces[0].screens[0].zoomed_pane_uuid, Some(pane(302)));
        assert_eq!(state.workspaces[0].screens[0].panes[0].selected_surface_uuid, surface(402));
        assert_eq!(state.claim_id, None);
        assert!(matches!(
            registry.legacy_access(owner.client_uuid, logical),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));

        let unchanged = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(unchanged[0].generation, 8);
    }

    #[test]
    fn live_v1_lifecycle_promotes_one_way_and_every_later_v1_access_fails_loudly() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let logical = uuid(10);
        let claimed = registry.legacy_claim(owner, logical, &topology).unwrap();
        let updated = registry
            .legacy_update(
                owner,
                ProjectionNavigationV1Update {
                    logical_presentation_id: logical,
                    claim_id: claimed.claim_id.unwrap(),
                    expected_generation: claimed.generation,
                    workspaces: vec![ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    }],
                },
                &topology,
            )
            .unwrap();
        assert_eq!(updated.generation, claimed.generation + 1);

        let promoted = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(promoted[0].logical_presentation_id, logical);
        assert_eq!(promoted[0].workspaces[0].workspace_uuid, workspace(101));
        assert_eq!(promoted[0].workspaces[0].selected_screen_uuid, screen(201));
        assert_eq!(promoted[0].claim_id, None);
        let v2_claimed = claim(&registry, owner, logical, &topology);
        assert!(v2_claimed.claim_id.is_some());

        assert!(matches!(
            registry.legacy_claim(owner, logical, &topology),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.legacy_update(
                owner,
                ProjectionNavigationV1Update {
                    logical_presentation_id: logical,
                    claim_id: updated.claim_id.unwrap(),
                    expected_generation: updated.generation,
                    workspaces: Vec::new(),
                },
                &topology,
            ),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.legacy_list(owner, &topology),
            Err(ProjectionNavigationConflict::ClientSchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.legacy_release(owner, logical, updated.claim_id.unwrap(), updated.generation,),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
    }

    #[test]
    fn v1_and_v2_records_share_one_workspace_owner_index() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let v1_claimed = registry.legacy_claim(owner, uuid(10), &topology).unwrap();
        let _v1_owned = registry
            .legacy_update(
                owner,
                ProjectionNavigationV1Update {
                    logical_presentation_id: uuid(10),
                    claim_id: v1_claimed.claim_id.unwrap(),
                    expected_generation: v1_claimed.generation,
                    workspaces: vec![ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    }],
                },
                &topology,
            )
            .unwrap();
        let v2_claimed = claim(&registry, owner, uuid(11), &topology);
        assert!(matches!(
            conflict(registry.mutate(
                owner,
                expectation(&topology),
                mutation(
                    &v2_claimed,
                    vec![ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    }],
                ),
                &topology,
            )),
            ProjectionNavigationConflict::WorkspaceOwned {
                workspace_uuid,
                owner_logical_presentation_id,
            } if workspace_uuid == workspace(101) && owner_logical_presentation_id == uuid(10)
        ));
        assert!(matches!(
            registry.legacy_claim(owner, uuid(12), &topology),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
    }

    #[test]
    fn v1_update_many_is_atomic_and_v1_list_reconciles_once() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let first = registry.legacy_claim(owner, uuid(10), &topology).unwrap();
        let second = registry.legacy_claim(owner, uuid(11), &topology).unwrap();
        let first = registry
            .legacy_update(
                owner,
                ProjectionNavigationV1Update {
                    logical_presentation_id: uuid(10),
                    claim_id: first.claim_id.unwrap(),
                    expected_generation: first.generation,
                    workspaces: vec![ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    }],
                },
                &topology,
            )
            .unwrap();
        let second = registry
            .legacy_update(
                owner,
                ProjectionNavigationV1Update {
                    logical_presentation_id: uuid(11),
                    claim_id: second.claim_id.unwrap(),
                    expected_generation: second.generation,
                    workspaces: vec![ProjectionNavigationV1Workspace {
                        workspace_uuid: workspace(102),
                        selected_screen_uuid: screen(203),
                    }],
                },
                &topology,
            )
            .unwrap();

        let swapped = registry
            .legacy_update_many(
                owner,
                vec![
                    ProjectionNavigationV1Update {
                        logical_presentation_id: uuid(11),
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: second.generation,
                        workspaces: vec![ProjectionNavigationV1Workspace {
                            workspace_uuid: workspace(101),
                            selected_screen_uuid: screen(202),
                        }],
                    },
                    ProjectionNavigationV1Update {
                        logical_presentation_id: uuid(10),
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        workspaces: vec![ProjectionNavigationV1Workspace {
                            workspace_uuid: workspace(102),
                            selected_screen_uuid: screen(203),
                        }],
                    },
                ],
                &topology,
            )
            .unwrap();
        assert_eq!(swapped[0].logical_presentation_id, uuid(11));
        assert_eq!(swapped[0].workspaces[0].workspace_uuid, workspace(101));
        assert_eq!(swapped[1].logical_presentation_id, uuid(10));
        assert_eq!(swapped[1].workspaces[0].workspace_uuid, workspace(102));

        assert!(matches!(
            registry.legacy_update_many(
                owner,
                vec![
                    ProjectionNavigationV1Update {
                        logical_presentation_id: uuid(11),
                        claim_id: swapped[0].claim_id.unwrap(),
                        expected_generation: swapped[0].generation,
                        workspaces: Vec::new(),
                    },
                    ProjectionNavigationV1Update {
                        logical_presentation_id: uuid(10),
                        claim_id: swapped[1].claim_id.unwrap(),
                        expected_generation: swapped[1].generation + 1,
                        workspaces: Vec::new(),
                    },
                ],
                &topology,
            ),
            Err(ProjectionNavigationConflict::LegacyStaleGeneration { .. })
        ));
        let after_rejection = registry.legacy_list(owner, &topology).unwrap();
        assert_eq!(
            after_rejection
                .iter()
                .find(|state| state.logical_presentation_id == uuid(11))
                .unwrap()
                .workspaces,
            swapped[0].workspaces
        );

        topology.remove_workspace(workspace(102));
        let reconciled = registry.legacy_list(owner, &topology).unwrap();
        let first_reconciled =
            reconciled.iter().find(|state| state.logical_presentation_id == uuid(10)).unwrap();
        assert!(first_reconciled.workspaces.is_empty());
        assert_eq!(first_reconciled.generation, swapped[1].generation + 1);
        let unchanged = registry.legacy_list(owner, &topology).unwrap();
        assert_eq!(
            unchanged
                .iter()
                .find(|state| state.logical_presentation_id == uuid(10))
                .unwrap()
                .generation,
            first_reconciled.generation
        );
    }

    #[test]
    fn cross_window_swap_is_atomic_and_one_sided_duplicate_rolls_back() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let first = claim(&registry, owner, uuid(10), &topology);
        let second = claim(&registry, owner, uuid(11), &topology);
        let first = mutate_one(
            &registry,
            owner,
            &first,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let second = mutate_one(
            &registry,
            owner,
            &second,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(102) }],
            &topology,
        );

        let rejected = registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![ProjectionNavigationMutation {
                    logical_presentation_id: second.logical_presentation_id,
                    claim_id: second.claim_id.unwrap(),
                    expected_generation: second.generation,
                    operations: vec![ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    }],
                }],
            },
            &topology,
        );
        assert!(matches!(
            conflict(rejected),
            ProjectionNavigationConflict::WorkspaceOwned {
                workspace_uuid,
                owner_logical_presentation_id,
            } if workspace_uuid == workspace(101)
                && owner_logical_presentation_id == first.logical_presentation_id
        ));
        let after_rejection =
            applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(state(&after_rejection, uuid(10)).generation, first.generation);
        assert_eq!(state(&after_rejection, uuid(11)).generation, second.generation);

        let swapped = applied_states(registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![
                    ProjectionNavigationMutation {
                        logical_presentation_id: first.logical_presentation_id,
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        operations: vec![
                            ProjectionNavigationOperation::UnassignWorkspace {
                                workspace_uuid: workspace(101),
                            },
                            ProjectionNavigationOperation::AssignWorkspace {
                                workspace_uuid: workspace(102),
                            },
                        ],
                    },
                    ProjectionNavigationMutation {
                        logical_presentation_id: second.logical_presentation_id,
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: second.generation,
                        operations: vec![
                            ProjectionNavigationOperation::UnassignWorkspace {
                                workspace_uuid: workspace(102),
                            },
                            ProjectionNavigationOperation::AssignWorkspace {
                                workspace_uuid: workspace(101),
                            },
                        ],
                    },
                ],
            },
            &topology,
        ));
        assert_eq!(swapped.len(), 2);
        assert_eq!(swapped[0].workspaces[0].workspace_uuid, workspace(102));
        assert_eq!(swapped[1].workspaces[0].workspace_uuid, workspace(101));
    }

    #[test]
    fn pane_move_keeps_its_surface_but_drops_old_screen_focus_and_zoom() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let focused = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![
                ProjectionNavigationOperation::ActivatePane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(301),
                },
                ProjectionNavigationOperation::SetZoomedPane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: Some(pane(301)),
                },
                ProjectionNavigationOperation::SelectSurface {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(301),
                    surface_uuid: surface(401),
                },
            ],
            &topology,
        );

        topology.move_pane(pane(301), screen(201), screen(202));
        let normalized = applied_states(registry.list(owner, expectation(&topology), &topology));
        let state = state(&normalized, focused.logical_presentation_id);
        let old_screen = screen_state(state, screen(201));
        let new_screen = screen_state(state, screen(202));
        assert_eq!(old_screen.active_pane_uuid, pane(302));
        assert_eq!(old_screen.zoomed_pane_uuid, None);
        assert_eq!(pane_state(new_screen, pane(301)).selected_surface_uuid, surface(401));
    }

    #[test]
    fn surface_move_drops_old_pane_selection_without_transferring_it() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        let selected = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(101),
                screen_uuid: screen(201),
                pane_uuid: pane(301),
                surface_uuid: surface(401),
            }],
            &topology,
        );

        topology.move_surface(surface(401), pane(301), pane(302));
        let normalized = applied_states(registry.list(owner, expectation(&topology), &topology));
        let screen =
            screen_state(state(&normalized, selected.logical_presentation_id), screen(201));
        assert_eq!(pane_state(screen, pane(301)).selected_surface_uuid, surface(402));
        assert_eq!(pane_state(screen, pane(302)).selected_surface_uuid, surface(403));
    }

    #[test]
    fn zoom_forces_active_and_later_activation_of_another_pane_clears_zoom() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );

        let activated_after_zoom = mutate_one(
            &registry,
            owner,
            &assigned,
            vec![
                ProjectionNavigationOperation::SetZoomedPane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: Some(pane(301)),
                },
                ProjectionNavigationOperation::ActivatePane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(302),
                },
            ],
            &topology,
        );
        let screen_state_value = screen_state(&activated_after_zoom, screen(201));
        assert_eq!(screen_state_value.active_pane_uuid, pane(302));
        assert_eq!(screen_state_value.zoomed_pane_uuid, None);

        let zoomed_after_activation = mutate_one(
            &registry,
            owner,
            &activated_after_zoom,
            vec![
                ProjectionNavigationOperation::ActivatePane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(302),
                },
                ProjectionNavigationOperation::SetZoomedPane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: Some(pane(301)),
                },
            ],
            &topology,
        );
        let screen_state_value = screen_state(&zoomed_after_activation, screen(201));
        assert_eq!(screen_state_value.active_pane_uuid, pane(301));
        assert_eq!(screen_state_value.zoomed_pane_uuid, Some(pane(301)));
    }

    #[test]
    fn stale_batch_does_not_persist_topology_repair_and_valid_retry_bumps_once() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![
                ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) },
                ProjectionNavigationOperation::ActivatePane {
                    workspace_uuid: workspace(101),
                    screen_uuid: screen(201),
                    pane_uuid: pane(301),
                },
            ],
            &topology,
        );
        topology.move_pane(pane(301), screen(201), screen(202));

        let stale = registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![ProjectionNavigationMutation {
                    logical_presentation_id: assigned.logical_presentation_id,
                    claim_id: assigned.claim_id.unwrap(),
                    expected_generation: assigned.generation + 1,
                    operations: Vec::new(),
                }],
            },
            &topology,
        );
        assert!(matches!(conflict(stale), ProjectionNavigationConflict::StaleGeneration { .. }));
        {
            let inner = registry.inner.lock().unwrap();
            let stored = inner
                .records
                .get(&ProjectionKey {
                    client_uuid: owner.client_uuid,
                    logical_presentation_id: assigned.logical_presentation_id,
                })
                .unwrap();
            assert_eq!(stored.generation, assigned.generation);
            assert_eq!(stored.reconciled_topology_revision, topology.revision - 1);
        }

        let repaired = mutate_one(&registry, owner, &assigned, Vec::new(), &topology);
        assert_eq!(repaired.generation, assigned.generation + 1);
        assert_eq!(repaired.reconciled_topology_revision, topology.revision);
    }

    #[test]
    fn deletion_empty_workspace_and_reorder_reconcile_in_canonical_order() {
        let mut topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![
                ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) },
                ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(102) },
            ],
            &topology,
        );
        topology.reorder_workspaces(vec![workspace(102), workspace(101)]);
        let reordered = applied_states(registry.list(owner, expectation(&topology), &topology));
        let reordered = state(&reordered, assigned.logical_presentation_id);
        assert_eq!(
            reordered
                .workspaces
                .iter()
                .map(|workspace| workspace.workspace_uuid)
                .collect::<Vec<_>>(),
            [workspace(102), workspace(101)]
        );
        assert_eq!(reordered.selected_workspace_uuid, Some(workspace(101)));

        topology.remove_workspace(workspace(101));
        let deleted = applied_states(registry.list(owner, expectation(&topology), &topology));
        let deleted = state(&deleted, assigned.logical_presentation_id);
        assert_eq!(deleted.selected_workspace_uuid, Some(workspace(102)));
        assert_eq!(deleted.workspaces.len(), 1);

        topology.empty_workspace(workspace(102));
        let emptied = applied_states(registry.list(owner, expectation(&topology), &topology));
        let emptied = state(&emptied, assigned.logical_presentation_id);
        assert_eq!(emptied.selected_workspace_uuid, None);
        assert!(emptied.workspaces.is_empty());
    }

    #[test]
    fn stale_topology_generation_and_claim_are_structured_conflicts() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let first = claimant(1, 2, 3);
        let claimed = claim(&registry, first, uuid(10), &topology);

        let stale_topology = registry.mutate(
            first,
            ProjectionNavigationTopologyExpectation {
                expected_topology_revision: 0,
                ..expectation(&topology)
            },
            mutation(&claimed, Vec::new()),
            &topology,
        );
        assert!(matches!(
            conflict(stale_topology),
            ProjectionNavigationConflict::StaleTopology {
                expected_revision: 0,
                current_revision: 1,
                ..
            }
        ));

        let stale_generation = registry.mutate(
            first,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![ProjectionNavigationMutation {
                    logical_presentation_id: claimed.logical_presentation_id,
                    claim_id: claimed.claim_id.unwrap(),
                    expected_generation: claimed.generation + 1,
                    operations: Vec::new(),
                }],
            },
            &topology,
        );
        assert!(matches!(
            conflict(stale_generation),
            ProjectionNavigationConflict::StaleGeneration { expected, current, .. }
                if expected == claimed.generation + 1 && current == claimed.generation
        ));

        let second = claimant(1, 4, 5);
        let _reclaimed = claim(&registry, second, uuid(10), &topology);
        let lost = registry.mutate(
            first,
            expectation(&topology),
            mutation(&claimed, Vec::new()),
            &topology,
        );
        assert!(matches!(
            conflict(lost),
            ProjectionNavigationConflict::ClaimLost {
                claimed_process_instance_uuid: Some(process),
                ..
            } if process == second.process_instance_uuid
        ));
    }

    #[test]
    fn second_record_stale_or_exhausted_rolls_back_the_entire_batch() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let first = claim(&registry, owner, uuid(10), &topology);
        let second = claim(&registry, owner, uuid(11), &topology);

        let stale = registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![
                    ProjectionNavigationMutation {
                        logical_presentation_id: first.logical_presentation_id,
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        operations: vec![ProjectionNavigationOperation::AssignWorkspace {
                            workspace_uuid: workspace(101),
                        }],
                    },
                    ProjectionNavigationMutation {
                        logical_presentation_id: second.logical_presentation_id,
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: second.generation + 1,
                        operations: Vec::new(),
                    },
                ],
            },
            &topology,
        );
        assert!(matches!(conflict(stale), ProjectionNavigationConflict::StaleGeneration { .. }));
        let listed = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(state(&listed, uuid(10)).generation, first.generation);
        assert!(state(&listed, uuid(10)).workspaces.is_empty());

        {
            let mut inner = registry.inner.lock().unwrap();
            inner
                .records
                .get_mut(&ProjectionKey {
                    client_uuid: owner.client_uuid,
                    logical_presentation_id: second.logical_presentation_id,
                })
                .unwrap()
                .generation = u64::MAX;
        }
        let exhausted = registry.mutate(
            owner,
            expectation(&topology),
            ProjectionNavigationMutationBatch {
                request_id: request_id(),
                projections: vec![
                    ProjectionNavigationMutation {
                        logical_presentation_id: first.logical_presentation_id,
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        operations: vec![ProjectionNavigationOperation::AssignWorkspace {
                            workspace_uuid: workspace(101),
                        }],
                    },
                    ProjectionNavigationMutation {
                        logical_presentation_id: second.logical_presentation_id,
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: u64::MAX,
                        operations: vec![ProjectionNavigationOperation::AssignWorkspace {
                            workspace_uuid: workspace(102),
                        }],
                    },
                ],
            },
            &topology,
        );
        assert!(matches!(
            conflict(exhausted),
            ProjectionNavigationConflict::GenerationExhausted {
                logical_presentation_id,
            } if logical_presentation_id == second.logical_presentation_id
        ));
        let inner = registry.inner.lock().unwrap();
        let first_record = inner
            .records
            .get(&ProjectionKey {
                client_uuid: owner.client_uuid,
                logical_presentation_id: first.logical_presentation_id,
            })
            .unwrap();
        assert_eq!(first_record.generation, first.generation);
        assert!(first_record.workspaces().is_empty());
    }

    #[test]
    fn no_op_claim_mutation_reclaim_and_disconnect_have_exact_generation_semantics() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let first_owner = claimant(1, 2, 3);
        let initial = claim(&registry, first_owner, uuid(10), &topology);
        let same_claim = claim(&registry, first_owner, uuid(10), &topology);
        assert_eq!(same_claim.generation, initial.generation);
        assert_eq!(same_claim.claim_id, initial.claim_id);

        let no_op = mutate_one(&registry, first_owner, &same_claim, Vec::new(), &topology);
        assert_eq!(no_op.generation, initial.generation);

        let second_owner = claimant(1, 4, 5);
        let reclaimed = claim(&registry, second_owner, uuid(10), &topology);
        assert_eq!(reclaimed.generation, initial.generation + 1);
        assert_ne!(reclaimed.claim_id, initial.claim_id);

        registry.reset_scale_counters();
        registry.release_connection(first_owner.connection_id).unwrap();
        assert_eq!(registry.scale_counters().records_touched, 0);
        let still_reclaimed = claim(&registry, second_owner, uuid(10), &topology);
        assert_eq!(still_reclaimed.generation, reclaimed.generation);
        assert_eq!(still_reclaimed.claim_id, reclaimed.claim_id);

        registry.release_connection(second_owner.connection_id).unwrap();
        let listed =
            applied_states(registry.list(claimant(1, 8, 9), expectation(&topology), &topology));
        assert_eq!(listed[0].generation, reclaimed.generation + 1);
        assert_eq!(listed[0].claim_id, None);
    }

    #[test]
    fn disconnect_is_indexed_and_preserves_durable_navigation() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let assigned = mutate_one(
            &registry,
            owner,
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
            &topology,
        );
        registry.reset_scale_counters();

        registry.release_connection(owner.connection_id).unwrap();

        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);
        let listed =
            applied_states(registry.list(claimant(1, 8, 9), expectation(&topology), &topology));
        assert_eq!(listed[0].workspaces, assigned.workspaces);
        assert_eq!(listed[0].claim_id, None);
        assert_eq!(listed[0].generation, assigned.generation + 1);
    }

    #[test]
    fn generation_exhaustion_during_disconnect_commits_no_claim_releases() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let first = claim(&registry, owner, uuid(10), &topology);
        let second = claim(&registry, owner, uuid(11), &topology);
        {
            let mut inner = registry.inner.lock().unwrap();
            inner
                .records
                .get_mut(&ProjectionKey {
                    client_uuid: owner.client_uuid,
                    logical_presentation_id: second.logical_presentation_id,
                })
                .unwrap()
                .generation = u64::MAX;
        }

        assert!(matches!(
            registry.release_connection(owner.connection_id),
            Err(ProjectionNavigationConflict::GenerationExhausted {
                logical_presentation_id,
            }) if logical_presentation_id == second.logical_presentation_id
        ));
        let inner = registry.inner.lock().unwrap();
        let first_record = inner
            .records
            .get(&ProjectionKey {
                client_uuid: owner.client_uuid,
                logical_presentation_id: first.logical_presentation_id,
            })
            .unwrap();
        let second_record = inner
            .records
            .get(&ProjectionKey {
                client_uuid: owner.client_uuid,
                logical_presentation_id: second.logical_presentation_id,
            })
            .unwrap();
        assert_eq!(first_record.generation, first.generation);
        assert_eq!(first_record.claim.as_ref().unwrap().id, first.claim_id.unwrap());
        assert_eq!(second_record.generation, u64::MAX);
        assert_eq!(second_record.claim.as_ref().unwrap().id, second.claim_id.unwrap());
    }

    #[test]
    fn mutation_replay_returns_exact_response_and_reuse_with_another_digest_conflicts() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let batch = mutation(
            &claimed,
            vec![ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: workspace(101) }],
        );
        let original_request_id = batch.request_id;
        let first = registry.mutate(owner, expectation(&topology), batch.clone(), &topology);
        let replay = registry.mutate(owner, expectation(&topology), batch.clone(), &topology);
        assert_eq!(replay, first);

        let mut reused = batch;
        reused.projections[0].operations = Vec::new();
        assert!(matches!(
            conflict(registry.mutate(
                owner,
                expectation(&topology),
                reused,
                &topology,
            )),
            ProjectionNavigationConflict::RequestIdReused { request_id }
                if request_id == original_request_id
        ));
        let listed = applied_states(registry.list(owner, expectation(&topology), &topology));
        let applied = applied_states(first);
        assert_eq!(listed[0].generation, applied[0].generation);
        assert_eq!(listed[0].workspaces, applied[0].workspaces);
    }

    #[test]
    fn mutation_replay_preserves_the_original_conflict_after_state_changes() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let first_owner = claimant(1, 2, 3);
        let claimed = claim(&registry, first_owner, uuid(10), &topology);
        let mut stale = mutation(&claimed, Vec::new());
        stale.projections[0].expected_generation += 1;
        let original =
            registry.mutate(first_owner, expectation(&topology), stale.clone(), &topology);
        assert!(matches!(
            &original,
            ProjectionNavigationResponse::Conflict {
                conflict: ProjectionNavigationConflict::StaleGeneration { .. },
            }
        ));

        let second_owner = claimant(1, 4, 5);
        let _ = claim(&registry, second_owner, uuid(10), &topology);
        assert_eq!(
            registry.mutate(first_owner, expectation(&topology), stale, &topology),
            original
        );
    }

    #[test]
    fn explicit_release_replays_and_leaves_a_permanent_v2_schema_floor() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let request = ProjectionNavigationReleaseRequest {
            request_id: request_id(),
            logical_presentation_id: claimed.logical_presentation_id,
            claim_id: claimed.claim_id.unwrap(),
            expected_generation: claimed.generation,
        };

        let first = registry.release(owner, expectation(&topology), request.clone(), &topology);
        assert!(matches!(&first, ProjectionNavigationResponse::Applied { .. }));
        assert_eq!(
            registry.release(owner, expectation(&topology), request.clone(), &topology),
            first
        );
        assert_eq!(registry.state_count(), 0);
        assert!(matches!(
            registry.legacy_access(owner.client_uuid, claimed.logical_presentation_id),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: claimed.logical_presentation_id,
                generation: 0,
                workspaces: Vec::new(),
            }),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.legacy_claim(owner, uuid(11), &topology),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: uuid(11),
                generation: 0,
                workspaces: Vec::new(),
            }),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert_eq!(registry.state_count(), 0);

        let mut reused = request;
        reused.expected_generation += 1;
        assert!(matches!(
            conflict(registry.release(
                owner,
                expectation(&topology),
                reused.clone(),
                &topology,
            )),
            ProjectionNavigationConflict::RequestIdReused { request_id }
                if request_id == reused.request_id
        ));
    }

    #[test]
    fn empty_v2_list_establishes_a_client_floor_without_a_fake_record_identity() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);

        let response = registry.list(owner, expectation(&topology), &topology);
        assert!(matches!(
            response,
            ProjectionNavigationResponse::Applied {
                client_revision: Some(1),
                next_cursor: None,
                states,
                ..
            } if states.is_empty()
        ));
        assert!(matches!(
            registry.legacy_claim(owner, uuid(10), &topology),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert!(matches!(
            registry.legacy_list(owner, &topology),
            Err(ProjectionNavigationConflict::ClientSchemaPromoted { .. })
        ));
        assert_eq!(registry.state_count(), 0);
    }

    #[test]
    fn fabricated_first_page_cursor_is_rejected_without_crossing_the_schema_floor() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let response = registry.list_page(
            owner,
            expectation(&topology),
            Some(ProjectionNavigationListCursor {
                client_revision: 0,
                after_logical_presentation_id: uuid(10),
            }),
            &topology,
        );
        assert!(matches!(
            conflict(response),
            ProjectionNavigationConflict::ListCursorRestartRequired { current_client_revision: 0 }
        ));
        assert!(registry.legacy_claim(owner, uuid(10), &topology).is_ok());
    }

    #[test]
    fn claim_of_one_v1_record_requires_fresh_list_before_any_remaining_v1_is_serialized() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        for logical_presentation_id in [uuid(10), uuid(11)] {
            registry
                .install_v1(ProjectionNavigationV1Seed {
                    client_uuid: owner.client_uuid,
                    logical_presentation_id,
                    generation: 0,
                    workspaces: Vec::new(),
                })
                .unwrap();
        }
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let current_client_revision =
            client_revision(&registry.inner.lock().unwrap(), owner.client_uuid);
        let continuation = registry.list_page(
            owner,
            expectation(&topology),
            Some(ProjectionNavigationListCursor {
                client_revision: current_client_revision,
                after_logical_presentation_id: claimed.logical_presentation_id,
            }),
            &topology,
        );
        assert!(matches!(
            conflict(continuation),
            ProjectionNavigationConflict::ListCursorRestartRequired { .. }
        ));

        let states = applied_states(registry.list(owner, expectation(&topology), &topology));
        assert_eq!(states.len(), 2);
        assert!(
            states.iter().all(|state| state.schema_version == PROJECTION_NAVIGATION_SCHEMA_VERSION)
        );
    }

    #[test]
    fn v2_release_of_a_v1_claim_is_panic_free_and_permanently_blocks_downgrade() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let claimed = registry.legacy_claim(owner, uuid(10), &topology).unwrap();

        let stale = registry.release(
            owner,
            expectation(&topology),
            ProjectionNavigationReleaseRequest {
                request_id: request_id(),
                logical_presentation_id: claimed.logical_presentation_id,
                claim_id: claimed.claim_id.unwrap(),
                expected_generation: claimed.generation + 1,
            },
            &topology,
        );
        assert!(matches!(
            stale,
            ProjectionNavigationResponse::Conflict {
                conflict: ProjectionNavigationConflict::StaleGeneration {
                    current_state,
                    ..
                },
            } if current_state.schema_version == PROJECTION_NAVIGATION_SCHEMA_VERSION
        ));

        let released = registry.release(
            owner,
            expectation(&topology),
            ProjectionNavigationReleaseRequest {
                request_id: request_id(),
                logical_presentation_id: claimed.logical_presentation_id,
                claim_id: claimed.claim_id.unwrap(),
                expected_generation: claimed.generation,
            },
            &topology,
        );
        assert!(matches!(released, ProjectionNavigationResponse::Applied { .. }));
        assert_eq!(registry.state_count(), 0);
        assert!(matches!(
            registry.legacy_claim(owner, uuid(11), &topology),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
    }

    #[test]
    fn client_wide_schema_floors_are_bounded_refuse_growth_and_are_never_evicted() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            schema_floors_per_client: 1,
            schema_floors_global: 1,
            ..ProjectionNavigationLimits::default()
        });
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let released = registry.release(
            owner,
            expectation(&topology),
            ProjectionNavigationReleaseRequest {
                request_id: request_id(),
                logical_presentation_id: claimed.logical_presentation_id,
                claim_id: claimed.claim_id.unwrap(),
                expected_generation: claimed.generation,
            },
            &topology,
        );
        assert!(matches!(released, ProjectionNavigationResponse::Applied { .. }));

        let same_client = claim(&registry, owner, uuid(11), &topology);
        assert_eq!(same_client.logical_presentation_id, uuid(11));
        assert!(matches!(
            conflict(registry.claim(
                claimant(2, 4, 5),
                uuid(12),
                expectation(&topology),
                &topology,
            )),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::SchemaFloorsGlobal,
                maximum: 1,
                attempted: 2,
            }
        ));
        assert!(matches!(
            registry.install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: uuid(10),
                generation: 0,
                workspaces: Vec::new(),
            }),
            Err(ProjectionNavigationConflict::SchemaPromoted { .. })
        ));
        assert_eq!(registry.state_count(), 1);

        let no_floors = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            schema_floors_per_client: 0,
            ..ProjectionNavigationLimits::default()
        });
        assert!(matches!(
            conflict(no_floors.claim(owner, uuid(20), expectation(&topology), &topology)),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::SchemaFloorsPerClient,
                maximum: 0,
                attempted: 1,
            }
        ));
        assert_eq!(no_floors.state_count(), 0);
    }

    #[test]
    fn aggregate_state_over_eight_mebibytes_recovers_by_stable_pages_and_restarts_on_mutation() {
        const RECORDS: usize = 64;
        const PANES_PER_WORKSPACE: usize = 2_000;

        let topology = FixtureTopology::many_large_workspaces(RECORDS, PANES_PER_WORKSPACE);
        let registry = ProjectionNavigationRegistry::new();
        let owner = claimant(1, 2, 3);
        let mut live_states = Vec::with_capacity(RECORDS);
        for index in 0..RECORDS as u128 {
            let claimed = claim(&registry, owner, uuid(10_000 + index), &topology);
            live_states.push(mutate_one(
                &registry,
                owner,
                &claimed,
                vec![ProjectionNavigationOperation::AssignWorkspace {
                    workspace_uuid: workspace(1_000_000 + index),
                }],
                &topology,
            ));
        }

        let mut cursor = None;
        let mut recovered = Vec::new();
        let mut page_count = 0;
        let mut snapshot_revision = None;
        loop {
            let response = registry.list_page(owner, expectation(&topology), cursor, &topology);
            assert!(serialized_response_bytes(&response) <= MAX_RESPONSE_BYTES);
            let ProjectionNavigationResponse::Applied {
                client_revision: Some(client_revision),
                next_cursor,
                states,
                ..
            } = response
            else {
                panic!("expected a paginated applied response")
            };
            if let Some(snapshot_revision) = snapshot_revision {
                assert_eq!(client_revision, snapshot_revision);
            } else {
                snapshot_revision = Some(client_revision);
            }
            recovered.extend(states);
            page_count += 1;
            let Some(next_cursor) = next_cursor else { break };
            cursor = Some(next_cursor);
        }
        assert!(page_count > 1);
        assert_eq!(recovered.len(), RECORDS);
        assert!(serde_json::to_vec(&recovered).unwrap().len() > MAX_RESPONSE_BYTES);
        let snapshot_revision = snapshot_revision.unwrap();

        let first_page = registry.list_page(owner, expectation(&topology), None, &topology);
        let ProjectionNavigationResponse::Applied { next_cursor: Some(stale_cursor), .. } =
            first_page
        else {
            panic!("aggregate state must retain a continuation cursor")
        };
        let changed = mutate_one(
            &registry,
            owner,
            &live_states[0],
            vec![ProjectionNavigationOperation::SetZoomedPane {
                workspace_uuid: workspace(1_000_000),
                screen_uuid: screen(2_000_000),
                pane_uuid: Some(pane(3_000_001)),
            }],
            &topology,
        );
        assert_eq!(changed.workspaces[0].screens[0].zoomed_pane_uuid, Some(pane(3_000_001)));
        assert!(matches!(
            conflict(registry.list_page(
                owner,
                expectation(&topology),
                Some(stale_cursor),
                &topology,
            )),
            ProjectionNavigationConflict::StaleListCursor {
                expected_client_revision,
                current_client_revision,
            } if expected_client_revision == snapshot_revision
                && current_client_revision == snapshot_revision + 1
        ));
    }

    #[test]
    fn replay_ledger_evicts_old_receipts_at_count_and_byte_limits() {
        let topology = FixtureTopology::empty();
        let reference_response_bytes = {
            let reference = ProjectionNavigationRegistry::new();
            let owner = claimant(1, 2, 3);
            let claimed = claim(&reference, owner, uuid(10), &topology);
            serialized_response_bytes(&reference.mutate(
                owner,
                expectation(&topology),
                mutation(&claimed, Vec::new()),
                &topology,
            ))
        };
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            replay_receipts_per_client: 1,
            replay_receipts_global: 1,
            replay_receipt_bytes_per_client: reference_response_bytes,
            replay_receipt_bytes_global: reference_response_bytes,
            ..ProjectionNavigationLimits::default()
        });
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let first = mutation(&claimed, Vec::new());
        let second = mutation(&claimed, Vec::new());
        assert!(matches!(
            registry.mutate(owner, expectation(&topology), first, &topology),
            ProjectionNavigationResponse::Applied { .. }
        ));
        assert!(matches!(
            registry.mutate(owner, expectation(&topology), second, &topology),
            ProjectionNavigationResponse::Applied { .. }
        ));
        let inner = registry.inner.lock().unwrap();
        assert_eq!(inner.replay_receipts.len(), 1);
        assert_eq!(inner.replay_order_global.len(), 1);
        assert!(inner.replay_bytes_global <= reference_response_bytes);
    }

    #[test]
    fn claim_mutate_reclaim_release_and_disconnect_are_indexed_at_thousand_record_scale() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let mut target = None;
        let mut disconnect_target = None;
        for index in 1..=1_000_u128 {
            let owner = claimant(index, index + 2_000, index + 4_000);
            let claimed = claim(&registry, owner, uuid(index + 10_000), &topology);
            if index == 777 {
                target = Some((owner, claimed));
            } else if index == 778 {
                disconnect_target = Some((owner, claimed));
            }
        }
        registry.reset_scale_counters();
        let (owner, claimed) = target.unwrap();

        let no_op = applied_states(registry.mutate(
            owner,
            expectation(&topology),
            mutation(&claimed, Vec::new()),
            &topology,
        ))
        .remove(0);

        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);
        assert!(counters.workspace_owner_lookups <= 1);

        registry.reset_scale_counters();
        let replacement_owner = claimant(777, 8_000, 8_001);
        let reclaimed =
            claim(&registry, replacement_owner, no_op.logical_presentation_id, &topology);
        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);

        registry.reset_scale_counters();
        assert!(matches!(
            registry.release(
                replacement_owner,
                expectation(&topology),
                ProjectionNavigationReleaseRequest {
                    request_id: request_id(),
                    logical_presentation_id: reclaimed.logical_presentation_id,
                    claim_id: reclaimed.claim_id.unwrap(),
                    expected_generation: reclaimed.generation,
                },
                &topology,
            ),
            ProjectionNavigationResponse::Applied { .. }
        ));
        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);

        registry.reset_scale_counters();
        let (disconnect_owner, _) = disconnect_target.unwrap();
        registry.release_connection(disconnect_owner.connection_id).unwrap();
        let counters = registry.scale_counters();
        assert_eq!(counters.records_touched, 1);
        assert_eq!(counters.global_record_scans, 0);
    }

    #[test]
    fn semantic_budgets_reject_before_any_record_or_index_changes() {
        let topology = FixtureTopology::two_workspaces();
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            records_per_client: 1,
            records_global: 1,
            operations_per_record: 1,
            operations_per_batch: 1,
            ..ProjectionNavigationLimits::default()
        });
        let owner = claimant(1, 2, 3);
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let record_limit = registry.claim(owner, uuid(11), expectation(&topology), &topology);
        assert!(matches!(
            conflict(record_limit),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerClient,
                maximum: 1,
                attempted: 2,
            }
        ));

        let operation_limit = registry.mutate(
            owner,
            expectation(&topology),
            mutation(
                &claimed,
                vec![
                    ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    },
                    ProjectionNavigationOperation::SelectWorkspace {
                        workspace_uuid: Some(workspace(101)),
                    },
                ],
            ),
            &topology,
        );
        assert!(matches!(
            conflict(operation_limit),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::OperationsPerRecord,
                maximum: 1,
                attempted: 2,
            }
        ));
        assert_eq!(registry.state_count(), 1);
        assert!(
            applied_states(registry.list(owner, expectation(&topology), &topology))[0]
                .workspaces
                .is_empty()
        );
    }

    #[test]
    fn every_global_sparse_batch_floor_and_replay_limit_class_is_enforced() {
        let topology = FixtureTopology::empty();
        let global_records =
            ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
                records_per_client: 2,
                records_global: 1,
                ..ProjectionNavigationLimits::default()
            });
        claim(&global_records, claimant(1, 2, 3), uuid(10), &topology);
        assert!(matches!(
            conflict(global_records.claim(
                claimant(2, 4, 5),
                uuid(11),
                expectation(&topology),
                &topology,
            )),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsGlobal,
                maximum: 1,
                attempted: 2,
            }
        ));

        let batch_limits =
            ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
                records_per_batch: 1,
                operations_per_record: 2,
                operations_per_batch: 1,
                ..ProjectionNavigationLimits::default()
            });
        let two_records = ProjectionNavigationMutationBatch {
            request_id: request_id(),
            projections: vec![
                ProjectionNavigationMutation {
                    logical_presentation_id: uuid(10),
                    claim_id: uuid(20),
                    expected_generation: 0,
                    operations: Vec::new(),
                },
                ProjectionNavigationMutation {
                    logical_presentation_id: uuid(11),
                    claim_id: uuid(21),
                    expected_generation: 0,
                    operations: Vec::new(),
                },
            ],
        };
        assert!(matches!(
            batch_limits.validate_batch_shape(&two_records),
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::RecordsPerBatch,
                maximum: 1,
                attempted: 2,
            })
        ));
        let too_many_operations = ProjectionNavigationMutationBatch {
            request_id: request_id(),
            projections: vec![ProjectionNavigationMutation {
                logical_presentation_id: uuid(10),
                claim_id: uuid(20),
                expected_generation: 0,
                operations: vec![
                    ProjectionNavigationOperation::AssignWorkspace {
                        workspace_uuid: workspace(101),
                    },
                    ProjectionNavigationOperation::SelectWorkspace {
                        workspace_uuid: Some(workspace(101)),
                    },
                ],
            }],
        };
        assert!(matches!(
            batch_limits.validate_batch_shape(&too_many_operations),
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::OperationsPerBatch,
                maximum: 1,
                attempted: 2,
            })
        ));

        let key = ProjectionKey { client_uuid: uuid(1), logical_presentation_id: uuid(10) };
        for (limits, record, expected_limit) in [
            (
                ProjectionNavigationLimits {
                    workspaces_per_record: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(1, 0, 0),
                ProjectionNavigationLimit::WorkspacesPerRecord,
            ),
            (
                ProjectionNavigationLimits {
                    workspaces_per_record: 1,
                    workspace_bindings_global: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(1, 0, 0),
                ProjectionNavigationLimit::WorkspaceBindingsGlobal,
            ),
            (
                ProjectionNavigationLimits {
                    screen_preferences_per_record: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(0, 1, 0),
                ProjectionNavigationLimit::ScreenPreferencesPerRecord,
            ),
            (
                ProjectionNavigationLimits {
                    screen_preferences_per_record: 1,
                    screen_preferences_global: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(0, 1, 0),
                ProjectionNavigationLimit::ScreenPreferencesGlobal,
            ),
            (
                ProjectionNavigationLimits {
                    pane_preferences_per_record: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(0, 0, 1),
                ProjectionNavigationLimit::PanePreferencesPerRecord,
            ),
            (
                ProjectionNavigationLimits {
                    pane_preferences_per_record: 1,
                    pane_preferences_global: 0,
                    ..ProjectionNavigationLimits::default()
                },
                synthetic_v2_record(0, 0, 1),
                ProjectionNavigationLimit::PanePreferencesGlobal,
            ),
        ] {
            let registry = ProjectionNavigationRegistry::new_with_limits(limits);
            assert!(matches!(
                registry.validate_candidate_budgets(
                    &RegistryInner::default(),
                    &[(key, record)],
                ),
                Err(ProjectionNavigationConflict::LimitExceeded { limit, .. })
                    if limit == expected_limit
            ));
        }

        let floor_global =
            ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
                schema_floors_per_client: 2,
                schema_floors_global: 1,
                ..ProjectionNavigationLimits::default()
            });
        let inner = RegistryInner {
            v2_schema_floor_clients: HashSet::from([uuid(1)]),
            ..RegistryInner::default()
        };
        assert!(matches!(
            floor_global.validate_schema_floor_growth(&inner, uuid(2), 1),
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::SchemaFloorsGlobal,
                maximum: 1,
                attempted: 2,
            })
        ));

        for (limits, expected_limit) in [
            (
                ProjectionNavigationLimits {
                    replay_receipts_per_client: 0,
                    ..ProjectionNavigationLimits::default()
                },
                ProjectionNavigationLimit::ReplayReceiptsPerClient,
            ),
            (
                ProjectionNavigationLimits {
                    replay_receipts_global: 0,
                    ..ProjectionNavigationLimits::default()
                },
                ProjectionNavigationLimit::ReplayReceiptsGlobal,
            ),
            (
                ProjectionNavigationLimits {
                    replay_receipt_bytes_per_client: 0,
                    ..ProjectionNavigationLimits::default()
                },
                ProjectionNavigationLimit::ReplayReceiptBytesPerClient,
            ),
            (
                ProjectionNavigationLimits {
                    replay_receipt_bytes_global: 0,
                    ..ProjectionNavigationLimits::default()
                },
                ProjectionNavigationLimit::ReplayReceiptBytesGlobal,
            ),
        ] {
            let registry = ProjectionNavigationRegistry::new_with_limits(limits);
            assert!(matches!(
                registry.validate_single_replay_receipt(1),
                Err(ProjectionNavigationConflict::LimitExceeded { limit, .. })
                    if limit == expected_limit
            ));
        }
    }

    #[test]
    fn exact_response_limit_rejects_before_mutation_commit() {
        let topology = FixtureTopology::two_workspaces();
        let owner = claimant(1, 2, 3);
        let empty_response_bytes = {
            let reference = ProjectionNavigationRegistry::new();
            serialized_response_bytes(&reference.claim(
                owner,
                uuid(10),
                expectation(&topology),
                &topology,
            ))
        };
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            response_bytes: empty_response_bytes,
            ..ProjectionNavigationLimits::default()
        });
        let claimed = claim(&registry, owner, uuid(10), &topology);
        let rejected = registry.mutate(
            owner,
            expectation(&topology),
            mutation(
                &claimed,
                vec![ProjectionNavigationOperation::AssignWorkspace {
                    workspace_uuid: workspace(101),
                }],
            ),
            &topology,
        );
        assert!(matches!(
            conflict(rejected),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::ResponseBytes,
                maximum,
                attempted,
            } if maximum == empty_response_bytes && attempted > maximum
        ));
        let inner = registry.inner.lock().unwrap();
        let record = inner
            .records
            .get(&ProjectionKey {
                client_uuid: owner.client_uuid,
                logical_presentation_id: claimed.logical_presentation_id,
            })
            .unwrap();
        assert_eq!(record.generation, claimed.generation);
        assert!(record.workspaces().is_empty());
    }

    #[test]
    fn oversized_list_does_not_promote_v1_or_establish_schema_floor() {
        let topology = FixtureTopology::two_workspaces();
        let owner = claimant(1, 2, 3);
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            response_bytes: 1,
            ..ProjectionNavigationLimits::default()
        });
        registry
            .install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: uuid(10),
                generation: 7,
                workspaces: vec![ProjectionNavigationV1Workspace {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(201),
                }],
            })
            .unwrap();

        assert!(matches!(
            conflict(registry.list(owner, expectation(&topology), &topology)),
            ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::ResponseBytes,
                maximum: 1,
                ..
            }
        ));
        let legacy = registry
            .legacy_access(owner.client_uuid, uuid(10))
            .expect("failed list must leave v1 accessible");
        assert_eq!(legacy.generation, 7);
    }

    #[test]
    fn install_v1_obeys_record_payload_and_owner_limits_atomically() {
        let owner = claimant(1, 2, 3);
        let registry = ProjectionNavigationRegistry::new_with_limits(ProjectionNavigationLimits {
            workspaces_per_record: 1,
            workspace_bindings_global: 2,
            ..ProjectionNavigationLimits::default()
        });
        let two_workspaces = registry.install_v1(ProjectionNavigationV1Seed {
            client_uuid: owner.client_uuid,
            logical_presentation_id: uuid(10),
            generation: 0,
            workspaces: vec![
                ProjectionNavigationV1Workspace {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(201),
                },
                ProjectionNavigationV1Workspace {
                    workspace_uuid: workspace(102),
                    selected_screen_uuid: screen(203),
                },
            ],
        });
        assert!(matches!(
            two_workspaces,
            Err(ProjectionNavigationConflict::LimitExceeded {
                limit: ProjectionNavigationLimit::WorkspacesPerRecord,
                maximum: 1,
                attempted: 2,
            })
        ));
        assert_eq!(registry.state_count(), 0);

        registry
            .install_v1(ProjectionNavigationV1Seed {
                client_uuid: owner.client_uuid,
                logical_presentation_id: uuid(10),
                generation: 0,
                workspaces: vec![ProjectionNavigationV1Workspace {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(201),
                }],
            })
            .unwrap();
        let duplicate_owner = registry.install_v1(ProjectionNavigationV1Seed {
            client_uuid: owner.client_uuid,
            logical_presentation_id: uuid(11),
            generation: 0,
            workspaces: vec![ProjectionNavigationV1Workspace {
                workspace_uuid: workspace(101),
                selected_screen_uuid: screen(201),
            }],
        });
        assert!(matches!(
            duplicate_owner,
            Err(ProjectionNavigationConflict::WorkspaceOwned {
                workspace_uuid,
                owner_logical_presentation_id,
            }) if workspace_uuid == workspace(101) && owner_logical_presentation_id == uuid(10)
        ));
        assert_eq!(registry.state_count(), 1);
    }

    #[test]
    fn nil_claim_request_claim_and_every_operation_identity_fail_closed() {
        let topology = FixtureTopology::empty();
        let registry = ProjectionNavigationRegistry::new();
        let valid = claimant(1, 2, 3);
        for invalid in [
            ProjectionNavigationClaimant { client_uuid: Uuid::nil(), ..valid },
            ProjectionNavigationClaimant { process_instance_uuid: Uuid::nil(), ..valid },
            ProjectionNavigationClaimant { connection_id: Uuid::nil(), ..valid },
        ] {
            assert!(matches!(
                conflict(registry.claim(invalid, uuid(10), expectation(&topology), &topology)),
                ProjectionNavigationConflict::InvalidIdentity { .. }
            ));
        }
        assert!(matches!(
            conflict(registry.claim(valid, Uuid::nil(), expectation(&topology), &topology)),
            ProjectionNavigationConflict::InvalidIdentity { field: "logical_presentation_id" }
        ));

        let nil_workspace = workspace(0);
        let nil_screen = screen(0);
        let nil_pane = pane(0);
        let nil_surface = surface(0);
        let operations = [
            ProjectionNavigationOperation::AssignWorkspace { workspace_uuid: nil_workspace },
            ProjectionNavigationOperation::UnassignWorkspace { workspace_uuid: nil_workspace },
            ProjectionNavigationOperation::SelectWorkspace { workspace_uuid: Some(nil_workspace) },
            ProjectionNavigationOperation::SelectScreen {
                workspace_uuid: nil_workspace,
                screen_uuid: screen(1),
            },
            ProjectionNavigationOperation::SelectScreen {
                workspace_uuid: workspace(1),
                screen_uuid: nil_screen,
            },
            ProjectionNavigationOperation::ActivatePane {
                workspace_uuid: workspace(1),
                screen_uuid: screen(1),
                pane_uuid: nil_pane,
            },
            ProjectionNavigationOperation::SetZoomedPane {
                workspace_uuid: workspace(1),
                screen_uuid: screen(1),
                pane_uuid: Some(nil_pane),
            },
            ProjectionNavigationOperation::SelectSurface {
                workspace_uuid: workspace(1),
                screen_uuid: screen(1),
                pane_uuid: pane(1),
                surface_uuid: nil_surface,
            },
        ];
        for operation in operations {
            assert!(matches!(
                validate_operation_identities(&operation),
                Err(ProjectionNavigationConflict::InvalidIdentity { .. })
            ));
        }

        let claimed = claim(&registry, valid, uuid(10), &topology);
        let mut nil_request = mutation(&claimed, Vec::new());
        nil_request.request_id = Uuid::nil();
        assert!(matches!(
            conflict(registry.mutate(valid, expectation(&topology), nil_request, &topology,)),
            ProjectionNavigationConflict::InvalidIdentity { field: "request_id" }
        ));
        let mut nil_claim = mutation(&claimed, Vec::new());
        nil_claim.projections[0].claim_id = Uuid::nil();
        assert!(matches!(
            conflict(registry.mutate(valid, expectation(&topology), nil_claim, &topology,)),
            ProjectionNavigationConflict::InvalidIdentity { field: "projections.claim_id" }
        ));
    }

    fn synthetic_v2_record(
        workspace_count: usize,
        screen_count: usize,
        pane_count: usize,
    ) -> StoredRecord {
        let mut payload = StoredV2::default();
        for index in 0..workspace_count as u128 {
            payload.workspaces.insert(workspace(10_000 + index));
        }
        for index in 0..screen_count as u128 {
            payload.active_pane_by_screen.insert(screen(20_000 + index), pane(30_000 + index));
        }
        for index in 0..pane_count as u128 {
            payload.selected_surface_by_pane.insert(pane(40_000 + index), surface(50_000 + index));
        }
        StoredRecord {
            generation: 0,
            claim: None,
            reconciled_topology_revision: 0,
            payload: StoredPayload::V2(payload),
        }
    }

    fn applied_states(response: ProjectionNavigationResponse) -> Vec<ProjectionNavigationState> {
        match response {
            ProjectionNavigationResponse::Applied { states, .. } => states,
            ProjectionNavigationResponse::Conflict { conflict } => {
                panic!("expected applied response, got {conflict:?}")
            }
        }
    }

    fn conflict(response: ProjectionNavigationResponse) -> ProjectionNavigationConflict {
        match response {
            ProjectionNavigationResponse::Applied { .. } => panic!("expected conflict"),
            ProjectionNavigationResponse::Conflict { conflict } => conflict,
        }
    }

    fn state(
        states: &[ProjectionNavigationState],
        logical_presentation_id: uuid::Uuid,
    ) -> &ProjectionNavigationState {
        states
            .iter()
            .find(|state| state.logical_presentation_id == logical_presentation_id)
            .unwrap()
    }

    fn screen_state(
        state: &ProjectionNavigationState,
        screen_uuid: ScreenUuid,
    ) -> &ProjectionNavigationScreenState {
        state
            .workspaces
            .iter()
            .flat_map(|workspace| &workspace.screens)
            .find(|screen| screen.screen_uuid == screen_uuid)
            .unwrap()
    }

    fn pane_state(
        screen: &ProjectionNavigationScreenState,
        pane_uuid: PaneUuid,
    ) -> &ProjectionNavigationPaneState {
        screen.panes.iter().find(|pane| pane.pane_uuid == pane_uuid).unwrap()
    }

    fn claim<T: ProjectionNavigationTopology>(
        registry: &ProjectionNavigationRegistry,
        claimant: ProjectionNavigationClaimant,
        logical_presentation_id: uuid::Uuid,
        topology: &T,
    ) -> ProjectionNavigationState {
        applied_states(registry.claim(
            claimant,
            logical_presentation_id,
            expectation(topology),
            topology,
        ))
        .remove(0)
    }

    fn mutate_one<T: ProjectionNavigationTopology>(
        registry: &ProjectionNavigationRegistry,
        claimant: ProjectionNavigationClaimant,
        state: &ProjectionNavigationState,
        operations: Vec<ProjectionNavigationOperation>,
        topology: &T,
    ) -> ProjectionNavigationState {
        applied_states(registry.mutate(
            claimant,
            expectation(topology),
            mutation(state, operations),
            topology,
        ))
        .remove(0)
    }

    fn mutation(
        state: &ProjectionNavigationState,
        operations: Vec<ProjectionNavigationOperation>,
    ) -> ProjectionNavigationMutationBatch {
        ProjectionNavigationMutationBatch {
            request_id: request_id(),
            projections: vec![ProjectionNavigationMutation {
                logical_presentation_id: state.logical_presentation_id,
                claim_id: state.claim_id.unwrap(),
                expected_generation: state.generation,
                operations,
            }],
        }
    }

    fn expectation<T: ProjectionNavigationTopology>(
        topology: &T,
    ) -> ProjectionNavigationTopologyExpectation {
        ProjectionNavigationTopologyExpectation {
            daemon_instance_id: topology.daemon_instance_id(),
            session_id: topology.session_id(),
            expected_topology_revision: topology.revision(),
        }
    }

    fn claimant(client: u128, process: u128, connection: u128) -> ProjectionNavigationClaimant {
        ProjectionNavigationClaimant {
            client_uuid: uuid(client),
            process_instance_uuid: uuid(process),
            connection_id: uuid(connection),
        }
    }

    fn uuid(value: u128) -> uuid::Uuid {
        uuid::Uuid::from_u128(value)
    }

    fn request_id() -> uuid::Uuid {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        uuid(
            0xffff_ffff_ffff_ffff_0000_0000_0000_0000
                | NEXT.fetch_add(1, Ordering::Relaxed) as u128,
        )
    }

    fn daemon(value: u128) -> DaemonInstanceId {
        uuid(value).to_string().parse().unwrap()
    }

    fn session(value: u128) -> SessionId {
        uuid(value).to_string().parse().unwrap()
    }

    fn workspace(value: u128) -> WorkspaceUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn screen(value: u128) -> ScreenUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn pane(value: u128) -> PaneUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn surface(value: u128) -> SurfaceUuid {
        uuid(value).to_string().parse().unwrap()
    }
}
