//! Unit tests for the sidebar / tab-bar hit testers used by the mouse-click
//! router. Pure coordinate math — no server spin-up required.

use cmux_cli_core::layout::Rect;
use cmux_cli_server::{chrome_layout, hit_test_sidebar, hit_test_tab_bar};

#[test]
fn sidebar_hit_rejects_header_and_spacer_rows() {
    let (sidebar, _space_bar, _tb, _pane, _bb, _st) = chrome_layout((120, 24));
    // The sidebar's first item row is 2 (row 0 = header, row 1 = spacer).
    // Rows 0 and 1 never map to an item regardless of workspace count.
    assert_eq!(hit_test_sidebar(5, 0, sidebar, 3), None);
    assert_eq!(hit_test_sidebar(5, 1, sidebar, 3), None);
}

#[test]
fn sidebar_hit_identifies_workspace_index() {
    let (sidebar, _space_bar, _tb, _pane, _bb, _st) = chrome_layout((120, 24));
    assert_eq!(hit_test_sidebar(5, 2, sidebar, 3), Some(0));
    assert_eq!(hit_test_sidebar(5, 3, sidebar, 3), Some(1));
    assert_eq!(hit_test_sidebar(5, 4, sidebar, 3), Some(2));
    // Row past the last workspace — no item to click.
    assert_eq!(hit_test_sidebar(5, 5, sidebar, 3), None);
}

#[test]
fn sidebar_hit_rejects_clicks_outside_sidebar_cols() {
    let (sidebar, _space_bar, _tb, _pane, _bb, _st) = chrome_layout((120, 24));
    // Column 20 is in the pane, not the sidebar (sidebar is 16 wide).
    assert_eq!(hit_test_sidebar(20, 2, sidebar, 3), None);
}

#[test]
fn sidebar_hit_returns_none_when_sidebar_hidden() {
    // Narrow viewport hides the sidebar.
    let (sidebar, _space_bar, _tb, _pane, _bb, _st) = chrome_layout((40, 24));
    assert_eq!(sidebar.cols, 0);
    assert_eq!(hit_test_sidebar(0, 2, sidebar, 3), None);
}

#[test]
fn tab_bar_hit_identifies_tab_index() {
    let (_sb, _space_bar, tab_bar, _pane, _bb, _st) = chrome_layout((120, 24));
    let titles = vec!["shell".into(), "logs".into(), "vim".into()];
    // Pill labels now have a leading 1-col activity-marker slot (a
    // dot on busy inactive tabs, a space otherwise). So " · 1:shell "
    // is 10 cols, " · 2:logs " is 9, " · 3:vim " is 8.
    let base = tab_bar.col;
    assert_eq!(
        hit_test_tab_bar(base, tab_bar.row, tab_bar, &titles),
        Some(0)
    );
    assert_eq!(
        hit_test_tab_bar(base + 9, tab_bar.row, tab_bar, &titles),
        Some(0)
    );
    assert_eq!(
        hit_test_tab_bar(base + 10, tab_bar.row, tab_bar, &titles),
        Some(1)
    );
    assert_eq!(
        hit_test_tab_bar(base + 18, tab_bar.row, tab_bar, &titles),
        Some(1)
    );
    assert_eq!(
        hit_test_tab_bar(base + 19, tab_bar.row, tab_bar, &titles),
        Some(2)
    );
    assert_eq!(
        hit_test_tab_bar(base + 26, tab_bar.row, tab_bar, &titles),
        Some(2)
    );
    // Past the last pill → None (empty tab-bar space).
    assert_eq!(
        hit_test_tab_bar(base + 27, tab_bar.row, tab_bar, &titles),
        None
    );
}

#[test]
fn tab_bar_hit_rejects_wrong_row() {
    let (_sb, _space_bar, tab_bar, _pane, _bb, _st) = chrome_layout((120, 24));
    let titles = vec!["a".into()];
    // Row 1 is inside the pane, not the tab bar.
    assert_eq!(
        hit_test_tab_bar(tab_bar.col, tab_bar.row + 1, tab_bar, &titles),
        None
    );
}

#[test]
fn tab_bar_hit_returns_none_with_no_tabs() {
    let (_sb, _space_bar, tab_bar, _pane, _bb, _st) = chrome_layout((120, 24));
    assert_eq!(
        hit_test_tab_bar(tab_bar.col, tab_bar.row, tab_bar, &[]),
        None
    );
}

#[test]
fn tab_bar_hit_truncates_when_viewport_too_narrow() {
    // Synthesize a tab bar that only fits one pill.
    let tab_bar = Rect {
        col: 16,
        row: 0,
        cols: 10,
        rows: 1,
    };
    let titles = vec!["a".into(), "b".into(), "c".into()];
    // `"  1:a "` = 6 cols (marker + space + "1:a" + space). A 10-col
    // bar fits only one pill since the second would start at col 6
    // and need 6 more (overflow).
    assert_eq!(hit_test_tab_bar(16, 0, tab_bar, &titles), Some(0));
    assert_eq!(hit_test_tab_bar(21, 0, tab_bar, &titles), Some(0));
    // Pill 2 doesn't fit → col 22 is in the empty tail.
    assert_eq!(hit_test_tab_bar(22, 0, tab_bar, &titles), None);
    // col=26 is one past tab_bar.col + tab_bar.cols → outside the bar.
    assert_eq!(hit_test_tab_bar(26, 0, tab_bar, &titles), None);
}
