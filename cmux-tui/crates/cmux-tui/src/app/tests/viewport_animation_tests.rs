//! Viewport animation leases and sweep bounds.

use super::*;

#[test]
fn viewport_animation_leases_every_column_in_its_swept_range() {
    let pane = |id, surface| PaneView {
        id,
        resource_id: None,
        short_id: format!("p{id}"),
        name: None,
        tabs: vec![TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{surface}"),
            name: None,
            title: format!("pane {id}"),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            remote_terminal: false,
            notification: None,
            supports_clear_history_key_fallback: false,
        }],
        active_tab: 0,
        focused_at: id,
    };
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: 3,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: vec![pane(1, 11), pane(2, 12), pane(3, 13)],
    };
    let layout = vec![
        (1, VirtualRect { x: 0, y: 0, width: 80, height: 24 }),
        (2, VirtualRect { x: 80, y: 0, width: 80, height: 24 }),
        (3, VirtualRect { x: 160, y: 0, width: 80, height: 24 }),
    ];

    let leases = swept_viewport_size_leases(
        PaneAreaProjection {
            screen: &screen,
            layout: &layout,
            stacked_headers: &HashSet::new(),
            area: Rect { x: 0, y: 0, width: 80, height: 24 },
            scrollbar_position: ScrollbarPosition::Column,
            pane_padding: 0,
            surface_only: None,
            viewport_offset: Some(0),
        },
        160,
    )
    .expect("a short animation sweep should stay within the synchronization budget");

    assert_eq!(leases.iter().map(|lease| lease.surface).collect::<Vec<_>>(), vec![11, 12, 13]);
}

#[test]
fn viewport_animation_rejects_an_unbounded_synchronization_sweep() {
    let pane = |id, surface| PaneView {
        id,
        resource_id: None,
        short_id: format!("p{id}"),
        name: None,
        tabs: vec![TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{surface}"),
            name: None,
            title: format!("pane {id}"),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            remote_terminal: false,
            notification: None,
            supports_clear_history_key_fallback: false,
        }],
        active_tab: 0,
        focused_at: id,
    };
    let pane_count = 80;
    let screen = ScreenView {
        id: 4,
        resource_id: None,
        short_id: "s".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: pane_count,
        zoomed_pane: None,
        viewport_base_width: Some(1.0),
        viewport_splits: BTreeMap::new(),
        panes: (1..=pane_count).map(|id| pane(id, 100 + id)).collect(),
    };
    let layout = (1..=pane_count)
        .map(|id| (id, VirtualRect { x: (id - 1) * 80, y: 0, width: 80, height: 24 }))
        .collect::<Vec<_>>();

    let leases = swept_viewport_size_leases(
        PaneAreaProjection {
            screen: &screen,
            layout: &layout,
            stacked_headers: &HashSet::new(),
            area: Rect { x: 0, y: 0, width: 80, height: 24 },
            scrollbar_position: ScrollbarPosition::Column,
            pane_padding: 0,
            surface_only: None,
            viewport_offset: Some(0),
        },
        (pane_count - 1) * 80,
    );

    assert!(
        leases.is_none(),
        "a distant jump must not enqueue synchronization for every crossed pane"
    );
}
