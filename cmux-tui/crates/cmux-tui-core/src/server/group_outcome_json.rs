//! The wire form of tab group, screen group and tab drag outcomes, and of
//! pane tab group runs and workspace groups (moved out of server.rs,
//! behavior unchanged).

use super::*;

pub(super) fn screen_group_outcome_json(outcome: &crate::ScreenGroupOutcome) -> Value {
    json!({
        "group": outcome.group.as_ref().map(|group| json!({
            "id": group.id,
            "name": group.name,
            "color": group.color,
            "collapsed": group.collapsed,
            "saved_id": group.saved_id,
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

pub(super) fn pane_tab_group_json(run: &crate::mux::PaneTabGroup, pane: Option<PaneId>) -> Value {
    let mut value = json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "start": run.start,
        "count": run.members.len(),
        "surfaces": run.members,
    });
    if let Some(pane) = pane {
        value["pane"] = json!(pane);
    }
    value
}

pub(super) fn workspace_group_json(
    group: &crate::workspace_registry::WorkspaceGroupRecord,
    index: usize,
) -> Value {
    json!({
        "id": group.id,
        "name": group.name,
        "color": group.color,
        "collapsed": group.collapsed,
        "index": index,
    })
}

pub(super) fn workspace_groups_json(
    presentation: &crate::workspace_registry::PresentationSnapshot,
) -> Value {
    json!(
        presentation
            .groups
            .iter()
            .enumerate()
            .map(|(index, group)| workspace_group_json(group, index))
            .collect::<Vec<_>>()
    )
}
