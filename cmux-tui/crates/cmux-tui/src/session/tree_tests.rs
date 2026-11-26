use super::*;
use serde_json::json;

#[test]
fn unnamed_screens_use_zero_based_display_names() {
    let screen = ScreenView {
        id: 1,
        resource_id: None,
        short_id: "1".to_string(),
        name: None,
        layout: Node::Leaf(1),
        active_pane: 1,
        zoomed_pane: None,
        viewport_base_width: None,
        viewport_splits: BTreeMap::new(),
        panes: Vec::new(),
    };

    assert_eq!(screen.display_name(0), "0");
    assert_eq!(screen.display_name(9), "9");
}

#[test]
fn retain_not_retired_keeps_tabs_when_local_catalog_is_empty() {
    // The fixture must be a COMPLETE tree: parse_tree drops
    // underspecified workspaces/screens, and this test shipped with a
    // minimal shape that parsed to an empty tree (the panic was masked
    // in CI by a clippy failure earlier in the same job).
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1, "active": true,
            "screens": [{
                "id": 2, "active": true, "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{"id": 3, "active_tab": 1, "tabs": [
                    {"surface": 7, "title": "a"},
                    {"surface": 8, "title": "b"}
                ]}]
            }]
        }]
    }));
    tree.retain_not_retired(&HashSet::new());
    let pane = &tree.workspaces[0].screens[0].panes[0];
    assert_eq!(pane.tabs.len(), 2);
    assert_eq!(pane.active_tab, 1);
}

#[test]
fn parser_reindexes_active_screen_after_dropping_malformed_screens() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [
                {"active": false},
                {
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": []
                }
            ]
        }]
    }));

    assert_eq!(tree.workspaces[0].screens.len(), 1);
    assert_eq!(tree.workspaces[0].active_screen, 0);
    assert_eq!(tree.active_screen().map(|screen| screen.id), Some(2));
}

#[test]
fn parser_fails_closed_when_active_screen_is_malformed() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [
                {
                    "id": 2,
                    "active": false,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": []
                },
                {"active": true}
            ]
        }]
    }));

    assert_eq!(tree.workspaces[0].screens.len(), 1);
    assert!(tree.active_screen().is_none());
}

fn tree_with_tabs(active_tab: usize, surfaces: &[SurfaceId]) -> TreeView {
    let tabs = surfaces
        .iter()
        .map(|surface| json!({"surface": surface, "title": "tab"}))
        .collect::<Vec<_>>();
    parse_tree(&json!({
        "workspaces": [{
            "id": 1, "active": true,
            "screens": [{
                "id": 2, "active": true, "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{"id": 3, "active_tab": active_tab, "tabs": tabs}]
            }]
        }]
    }))
}

#[test]
fn retain_not_retired_reindexes_active_tab_after_leading_retire() {
    let mut tree = tree_with_tabs(2, &[7, 8, 9]);
    tree.retain_not_retired(&HashSet::from([7]));

    let pane = &tree.workspaces[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![8, 9]);
    assert_eq!(pane.active_tab, 1);
}

#[test]
fn retain_not_retired_clamps_when_active_tab_is_retired() {
    let mut tree = tree_with_tabs(1, &[7, 8]);
    tree.retain_not_retired(&HashSet::from([8]));

    let pane = &tree.workspaces[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7]);
    assert_eq!(pane.active_tab, 0);
}

#[test]
fn retain_not_retired_clamps_out_of_range_active_tab() {
    let mut tree = tree_with_tabs(9, &[7, 8]);
    tree.retain_not_retired(&HashSet::new());

    let pane = &tree.workspaces[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7, 8]);
    assert_eq!(pane.active_tab, 1);
}

#[test]
fn retain_not_retired_uses_first_duplicate_surface_match() {
    let mut tree = tree_with_tabs(1, &[7, 7, 8]);
    tree.retain_not_retired(&HashSet::new());

    let pane = &tree.workspaces[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7, 7, 8]);
    assert_eq!(pane.active_tab, 0);
}

#[test]
fn protocol_v8_parser_preserves_split_ids() {
    let tree = parse_tree_with_capabilities(
        &json!({
            "workspaces": [{
                "id": 1,
                "name": "one",
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {
                        "type": "split",
                        "split": 9,
                        "dir": "right",
                        "ratio": 0.5,
                        "a": {"type": "leaf", "pane": 3},
                        "b": {"type": "leaf", "pane": 4}
                    },
                    "viewport_splits": [{"split": 9, "width": 0.6666667}],
                    "panes": []
                }]
            }]
        }),
        TreeCapabilities { viewport_splits: true, viewport_column_resize: false },
    );

    let Node::Split { id, .. } = &tree.workspaces[0].screens[0].layout else {
        panic!("layout should be split");
    };
    assert_eq!(*id, 9);
    assert_eq!(tree.workspaces[0].screens[0].viewport_splits.get(&9), Some(&(2.0 / 3.0)));
}

#[test]
fn parser_ignores_out_of_range_viewport_widths() {
    let tree = parse_tree_with_capabilities(
        &json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "viewport_base_width": 1.1,
                    "viewport_splits": [
                        {"split": 8, "width": 0.09},
                        {"split": 9, "width": 0.5},
                        {"split": 10, "width": 1.01}
                    ],
                    "panes": []
                }]
            }]
        }),
        TreeCapabilities { viewport_splits: true, viewport_column_resize: true },
    );

    let screen = &tree.workspaces[0].screens[0];
    assert_eq!(screen.viewport_base_width, None);
    assert_eq!(screen.viewport_splits, BTreeMap::from([(9, 0.5)]));
}

#[test]
fn parser_ignores_viewport_metadata_without_capabilities() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "viewport_base_width": 0.8,
                "viewport_splits": [{"split": 9, "width": 0.5}],
                "panes": []
            }]
        }]
    }));

    let screen = &tree.workspaces[0].screens[0];
    assert_eq!(screen.viewport_base_width, None);
    assert!(screen.viewport_splits.is_empty());
}

#[test]
fn parser_builds_stable_resource_selectors_for_creation_receipts() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "resource_id": "ws_00000000000000000000000000000001",
            "active": true,
            "screens": [{
                "id": 2,
                "resource_id": "screen_00000000000000000000000000000002",
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "resource_id": "pane_00000000000000000000000000000003",
                    "tabs": []
                }]
            }]
        }]
    }));

    assert_eq!(
        tree.resource_selectors_for_pane(Some(3)),
        Some(ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some("ws_00000000000000000000000000000001".to_string()),
            screen: Some("screen_00000000000000000000000000000002".to_string()),
            pane: Some("pane_00000000000000000000000000000003".to_string()),
            ..ResourceSelectors::default()
        })
    );
}

#[test]
fn protocol_v9_parser_preserves_stack_expansion() {
    let layout = parse_layout(&json!({
        "type": "stack",
        "panes": [3, 4, 5],
        "expanded": 4
    }))
    .unwrap();

    assert!(matches!(layout, Node::Stack { expanded: 4, .. }));
}

#[test]
fn resolving_terminal_and_selecting_surface_update_the_full_active_path() {
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [
                        {
                            "surface": 4,
                            "terminal_resource_id": "term_00000000000000000000000000000004"
                        },
                        {
                            "surface": 5,
                            "terminal_resource_id": "term_00000000000000000000000000000005"
                        }
                    ]
                }]
            }]
        }]
    }));

    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000005").unwrap();
    assert_eq!(tree.resolve_terminal(&terminal), Some(5));
    assert!(tree.select_surface(5));
    assert_eq!(tree.active_surface(), Some(5));
    assert!(!tree.select_surface(99));
}

#[test]
fn surface_and_pane_lookup_keep_first_match_after_tree_mutation() {
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [
                        {"surface": 7, "title": "first"},
                        {"surface": 8, "title": "retained"}
                    ]
                }]
            }]
        }, {
            "id": 4,
            "screens": [{
                "id": 5,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 7, "title": "duplicate"}]
                }]
            }]
        }]
    }));

    assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("first"));
    assert_eq!(tree.pane(3).map(|pane| pane.tabs[0].title.as_str()), Some("first"));
    tree.active_workspace = 1;
    assert!(tree.select_surface(7));
    assert_eq!(tree.active_workspace, 0);
    assert_eq!(tree.active_surface(), Some(7));

    tree.retain_not_retired(&HashSet::from([7]));
    assert!(tree.surface(7).is_none());
    assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
    assert!(tree.pane(3).is_some());
}

#[test]
fn indexed_lookup_fails_closed_after_internal_topology_mutation() {
    let tree = || {
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [
                            {"surface": 7, "title": "first"},
                            {"surface": 8, "title": "retained"}
                        ]
                    }]
                }]
            }]
        }))
    };

    let mut appended = tree();
    assert!(appended.surface(7).is_some());
    let tab = appended.workspaces[0].screens[0].panes[0].tabs[0].clone();
    appended.workspaces[0].screens[0].panes[0].tabs.push(tab);
    assert!(appended.surface(7).is_some());

    let mut inserted = tree();
    assert!(inserted.surface(8).is_some());
    let tab = inserted.workspaces[0].screens[0].panes[0].tabs[0].clone();
    inserted.workspaces[0].screens[0].panes[0].tabs.insert(0, tab);
    assert!(inserted.surface(8).is_none());
    assert!(!inserted.select_surface(8));

    let mut removed = tree();
    assert!(removed.surface(8).is_some());
    removed.workspaces[0].screens[0].panes[0].tabs.remove(0);
    assert!(removed.surface(8).is_none());
    assert!(!removed.select_surface(8));

    let mut replaced = tree();
    assert!(replaced.surface(8).is_some());
    replaced.workspaces[0].screens[0].panes[0].tabs[0].surface = 8;
    assert!(replaced.surface(8).is_none());
    assert!(!replaced.select_surface(8));
}

#[test]
fn topology_mutation_guard_invalidates_index_before_nested_mutation() {
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [
                        {"surface": 7, "title": "first"},
                        {"surface": 8, "title": "retained"}
                    ]
                }]
            }]
        }]
    }));

    assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
    let mut inserted = tree.workspaces_mut()[0].screens[0].panes[0].tabs[0].clone();
    inserted.title = "inserted".to_string();
    tree.workspaces_mut()[0].screens[0].panes[0].tabs.insert(0, inserted);

    assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
    assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("inserted"));
    assert!(tree.select_surface(8));
}

#[test]
fn title_updates_reuse_the_existing_location_index() {
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [{"surface": 7, "title": "first"}]
                }]
            }]
        }]
    }));

    let index_before = tree.location_index() as *const TreeLocationIndex;
    assert!(tree.update_surface_title(7, "renamed"));
    let index_after = tree.location_index() as *const TreeLocationIndex;

    assert!(std::ptr::eq(index_before, index_after));
    assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("renamed"));
}

#[test]
fn focus_updates_reuse_the_existing_location_index() {
    let mut tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [{"surface": 7, "title": "first"}]
                }]
            }]
        }]
    }));

    let index_before = tree.location_index() as *const TreeLocationIndex;
    assert!(tree.set_active_screen(0, 0));
    assert!(tree.set_active_pane(0, 0, 3));
    assert!(tree.set_active_tab(0, 0, 3, 0));
    assert!(tree.set_pane_active_tab(3, 0));
    let index_after = tree.location_index() as *const TreeLocationIndex;

    assert!(std::ptr::eq(index_before, index_after));
    assert_eq!(tree.active_surface(), Some(7));
}

#[test]
fn terminal_resolution_ignores_internal_ids_and_browser_tabs() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [
                        {
                            "surface": 10,
                            "short_id": "term_0000000000000000000000000000000a",
                            "kind": "browser"
                        }
                    ]
                }]
            }]
        }]
    }));
    let id = TerminalPublicId::parse("term_0000000000000000000000000000000a").unwrap();
    assert_eq!(tree.resolve_terminal(&id), None);
}

#[test]
fn pane_parser_preserves_authoritative_focus_recency() {
    let pane = parse_pane(&json!({
        "id": 3,
        "focused_at": 42,
        "tabs": []
    }))
    .unwrap();

    assert_eq!(pane.focused_at, 42);
}

#[test]
fn pane_parser_reindexes_active_tab_after_dropping_malformed_tabs() {
    let pane = parse_pane(&json!({
        "id": 3,
        "active_tab": 1,
        "tabs": [
            {"title": "malformed"},
            {"surface": 5, "title": "active"}
        ]
    }))
    .unwrap();

    assert_eq!(pane.tabs.len(), 1);
    assert_eq!(pane.active_tab, 0);
    assert_eq!(pane.active_surface(), Some(5));
}

#[test]
fn pane_parser_fails_closed_when_active_tab_is_out_of_range() {
    let pane = parse_pane(&json!({
        "id": 3,
        "active_tab": 9,
        "tabs": [{"surface": 5, "title": "only"}]
    }))
    .unwrap();

    assert_eq!(pane.active_tab, usize::MAX);
    assert_eq!(pane.active_surface(), None);
}

#[test]
fn pane_parser_fails_closed_when_active_tab_value_is_malformed() {
    let pane = parse_pane(&json!({
        "id": 3,
        "active_tab": "invalid",
        "tabs": [{"surface": 5, "title": "only"}]
    }))
    .unwrap();

    assert_eq!(pane.active_tab, usize::MAX);
    assert_eq!(pane.active_surface(), None);
}

#[test]
fn pane_parser_fails_closed_when_active_tab_is_malformed() {
    let pane = parse_pane(&json!({
        "id": 3,
        "active_tab": 1,
        "tabs": [
            {"surface": 5, "title": "first"},
            {"title": "malformed"},
            {"surface": 6, "title": "third"}
        ]
    }))
    .unwrap();

    assert_eq!(pane.tabs.len(), 2);
    assert_eq!(pane.active_tab, usize::MAX);
    assert_eq!(pane.active_surface(), None);
}

#[test]
fn tree_parser_defaults_and_preserves_pane_revision() {
    assert_eq!(parse_tree(&json!({"workspaces": []})).pane_revision, None);
    assert_eq!(parse_tree(&json!({"pane_revision": 7, "workspaces": []})).pane_revision, Some(7));
}

#[test]
fn tree_parser_defaults_clear_fallback_support_to_false() {
    let pane = parse_pane(&json!({
        "id": 3,
        "tabs": [
            {"surface": 4},
            {"surface": 5, "supports_clear_history_key_fallback": true}
        ]
    }))
    .unwrap();

    assert!(!pane.tabs[0].supports_clear_history_key_fallback);
    assert!(pane.tabs[1].supports_clear_history_key_fallback);
}

#[test]
fn tree_parser_preserves_browser_source_and_rejects_unknown_values() {
    let pane = parse_pane(&json!({
        "id": 3,
        "tabs": [
            {"surface": 4, "kind": "browser", "browser_source": "external"},
            {"surface": 5, "kind": "browser", "browser_source": "launched"},
            {"surface": 6, "kind": "browser", "browser_source": "remote"}
        ]
    }))
    .unwrap();

    assert_eq!(pane.tabs[0].browser_source, Some(BrowserSource::External));
    assert_eq!(pane.tabs[1].browser_source, Some(BrowserSource::Launched));
    assert_eq!(pane.tabs[2].browser_source, None);
}
