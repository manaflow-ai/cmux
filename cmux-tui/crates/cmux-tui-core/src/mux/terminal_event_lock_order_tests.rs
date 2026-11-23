//! The local PTY reader publishes titles and bells, and the frame producer
//! publishes output, after each releases the terminal lock.
//!
//! `Mux::emit_terminal_title` and `Mux::emit_terminal_bell` resolve placements
//! under `Mux::state`. A tree delta reads `Surface::size` (the geometry lock)
//! while it holds `Mux::state`, and a resize holds the geometry lock while it
//! takes the terminal lock. A reader that still holds the terminal lock while
//! it waits for `Mux::state` closes that cycle: the cmux-tui test
//! `workspace_keyboard_enter_returns_focus_to_pane` hung this way in hosted run
//! 42697795746 (close_surface, the Enter key's geometry claim and the shell's
//! title deadlocked).
//!
//! The frame producer had the same leg: it built a frame and sent
//! `SurfaceOutput` (`emit_terminal_output` also takes `Mux::state`) with the
//! terminal lock held. With the reader's terminal-directory publication
//! (`Mux::state`, then `Surface::size`) and a sizing-menu resize, the cmux-tui
//! test `size_menu_commands_reach_the_shared_sizing_host` timed out this way in
//! hosted run 42761781665 (attempt 3).

use super::*;
use std::sync::mpsc;

/// Generous for a loaded runner: the shell must start and answer one line.
const PUBLISH_DEADLINE: Duration = Duration::from_secs(20);
/// A free terminal lock makes the resize immediate; this is only the guard.
const RESIZE_DEADLINE: Duration = Duration::from_secs(5);

/// Hold the reader at the start of one publication, take `Mux::state` the way
/// a tree delta does, then resize the terminal the way a geometry claim does.
/// The resize must not wait for the held `Mux::state`.
fn resize_completes_while_the_reader_waits_for_state(kind: TerminalEventPublication, script: &str) {
    let mux = Mux::new(format!("terminal-event-lock-order-{kind:?}"), SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(Some("lock-order".into()), None, None).unwrap();
    let (surface, _) = mux
        .create_terminal_surface_in_workspace(
            workspace.workspace,
            Some(vec!["sh".into(), "-c".into(), script.into()]),
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();

    let (reached_tx, reached_rx) = mpsc::channel();
    let (resume_tx, resume_rx) = mpsc::channel::<()>();
    let resume_rx = Mutex::new(resume_rx);
    let observed = surface.id;
    let held_once = AtomicBool::new(false);
    mux.set_terminal_event_publish_hook(Some(Arc::new(move |event, surface| {
        // Hold only the first publication; the resize makes more output.
        if event != kind || surface != observed || held_once.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = reached_tx.send(());
        // Keep the reader here until the test owns `Mux::state`.
        let _ = resume_rx.lock().unwrap().recv_timeout(PUBLISH_DEADLINE);
    })));

    // A clean surface, so the next output publication is the observed one.
    surface.take_dirty();
    surface.write_bytes(b"go\n").unwrap();
    reached_rx.recv_timeout(PUBLISH_DEADLINE).expect("the publisher never reached the event");

    // A tree delta (close_surface) holds `Mux::state` ...
    let state = mux.state.lock().unwrap();
    resume_tx.send(()).unwrap();
    // ... while the TUI's geometry claim resizes the same terminal.
    let (resized_tx, resized_rx) = mpsc::channel();
    let resizer = std::thread::spawn({
        let surface = surface.clone();
        move || {
            let _ = resized_tx.send(surface.resize(100, 30).map_err(|error| error.to_string()));
        }
    });
    let resized = resized_rx.recv_timeout(RESIZE_DEADLINE);
    // Release the cycle before asserting so a failure cannot hang the suite.
    drop(state);
    resizer.join().unwrap();
    mux.set_terminal_event_publish_hook(None);
    let _ = surface.write_bytes(b"done\n");

    assert!(
        matches!(resized, Ok(Ok(true))),
        "the resize waited behind the publisher's terminal lock while the publisher waited for \
         Mux::state ({kind:?}): {resized:?}"
    );
}

#[test]
fn local_reader_publishes_a_title_after_releasing_the_terminal_lock() {
    resize_completes_while_the_reader_waits_for_state(
        TerminalEventPublication::Title,
        "IFS= read -r line; printf '\\033]0;lock-order-title\\007'; IFS= read -r line",
    );
}

#[test]
fn local_reader_publishes_a_bell_after_releasing_the_terminal_lock() {
    resize_completes_while_the_reader_waits_for_state(
        TerminalEventPublication::Bell,
        "IFS= read -r line; printf '\\007'; IFS= read -r line",
    );
}

#[test]
fn frame_producer_publishes_output_after_releasing_the_terminal_lock() {
    resize_completes_while_the_reader_waits_for_state(
        TerminalEventPublication::Output,
        "IFS= read -r line; printf 'lock-order-output'; IFS= read -r line",
    );
}
