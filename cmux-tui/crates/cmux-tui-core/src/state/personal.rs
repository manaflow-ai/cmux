//! Personal workspace groups, the personal sidebar order (placements), and
//! rooms as v2 state mutations on the home session. Each commit advances the
//! resource revision (so `session.events` carries the change) and
//! `personal_revision` (so raw `personal-changed` readers refetch).

use rusqlite::Transaction;
use serde::Serialize;

use crate::mux::*;
use crate::state::commit::{StateEffects, state_not_found, workspace_identity};
use crate::state::personal_state_store as personal;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::state::values::local_registry_id;
use crate::workspace_registry::{PersonalWorkspaceUpdate, ProfileInput, ProfileUpdate};

/// Advertises `icon` on `workspace_group.update`, `WorkspaceGroupSnapshot`
/// and `list-personal` groups.
pub(crate) const WORKSPACE_GROUP_ICON_CAPABILITY: &str = "workspace-group-icon-v1";

/// Advertises `pinned` on `workspace_group.update`, `WorkspaceGroupSnapshot`
/// and `list-personal` groups.
pub(crate) const WORKSPACE_GROUP_PIN_CAPABILITY: &str = "workspace-group-pin-v1";

/// One personal state mutation.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "change", rename_all = "snake_case")]
pub(crate) enum PersonalChange {
    GroupCreate {
        name: String,
        color: Option<String>,
        collapsed: bool,
        room: Option<String>,
        index: Option<usize>,
    },
    GroupUpdate {
        group: String,
        name: Option<String>,
        color: Option<Option<String>>,
        collapsed: Option<bool>,
        room: Option<String>,
        /// The group's slot among the loose workspaces
        /// (`personal-mixed-order-v1`); `Some(None)` clears it. Omitted
        /// when absent, so older mutation fingerprints keep their shape.
        #[serde(skip_serializing_if = "Option::is_none")]
        top_index: Option<Option<usize>>,
        /// The group's icon (`workspace-group-icon-v1`); `Some(None)`
        /// clears it. Omitted when absent, like `top_index`.
        #[serde(skip_serializing_if = "Option::is_none")]
        icon: Option<Option<String>>,
        /// Pin (save) or unpin the group (`workspace-group-pin-v1`).
        /// Omitted when absent, like `top_index`.
        #[serde(skip_serializing_if = "Option::is_none")]
        pinned: Option<bool>,
    },
    GroupDelete {
        group: String,
    },
    GroupMove {
        group: String,
        index: usize,
    },
    Place {
        group: Option<Option<String>>,
        index: Option<usize>,
    },
    RoomCreate {
        name: String,
        color: Option<String>,
        icon: Option<String>,
        theme: Option<String>,
        index: Option<usize>,
    },
    RoomUpdate {
        room: String,
        name: Option<String>,
        color: Option<Option<String>>,
        icon: Option<Option<String>>,
        theme: Option<Option<String>>,
        browser_profile_id: Option<Option<String>>,
        default_session_id: Option<Option<String>>,
    },
    RoomDelete {
        room: String,
        move_to: Option<String>,
    },
    RoomMove {
        room: String,
        index: usize,
    },
    RoomFollow {
        room: String,
        sessions: Vec<String>,
    },
    RoomPin {
        room: String,
    },
    RoomUnpin,
}

impl PersonalChange {
    /// Changes addressed to one workspace resolve the `workspace` selector.
    fn targets_workspace(&self) -> bool {
        matches!(self, Self::Place { .. } | Self::RoomPin { .. } | Self::RoomUnpin)
    }
}

/// Map registry "unknown ..." failures of personal rows to typed errors.
fn typed(error: anyhow::Error, scope: &str, id: &str) -> anyhow::Error {
    let message = error.to_string();
    if message.starts_with("unknown room") || message.starts_with("unknown personal group") {
        state_not_found(scope, id)
    } else {
        error
    }
}

pub(crate) fn all_groups(transaction: &Transaction<'_>) -> anyhow::Result<Vec<Value>> {
    Ok(personal::workspace_group_snapshots(transaction, None)?
        .into_iter()
        .map(|group| {
            let id = group["id"].as_str().unwrap_or_default().to_string();
            state_upsert("workspace_group", &id, group)
        })
        .collect())
}

pub(crate) fn all_rooms(transaction: &Transaction<'_>) -> anyhow::Result<Vec<Value>> {
    Ok(personal::room_snapshots(transaction)?
        .into_iter()
        .map(|room| {
            let id = room["id"].as_str().unwrap_or_default().to_string();
            state_upsert("room", &id, room)
        })
        .collect())
}

pub(crate) fn all_placements(transaction: &Transaction<'_>) -> anyhow::Result<Vec<Value>> {
    Ok(personal::placement_snapshots(transaction)?
        .into_iter()
        .map(|placement| {
            let id = personal::placement_id(
                placement["workspace"]["session_id"].as_str().unwrap_or_default(),
                placement["workspace"]["workspace_ref"].as_str().unwrap_or_default(),
            );
            state_upsert("workspace_placement", &id, placement)
        })
        .collect())
}

fn refs(transaction: &Transaction<'_>, pairs: &[(String, String)]) -> anyhow::Result<Vec<Value>> {
    let local = local_registry_id(transaction)?;
    pairs
        .iter()
        .map(|(session, key)| {
            crate::state::values::workspace_ref(transaction, &local, session, key)
        })
        .collect()
}

impl Mux {
    pub(crate) fn state_personal(
        &self,
        mutation: &WorkspaceMutation,
        operation: &'static str,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        change: PersonalChange,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": operation,
            "selectors": change.targets_workspace().then_some(selectors),
            "change": change,
        });
        // Delete Space closes its workspaces (SPACE-DELETE-CLOSES-ITS-WORKSPACES).
        if let PersonalChange::RoomDelete { room, move_to: None } = &change {
            let closed_id = crate::state::closed_history_store::new_closed_id();
            return self
                .state_room_delete(
                    mutation,
                    operation,
                    &fingerprint,
                    expected_revision,
                    room,
                    &closed_id,
                )
                .map(|deleted| deleted.commit);
        }
        self.commit_state(
            mutation,
            operation,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                let workspace_key = if change.targets_workspace() {
                    let resolved =
                        self.resolve_in_state(state, crate::ResourceTarget::Workspace, selectors)?;
                    Some(workspace_identity(state, resolved.workspace)?.0)
                } else {
                    None
                };
                let session = local_registry_id(transaction)?;
                apply_personal(transaction, &session, workspace_key.as_deref(), change)
            },
        )
    }
}

fn apply_personal(
    tx: &Transaction<'_>,
    session: &str,
    workspace_key: Option<&str>,
    change: PersonalChange,
) -> anyhow::Result<StateChanges> {
    match change {
        PersonalChange::GroupCreate { name, color, collapsed, room, index } => {
            let group = personal::create_group(
                tx,
                room.as_deref(),
                &name,
                color.as_deref(),
                collapsed,
                index,
            )
            .map_err(|error| typed(error, "room", room.as_deref().unwrap_or_default()))?;
            let value = personal::workspace_group_snapshot(tx, &group.id)?
                .context("created group vanished")?;
            Ok(StateChanges::new(value, all_groups(tx)?))
        }
        PersonalChange::GroupUpdate {
            group,
            name,
            color,
            collapsed,
            room,
            top_index,
            icon,
            pinned,
        } => {
            personal::update_group(
                tx,
                &group,
                name.as_deref(),
                color.as_ref().map(Option::as_deref),
                collapsed,
                room.as_deref(),
            )
            .map_err(|error| typed(error, "workspace_group", &group))?;
            if let Some(top_index) = top_index {
                personal::set_group_top(tx, &group, top_index)
                    .map_err(|error| typed(error, "workspace_group", &group))?;
            }
            if let Some(icon) = &icon {
                personal::set_group_icon(tx, &group, icon.as_deref())
                    .map_err(|error| typed(error, "workspace_group", &group))?;
            }
            if let Some(pinned) = pinned {
                personal::set_group_pinned(tx, &group, pinned)
                    .map_err(|error| typed(error, "workspace_group", &group))?;
            }
            let value = personal::workspace_group_snapshot(tx, &group)?
                .context("updated group vanished")?;
            let mut changes = vec![state_upsert("workspace_group", &group, value.clone())];
            if room.is_some() {
                changes.extend(all_rooms(tx)?);
                changes.extend(all_placements(tx)?);
            }
            Ok(StateChanges::new(value, changes))
        }
        PersonalChange::GroupDelete { group } => {
            let ungrouped = personal::delete_group(tx, &group)
                .map_err(|error| typed(error, "workspace_group", &group))?;
            let mut changes = vec![state_delete("workspace_group", &group)];
            changes.extend(all_groups(tx)?);
            changes.extend(all_placements(tx)?);
            Ok(StateChanges::new(
                serde_json::json!({"id": group, "ungrouped": refs(tx, &ungrouped)?}),
                changes,
            ))
        }
        PersonalChange::GroupMove { group, index } => {
            personal::move_group(tx, &group, index)
                .map_err(|error| typed(error, "workspace_group", &group))?;
            let value =
                personal::workspace_group_snapshot(tx, &group)?.context("moved group vanished")?;
            Ok(StateChanges::new(value, all_groups(tx)?))
        }
        PersonalChange::Place { group, index } => {
            let key = workspace_key.context("placement needs a workspace")?;
            if let Some(Some(group)) = &group
                && personal::workspace_group_snapshot(tx, group)?.is_none()
            {
                return Err(state_not_found("workspace_group", group));
            }
            personal::place_workspace(
                tx,
                session,
                key,
                PersonalWorkspaceUpdate { index, group, ..PersonalWorkspaceUpdate::default() },
            )?;
            let value = personal::placement_snapshot(tx, session, key)?;
            Ok(StateChanges::new(value, all_placements(tx)?))
        }
        PersonalChange::RoomCreate { name, color, icon, theme, index } => {
            let room = personal::create_room(
                tx,
                ProfileInput { name, color, icon, theme, index, ..ProfileInput::default() },
            )?;
            let value = personal::room_snapshot(tx, &room.id)?.context("created room vanished")?;
            Ok(StateChanges::new(value, all_rooms(tx)?))
        }
        PersonalChange::RoomUpdate {
            room,
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
        } => {
            personal::update_room(
                tx,
                &room,
                ProfileUpdate {
                    name,
                    color,
                    icon,
                    theme,
                    browser_profile_id,
                    default_session_id,
                    defaults: None,
                },
            )
            .map_err(|error| typed(error, "room", &room))?;
            let value = personal::room_snapshot(tx, &room)?.context("updated room vanished")?;
            Ok(StateChanges::new(value.clone(), vec![state_upsert("room", &room, value)]))
        }
        PersonalChange::RoomDelete { room, move_to } => {
            let deletion =
                personal::delete_room(tx, &room, move_to.as_deref()).map_err(|error| {
                    let message = error.to_string();
                    if message == format!("unknown room {room}") {
                        state_not_found("room", &room)
                    } else if let Some(target) = move_to.as_deref()
                        && message == format!("unknown room {target}")
                    {
                        state_not_found("room", target)
                    } else {
                        error
                    }
                })?;
            let mut changes = vec![state_delete("room", &room)];
            changes.extend(all_rooms(tx)?);
            changes.extend(all_groups(tx)?);
            changes.extend(all_placements(tx)?);
            let result = serde_json::json!({
                "id": room,
                "moved_to": deletion.moved_to,
                "unpinned": refs(tx, &deletion.unpinned)?,
            });
            Ok(StateChanges::new(result, changes))
        }
        PersonalChange::RoomMove { room, index } => {
            personal::move_room(tx, &room, index).map_err(|error| typed(error, "room", &room))?;
            let value = personal::room_snapshot(tx, &room)?.context("moved room vanished")?;
            Ok(StateChanges::new(value, all_rooms(tx)?))
        }
        PersonalChange::RoomFollow { room, sessions } => {
            personal::follow_sessions(tx, &room, &sessions)
                .map_err(|error| typed(error, "room", &room))?;
            let value = personal::room_snapshot(tx, &room)?.context("room vanished")?;
            Ok(StateChanges::new(value.clone(), vec![state_upsert("room", &room, value)]))
        }
        PersonalChange::RoomPin { room } => {
            let key = workspace_key.context("pin needs a workspace")?;
            personal::pin_workspace(tx, session, key, &room)
                .map_err(|error| typed(error, "room", &room))?;
            let value = personal::room_snapshot(tx, &room)?.context("room vanished")?;
            let mut changes = all_rooms(tx)?;
            let placement = personal::placement_snapshot(tx, session, key)?;
            changes.push(state_upsert(
                "workspace_placement",
                &personal::placement_id(session, key),
                placement,
            ));
            Ok(StateChanges::new(value, changes))
        }
        PersonalChange::RoomUnpin => {
            let key = workspace_key.context("unpin needs a workspace")?;
            personal::unpin_workspace(tx, session, key)?;
            let placement = personal::placement_snapshot(tx, session, key)?;
            let mut changes = all_rooms(tx)?;
            changes.push(state_upsert(
                "workspace_placement",
                &personal::placement_id(session, key),
                placement.clone(),
            ));
            Ok(StateChanges::new(placement, changes))
        }
    }
}

impl Mux {
    pub(crate) fn personal_state_read<T>(
        &self,
        read: impl FnOnce(&rusqlite::Connection) -> anyhow::Result<T>,
    ) -> Result<T, ResourceError> {
        self.read_registry_state(read).map_err(crate::resource_api::operation_failed)
    }
}
