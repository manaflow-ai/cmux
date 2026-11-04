//! `set-layout-sizes` (R-DAEMON-STATE DESIGN 2.10.1): a key resize's or a drag release's divider values commit as
//! one change, or not at all.

use super::*;

/// Two columns (the first pane, a pane right of it) and the right column's width, the layout revision and the undo
/// depth of their screen.
fn two_columns(mux: &Arc<Mux>) -> (PaneId, PaneId) {
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    (first_pane, right_pane)
}

fn widths_revision_and_undo(mux: &Arc<Mux>) -> (Vec<f32>, u64, usize) {
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (
            screen.layout_columns.iter().map(|column| column.width).collect(),
            screen.layout_revision,
            screen.layout_undo.len(),
        )
    })
}

/// A key trade whose second width the daemon refuses must leave the first width unapplied: the person sees the old
/// sizes again, never half a trade.
#[test]
fn a_refused_second_value_leaves_the_first_unapplied() {
    let mux = test_mux();
    let (first_pane, right_pane) = two_columns(&mux);
    let before = widths_revision_and_undo(&mux);

    let error = mux
        .set_layout_sizes_in_transaction_checked_as(
            &Actor::Daemon,
            &[
                LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
                LayoutSizeValue::PaneWidth { pane: right_pane, width: 1.5 },
            ],
            7,
            11,
        )
        .unwrap_err();
    assert_eq!(error.index(), Some(1), "{error}");
    assert_eq!(error.code(), ViewportWidthError::OUT_OF_RANGE_CODE, "{error}");
    assert_eq!(
        widths_revision_and_undo(&mux),
        before,
        "a refused second value left the first applied (or moved the layout revision or the undo stack)"
    );
}

/// A batch the daemon takes is one layout change and one undo step, and one undo restores every value.
#[test]
fn a_batch_is_one_layout_change_and_one_undo_step() {
    let mux = test_mux();
    let (first_pane, right_pane) = two_columns(&mux);
    let (widths, revision, undo) = widths_revision_and_undo(&mux);

    mux.set_layout_sizes_in_transaction_checked_as(
        &Actor::Daemon,
        &[
            LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
            LayoutSizeValue::PaneWidth { pane: right_pane, width: 0.6 },
        ],
        7,
        12,
    )
    .unwrap();
    let (after_widths, after_revision, after_undo) = widths_revision_and_undo(&mux);
    assert_eq!(after_widths, vec![0.4, 0.6]);
    assert_eq!(after_revision, revision + 1, "the batch made more than one layout change");
    assert_eq!(after_undo, undo + 1, "the batch is not one undo step");

    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_eq!(widths_revision_and_undo(&mux).0, widths, "one undo did not restore every value");
}

/// The values the drag sent while it moved (`set-viewport-pane-width` under the same transaction) and its release
/// batch are one undo step.
#[test]
fn a_release_batch_joins_its_drag_in_one_undo_step() {
    let mux = test_mux();
    let (first_pane, right_pane) = two_columns(&mux);
    let (widths, _, undo) = widths_revision_and_undo(&mux);

    mux.set_viewport_pane_width_in_transaction_checked(right_pane, 0.55, 7, 13).unwrap();
    mux.set_layout_sizes_in_transaction_checked_as(
        &Actor::Daemon,
        &[
            LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
            LayoutSizeValue::PaneWidth { pane: right_pane, width: 0.6 },
        ],
        7,
        13,
    )
    .unwrap();
    assert_eq!(
        widths_revision_and_undo(&mux).2,
        undo + 1,
        "drag and release are not one undo step"
    );
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_eq!(widths_revision_and_undo(&mux).0, widths);
}

/// No value, or more than the limit, changes nothing and says so.
#[test]
fn an_empty_or_oversized_batch_is_refused() {
    let mux = test_mux();
    let (first_pane, _) = two_columns(&mux);
    let before = widths_revision_and_undo(&mux);
    for count in [0, MAX_LAYOUT_SIZE_VALUES + 1] {
        let values = vec![LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 }; count];
        let error = mux
            .set_layout_sizes_in_transaction_checked_as(&Actor::Daemon, &values, 7, 14)
            .unwrap_err();
        assert!(matches!(error, LayoutSizesError::BadCount { count: c } if c == count), "{error}");
    }
    assert_eq!(widths_revision_and_undo(&mux), before);
}
