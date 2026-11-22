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
    for count in [0, crate::mux::layout_sizes::MAX_LAYOUT_SIZE_VALUES + 1] {
        let values = vec![LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 }; count];
        let error = mux
            .set_layout_sizes_in_transaction_checked_as(&Actor::Daemon, &values, 7, 14)
            .unwrap_err();
        assert!(matches!(error, LayoutSizesError::BadCount { count: c } if c == count), "{error}");
    }
    assert_eq!(widths_revision_and_undo(&mux), before);
}

/// Three columns (the first pane and two panes right of it), the panes left to right.
fn three_columns(mux: &Arc<Mux>) -> [PaneId; 3] {
    let (first_pane, second_pane) = two_columns(mux);
    let third = mux.new_pane_right(second_pane, 0.5, Some((18, 22))).unwrap();
    let third_pane = mux.with_state(|state| state.pane_of(third.id).unwrap());
    [first_pane, second_pane, third_pane]
}

/// The split id of the column at `index` on the first screen.
fn column_split(mux: &Arc<Mux>, index: usize) -> SplitId {
    mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[index].id)
}

/// #34928 review C: a ratio value sets its column's width from the widths the same batch set before it (a column
/// split's ratio is the share of the columns left of it), and the batch is still one change and one undo step.
#[test]
fn a_ratio_value_uses_the_widths_the_batch_set_before_it() {
    let mux = test_mux();
    let [first_pane, _, _] = three_columns(&mux);
    let third_split = column_split(&mux, 2);
    let (_, revision, undo) = widths_revision_and_undo(&mux);

    mux.set_layout_sizes_in_transaction_checked_as(
        &Actor::Daemon,
        &[
            LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
            LayoutSizeValue::SplitRatio { split: third_split, ratio: 0.5 },
        ],
        7,
        15,
    )
    .unwrap();
    let (widths, after_revision, after_undo) = widths_revision_and_undo(&mux);
    let left_of_third = widths[0] + widths[1];
    assert!(
        (widths[2] - left_of_third).abs() < 1e-5,
        "a ratio of 0.5 must make the third column as wide as the two left of it as the batch set them: {widths:?}"
    );
    assert!((widths[0] - 0.4).abs() < 1e-6, "the batch's first width: {widths:?}");
    assert_eq!(after_revision, revision + 1, "the batch made more than one layout change");
    assert_eq!(after_undo, undo + 1, "the batch is not one undo step");
}

/// #34928 review B: a NaN ratio is refused in-process (the clamp keeps a NaN, and the store cannot persist one), and
/// nothing changes.
#[test]
fn a_nan_ratio_is_refused_and_changes_nothing() {
    let mux = test_mux();
    let [first_pane, _, _] = three_columns(&mux);
    let third_split = column_split(&mux, 2);
    let before = widths_revision_and_undo(&mux);
    let error = mux
        .set_layout_sizes_in_transaction_checked_as(
            &Actor::Daemon,
            &[
                LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
                LayoutSizeValue::SplitRatio { split: third_split, ratio: f32::NAN },
            ],
            7,
            16,
        )
        .expect_err("a NaN ratio was taken");
    assert!(matches!(error, LayoutSizesError::NanRatio { index: 1 }), "{error}");
    assert_eq!(error.code(), "invalid-argument");
    assert_eq!(widths_revision_and_undo(&mux), before, "a refused batch changed the layout");
}

/// #34928 review C: values on two screens are refused whole, with the index of the first value on another screen.
#[test]
fn values_on_two_screens_are_refused_whole() {
    let mux = test_mux();
    let (first_pane, _) = two_columns(&mux);
    let second = mux.new_screen(None, Some((80, 22))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    mux.new_pane_right(second_pane, 0.5, Some((38, 22))).unwrap();
    let before = widths_revision_and_undo(&mux);

    let error = mux
        .set_layout_sizes_in_transaction_checked_as(
            &Actor::Daemon,
            &[
                LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
                LayoutSizeValue::PaneWidth { pane: second_pane, width: 0.4 },
            ],
            7,
            17,
        )
        .unwrap_err();
    assert!(matches!(error, LayoutSizesError::OtherScreen { index: 1 }), "{error}");
    assert_eq!(error.code(), "layout-sizes-other-screen");
    assert_eq!(widths_revision_and_undo(&mux), before, "a refused batch changed the layout");
}

/// #34928 review C: a batch that changes nothing commits nothing: no layout change, no undo step, no event.
#[test]
fn a_batch_of_the_current_sizes_commits_nothing() {
    let mux = test_mux();
    let (first_pane, right_pane) = two_columns(&mux);
    let before = widths_revision_and_undo(&mux);
    let values: Vec<_> = [first_pane, right_pane]
        .iter()
        .zip(&before.0)
        .map(|(pane, width)| LayoutSizeValue::PaneWidth { pane: *pane, width: *width })
        .collect();
    let events = mux.subscribe();

    mux.set_layout_sizes_in_transaction_checked_as(&Actor::Daemon, &values, 7, 18).unwrap();
    assert_eq!(
        widths_revision_and_undo(&mux),
        before,
        "a batch of the current sizes changed the layout"
    );
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, MuxEvent::LayoutChanged(..)),
            "a batch that changed nothing sent a layout-changed event"
        );
    }
}

/// #34928 review C: a batch that changes the layout sends exactly one layout-changed event.
#[test]
fn a_batch_sends_one_layout_changed_event() {
    let mux = test_mux();
    let (first_pane, right_pane) = two_columns(&mux);
    let events = mux.subscribe();

    mux.set_layout_sizes_in_transaction_checked_as(
        &Actor::Daemon,
        &[
            LayoutSizeValue::PaneWidth { pane: first_pane, width: 0.4 },
            LayoutSizeValue::PaneWidth { pane: right_pane, width: 0.6 },
        ],
        7,
        19,
    )
    .unwrap();
    let mut transactions = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let MuxEvent::LayoutChanged(_, delta) = event {
            transactions.push(delta.and_then(|delta| delta.transaction.clone()));
        }
    }
    assert_eq!(
        transactions,
        vec![Some(Arc::<str>::from("19"))],
        "a batch of two values must send one layout-changed event that echoes its transaction"
    );
}

/// #34928 review B, on the path it named: a tree split (no viewport column, so no implied width to refuse it) takes
/// the ratio as it is. A NaN ratio is refused there too; an infinite one (JSON `1e39` read as f32) clamps to 0.95, as
/// `set-split-ratio` clamps it (#35261 review).
#[test]
fn a_nan_ratio_on_a_tree_split_is_refused_and_an_infinite_one_clamps() {
    let mux = test_mux();
    let (_, _, _, root_split, _) = seed_split_ratio_tree(&mux);
    let root_ratio = |mux: &Arc<Mux>| {
        mux.with_state(|state| state.workspaces[0].screens[0].root.split_ratio(root_split))
    };
    let before = root_ratio(&mux);
    assert!(before.is_some(), "the seed's root is a split");
    let error = mux
        .set_layout_sizes_in_transaction_checked_as(
            &Actor::Daemon,
            &[LayoutSizeValue::SplitRatio { split: root_split, ratio: f32::NAN }],
            7,
            20,
        )
        .expect_err("a NaN ratio on a tree split was taken");
    assert!(matches!(error, LayoutSizesError::NanRatio { index: 0 }), "{error}");
    assert_eq!(root_ratio(&mux), before, "a refused ratio changed the split");

    mux.set_layout_sizes_in_transaction_checked_as(
        &Actor::Daemon,
        &[LayoutSizeValue::SplitRatio { split: root_split, ratio: f32::INFINITY }],
        7,
        21,
    )
    .expect("an infinite ratio is clamped, as set-split-ratio clamps it");
    assert_eq!(root_ratio(&mux), Some(0.95), "an infinite ratio did not clamp to 0.95");
}
