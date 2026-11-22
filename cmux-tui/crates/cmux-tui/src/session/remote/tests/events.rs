//! Server events: titles, presence, agents, and surface event scopes.

use super::*;

fn recording_acknowledging_session() -> (Arc<RemoteSession>, Receiver<Value>) {
    let session_slot = Arc::new(Mutex::new(None));
    let (requests, received_requests) = channel();
    let session = test_session(Box::new(AcknowledgingWriter {
        session: session_slot.clone(),
        requests: Some(requests),
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session
        .capabilities
        .lock()
        .unwrap()
        .insert(cmux_tui_core::server::SURFACE_SUBSCRIBE_FILTER_CAPABILITY.to_string());
    (session, received_requests)
}

#[cfg(unix)]
#[test]
fn repeated_surface_overflow_stops_until_reconnect() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);

    for _ in 0..SURFACE_OVERFLOW_RETRY_DELAYS.len() {
        let (delay, stopped) = session.record_surface_overflow(7);
        assert!(delay.is_some());
        assert!(!stopped);
        let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
        let recovery = recoveries.get_mut(&7).unwrap();
        recovery.retry_after = Some(Instant::now() - Duration::from_millis(1));
        recovery.attached_at = Some(Instant::now());
        drop(recoveries);
        assert!(session.can_attach_after_overflow(7));
    }

    let (delay, stopped) = session.record_surface_overflow(7);
    assert!(delay.is_none());
    assert!(stopped);
    assert!(!session.can_attach_after_overflow(7));

    let mut recoveries = session.surface_overflow_recovery.lock().unwrap();
    let recovery = recoveries.get_mut(&7).unwrap();
    recovery.attached_at = Some(Instant::now() - SURFACE_OVERFLOW_STABLE);
    drop(recoveries);
    let (delay, stopped) = session.record_surface_overflow(7);
    assert_eq!(delay, Some(SURFACE_OVERFLOW_RETRY_DELAYS[0]));
    assert!(!stopped);
}

#[cfg(unix)]
#[test]
fn background_refresh_failure_does_not_mark_identity_stale() {
    let (client, server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    session.tree_stale.store(false, Ordering::Release);
    let refreshing = session.clone();
    let refresh = std::thread::spawn(move || refreshing.refresh_tree_background());

    let mut peer = BufReader::new(server);
    let mut line = String::new();
    peer.read_line(&mut line).unwrap();
    let request: Value = serde_json::from_str(&line).unwrap();
    writeln!(peer.get_mut(), "{}", json!({"id": request["id"], "ok": false, "error": "temporary"}))
        .unwrap();

    assert!(refresh.join().unwrap().is_err());
    assert!(!session.tree_is_stale());
}

#[cfg(unix)]
#[test]
fn unknown_surface_title_churn_emits_one_tree_invalidation_per_stale_transition() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.tree_stale.store(false, Ordering::Release);

    for index in 0..1_000 {
        session.handle_line(json!({
            "event": "title-changed",
            "surface": 77,
            "title": format!("unknown-{index}"),
        }));
    }

    let received = events.try_iter().collect::<Vec<_>>();
    assert_eq!(received.iter().filter(|event| matches!(event, MuxEvent::TreeChanged)).count(), 1);
    assert!(
        received.iter().any(|event| matches!(event, MuxEvent::TitleChanged { surface: 77, .. }))
    );

    assert!(session.take_tree_stale());
    session.handle_line(json!({
        "event": "title-changed",
        "surface": 77,
        "title": "after-refresh",
    }));
    assert!(events.try_iter().any(|event| matches!(event, MuxEvent::TreeChanged)));
}

#[cfg(unix)]
#[test]
fn client_presence_events_reach_remote_tui_subscribers() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();

    session.handle_line(json!({
        "event": "client-attached",
        "client": 7,
        "transport": "unix",
        "name": "small",
        "kind": "tui",
    }));
    session.handle_line(json!({
        "event": "client-changed",
        "client": 7,
        "name": "small",
        "kind": "tui",
    }));
    session.handle_line(json!({"event": "client-detached", "client": 7}));

    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientAttached { client: 7, .. })
    ));
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: 7, .. })
    ));
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::ClientDetached(7))));
}

#[cfg(unix)]
#[test]
fn agent_events_update_the_remote_cache_without_invalidating_the_tree() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let events = session.subscribe();
    session.tree_stale.store(false, Ordering::Release);

    for (state, updated_at_ms) in [("working", 40), ("blocked", 41)] {
        session.handle_line(json!({
            "event": "agent-changed",
            "surface": 7,
            "state": state,
            "source": "hook",
            "session": "review",
            "updated_at_ms": updated_at_ms,
        }));
    }

    assert!(!session.tree_is_stale());
    assert_eq!(
        session.cached_agents(),
        vec![AgentInfo {
            surface: 7,
            state: "blocked".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        }]
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::AgentChanged {
            surface: 7,
            state,
            updated_at_ms: 41,
            ..
        }) if state.as_ref() == "blocked"
    ));
    assert!(events.try_iter().next().is_none());
}

#[cfg(unix)]
#[test]
fn surface_exit_drops_cached_agent_before_a_stale_topology_can_restore_it() {
    let tree = || {
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 7, "title": "agent terminal"}],
                    }],
                }],
            }],
        }))
    };
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    session.tree.lock().unwrap().replace(tree(), 0);

    session.handle_line(json!({
        "event": "agent-changed",
        "surface": 7,
        "state": "working",
        "source": "hook",
        "session": "review",
        "updated_at_ms": 41,
    }));
    assert_eq!(session.cached_agents().len(), 1);

    session.handle_line(json!({"event": "surface-exited", "surface": 7}));
    assert!(session.cached_agents().is_empty());

    // A stale topology response can briefly show the exited surface again.
    // A stale agent snapshot must not resurrect the exited agent row.
    let retired_surfaces = session.retired_surfaces.lock().unwrap().clone();
    let mut cache = session.tree.lock().unwrap();
    let title_generation = cache.title_generation();
    cache.replace(tree(), title_generation);
    cache.replace_agents(
        vec![AgentInfo {
            surface: 7,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: 41,
        }],
        0,
        &retired_surfaces,
    );
    assert!(cache.agents.is_empty());
}

#[cfg(unix)]
#[test]
fn surface_exit_serializes_agent_updates_after_retirement_marker() {
    let tree = || {
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "screens": [{
                    "id": 2,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 7, "title": "agent terminal"}],
                    }],
                }],
            }],
        }))
    };
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    session.tree.lock().unwrap().replace(tree(), 0);
    session.handle_line(json!({
        "event": "agent-changed",
        "surface": 7,
        "state": "working",
        "source": "hook",
        "session": "review",
        "updated_at_ms": 41,
    }));

    let (marker_tx, marker_rx) = channel();
    *session.retire_surface_test_marker.lock().unwrap() = Some(marker_tx);

    // Hold the cache lock. The retirement must publish its marker before
    // waiting for this lock, so a concurrent agent update cannot slip in.
    let tree_guard = session.tree.lock().unwrap();
    let retiring = session.clone();
    let retire_thread = std::thread::spawn(move || {
        retiring.handle_line(json!({"event": "surface-exited", "surface": 7}));
    });
    if marker_rx.recv_timeout(Duration::from_secs(1)).is_err() {
        drop(tree_guard);
        retire_thread.join().unwrap();
        panic!("surface retirement did not publish its marker before cache cleanup");
    }

    let updating = session.clone();
    let update_thread = std::thread::spawn(move || {
        updating.handle_line(json!({
            "event": "agent-changed",
            "surface": 7,
            "state": "needsInput",
            "source": "hook",
            "session": "review",
            "updated_at_ms": 42,
        }));
    });
    drop(tree_guard);
    retire_thread.join().unwrap();
    update_thread.join().unwrap();

    assert!(session.cached_agents().is_empty());
}

#[test]
fn agent_refresh_filters_retired_surfaces_in_one_authoritative_pass() {
    fn agent(surface: SurfaceId) -> AgentInfo {
        AgentInfo {
            surface,
            state: "working".into(),
            source: "hook".into(),
            session: Some("review".into()),
            agent: None,
            updated_at_ms: surface,
        }
    }

    let mut cache = RemoteTreeCache::default();
    let agents = (0..4096_u64).map(agent).collect::<Vec<_>>();
    for surface in 0..4096_u64 {
        let agent = agents[surface as usize].clone();
        cache
            .agent_updates
            .insert(surface, AgentUpdate { generation: surface.saturating_add(1), agent });
    }
    let retired = (0..4096_u64).step_by(2).collect::<HashSet<_>>();

    cache.replace_agents(agents, 0, &retired);

    assert_eq!(cache.agents.len(), 2048);
    assert!(cache.agents.iter().all(|agent| !retired.contains(&agent.surface)));
    assert_eq!(cache.agent_updates.len(), 2048);
    assert!(cache.agent_updates.keys().all(|surface| !retired.contains(surface)));
    assert!(cache.agents.iter().all(|agent| cache.agent_updates.contains_key(&agent.surface)));
}

#[test]
fn agent_cache_does_not_keep_permanent_retirement_tombstones() {
    let agent = AgentInfo {
        surface: 7,
        state: "working".into(),
        source: "hook".into(),
        session: Some("review".into()),
        agent: None,
        updated_at_ms: 41,
    };
    let mut cache = RemoteTreeCache::default();
    cache.replace_agent(agent.clone());
    cache.remove_agent(agent.surface);

    let retired = HashSet::new();
    cache.update_agent(agent.clone(), &retired);

    assert_eq!(cache.agents, vec![agent]);
    assert_eq!(cache.agent_updates.len(), 1);
}

#[test]
fn surface_event_scope_filters_before_remote_cache_invalidation() {
    let (session, _requests) = recording_acknowledging_session();
    session.tree.lock().unwrap().replace(
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [
                            {"surface": 7, "title": "target"},
                            {"surface": 8, "title": "unrelated"}
                        ]
                    }]
                }]
            }]
        })),
        0,
    );
    session.scope_events_to_surface(7).unwrap();
    session.tree_stale.store(false, Ordering::Release);
    let events = session.subscribe();

    for event in [
        json!({"event": "title-changed", "surface": 8, "title": "changed"}),
        json!({
            "event": "agent-changed",
            "surface": 8,
            "state": "working",
            "source": "hook",
            "session": null,
            "updated_at_ms": 1,
        }),
        json!({"event": "surface-output", "surface": 8}),
        json!({"event": "surface-exited", "surface": 8}),
        json!({"event": "client-list-invalidated"}),
        json!({"event": "client-attached", "client": 11, "transport": "unix"}),
        json!({"event": "notification", "notification": 12, "surface": 8}),
    ] {
        session.handle_line(event);
    }

    assert!(!session.tree_is_stale());
    assert!(events.try_iter().next().is_none());
    assert!(session.cached_agents().is_empty());
    assert_eq!(session.tree.lock().unwrap().view.surface(8).unwrap().title, "unrelated");

    session.handle_line(json!({"event": "tree-changed"}));
    assert!(session.tree_is_stale());
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::TreeChanged)));
    session.tree_stale.store(false, Ordering::Release);

    session.handle_line(json!({"event": "layout-changed", "screen": 2}));
    assert!(session.tree_is_stale());
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::LayoutChanged(2))));
    session.tree_stale.store(false, Ordering::Release);

    session.handle_line(json!({
        "event": "title-changed",
        "surface": 7,
        "title": "target changed",
    }));
    assert!(!session.tree_is_stale());
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::TitleChanged { surface: 7, .. })
    ));

    session.handle_line(json!({
        "event": "agent-changed",
        "surface": 7,
        "state": "working",
        "source": "hook",
        "session": null,
        "updated_at_ms": 2,
    }));
    assert!(!session.tree_is_stale());
    assert_eq!(session.cached_agents()[0].surface, 7);
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::AgentChanged { surface: 7, .. })
    ));

    session.handle_line(json!({"event": "surface-exited", "surface": 7}));
    assert!(session.tree_is_stale());
    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::SurfaceExited(7))));
}

#[test]
fn surface_event_scope_registers_a_filtered_server_subscription() {
    let (session, requests) = recording_acknowledging_session();

    session.scope_events_to_surface(7).unwrap();

    let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(request.get("cmd").and_then(Value::as_str), Some("subscribe"));
    assert_eq!(request.get("surface").and_then(Value::as_u64), Some(7));
}

#[test]
fn surface_event_scope_retains_events_until_the_first_local_receiver_starts() {
    let (session, _requests) = recording_acknowledging_session();

    session.scope_events_to_surface(7).unwrap();
    session.handle_line(json!({"event": "surface-exited", "surface": 7}));
    let events = session.subscribe();

    assert!(matches!(events.recv_timeout(Duration::from_secs(1)), Ok(MuxEvent::SurfaceExited(7))));
}

#[test]
fn surface_event_scope_rejects_servers_without_source_filtering() {
    let session = test_session(Box::new(UnexpectedWriteWriter));

    let error = session.scope_events_to_surface(7).unwrap_err();

    assert_eq!(error.to_string(), "remote server does not support filtered surface subscriptions");
}

#[test]
fn indexed_title_update_changes_only_the_addressed_surface() {
    let mut cache = RemoteTreeCache::default();
    cache.replace(
        parse_tree(&json!({
            "workspaces": [
                {
                    "id": 1,
                    "active": true,
                    "screens": [{
                        "id": 2,
                        "active": true,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": [{
                            "id": 3,
                            "tabs": [{"surface": 4, "title": "old target"}],
                        }],
                    }],
                },
                {
                    "id": 5,
                    "screens": [{
                        "id": 6,
                        "layout": {"type": "leaf", "pane": 7},
                        "panes": [{
                            "id": 7,
                            "tabs": [{"surface": 8, "title": "other title"}],
                        }],
                    }],
                },
            ],
        })),
        0,
    );

    assert!(cache.view.location_index.get().is_none());
    assert!(cache.update_title(4, "server title".to_string()));
    assert!(cache.view.location_index.get().is_none());
    assert_eq!(cache.view.workspaces()[0].screens[0].panes[0].tabs[0].title, "server title");
    assert_eq!(cache.view.workspaces()[1].screens[0].panes[0].tabs[0].title, "other title");
    assert!(!cache.update_title(99, "missing".to_string()));
}
