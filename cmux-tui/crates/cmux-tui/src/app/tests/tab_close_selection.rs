//! Tests: the tab a pane shows after one of its tabs closes, in this client's
//! cached tree (the repair before the daemon's next tree): Chrome's rule, the
//! tab after the closed one, else the one before it, as the app and the
//! daemon pick it (cmux-focus-core `close_focus::tab`; Lawrence 2026-11-09:
//! "ensure our cmd w behavior matches chrome").

use super::*;
use crate::app::adjust_active_tab_after_removal;

fn pane(count: u64, active: usize) -> PaneView {
    let tab = |surface: u64| TabView {
        surface,
        public_id: None,
        content_id: None,
        terminal_id: None,
        short_id: format!("t{surface}"),
        name: None,
        title: String::new(),
        kind: SurfaceKind::Pty,
        browser_source: None,
        browser_frames_stalled: false,
        supports_clear_history_key_fallback: false,
        notification: None,
        program_status: None,
        attention: None,
        git_branch: None,
    };
    PaneView {
        id: 1,
        resource_id: None,
        short_id: "p".to_string(),
        name: None,
        tabs: (1..=count).map(tab).collect(),
        active_tab: active,
        focused_at: 0,
    }
}

/// Closes the tab at `index` as the cached tree does (remove, then repair)
/// and returns the surface the pane shows.
fn close(pane: &mut PaneView, index: usize) -> Option<u64> {
    pane.tabs.remove(index);
    adjust_active_tab_after_removal(pane, index);
    pane.tabs.get(pane.active_tab).map(|tab| tab.surface)
}

#[test]
fn tab_close_like_chrome_in_the_tui_cached_tree() {
    // 1 2 3 4, 3 selected and closed: 4, the tab after it.
    let mut strip = pane(4, 2);
    assert_eq!(close(&mut strip, 2), Some(4));
    // The last tab selected and closed: the one before it.
    let mut strip = pane(4, 3);
    assert_eq!(close(&mut strip, 3), Some(3));
    // The first tab selected and closed: the one after it.
    let mut strip = pane(3, 0);
    assert_eq!(close(&mut strip, 0), Some(2));
}

#[test]
fn tab_close_like_chrome_keeps_an_unselected_close_in_the_tui() {
    let mut strip = pane(4, 1);
    assert_eq!(close(&mut strip, 3), Some(2));
    assert_eq!(close(&mut strip, 0), Some(2));
}

#[test]
fn tab_close_like_chrome_on_rapid_closes_in_the_tui() {
    // 1 2 3 4 with 3 selected, the selected tab closed four times: each close
    // starts from the selection the one before made.
    let mut strip = pane(4, 2);
    let mut shown = Vec::new();
    while !strip.tabs.is_empty() {
        let index = strip.active_tab;
        shown.push(close(&mut strip, index));
    }
    // 3 closes: 4; 4 (last) closes: 2; 2 closes: 1.
    assert_eq!(shown, vec![Some(4), Some(2), Some(1), None]);
}
