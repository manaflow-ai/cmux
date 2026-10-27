//! A holder terminal's end comes from the holder's EXIT {status, end}, read
//! once the parser reached the stream's end (p01-process-121): no
//! `surface-{id}-wait` thread, and the exit shows after the final output.

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;

use super::*;
use crate::holder_runtime::test_support::{nonblocking_pty, stand_in_service, stand_in_terminal};
use crate::holder_runtime::{HolderTerminal, holder_local_launch};
use crate::terminal_host_protocol::TerminalExitOutcome;

const WAIT: Duration = Duration::from_secs(10);

fn spawn_options(id: SurfaceId) -> LocalSpawn {
    let geometry = PtyGeometry { cols: 40, rows: 4, cell_width: 8, cell_height: 16 };
    LocalSpawn {
        id,
        opts: SurfaceOptions { cols: 40, rows: 4, ..SurfaceOptions::default() },
        mux: Weak::new(),
        terminal_public_id: None,
        kitty_reservation: None,
        initial_kitty_limits: KittyGraphicsLimits::disabled(),
        resource_identity: None,
        lifetime: PtyLifetime::DaemonOwned,
        cell_pixels: (8, 16),
        initial_geometry: geometry,
        host_identity: None,
    }
}

/// A holder terminal surface on a stand-in service no holder listens on
/// (an ended terminal's CLOSE finds no link).
fn holder_surface(id: SurfaceId, chan: u32) -> (Arc<Surface>, Arc<HolderTerminal>, std::fs::File) {
    let socket = std::env::temp_dir()
        .join(format!("cmux-holder-exit-{}-{id}-absent.sock", std::process::id()));
    let (master, shell) = nonblocking_pty();
    let terminal = stand_in_terminal(stand_in_service(socket), chan, master);
    let surface = Surface::spawn_local(
        spawn_options(id),
        holder_local_launch(&terminal, Vec::new(), None).unwrap(),
    )
    .unwrap();
    (surface, terminal, shell)
}

#[test]
fn a_holder_terminal_ends_on_its_exit_frame_after_its_final_output_with_no_wait_thread() {
    let (surface, terminal, _shell) = holder_surface(4247, 7);
    let pty = surface.as_pty().unwrap();
    assert!(
        pty.reaper_thread.lock().unwrap().is_none(),
        "a holder terminal started a surface-{{id}}-wait thread"
    );

    // The holder sends the last DATA, then EXIT with the offset after it.
    terminal.sink.data(0, b"final-output");
    terminal.sink.exit(ExitStatus::Exited(3), 12);

    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT), "the reader never ended");
    assert!(surface.is_dead(), "the exit was not published at the stream's end");
    assert_eq!(
        surface.terminal_exit().expect("the EXIT's status was recorded").outcome,
        TerminalExitOutcome::Exit { code: 3 }
    );
    let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
    assert!(text.contains("final-output"), "the exit came without the final output: {text:?}");
    assert_eq!(terminal.sink.confirmed(), 12, "the parser had not reached the EXIT's end");
    assert!(pty.reaper_thread.lock().unwrap().is_none());
}

#[test]
fn a_lost_holder_ends_the_terminal_at_the_stream_end_with_no_wait_thread() {
    let (surface, terminal, _shell) = holder_surface(4248, 8);
    let pty = surface.as_pty().unwrap();

    terminal.sink.data(0, b"before-the-loss");
    terminal.sink.lose();

    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT), "the reader never ended");
    assert!(surface.is_dead());
    let end = surface.terminal_end().expect("the loss was recorded");
    assert!(
        !matches!(end, TerminalEnd::ProcessEnded(_)),
        "a lost holder is not a process end: {end:?}"
    );
    let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
    assert!(text.contains("before-the-loss"), "{text:?}");
    assert!(pty.reaper_thread.lock().unwrap().is_none());
}
