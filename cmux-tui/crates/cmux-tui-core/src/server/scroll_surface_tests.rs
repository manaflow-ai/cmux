use super::tests::{test_mux, test_writer};
use super::*;
use std::sync::mpsc::TryRecvError;

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
        0,
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
        0,
        Command::ScrollSurface { surface: surface.id, delta: 0 },
        &test_writer(),
    )
    .unwrap();
    assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
}
