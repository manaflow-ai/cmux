use super::*;

/// Build a terminal tab fixture with the requested durable placement.
fn tab(id: &str, pane_id: &str, position: usize) -> RegistryTab {
    RegistryTab {
        name_source: Default::default(),
        name_revision: 0,
        public_id: TabPublicId::parse(id.to_string()).unwrap(),
        pane_id: PanePublicId::parse(pane_id.to_string()).unwrap(),
        position,
        content_id: ContentPublicId::Terminal(
            TerminalPublicId::parse("term_00000000000000000000000000000001".to_string()).unwrap(),
        ),
        name: None,
        browser_url: None,
        terminal_id: Some("term_00000000000000000000000000000001".to_string()),
    }
}

/// Reindex the moved tab and existing target tabs without touching others.
#[test]
fn target_tab_positions_reindex_moved_and_target_tabs_only() {
    let target_pane =
        PanePublicId::parse("pane_00000000000000000000000000000001".to_string()).unwrap();
    let other_pane =
        PanePublicId::parse("pane_00000000000000000000000000000002".to_string()).unwrap();
    let moved = tab("tab_00000000000000000000000000000001", other_pane.as_str(), 0);
    let target_a = tab("tab_00000000000000000000000000000002", target_pane.as_str(), 0);
    let target_b = tab("tab_00000000000000000000000000000003", target_pane.as_str(), 1);
    let unrelated = tab("tab_00000000000000000000000000000004", other_pane.as_str(), 1);
    let mut tabs = vec![moved, target_a, target_b, unrelated];

    let target_order = vec![
        TabPublicId::parse("tab_00000000000000000000000000000003".to_string()).unwrap(),
        TabPublicId::parse("tab_00000000000000000000000000000001".to_string()).unwrap(),
        TabPublicId::parse("tab_00000000000000000000000000000002".to_string()).unwrap(),
        // Malformed duplicate IDs retain the first-match position from
        // the previous `position` scan.
        TabPublicId::parse("tab_00000000000000000000000000000001".to_string()).unwrap(),
    ];
    reindex_target_tab_positions(&mut tabs, &target_pane, &target_order);

    assert_eq!(tabs[0].pane_id, target_pane);
    assert_eq!(tabs[0].position, 1);
    assert_eq!(tabs[1].position, 2);
    assert_eq!(tabs[2].position, 0);
    assert_eq!(tabs[3].pane_id, other_pane);
    assert_eq!(tabs[3].position, 1);
}
