//! Delete Space (SPACE-DELETE-CLOSES-ITS-WORKSPACES, RECOVERABLE-BY-DEFAULT):
//! the one delete path of a room, behind `room.delete` and the raw
//! `delete-profile`, so the Mac app, iOS, GPUI and the CLI agree.
//!
//! The delete removes the room and closes every workspace of this session
//! that only that room shows, through the shared batch close (the terminals
//! the close ends end, as with any workspace close). The room's rows, the
//! workspaces and their closed-history record commit in ONE transaction
//! and form ONE closed group, so Reopen Closed (Cmd-Shift-T, History)
//! restores the room with its name, order, follows, groups and pins, and its
//! workspaces. A room with no workspace to close is recorded as a group with
//! no member (its reopen result names the active workspace). The home workspace never closes. Workspaces of other sessions
//! (remote machines, Cloud VMs) are never closed on their daemon: they lose
//! their pin and show in the rooms that follow their session, so a Cloud VM
//! is never stopped or deleted. Agent folders are never touched. An explicit
//! `move_to` keeps the move (no close).

use rusqlite::Transaction;
use serde_json::json;

use crate::mux::*;
use crate::state::closed_history_store::{flush_pending_group, pend_group, queue_change};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::personal::{all_groups, all_placements, all_rooms};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete};
use crate::state::values::{local_registry_id, workspace_ref};
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::personal_mutations::room_archive;
use crate::workspace_registry::personal_store::{DEFAULT_PROFILE_ID, read_profile};

/// What a room delete did.
pub(crate) struct RoomDeleted {
    pub(crate) commit: StateCommit,
    /// The pins the delete removed (session, workspace key); empty on replay.
    pub(crate) unpinned: Vec<(String, String)>,
}

/// What the delete closes and returns, read before it commits.
struct Plan {
    closing: Vec<SurfaceId>,
    unpinned: Vec<(String, String)>,
    result: Value,
}

/// Delete `room` in `transaction` and announce its closed group
/// (`closed_id`, carrying the room's record). Returns the public changes.
fn delete_in(
    transaction: &Transaction<'_>,
    room: &str,
    closed_id: &str,
) -> anyhow::Result<Vec<Value>> {
    let archive = room_archive::snapshot_room(transaction, room)?;
    pend_group(transaction, closed_id, &json!({"room": archive}))?;
    WorkspaceRegistry::delete_profile_in(transaction, room, None)?;
    let mut changes = vec![state_delete("room", room)];
    changes.extend(all_rooms(transaction)?);
    changes.extend(all_groups(transaction)?);
    changes.extend(all_placements(transaction)?);
    Ok(changes)
}

impl Mux {
    fn room_delete_plan(&self, room: &str) -> anyhow::Result<Plan> {
        let live = self.with_state(|state| {
            state
                .workspaces
                .iter()
                .map(|workspace| (workspace.id, workspace.key.clone()))
                .collect::<Vec<_>>()
        });
        let keys = live.iter().map(|(_, key)| key.clone()).collect::<Vec<_>>();
        let (closing_keys, unpinned, refs) = self.read_registry_state(|connection| {
            if read_profile(connection, room)?.is_none() {
                return Err(state_not_found("room", room));
            }
            let local = local_registry_id(connection)?;
            let closing = room_archive::closing_keys(connection, room, &local, &keys)?
                .into_iter()
                .filter(|key| crate::state::home_store::refuse_close_key(connection, key).is_ok())
                .collect::<Vec<_>>();
            let pins = connection
                .prepare(
                    "SELECT session_id, workspace_key FROM profile_pins WHERE profile_id = ?1
                     ORDER BY session_id, workspace_key",
                )?
                .query_map([room], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            let refs = pins
                .iter()
                .map(|(session, key)| workspace_ref(connection, &local, session, key))
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok((closing, pins, refs))
        })?;
        let closing = self.with_state(|state| {
            let mut surfaces = Vec::new();
            for (id, key) in &live {
                if !closing_keys.contains(key) {
                    continue;
                }
                let Some(index) = state.workspace_index(*id) else { continue };
                let mut panes = Vec::new();
                for screen in &state.workspaces[index].screens {
                    screen.root.pane_ids(&mut panes);
                }
                for pane in panes {
                    if let Some(pane) = state.panes.get(&pane) {
                        surfaces.extend(pane.tabs.iter().copied());
                    }
                }
            }
            surfaces
        });
        Ok(Plan {
            closing,
            unpinned,
            result: json!({"id": room, "moved_to": null, "unpinned": refs}),
        })
    }

    /// Delete `room`, closing its workspaces, as one closed group with id
    /// `closed_id`. A retry with the same key replays.
    pub(crate) fn state_room_delete(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        room: &str,
        closed_id: &str,
    ) -> anyhow::Result<RoomDeleted> {
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, operation, fingerprint)?
        {
            return Ok(RoomDeleted { commit: replay.into(), unpinned: Vec::new() });
        }
        anyhow::ensure!(room != DEFAULT_PROFILE_ID, "the default room cannot be deleted");
        let plan = self.room_delete_plan(room)?;
        if plan.closing.is_empty() {
            let result = plan.result.clone();
            let commit = self.commit_state(
                mutation,
                operation,
                fingerprint,
                expected_revision,
                StateEffects::EVENTS_ONLY,
                |transaction, _| {
                    let changes = delete_in(transaction, room, closed_id)?;
                    flush_pending_group(transaction)?;
                    Ok(StateChanges::new(result, changes))
                },
            )?;
            return Ok(RoomDeleted { commit, unpinned: plan.unpinned });
        }
        if let Some(expected) = expected_revision {
            let current = self.with_state(|state| state.resource_revision);
            anyhow::ensure!(
                current == expected,
                "resource revision conflict: expected {expected}, current {current}"
            );
        }
        let before_patch = |transaction: &Transaction<'_>| -> anyhow::Result<()> {
            for change in delete_in(transaction, room, closed_id)? {
                queue_change(transaction, &change)?;
            }
            Ok(())
        };
        let outcome = self.close_tabs_for_room_delete(
            plan.closing,
            operation,
            fingerprint,
            mutation,
            &before_patch,
            plan.result,
        )?;
        let personal_revision = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .personal_revision()?;
        if !outcome.replayed {
            self.emit(MuxEvent::PersonalChanged { personal_revision });
        }
        Ok(RoomDeleted {
            commit: StateCommit {
                revision: outcome.resource_revision,
                result: outcome.result,
                replayed: outcome.replayed,
                personal_revision: Some(personal_revision),
            },
            unpinned: plan.unpinned,
        })
    }
}
