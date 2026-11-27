//! The wire form of tab group, screen group and tab drag outcomes, and of
//! pane tab group runs and workspace groups (moved out of server.rs,
//! behavior unchanged).

use super::*;
use crate::panic_free::JsonFields;
pub(super) use crate::tree_wire::{
    pane_tab_group_json, workspace_group_json, workspace_groups_json,
};

pub(super) fn screen_group_outcome_json(outcome: &crate::ScreenGroupOutcome) -> Value {
    json!({
        "group": outcome.group.as_ref().map(|group| json!({
            "id": group.id,
            "name": group.name,
            "color": group.color,
            "collapsed": group.collapsed,
            "saved_id": group.saved_id,
            "icon": group.icon,
        })),
        "workspace": outcome.workspace,
        "key": outcome.key,
        "screens": outcome.members,
    })
}

pub(super) fn tab_group_outcome_json(outcome: &crate::TabGroupOutcome) -> Value {
    json!({
        "group": outcome.group.as_ref().map(|group| json!({
            "id": group.id,
            "name": group.name,
            "color": group.color,
            "collapsed": group.collapsed,
            "saved_id": group.saved_id,
            "icon": group.icon,
        })),
        "pane": outcome.pane,
        "workspace": outcome.workspace,
        "surfaces": outcome.members,
    })
}

pub(super) fn tab_drag_outcome_json(outcome: &crate::TabDragOutcome) -> Value {
    json!({
        "surface": outcome.surface,
        "pane": outcome.pane,
        "screen": outcome.screen,
        "workspace": outcome.workspace,
        "undoable": outcome.undoable,
    })
}
