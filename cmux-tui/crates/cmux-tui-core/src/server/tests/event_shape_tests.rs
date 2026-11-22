use super::*;

#[test]
fn agent_changed_event_preserves_the_scoped_agent_state() {
    assert_eq!(
        subscribed_event_json(&MuxEvent::AgentChanged {
            surface: 7,
            state: Arc::<str>::from("working"),
            source: Arc::<str>::from("hook"),
            session: Some(Arc::<str>::from("review")),
            agent: Some(Arc::<str>::from("claude")),
            updated_at_ms: 41,
        }),
        json!({
            "event": "agent-changed",
            "surface": 7,
            "state": "working",
            "source": "hook",
            "session": "review",
            "agent": "claude",
            "updated_at_ms": 41,
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
