use super::*;

#[test]
fn agent_presence_changed_event_carries_the_target_and_clears_with_nulls() {
    let presence = crate::AgentPresence {
        activity: crate::AgentActivity::Reading,
        agent: Some(Arc::from("claude")),
        session: Some(Arc::from("s-1")),
        tool: Some(Arc::from("Read")),
        path: Some(Arc::from("/repo/src/lib.rs")),
        line: Some(120),
        updated_at_ms: 41,
    };
    assert_eq!(
        subscribed_event_json(&MuxEvent::AgentPresenceChanged {
            surface: 7,
            presence: Some(Arc::new(presence)),
        }),
        json!({
            "event": "agent-presence-changed",
            "surface": 7,
            "activity": "reading",
            "agent": "claude",
            "session": "s-1",
            "tool": "Read",
            "path": "/repo/src/lib.rs",
            "line": 120,
            "updated_at_ms": 41,
        })
    );
    assert_eq!(
        subscribed_event_json(&MuxEvent::AgentPresenceChanged { surface: 7, presence: None }),
        json!({
            "event": "agent-presence-changed",
            "surface": 7,
            "activity": null,
            "agent": null,
            "session": null,
            "tool": null,
            "path": null,
            "line": null,
            "updated_at_ms": null,
        })
    );
}

#[test]
fn graphics_status_events_preserve_structured_localization_data() {
    assert_eq!(
        subscribed_event_json(&MuxEvent::GraphicsStatus(
            GraphicsStatus::KittyImageBudgetUpdateFailed {
                retry_exhausted: true,
                summary: Arc::<str>::from("surface 7: offline"),
            },
        )),
        json!({
            "event": "graphics-status",
            "kind": "kitty-image-budget-update-failed",
            "retry_exhausted": true,
            "summary": "surface 7: offline",
        })
    );
    assert_eq!(
        subscribed_event_json(&MuxEvent::GraphicsStatus(
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts: 5,
                remaining: 2,
                cell_pixels: (8, 16),
            },
        )),
        json!({
            "event": "graphics-status",
            "kind": "cell-pixel-update-retries-exhausted",
            "attempts": 5,
            "remaining": 2,
            "cell_width": 8,
            "cell_height": 16,
        })
    );
}

#[test]
fn scroll_surface_emits_one_scroll_changed_event() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    surface
        .try_with_terminal(|term| {
            for i in 0..20 {
                term.vt_write(format!("line{i}\r\n").as_bytes());
            }
        })
        .unwrap();
    let shared_scrollbar = surface.try_with_terminal(|term| term.scrollbar().unwrap()).unwrap();
    let view_scrollbar = surface.view_scrollbar().unwrap();
    let events = mux.subscribe();

    handle_command(
        &mux,
        mux.local_test_client(0),
        Command::ScrollSurface { surface: surface.id, delta: -5 },
        &test_writer(),
    )
    .unwrap();

    let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        event,
        MuxEvent::ScrollChanged { surface: id, offset, at_bottom: false }
            if id == surface.id && offset > 0
    ));
    assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    assert_eq!(
        surface.try_with_terminal(|term| term.scrollbar().unwrap()).unwrap(),
        shared_scrollbar,
        "a backend view scroll must not mutate the shared terminal runtime"
    );
    assert_ne!(surface.view_scrollbar().unwrap(), view_scrollbar);

    handle_command(
        &mux,
        mux.local_test_client(0),
        Command::ScrollSurface { surface: surface.id, delta: 0 },
        &test_writer(),
    )
    .unwrap();
    assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
}

/// A hook-reported agent keeps `session` for its human label (the hook
/// marker is dropped), so `list-agents` and `agent-changed` carry the
/// harness's own session id as `agent_session_id`: `cmux://agent` links
/// (manaflow-ai/cmux#22096) resolve a live terminal by it.
#[test]
fn list_agents_and_agent_changed_carry_the_hook_session_id() {
    let mux = Mux::new_for_test("agent-session-id-wire", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();
    let hook = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionStart",
        Some(&terminal_id.to_string()),
        json!({"session_id":"claude-session-1"}),
    )
    .unwrap();
    mux.append_journal_ingress(&hook, "test", "hook-1").unwrap();

    let listed = cmd_frontend::list_agents(&mux, Some(surface.id), None).unwrap();
    let agents = listed["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 1, "{listed}");
    assert_eq!(agents[0]["agent"], "claude", "{listed}");
    assert_eq!(agents[0]["agent_session_id"], "claude-session-1", "{listed}");

    let changed = events
        .try_iter()
        .map(|event| subscribed_event_json(&event))
        .find(|event| event["event"] == "agent-changed")
        .expect("the hook publishes agent-changed");
    assert_eq!(changed["agent_session_id"], "claude-session-1", "{changed}");
}
