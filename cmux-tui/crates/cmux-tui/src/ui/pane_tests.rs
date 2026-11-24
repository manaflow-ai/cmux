use super::{client_border_labels, clip_tab_bar_rect, tab_scroll_for_active};
use crate::session::{ClientInfo, ClientSizeInfo};
use cmux_tui_core::Rect;

#[test]
fn offscreen_tab_hit_clipping_returns_none_without_underflow() {
    let bar = Rect { x: 0, y: 0, width: 8, height: 1 };
    let logical = Rect { x: 1, y: 0, width: 3, height: 1 };
    assert_eq!(clip_tab_bar_rect(logical, bar, 10), None);
}

#[test]
fn tab_scroll_preserves_requested_offset_when_active_range_fits() {
    assert_eq!(tab_scroll_for_active(&[4, 5, 6, 7], 2, 1, 15, 1, 1), 1);
}

#[test]
fn tab_scroll_advances_to_the_first_offset_that_fits_active_tab() {
    assert_eq!(tab_scroll_for_active(&[4, 5, 6, 7], 3, 0, 16, 1, 1), 2);
}

#[test]
fn tab_scroll_handles_a_large_tab_set_without_changing_selection_semantics() {
    let widths = vec![3; 100_000];
    assert_eq!(tab_scroll_for_active(&widths, 99_999, 0, 12, 1, 1), 99_997);
}

fn client(id: u64, surface: u64, size: Option<(u16, u16)>) -> ClientInfo {
    ClientInfo {
        client: id,
        transport: "unix".to_string(),
        name: None,
        kind: Some("tui".to_string()),
        connected_seconds: 0,
        attached: vec![surface],
        sizes: vec![ClientSizeInfo {
            surface,
            cols: size.map(|size| size.0),
            rows: size.map(|size| size.1),
            size_participating: true,
        }],
        is_self: id == 1,
    }
}

#[test]
fn attached_but_hidden_client_does_not_show_on_pane_border() {
    let clients = vec![client(1, 9, Some((80, 24))), client(2, 9, None)];
    assert_eq!(client_border_labels(&clients).get(&9), None);
}

#[test]
fn client_button_shows_shared_minimum_after_all_sizes_arrive() {
    let clients = vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40)))];
    assert_eq!(
        client_border_labels(&clients).get(&9).map(String::as_str),
        Some(" 2 clients · 80×30 min ")
    );
}

#[test]
fn client_button_shows_fallback_minimum_when_every_viewer_is_excluded() {
    let mut clients = vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40)))];
    for client in &mut clients {
        client.sizes[0].size_participating = false;
    }

    assert_eq!(
        client_border_labels(&clients).get(&9).map(String::as_str),
        Some(" 2 clients · 80×30 min ")
    );
}

#[test]
fn unsized_participant_suppresses_excluded_report_fallback() {
    let mut clients =
        vec![client(1, 9, Some((120, 30))), client(2, 9, Some((80, 40))), client(3, 9, None)];
    clients[0].sizes[0].size_participating = false;
    clients[1].sizes[0].size_participating = false;

    assert_eq!(client_border_labels(&clients).get(&9), None);
}

#[test]
fn client_visible_on_another_tab_does_not_show_on_this_pane_border() {
    let clients = vec![client(1, 9, Some((120, 30))), client(2, 10, Some((80, 40)))];
    assert_eq!(client_border_labels(&clients).get(&9), None);
}
