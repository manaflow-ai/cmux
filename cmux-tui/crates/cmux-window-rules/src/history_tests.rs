use super::*;

#[test]
fn each_walk_has_its_direction_and_its_nowhere() {
    let table = actions();
    let walks: Vec<_> =
        table.walks.iter().map(|walk| (walk.action, walk.direction, walk.nowhere)).collect();
    assert_eq!(
        walks,
        vec![
            ("focusHistoryBack", Direction::Back, Nowhere::NothingBack),
            ("focusHistoryForward", Direction::Forward, Nowhere::NothingForward),
            ("focusHistoryLast", Direction::Last, Nowhere::NothingLast),
        ]
    );
    assert_eq!(table.pages.len(), 4);
    assert_eq!(table.history_page, vec!["history.show", "browserShowHistory"]);
}

#[test]
fn an_undo_that_needs_no_confirmation_leaves_nothing_pending() {
    assert_eq!(undo_reply(false, Some(4), Some(2)), UndoReply::default());
}

#[test]
fn an_undo_that_closes_panes_waits_for_the_next_undo_on_its_revision() {
    assert_eq!(
        undo_reply(true, Some(4), Some(2)),
        UndoReply { pending: Some(4), closes_panes: Some(2) }
    );
    assert_eq!(undo_reply(true, None, None), UndoReply { pending: None, closes_panes: Some(1) });
}

#[test]
fn each_tab_walk_has_its_step_and_its_strict_scope() {
    let walks: Vec<_> =
        actions().tab_walks.iter().map(|walk| (walk.action, walk.step, walk.scope)).collect();
    assert_eq!(
        walks,
        vec![
            ("focusTabBack", TabStep::Back, TabScope::Any),
            ("focusTabBackInWorkspace", TabStep::Back, TabScope::Workspace),
            ("focusTabRecent", TabStep::Recent, TabScope::Any),
            ("focusTabRecentInWorkspace", TabStep::Recent, TabScope::Workspace),
        ]
    );
}
