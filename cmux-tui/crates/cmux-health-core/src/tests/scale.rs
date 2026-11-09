//! Constant cost as parts grow: hidden parts are never timed, a tick visits
//! only expired heap entries, and dead entries do not pile up, nor does
//! sweeping them look at any part that is not armed.

use super::*;
use crate::State;

const PAGES: usize = 10_000;

#[test]
fn ten_thousand_hidden_pages_cost_a_tick_nothing() {
    let mut h = model();
    for n in 0..PAGES {
        h.register(&format!("page:{n}"), Kind::Page, "Workspace page", Some(0), false);
    }
    assert_eq!(h.next_tick_ms(), None, "hidden pages arm no timer");
    register(&mut h, "page:live", Kind::Page, "Agent chat", 0);
    assert_eq!(h.next_tick_ms(), Some(5_000));
    assert_eq!(h.heap_sizes(), (1, 1));

    h.visited = 0;
    assert!(h.tick(4_999).is_empty());
    assert_eq!(h.visited, 0, "nothing expired, nothing visited");
    h.tick(5_000);
    assert_eq!(h.visited, 1, "only the one visible page");
    assert_eq!(h.snapshot().parts.len(), 1);
    assert_eq!(h.snapshot().parts[0].state, State::Slow);
}

#[test]
fn hiding_ten_thousand_armed_pages_leaves_a_small_heap() {
    let mut h = model();
    register(&mut h, "page:live", Kind::Page, "Agent chat", 0);
    for n in 0..PAGES {
        register(&mut h, &format!("page:{n}"), Kind::Page, "Workspace page", 0);
    }
    assert_eq!(h.heap_sizes(), (PAGES + 1, PAGES + 1));
    for n in 0..PAGES {
        h.visibility(&format!("page:{n}"), false, 100);
    }
    let (armed, entries) = h.heap_sizes();
    assert_eq!(armed, 1);
    assert!(entries <= 65, "dead entries are rebuilt away: {entries}");

    h.visited = 0;
    h.tick(5_000);
    assert!(h.visited <= 65, "a tick is bounded by the live parts, not by {PAGES}: {}", h.visited);
    assert_eq!(h.snapshot().parts.len(), 1);
}

#[test]
fn beats_do_not_grow_the_heap() {
    let mut h = model();
    register(&mut h, "page:live", Kind::Page, "Agent chat", 0);
    for n in 0..PAGES as u64 {
        h.beat("page:live", n * 2_000);
    }
    let (armed, entries) = h.heap_sizes();
    assert_eq!(armed, 1);
    assert!(entries <= 65, "{entries}");
    assert_eq!(h.next_tick_ms(), Some((PAGES as u64 - 1) * 2_000 + 5_000));
}

#[test]
fn all_healthy_or_hidden_means_no_timer() {
    let mut h = model();
    register(&mut h, "page:a", Kind::Page, "A", 0);
    register(&mut h, "sessionDaemon", Kind::SessionDaemon, "Session service", 0);
    register(&mut h, "roster", Kind::Roster, "Workspaces", 0);
    register(&mut h, "pageHost", Kind::PageHost, "Page server", 0);
    register(&mut h, "renderer:1", Kind::Renderer, "Web content", 0);
    assert_eq!(h.next_tick_ms(), Some(5_000), "only the visible page is timed");
    h.visibility("page:a", false, 1_000);
    assert_eq!(h.next_tick_ms(), None);
    assert!(h.tick(1_000_000).is_empty());
    assert_eq!(h.snapshot().worst, State::Healthy);
}

#[test]
fn re_arming_one_page_beside_ten_thousand_hidden_ones_never_walks_them() {
    const BEATS: u64 = 10_000;
    let mut h = model();
    for n in 0..PAGES {
        h.register(&format!("page:{n}"), Kind::Page, "Workspace page", Some(0), false);
    }
    register(&mut h, "page:live", Kind::Page, "Agent chat", 0);
    h.rebuilt = 0;
    for n in 0..BEATS {
        h.beat("page:live", n * 2_000);
    }
    assert_eq!(h.heap_sizes().0, 1);
    // Every beat leaves one dead entry; each rebuild sweeps the ~65 entries
    // in the heap, so the total is about one look per beat, not 10,000 per
    // rebuild.
    assert!(h.rebuilt > 0, "the heap was rebuilt");
    assert!(h.rebuilt <= 2 * BEATS, "rebuilds are O(armed), not O(parts): {}", h.rebuilt);
    assert_eq!(h.next_tick_ms(), Some((BEATS - 1) * 2_000 + 5_000));
}
