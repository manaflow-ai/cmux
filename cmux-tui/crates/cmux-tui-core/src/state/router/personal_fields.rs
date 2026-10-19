//! The personal state operations' fields (`workspace_group.*`,
//! `workspace.place`, `room.*`) as one [`PersonalChange`].

use serde_json::{Map, Value};

use super::{index, nullable_string, require_any, string, strings};
use crate::mux::PersonalChange;
use crate::resource::{ResourceError, ResourceOperation};

pub(super) fn personal_change(
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
            parent: string(fields, "parent_group"),
        },
        Op::WorkspaceGroupUpdate => {
            require_any(
                fields,
                &[
                    "name",
                    "color",
                    "collapsed",
                    "room",
                    "top_index",
                    "icon",
                    "pinned",
                    "parent_group",
                ],
            )?;
            PersonalChange::GroupUpdate {
                group: group(),
                name: string(fields, "name"),
                color: nullable_string(fields, "color"),
                collapsed: fields.get("collapsed").and_then(Value::as_bool),
                room: string(fields, "room"),
                top_index: fields
                    .get("top_index")
                    .map(|value| value.as_u64().and_then(|index| usize::try_from(index).ok())),
                icon: nullable_string(fields, "icon"),
                pinned: fields.get("pinned").and_then(Value::as_bool),
                parent: nullable_string(fields, "parent_group"),
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
