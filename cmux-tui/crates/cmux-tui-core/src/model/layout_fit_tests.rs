use super::super::{ColumnDock, DockEdge, DockMode, LayoutColumn, Node, Screen};
use crate::SplitId;
use crate::resource::ScreenPublicId;

fn tree_screen() -> Screen {
    Screen {
        id: 1,
        public_id: ScreenPublicId::parse(format!("screen_{:032x}", 1)).unwrap(),
        name: None,
        root: Node::Leaf(10),
        active_pane: 10,
        zoomed_pane: None,
        creation_order_auto_layout: None,
        viewport_splits: Default::default(),
        viewport_base_width: None,
        layout_columns: Vec::new(),
        layout_revision: 0,
        layout_undo: Default::default(),
    }
}

fn screen(widths: &[f32]) -> Screen {
    let mut screen = tree_screen();
    screen.layout_columns = widths
        .iter()
        .enumerate()
        .map(|(index, width)| {
            LayoutColumn::single(index as SplitId + 100, *width, 10 + index as u64)
        })
        .collect();
    screen
}

fn widths(screen: &Screen) -> Vec<f32> {
    screen.layout_columns.iter().map(|column| column.width).collect()
}

fn close(actual: &[f32], expected: &[f32]) {
    assert_eq!(actual.len(), expected.len(), "{actual:?} vs {expected:?}");
    for (a, e) in actual.iter().zip(expected) {
        assert!((a - e).abs() < 1e-4, "{actual:?} vs {expected:?}");
    }
}

#[test]
fn a_column_beside_a_full_width_one_makes_two_halves() {
    let mut screen = screen(&[1.0, 0.5]);
    assert!(screen.fit_strip_after_insert(101));
    close(&widths(&screen), &[0.5, 0.5]);
}

#[test]
fn a_third_column_takes_a_third_and_keeps_the_others_proportions() {
    let mut even = screen(&[0.5, 0.5, 0.5]);
    assert!(even.fit_strip_after_insert(102));
    close(&widths(&even), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
    let mut uneven = screen(&[0.75, 0.25, 0.5]);
    assert!(uneven.fit_strip_after_insert(102));
    close(&widths(&uneven), &[0.5, 1.0 / 6.0, 1.0 / 3.0]);
}

#[test]
fn a_column_that_would_shrink_under_the_minimum_gets_equal_shares() {
    let mut screen = screen(&[0.9, 0.1, 0.5]);
    assert!(screen.fit_strip_after_insert(102));
    close(&widths(&screen), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
}

#[test]
fn too_many_columns_to_fit_keep_their_widths() {
    let mut many: Vec<f32> = vec![0.1; 10];
    many.push(0.5);
    let mut screen = screen(&many);
    assert!(!screen.fit_strip_after_insert(110));
    close(&widths(&screen), &many);
}

#[test]
fn docked_columns_keep_their_width_and_do_not_count() {
    let mut screen = screen(&[0.33, 1.0, 0.5]);
    screen.layout_columns[0].dock = Some(ColumnDock::new(DockEdge::Left, DockMode::Docked));
    assert!(screen.fit_strip_after_insert(102));
    close(&widths(&screen), &[0.33, 0.5, 0.5]);
}

#[test]
fn a_split_tree_and_a_fitting_strip_fit_and_a_wide_strip_does_not() {
    assert!(tree_screen().strip_fits_window());
    assert!(screen(&[0.5, 0.5]).strip_fits_window());
    assert!(!screen(&[1.0, 0.5]).strip_fits_window());
}
