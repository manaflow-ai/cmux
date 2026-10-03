//! The state resources of plans/cmux-next/state-ownership.md (steps A and
//! B): workspace identity, tab pins and tab state, tab groups, personal
//! workspace groups, placements and rooms, saved tab groups, screen
//! metadata and screen groups, closed history, and workspace status.

use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::mux::{PersonalChange, ScreenChange, StripRequest, WorkspaceStatusChange};
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{
    ParsedResourceRequest, expected_revision, mutation_result, operation_name,
    resource_operation_error, validation_error,
};
use crate::state::store::StateCommit;
use crate::state::tab_state_store::TabStateUpdate;
use crate::state::window_records::WindowRecordChange;
use crate::state::{
    closed_history_store, personal_state_store, screen_state_store, tab_state_store,
    window_record_store,
};
use crate::workspace_registry::{ResourcePatchCommit, WorkspacePresentationUpdate};
use crate::{Mux, ResourceSelectors, WorkspaceMutation};

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    use ResourceOperation as Op;
    matches!(
        operation,
        Op::WorkspaceUpdate
            | Op::TabPin
            | Op::TabUnpin
            | Op::TabUpdate
            | Op::TabGroupList
            | Op::TabGroupGet
            | Op::TabGroupCreate
            | Op::TabGroupUpdate
            | Op::TabGroupAddTabs
            | Op::TabGroupRemoveTabs
            | Op::TabGroupMove
            | Op::TabGroupUngroup
            | Op::TabGroupClose
            | Op::WorkspaceGroupList
            | Op::WorkspaceGroupCreate
            | Op::WorkspaceGroupUpdate
            | Op::WorkspaceGroupDelete
            | Op::WorkspaceGroupMove
            | Op::WorkspacePlacementList
            | Op::WorkspacePlace
            | Op::RoomList
            | Op::RoomCreate
            | Op::RoomUpdate
            | Op::RoomDelete
            | Op::RoomMove
            | Op::RoomFollow
            | Op::RoomPin
            | Op::RoomUnpin
            | Op::SavedTabGroupList
            | Op::SavedTabGroupSave
            | Op::SavedTabGroupReopen
            | Op::SavedTabGroupDelete
            | Op::ScreenUpdate
            | Op::ScreenMove
            | Op::ScreenGroupList
            | Op::ScreenGroupGet
            | Op::ScreenGroupCreate
            | Op::ScreenGroupUpdate
            | Op::ScreenGroupAddScreens
            | Op::ScreenGroupRemoveScreens
            | Op::ScreenGroupUngroup
            | Op::ClosedList
            | Op::ClosedReopen
            | Op::WindowRecordList
            | Op::WindowRecordPut
            | Op::WindowRecordDelete
            | Op::WorkspaceEnsureHome
            | Op::WorkspaceStatusList
            | Op::WorkspaceStatusSet
            | Op::WorkspaceStatusClear
            | Op::WorkspaceProgressSet
            | Op::WorkspaceProgressClear
            | Op::WorkspaceLogAppend
            | Op::WorkspaceLogList
            | Op::WorkspaceLogClear
    )
}

/// Map a state failure to its typed protocol error. Registry validation
/// failures are `bad request: ...`.
fn state_error(error: anyhow::Error) -> ResourceError {
    if error.downcast_ref::<ResourceError>().is_none()
        && let Some(reason) = error.to_string().strip_prefix("bad request: ")
    {
        return ResourceError::validation_invalid(None, reason);
    }
    resource_operation_error(error)
}

fn mutation(request: &ParsedResourceRequest) -> Result<WorkspaceMutation, ResourceError> {
    request.mutation("resource-api").map_err(resource_operation_error)
}

fn ensure_session(mux: &Mux, selectors: &ResourceSelectors) -> Result<(), ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, selectors).map(|_| ())
}

fn state_result(mux: &Mux, commit: StateCommit) -> Result<Value, ResourceError> {
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn patch_result(mux: &Mux, commit: ResourcePatchCommit) -> Result<Value, ResourceError> {
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn string(fields: &Map<String, Value>, name: &str) -> Option<String> {
    fields.get(name).and_then(Value::as_str).map(str::to_string)
}

/// `None` when absent, `Some(None)` for JSON null, `Some(Some(value))`.
fn nullable_string(fields: &Map<String, Value>, name: &str) -> Option<Option<String>> {
    fields.get(name).map(|value| value.as_str().map(str::to_string))
}

fn index(fields: &Map<String, Value>, name: &str) -> Option<usize> {
    fields.get(name).and_then(Value::as_u64).and_then(|value| usize::try_from(value).ok())
}

fn strings(fields: &Map<String, Value>, name: &str) -> Vec<String> {
    fields
        .get(name)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_str().map(str::to_string))
        .collect()
}

fn require_any(fields: &Map<String, Value>, names: &[&str]) -> Result<(), ResourceError> {
    if names.iter().any(|name| fields.contains_key(*name)) {
        Ok(())
    } else {
        Err(validation_error(
            &format!("at least one of {} is required", names.join(", ")),
            json!({"field": names[0]}),
        ))
    }
}

/// A strip request whose fingerprint is the operation and its parameters.
fn strip_request(request: &ParsedResourceRequest) -> Result<StripRequest, ResourceError> {
    let mut fields = request.fields.clone();
    fields.remove("expected_revision");
    Ok(Mux::strip_request(
        mutation(request)?,
        operation_name(request.envelope.operation).as_str(),
        json!({
            "operation": operation_name(request.envelope.operation),
            "selectors": request.selectors,
            "fields": fields,
        }),
        expected_revision(&request.fields)?,
    ))
}

fn read<T>(
    mux: &Mux,
    read: impl FnOnce(&rusqlite::Connection) -> anyhow::Result<T>,
) -> Result<T, ResourceError> {
    mux.personal_state_read(read)
}

fn found(value: Option<Value>, scope: &str, id: &str) -> Result<Value, ResourceError> {
    value.ok_or_else(|| {
        ResourceError::new(
            "resource.not_found",
            format!("no {scope} {id:?}"),
            json!({"scope": scope, "id": id}),
            false,
        )
    })
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    use ResourceOperation as Op;
    debug_assert!(handles(request.envelope.operation));
    let operation = request.envelope.operation;
    let fields = &request.fields;
    let selectors = &request.selectors;
    match operation {
        // A1: workspace identity, pins, tab state
        Op::WorkspaceUpdate => {
            require_any(fields, &["title", "color", "icon"])?;
            let update = WorkspacePresentationUpdate {
                group: None,
                color: nullable_string(fields, "color"),
                icon: nullable_string(fields, "icon"),
                title: nullable_string(fields, "title"),
                ..WorkspacePresentationUpdate::default()
            };
            let commit = mux
                .state_update_workspace(
                    &mutation(&request)?,
                    expected_revision(fields)?,
                    selectors,
                    update,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::TabPin | Op::TabUnpin => {
            let commit = mux
                .state_pin_tab(strip_request(&request)?, selectors.clone(), operation == Op::TabPin)
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabUpdate => {
            require_any(fields, &["zoom", "back", "forward", "owner"])?;
            let update = TabStateUpdate {
                zoom: fields.get("zoom").map(Value::as_f64),
                back: fields.contains_key("back").then(|| strings(fields, "back")),
                forward: fields.contains_key("forward").then(|| strings(fields, "forward")),
                owner: string(fields, "owner"),
            };
            let commit = mux
                .state_update_tab(strip_request(&request)?, selectors.clone(), update)
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        // A2: tab groups
        Op::TabGroupList => {
            ensure_session(mux, selectors)?;
            let pane = string(fields, "pane_id");
            read(mux, |connection| {
                tab_state_store::tab_group_snapshots(connection, pane.as_deref())
            })
            .map(Value::Array)
        }
        Op::TabGroupGet => {
            ensure_session(mux, selectors)?;
            let id = string(fields, "tab_group").unwrap_or_default();
            found(
                read(mux, |connection| tab_state_store::tab_group_snapshot(connection, &id))?,
                "tab_group",
                &id,
            )
        }
        Op::TabGroupCreate => {
            let commit = mux
                .state_create_tab_group(
                    strip_request(&request)?,
                    strings(fields, "tabs"),
                    string(fields, "name"),
                    string(fields, "color"),
                )
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupUpdate => {
            require_any(fields, &["name", "color", "collapsed"])?;
            let group = string(fields, "tab_group").unwrap_or_default();
            let commit = mux
                .tab_group_update(
                    strip_request(&request)?,
                    &group,
                    string(fields, "name"),
                    string(fields, "color"),
                    fields.get("collapsed").and_then(Value::as_bool),
                )
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupAddTabs => {
            let group = string(fields, "tab_group").unwrap_or_default();
            let commit = mux
                .state_add_tabs_to_group(
                    strip_request(&request)?,
                    &group,
                    strings(fields, "tabs"),
                    index(fields, "index"),
                )
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupRemoveTabs => {
            let commit = mux
                .state_remove_tabs_from_groups(strip_request(&request)?, strings(fields, "tabs"))
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupMove => {
            let group = string(fields, "tab_group").unwrap_or_default();
            let commit = mux
                .state_move_tab_group(
                    strip_request(&request)?,
                    &group,
                    string(fields, "pane_id"),
                    index(fields, "index"),
                )
                .map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupUngroup => {
            let group = string(fields, "tab_group").unwrap_or_default();
            let commit =
                mux.tab_group_ungroup(strip_request(&request)?, &group).map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::TabGroupClose => {
            let group = string(fields, "tab_group").unwrap_or_default();
            let (_, commit) =
                mux.tab_group_close(strip_request(&request)?, &group).map_err(state_error)?;
            patch_result(mux, commit)
        }
        // A3: personal workspace groups, placements, rooms
        Op::WorkspaceGroupList => {
            ensure_session(mux, selectors)?;
            let room = string(fields, "room");
            read(mux, |connection| {
                personal_state_store::workspace_group_snapshots(connection, room.as_deref())
            })
            .map(Value::Array)
        }
        Op::WorkspacePlacementList => {
            ensure_session(mux, selectors)?;
            read(mux, personal_state_store::placement_snapshots).map(Value::Array)
        }
        Op::RoomList => {
            ensure_session(mux, selectors)?;
            read(mux, personal_state_store::room_snapshots).map(Value::Array)
        }
        Op::WorkspaceGroupCreate
        | Op::WorkspaceGroupUpdate
        | Op::WorkspaceGroupDelete
        | Op::WorkspaceGroupMove
        | Op::WorkspacePlace
        | Op::RoomCreate
        | Op::RoomUpdate
        | Op::RoomDelete
        | Op::RoomMove
        | Op::RoomFollow
        | Op::RoomPin
        | Op::RoomUnpin => {
            let change = personal_change(operation, fields)?;
            // Workspace-addressed changes resolve their selector in the commit.
            if selectors.workspace.is_none() {
                ensure_session(mux, selectors)?;
            }
            let name = operation.wire_name();
            let commit = mux
                .state_personal(
                    &mutation(&request)?,
                    name,
                    expected_revision(fields)?,
                    selectors,
                    change,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        // A4: saved tab groups
        Op::SavedTabGroupList => {
            ensure_session(mux, selectors)?;
            let room = string(fields, "room");
            read(mux, |connection| {
                tab_state_store::saved_tab_group_snapshots(connection, room.as_deref())
            })
            .map(Value::Array)
        }
        Op::SavedTabGroupSave => {
            let group = string(fields, "tab_group").unwrap_or_default();
            let room = string(fields, "room");
            if let Some(room) = &room {
                let exists =
                    read(mux, |connection| personal_state_store::room_snapshot(connection, room))?;
                found(exists, "room", room)?;
            }
            let commit =
                mux.tab_group_save(strip_request(&request)?, &group, room).map_err(state_error)?;
            patch_result(mux, commit)
        }
        Op::SavedTabGroupReopen => {
            ensure_session(mux, selectors)?;
            let saved = string(fields, "saved_tab_group").unwrap_or_default();
            let commit = mux
                .state_reopen_saved_tab_group(
                    &mutation(&request)?,
                    expected_revision(fields)?,
                    &saved,
                    string(fields, "pane_id"),
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::SavedTabGroupDelete => {
            ensure_session(mux, selectors)?;
            let saved = string(fields, "saved_tab_group").unwrap_or_default();
            let commit = mux
                .saved_tab_group_delete(
                    &mutation(&request)?,
                    expected_revision(fields)?,
                    &saved,
                    false,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        // B1: screens
        Op::ScreenUpdate
        | Op::ScreenMove
        | Op::ScreenGroupCreate
        | Op::ScreenGroupAddScreens
        | Op::ScreenGroupRemoveScreens
        | Op::ScreenGroupUpdate
        | Op::ScreenGroupUngroup => {
            if matches!(operation, Op::ScreenGroupUpdate | Op::ScreenGroupUngroup) {
                ensure_session(mux, selectors)?;
            }
            let change = screen_change(operation, selectors, fields)?;
            let commit =
                mux.state_screen_change(strip_request(&request)?, change).map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::ScreenGroupList => {
            let workspace = if selectors.workspace.is_some() {
                mux.resolve_resource_path(crate::ResourceTarget::Workspace, selectors)?
                    .workspace
                    .map(|id| id.to_string())
            } else {
                ensure_session(mux, selectors)?;
                None
            };
            read(mux, |connection| {
                screen_state_store::screen_group_snapshots(connection, workspace.as_deref())
            })
            .map(Value::Array)
        }
        Op::ScreenGroupGet => {
            ensure_session(mux, selectors)?;
            let id = string(fields, "screen_group").unwrap_or_default();
            found(
                read(mux, |connection| screen_state_store::screen_group_snapshot(connection, &id))?,
                "screen_group",
                &id,
            )
        }
        // B2: closed history
        Op::ClosedList => {
            ensure_session(mux, selectors)?;
            read(mux, closed_history_store::closed_items).map(Value::Array)
        }
        Op::ClosedReopen => {
            ensure_session(mux, selectors)?;
            let closed = string(fields, "closed").unwrap_or_default();
            let commit = mux
                .state_reopen_closed(&mutation(&request)?, expected_revision(fields)?, &closed)
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        // Window records (personal, one writer per record)
        Op::WindowRecordList => {
            ensure_session(mux, selectors)?;
            read(mux, window_record_store::record_snapshots).map(Value::Array)
        }
        Op::WindowRecordPut | Op::WindowRecordDelete => {
            ensure_session(mux, selectors)?;
            let change = if operation == Op::WindowRecordPut {
                WindowRecordChange::Put {
                    record: fields.get("record").cloned().unwrap_or_default(),
                }
            } else {
                WindowRecordChange::Delete
            };
            let commit = mux
                .state_window_record(
                    &mutation(&request)?,
                    &operation_name(operation),
                    &string(fields, "install_id").unwrap_or_default(),
                    &string(fields, "window_id").unwrap_or_default(),
                    expected_revision(fields)?,
                    change,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        // workspace-kind-v1: the one home workspace, created by the store.
        Op::WorkspaceEnsureHome => {
            ensure_session(mux, selectors)?;
            let home = mux.state_ensure_home().map_err(state_error)?;
            mutation_result(
                mux,
                json!({"kind": "workspace", "workspace_id": home.workspace_id}),
                home.revision,
                home.replayed,
            )
        }
        // B4: workspace status
        Op::WorkspaceStatusList => mux.workspace_status_snapshots(selectors).map(Value::Array),
        Op::WorkspaceLogList => {
            let limit = index(fields, "limit").unwrap_or(200);
            mux.workspace_log_lines(selectors, limit).map(Value::Array)
        }
        Op::WorkspaceStatusSet
        | Op::WorkspaceStatusClear
        | Op::WorkspaceProgressSet
        | Op::WorkspaceProgressClear
        | Op::WorkspaceLogAppend
        | Op::WorkspaceLogClear => {
            let change = match operation {
                Op::WorkspaceStatusSet => WorkspaceStatusChange::Set {
                    key: string(fields, "key").unwrap_or_default(),
                    text: string(fields, "text").unwrap_or_default(),
                    icon: string(fields, "icon"),
                    color: string(fields, "color"),
                },
                Op::WorkspaceStatusClear => {
                    WorkspaceStatusChange::Clear { key: string(fields, "key") }
                }
                Op::WorkspaceProgressSet => WorkspaceStatusChange::Progress {
                    value: fields.get("value").and_then(Value::as_f64),
                    label: string(fields, "label"),
                },
                Op::WorkspaceProgressClear => WorkspaceStatusChange::ProgressClear,
                Op::WorkspaceLogAppend => WorkspaceStatusChange::Log {
                    level: string(fields, "level").unwrap_or_else(|| "info".into()),
                    source: string(fields, "source"),
                    text: string(fields, "text").unwrap_or_default(),
                },
                _ => WorkspaceStatusChange::LogClear,
            };
            let commit = mux
                .state_workspace_status(
                    &mutation(&request)?,
                    operation.wire_name(),
                    expected_revision(fields)?,
                    selectors,
                    change,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        operation => Err(ResourceError::operation_failed(
            operation_name(operation),
            "state router received an operation it does not own",
            json!({}),
        )),
    }
}

fn personal_change(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> Result<PersonalChange, ResourceError> {
    use ResourceOperation as Op;
    let group = || string(fields, "workspace_group").unwrap_or_default();
    let room = || string(fields, "room").unwrap_or_default();
    Ok(match operation {
        Op::WorkspaceGroupCreate => PersonalChange::GroupCreate {
            name: string(fields, "name").unwrap_or_default(),
            color: string(fields, "color"),
            collapsed: fields.get("collapsed").and_then(Value::as_bool).unwrap_or(false),
            room: string(fields, "room"),
            index: index(fields, "index"),
        },
        Op::WorkspaceGroupUpdate => {
            require_any(fields, &["name", "color", "collapsed", "room"])?;
            PersonalChange::GroupUpdate {
                group: group(),
                name: string(fields, "name"),
                color: nullable_string(fields, "color"),
                collapsed: fields.get("collapsed").and_then(Value::as_bool),
                room: string(fields, "room"),
            }
        }
        Op::WorkspaceGroupDelete => PersonalChange::GroupDelete { group: group() },
        Op::WorkspaceGroupMove => {
            PersonalChange::GroupMove { group: group(), index: index(fields, "index").unwrap_or(0) }
        }
        Op::WorkspacePlace => {
            require_any(fields, &["group", "index"])?;
            PersonalChange::Place {
                group: nullable_string(fields, "group"),
                index: index(fields, "index"),
            }
        }
        Op::RoomCreate => PersonalChange::RoomCreate {
            name: string(fields, "name").unwrap_or_default(),
            color: string(fields, "color"),
            icon: string(fields, "icon"),
            theme: string(fields, "theme"),
            index: index(fields, "index"),
        },
        Op::RoomUpdate => {
            require_any(
                fields,
                &["name", "color", "icon", "theme", "browser_profile_id", "default_session_id"],
            )?;
            PersonalChange::RoomUpdate {
                room: room(),
                name: string(fields, "name"),
                color: nullable_string(fields, "color"),
                icon: nullable_string(fields, "icon"),
                theme: nullable_string(fields, "theme"),
                browser_profile_id: nullable_string(fields, "browser_profile_id"),
                default_session_id: nullable_string(fields, "default_session_id"),
            }
        }
        Op::RoomDelete => {
            PersonalChange::RoomDelete { room: room(), move_to: string(fields, "move_to") }
        }
        Op::RoomMove => {
            PersonalChange::RoomMove { room: room(), index: index(fields, "index").unwrap_or(0) }
        }
        Op::RoomFollow => {
            PersonalChange::RoomFollow { room: room(), sessions: strings(fields, "sessions") }
        }
        Op::RoomPin => PersonalChange::RoomPin { room: room() },
        _ => PersonalChange::RoomUnpin,
    })
}

fn screen_change(
    operation: ResourceOperation,
    selectors: &ResourceSelectors,
    fields: &Map<String, Value>,
) -> Result<ScreenChange, ResourceError> {
    use ResourceOperation as Op;
    Ok(match operation {
        Op::ScreenUpdate => {
            require_any(fields, &["pinned", "color", "icon"])?;
            ScreenChange::Update {
                selectors: selectors.clone(),
                update: screen_state_store::ScreenMetaUpdate {
                    pinned: fields.get("pinned").and_then(Value::as_bool),
                    color: nullable_string(fields, "color"),
                    icon: nullable_string(fields, "icon"),
                },
            }
        }
        Op::ScreenMove => ScreenChange::Move {
            selectors: selectors.clone(),
            index: index(fields, "index").unwrap_or(0),
        },
        Op::ScreenGroupCreate => ScreenChange::GroupCreate {
            screens: strings(fields, "screens"),
            name: string(fields, "name").unwrap_or_default(),
            color: string(fields, "color").unwrap_or_else(|| "grey".into()),
        },
        Op::ScreenGroupAddScreens => ScreenChange::GroupAdd {
            group: string(fields, "screen_group").unwrap_or_default(),
            screens: strings(fields, "screens"),
        },
        Op::ScreenGroupUpdate => {
            require_any(fields, &["name", "color", "collapsed"])?;
            ScreenChange::GroupUpdate {
                group: string(fields, "screen_group").unwrap_or_default(),
                name: string(fields, "name"),
                color: string(fields, "color"),
                collapsed: fields.get("collapsed").and_then(Value::as_bool),
            }
        }
        Op::ScreenGroupUngroup => {
            ScreenChange::GroupUngroup { group: string(fields, "screen_group").unwrap_or_default() }
        }
        _ => ScreenChange::GroupRemove { screens: strings(fields, "screens") },
    })
}
