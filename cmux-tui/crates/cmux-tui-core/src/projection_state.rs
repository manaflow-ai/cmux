//! Daemon-lifetime Swift projection state.
//!
//! Renderer presentations remain connection-owned. This registry retains only
//! the stable mapping from a logical frontend window to canonical workspaces
//! and selected screens, so a Swift process can reconstruct its windows after
//! reconnecting without keeping any renderer or PTY mutation lease alive.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ScreenUuid, WorkspaceUuid};

const MAX_PROJECTIONS_PER_CLIENT: usize = 64;
const MAX_PROJECTIONS_GLOBAL: usize = 1024;
const MAX_WORKSPACES_PER_PROJECTION: usize = 4096;
const MAX_WORKSPACE_BINDINGS_GLOBAL: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ProjectionClaimant {
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
    pub(crate) connection_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ProjectionWorkspaceState {
    pub(crate) workspace_uuid: WorkspaceUuid,
    pub(crate) selected_screen_uuid: ScreenUuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct ProjectionStateUpdate {
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) claim_id: Uuid,
    pub(crate) expected_generation: u64,
    pub(crate) workspaces: Vec<ProjectionWorkspaceState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct ProjectionState {
    pub(crate) logical_presentation_id: Uuid,
    pub(crate) generation: u64,
    pub(crate) claim_id: Option<Uuid>,
    pub(crate) claimed_process_instance_uuid: Option<Uuid>,
    pub(crate) workspaces: Vec<ProjectionWorkspaceState>,
}

#[derive(Debug, Clone)]
struct ActiveClaim {
    id: Uuid,
    claimant: ProjectionClaimant,
}

#[derive(Debug, Clone)]
struct StoredProjectionState {
    generation: u64,
    claim: Option<ActiveClaim>,
    workspaces: BTreeMap<WorkspaceUuid, ScreenUuid>,
}

#[derive(Debug, Clone, Copy)]
struct ProjectionStateLimits {
    per_client: usize,
    global: usize,
    workspaces_per_projection: usize,
    workspace_bindings_global: usize,
}

impl Default for ProjectionStateLimits {
    fn default() -> Self {
        Self {
            per_client: MAX_PROJECTIONS_PER_CLIENT,
            global: MAX_PROJECTIONS_GLOBAL,
            workspaces_per_projection: MAX_WORKSPACES_PER_PROJECTION,
            workspace_bindings_global: MAX_WORKSPACE_BINDINGS_GLOBAL,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ProjectionKey {
    client_uuid: Uuid,
    logical_presentation_id: Uuid,
}

pub(crate) struct ProjectionStateRegistry {
    states: Mutex<BTreeMap<ProjectionKey, StoredProjectionState>>,
    limits: ProjectionStateLimits,
}

impl ProjectionStateRegistry {
    pub(crate) fn new() -> Self {
        Self { states: Mutex::new(BTreeMap::new()), limits: ProjectionStateLimits::default() }
    }

    #[cfg(test)]
    fn new_with_limits(
        per_client: usize,
        global: usize,
        workspaces_per_projection: usize,
        workspace_bindings_global: usize,
    ) -> Self {
        Self {
            states: Mutex::new(BTreeMap::new()),
            limits: ProjectionStateLimits {
                per_client,
                global,
                workspaces_per_projection,
                workspace_bindings_global,
            },
        }
    }

    pub(crate) fn claim(
        &self,
        claimant: ProjectionClaimant,
        logical_presentation_id: Uuid,
        live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
    ) -> anyhow::Result<ProjectionState> {
        if logical_presentation_id.is_nil() {
            anyhow::bail!("logical presentation ID must be a non-nil UUID");
        }
        let key = ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
        let mut states = self.states.lock().unwrap();
        reconcile_locked(&mut states, live_bindings)?;
        if !states.contains_key(&key) {
            if states.len() >= self.limits.global {
                anyhow::bail!(
                    "global projection-state limit reached (maximum {})",
                    self.limits.global
                );
            }
            let client_count =
                states.keys().filter(|stored| stored.client_uuid == claimant.client_uuid).count();
            if client_count >= self.limits.per_client {
                anyhow::bail!(
                    "projection-state limit reached for logical client (maximum {})",
                    self.limits.per_client
                );
            }
            states.insert(
                key,
                StoredProjectionState { generation: 0, claim: None, workspaces: BTreeMap::new() },
            );
        }
        let stored = states.get_mut(&key).expect("projection was inserted");
        if let Some(active) = &stored.claim
            && active.claimant == claimant
        {
            return Ok(wire_state(key, stored, Some(active.id)));
        }
        stored.generation = next_generation(stored.generation)?;
        let claim_id = Uuid::new_v4();
        stored.claim = Some(ActiveClaim { id: claim_id, claimant });
        Ok(wire_state(key, stored, Some(claim_id)))
    }

    pub(crate) fn update(
        &self,
        claimant: ProjectionClaimant,
        logical_presentation_id: Uuid,
        claim_id: Uuid,
        expected_generation: u64,
        workspaces: Vec<ProjectionWorkspaceState>,
        live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
    ) -> anyhow::Result<ProjectionState> {
        let mut updated = self.update_many(
            claimant,
            vec![ProjectionStateUpdate {
                logical_presentation_id,
                claim_id,
                expected_generation,
                workspaces,
            }],
            live_bindings,
        )?;
        Ok(updated.remove(0))
    }

    /// Atomically replaces several logical windows. Cross-window workspace
    /// moves cannot become half-persisted if the frontend exits mid-update.
    pub(crate) fn update_many(
        &self,
        claimant: ProjectionClaimant,
        updates: Vec<ProjectionStateUpdate>,
        live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
    ) -> anyhow::Result<Vec<ProjectionState>> {
        if updates.is_empty() {
            anyhow::bail!("projection-state update must contain at least one logical presentation");
        }
        if updates.len() > self.limits.per_client {
            anyhow::bail!(
                "projection-state update exceeds logical-client limit (maximum {})",
                self.limits.per_client
            );
        }
        let mut seen_presentations = BTreeSet::new();
        let mut normalized_updates = Vec::with_capacity(updates.len());
        for update in updates {
            if update.logical_presentation_id.is_nil() || update.claim_id.is_nil() {
                anyhow::bail!("projection-state update identities must be non-nil UUIDs");
            }
            if !seen_presentations.insert(update.logical_presentation_id) {
                anyhow::bail!(
                    "duplicate logical presentation {} in projection-state update",
                    update.logical_presentation_id
                );
            }
            if update.workspaces.len() > self.limits.workspaces_per_projection {
                anyhow::bail!(
                    "projection workspace limit reached (maximum {})",
                    self.limits.workspaces_per_projection
                );
            }
            normalized_updates.push((
                update.logical_presentation_id,
                update.claim_id,
                update.expected_generation,
                validate_workspaces(update.workspaces, live_bindings)?,
            ));
        }
        let mut states = self.states.lock().unwrap();
        reconcile_locked(&mut states, live_bindings)?;
        let mut candidate = states.clone();
        for (logical_presentation_id, claim_id, expected_generation, workspaces) in
            &normalized_updates
        {
            let key = ProjectionKey {
                client_uuid: claimant.client_uuid,
                logical_presentation_id: *logical_presentation_id,
            };
            let stored = candidate.get_mut(&key).ok_or_else(|| {
                anyhow::anyhow!("unknown logical presentation {logical_presentation_id}")
            })?;
            require_claim(stored, claimant, *claim_id)?;
            if stored.generation != *expected_generation {
                anyhow::bail!(
                    "stale projection-state generation {expected_generation}; current generation is {}",
                    stored.generation
                );
            }
            if stored.workspaces != *workspaces {
                stored.generation = next_generation(stored.generation)?;
                stored.workspaces = workspaces.clone();
            }
        }
        let global_bindings =
            candidate.values().map(|stored| stored.workspaces.len()).sum::<usize>();
        if global_bindings > self.limits.workspace_bindings_global {
            anyhow::bail!(
                "global projection workspace-binding limit reached (maximum {})",
                self.limits.workspace_bindings_global
            );
        }
        let mut workspace_owners = BTreeMap::new();
        for (key, stored) in
            candidate.iter().filter(|(key, _)| key.client_uuid == claimant.client_uuid)
        {
            for workspace_uuid in stored.workspaces.keys() {
                if let Some(previous) =
                    workspace_owners.insert(*workspace_uuid, key.logical_presentation_id)
                {
                    anyhow::bail!(
                        "projection workspace {workspace_uuid} is assigned to logical presentations {previous} and {}",
                        key.logical_presentation_id
                    );
                }
            }
        }
        *states = candidate;
        Ok(normalized_updates
            .into_iter()
            .map(|(logical_presentation_id, claim_id, _, _)| {
                let key =
                    ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
                wire_state(
                    key,
                    states.get(&key).expect("updated projection exists"),
                    Some(claim_id),
                )
            })
            .collect())
    }

    pub(crate) fn release(
        &self,
        claimant: ProjectionClaimant,
        logical_presentation_id: Uuid,
        claim_id: Uuid,
        expected_generation: u64,
    ) -> anyhow::Result<()> {
        let key = ProjectionKey { client_uuid: claimant.client_uuid, logical_presentation_id };
        let mut states = self.states.lock().unwrap();
        let stored = states.get(&key).ok_or_else(|| {
            anyhow::anyhow!("unknown logical presentation {logical_presentation_id}")
        })?;
        require_claim(stored, claimant, claim_id)?;
        if stored.generation != expected_generation {
            anyhow::bail!(
                "stale projection-state generation {expected_generation}; current generation is {}",
                stored.generation
            );
        }
        states.remove(&key);
        Ok(())
    }

    pub(crate) fn list(
        &self,
        claimant: ProjectionClaimant,
        live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
    ) -> anyhow::Result<Vec<ProjectionState>> {
        let mut states = self.states.lock().unwrap();
        reconcile_locked(&mut states, live_bindings)?;
        Ok(states
            .iter()
            .filter(|(key, _)| key.client_uuid == claimant.client_uuid)
            .map(|(key, stored)| {
                let visible_claim = stored
                    .claim
                    .as_ref()
                    .and_then(|active| (active.claimant == claimant).then_some(active.id));
                wire_state(*key, stored, visible_claim)
            })
            .collect())
    }

    /// Disconnect clears only ephemeral ownership. Durable window placement
    /// remains available to the next process using the same logical client.
    pub(crate) fn release_connection(&self, connection_id: Uuid) {
        let mut states = self.states.lock().unwrap();
        for stored in states.values_mut() {
            if stored
                .claim
                .as_ref()
                .is_some_and(|claim| claim.claimant.connection_id == connection_id)
            {
                stored.claim = None;
                if let Ok(generation) = next_generation(stored.generation) {
                    stored.generation = generation;
                }
            }
        }
    }
}

fn next_generation(generation: u64) -> anyhow::Result<u64> {
    generation
        .checked_add(1)
        .ok_or_else(|| anyhow::anyhow!("projection-state generation exhausted"))
}

fn require_claim(
    stored: &StoredProjectionState,
    claimant: ProjectionClaimant,
    claim_id: Uuid,
) -> anyhow::Result<()> {
    let active = stored
        .claim
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("logical presentation is not claimed"))?;
    if active.id != claim_id || active.claimant != claimant {
        anyhow::bail!("stale or foreign projection-state claim");
    }
    Ok(())
}

fn validate_workspaces(
    workspaces: Vec<ProjectionWorkspaceState>,
    live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
) -> anyhow::Result<BTreeMap<WorkspaceUuid, ScreenUuid>> {
    let mut normalized = BTreeMap::new();
    for workspace in workspaces {
        let screens = live_bindings.get(&workspace.workspace_uuid).ok_or_else(|| {
            anyhow::anyhow!("unknown projection workspace {}", workspace.workspace_uuid)
        })?;
        if !screens.contains(&workspace.selected_screen_uuid) {
            anyhow::bail!(
                "screen {} does not belong to projection workspace {}",
                workspace.selected_screen_uuid,
                workspace.workspace_uuid
            );
        }
        if normalized.insert(workspace.workspace_uuid, workspace.selected_screen_uuid).is_some() {
            anyhow::bail!("duplicate projection workspace {}", workspace.workspace_uuid);
        }
    }
    Ok(normalized)
}

fn reconcile_locked(
    states: &mut BTreeMap<ProjectionKey, StoredProjectionState>,
    live_bindings: &BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>>,
) -> anyhow::Result<()> {
    let mut replacements = Vec::new();
    for (key, stored) in states.iter() {
        let mut retained = stored.workspaces.clone();
        retained.retain(|workspace, screen| {
            live_bindings.get(workspace).is_some_and(|screens| screens.contains(screen))
        });
        if retained != stored.workspaces {
            replacements.push((*key, next_generation(stored.generation)?, retained));
        }
    }
    for (key, generation, workspaces) in replacements {
        let stored = states.get_mut(&key).expect("reconciled projection still exists");
        stored.generation = generation;
        stored.workspaces = workspaces;
    }
    Ok(())
}

fn wire_state(
    key: ProjectionKey,
    stored: &StoredProjectionState,
    visible_claim_id: Option<Uuid>,
) -> ProjectionState {
    ProjectionState {
        logical_presentation_id: key.logical_presentation_id,
        generation: stored.generation,
        claim_id: visible_claim_id,
        claimed_process_instance_uuid: visible_claim_id
            .and_then(|_| stored.claim.as_ref().map(|claim| claim.claimant.process_instance_uuid)),
        workspaces: stored
            .workspaces
            .iter()
            .map(|(workspace_uuid, selected_screen_uuid)| ProjectionWorkspaceState {
                workspace_uuid: *workspace_uuid,
                selected_screen_uuid: *selected_screen_uuid,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(value: u128) -> Uuid {
        Uuid::from_u128(value)
    }

    fn workspace(value: u128) -> WorkspaceUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn screen(value: u128) -> ScreenUuid {
        uuid(value).to_string().parse().unwrap()
    }

    fn claimant(client: u128, process: u128, connection: u128) -> ProjectionClaimant {
        ProjectionClaimant {
            client_uuid: uuid(client),
            process_instance_uuid: uuid(process),
            connection_id: uuid(connection),
        }
    }

    fn topology() -> BTreeMap<WorkspaceUuid, BTreeSet<ScreenUuid>> {
        BTreeMap::from([
            (workspace(101), BTreeSet::from([screen(201), screen(202)])),
            (workspace(102), BTreeSet::from([screen(203)])),
        ])
    }

    #[test]
    fn reconnect_reclaims_durable_state_and_fences_old_process() {
        let registry = ProjectionStateRegistry::new();
        let first = claimant(1, 2, 3);
        let second = claimant(1, 4, 5);
        let presentation = uuid(10);
        let claimed = registry.claim(first, presentation, &topology()).unwrap();
        let updated = registry
            .update(
                first,
                presentation,
                claimed.claim_id.unwrap(),
                claimed.generation,
                vec![ProjectionWorkspaceState {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(202),
                }],
                &topology(),
            )
            .unwrap();

        let reclaimed = registry.claim(second, presentation, &topology()).unwrap();
        assert_ne!(reclaimed.claim_id, updated.claim_id);
        assert!(reclaimed.generation > updated.generation);
        assert_eq!(reclaimed.workspaces, updated.workspaces);
        let error = registry
            .update(
                first,
                presentation,
                updated.claim_id.unwrap(),
                updated.generation,
                Vec::new(),
                &topology(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("stale or foreign"));
    }

    #[test]
    fn disconnect_releases_claim_without_deleting_projection() {
        let registry = ProjectionStateRegistry::new();
        let first = claimant(1, 2, 3);
        let presentation = uuid(10);
        let claimed = registry.claim(first, presentation, &topology()).unwrap();
        registry
            .update(
                first,
                presentation,
                claimed.claim_id.unwrap(),
                claimed.generation,
                vec![ProjectionWorkspaceState {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(201),
                }],
                &topology(),
            )
            .unwrap();
        registry.release_connection(first.connection_id);

        let listed = registry.list(claimant(1, 9, 10), &topology()).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].workspaces.len(), 1);
        assert_eq!(listed[0].claim_id, None);
        assert_eq!(listed[0].claimed_process_instance_uuid, None);
    }

    #[test]
    fn explicit_release_deletes_projection_and_requires_current_fence() {
        let registry = ProjectionStateRegistry::new();
        let owner = claimant(1, 2, 3);
        let presentation = uuid(10);
        let claimed = registry.claim(owner, presentation, &topology()).unwrap();
        assert!(registry.release(owner, presentation, uuid(99), claimed.generation).is_err());
        registry
            .release(owner, presentation, claimed.claim_id.unwrap(), claimed.generation)
            .unwrap();
        assert!(registry.list(owner, &topology()).unwrap().is_empty());
    }

    #[test]
    fn update_validates_exact_live_workspace_screen_relation() {
        let registry = ProjectionStateRegistry::new();
        let owner = claimant(1, 2, 3);
        let presentation = uuid(10);
        let claimed = registry.claim(owner, presentation, &topology()).unwrap();
        let error = registry
            .update(
                owner,
                presentation,
                claimed.claim_id.unwrap(),
                claimed.generation,
                vec![ProjectionWorkspaceState {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(203),
                }],
                &topology(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("does not belong"));
    }

    #[test]
    fn bounded_registry_rejects_projection_and_workspace_growth() {
        let registry = ProjectionStateRegistry::new_with_limits(1, 2, 1, 1);
        let first = claimant(1, 2, 3);
        let second = claimant(2, 4, 5);
        let claimed = registry.claim(first, uuid(10), &topology()).unwrap();
        assert!(registry.claim(first, uuid(11), &topology()).is_err());
        registry.claim(second, uuid(12), &topology()).unwrap();
        assert!(registry.claim(claimant(3, 6, 7), uuid(13), &topology()).is_err());
        assert!(
            registry
                .update(
                    first,
                    uuid(10),
                    claimed.claim_id.unwrap(),
                    claimed.generation,
                    vec![
                        ProjectionWorkspaceState {
                            workspace_uuid: workspace(101),
                            selected_screen_uuid: screen(201),
                        },
                        ProjectionWorkspaceState {
                            workspace_uuid: workspace(102),
                            selected_screen_uuid: screen(203),
                        },
                    ],
                    &topology(),
                )
                .is_err()
        );
    }

    #[test]
    fn topology_reconciliation_advances_generation_exactly_once() {
        let registry = ProjectionStateRegistry::new();
        let owner = claimant(1, 2, 3);
        let presentation = uuid(10);
        let claimed = registry.claim(owner, presentation, &topology()).unwrap();
        let updated = registry
            .update(
                owner,
                presentation,
                claimed.claim_id.unwrap(),
                claimed.generation,
                vec![
                    ProjectionWorkspaceState {
                        workspace_uuid: workspace(101),
                        selected_screen_uuid: screen(201),
                    },
                    ProjectionWorkspaceState {
                        workspace_uuid: workspace(102),
                        selected_screen_uuid: screen(203),
                    },
                ],
                &topology(),
            )
            .unwrap();
        let reduced_topology =
            BTreeMap::from([(workspace(101), BTreeSet::from([screen(201), screen(202)]))]);

        let reconciled = registry.list(owner, &reduced_topology).unwrap().remove(0);
        assert_eq!(reconciled.generation, updated.generation + 1);
        assert_eq!(reconciled.workspaces.len(), 1);
        let unchanged = registry.list(owner, &reduced_topology).unwrap().remove(0);
        assert_eq!(unchanged.generation, reconciled.generation);
    }

    #[test]
    fn multi_projection_replace_moves_workspace_atomically() {
        let registry = ProjectionStateRegistry::new();
        let owner = claimant(1, 2, 3);
        let first_id = uuid(10);
        let second_id = uuid(11);
        let first = registry.claim(owner, first_id, &topology()).unwrap();
        let second = registry.claim(owner, second_id, &topology()).unwrap();
        let first = registry
            .update(
                owner,
                first_id,
                first.claim_id.unwrap(),
                first.generation,
                vec![ProjectionWorkspaceState {
                    workspace_uuid: workspace(101),
                    selected_screen_uuid: screen(202),
                }],
                &topology(),
            )
            .unwrap();
        let duplicate = registry.update(
            owner,
            second_id,
            second.claim_id.unwrap(),
            second.generation,
            vec![ProjectionWorkspaceState {
                workspace_uuid: workspace(101),
                selected_screen_uuid: screen(202),
            }],
            &topology(),
        );
        assert!(duplicate.unwrap_err().to_string().contains("assigned to logical presentations"));

        let moved = registry
            .update_many(
                owner,
                vec![
                    ProjectionStateUpdate {
                        logical_presentation_id: first_id,
                        claim_id: first.claim_id.unwrap(),
                        expected_generation: first.generation,
                        workspaces: Vec::new(),
                    },
                    ProjectionStateUpdate {
                        logical_presentation_id: second_id,
                        claim_id: second.claim_id.unwrap(),
                        expected_generation: second.generation,
                        workspaces: vec![ProjectionWorkspaceState {
                            workspace_uuid: workspace(101),
                            selected_screen_uuid: screen(202),
                        }],
                    },
                ],
                &topology(),
            )
            .unwrap();
        assert!(moved[0].workspaces.is_empty());
        assert_eq!(moved[1].workspaces.len(), 1);
    }
}
