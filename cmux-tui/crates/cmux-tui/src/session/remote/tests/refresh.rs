//! Tree and agent refreshes racing with live title and agent events.

use super::*;

#[test]
fn refresh_preserves_title_events_that_arrived_after_it_started() {
    let tree = |title: &str| {
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 4, "title": title}],
                    }],
                }],
            }],
        }))
    };
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree("initial"), 0);

    let refresh_generation = cache.title_generation();
    assert!(cache.update_title(4, "event title".to_string()));
    cache.replace(tree("stale snapshot"), refresh_generation);

    assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "event title");
}

#[test]
fn refresh_uses_snapshot_for_title_events_that_predate_it() {
    let tree = |title: &str| {
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 4, "title": title}],
                    }],
                }],
            }],
        }))
    };
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree("initial"), 0);
    assert!(cache.update_title(4, "older event".to_string()));

    let refresh_generation = cache.title_generation();
    cache.replace(tree("fresh snapshot"), refresh_generation);

    assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "fresh snapshot");
}

#[test]
fn agent_refresh_does_not_restore_an_update_for_a_removed_surface() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree, 0);
    let retired = HashSet::new();
    let refresh_generation = cache.agent_generation();
    cache.update_agent(
        AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        },
        &retired,
    );

    let title_generation = cache.title_generation();
    cache.replace(TreeView::default(), title_generation);
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert!(cache.agents.is_empty());
}

#[test]
fn agent_refresh_does_not_resurrect_after_confirmed_omission() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree.clone(), 0);
    let retired = HashSet::new();

    // The event races the first refresh and is retained while the
    // topology omits the surface.
    let refresh_generation = cache.agent_generation();
    cache.update_agent(
        AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        },
        &retired,
    );
    cache.replace(TreeView::default(), cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    // A later refresh confirms the agent is absent. A stale topology may
    // briefly show the surface again, but the old event must not return.
    let confirmed_generation = cache.agent_generation();
    cache.replace(tree, cache.title_generation());
    cache.replace_agents(Vec::new(), confirmed_generation, &retired);

    assert!(cache.agents.is_empty());
    assert!(cache.agent_updates.is_empty());
}

#[test]
fn agent_refresh_retains_updates_when_topology_temporarily_omits_surface() {
    let tree = parse_tree(&json!({
        "workspaces": [{
            "id": 1,
            "screens": [{
                "id": 2,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "tabs": [{"surface": 4, "title": "agent terminal"}],
                }],
            }],
        }],
    }));
    let mut cache = RemoteTreeCache::default();
    cache.replace(tree.clone(), 0);
    let retired = HashSet::new();
    let refresh_generation = cache.agent_generation();
    let update = AgentInfo {
        surface: 4,
        state: "working".into(),
        source: "hook".into(),
        session: Some("review".into()),
        agent: None,
        updated_at_ms: 41,
    };
    cache.update_agent(update.clone(), &retired);

    // The tree response can lag the event stream and omit a live surface.
    cache.replace(TreeView::default(), cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert_eq!(cache.agent_updates.get(&4).map(|pending| &pending.agent), Some(&update));

    // A later topology response makes the pending event visible again.
    cache.replace(tree, cache.title_generation());
    cache.replace_agents(Vec::new(), refresh_generation, &retired);

    assert_eq!(cache.agents, vec![update]);
}

#[test]
fn browser_state_without_frame_keeps_cached_frame() {
    let surface = RemoteSurface {
        id: 1,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    };

    surface.update_browser_frame(&json!({
        "seq": 9,
        "width": 80,
        "height": 40,
        "data": "Zmlyc3Q=",
    }));
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "a frame event without explicit authority metadata must fail closed"
    );
    surface.update_browser_state(&json!({
        "url": "https://next.test",
        "title": "next",
        "status": "live",
        "frames_stalled": false,
    }));
    assert_eq!(surface.browser_frame_seq(), None, "missing pointer admission must fail closed");

    surface.update_browser_state(&json!({
        "url": "https://next.test",
        "title": "next",
        "status": "live",
        "frames_stalled": false,
        "pointer_frame_seq": 9,
    }));
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "state alone must not grant new authority to the cached frame"
    );
    surface.update_browser_frame(&json!({
        "seq": 9,
        "width": 80,
        "height": 40,
        "data": "Zmlyc3Q=",
        "status": "live",
        "pointer_frame_seq": 9,
    }));
    assert_eq!(surface.browser_frame_seq(), Some(9));

    surface.update_browser_state(&json!({
        "url": "https://next.test",
        "title": "next",
        "status": "live",
        "frames_stalled": false,
        "pointer_frame_seq": null,
    }));

    let frame = surface.browser_frame().expect("cached frame");
    assert_eq!(frame.seq, 9);
    assert_eq!(frame.data_b64, "Zmlyc3Q=");
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "cached display frames must not imply pointer admission"
    );
    assert_eq!(surface.browser_url().as_deref(), Some("https://next.test"));

    surface.update_browser_state(&json!({
        "url": "https://next.test",
        "title": "next",
        "status": "live",
        "frames_stalled": false,
        "pointer_frame_seq": 9,
    }));
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "restoring cached-frame input requires a paired authoritative frame event"
    );
}
