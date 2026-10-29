//! Receipted input on holder terminals, whose input the `pty-writer` writes
//! (`crate::pty_write`): a confirmed write answers for the bytes the PTY
//! took, not for the bytes the queue took.

use std::fs::File;

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;

use super::*;
use crate::holder_runtime::holder_local_launch;
use crate::holder_runtime::test_support::{nonblocking_pty, stand_in_service, stand_in_terminal};

/// A surface on a holder terminal (a stand-in holder nobody connects to),
/// with the terminal and the program's end of its PTY.
fn holder_surface(
    name: &str,
) -> (Arc<Surface>, Arc<crate::holder_runtime::HolderTerminal>, File, PathBuf) {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let service = stand_in_service(dir.join("h.sock"));
    let (master, program) = nonblocking_pty();
    let terminal = stand_in_terminal(service, 7, master);
    let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
    let surface = Surface::spawn_local(
        LocalSpawn {
            id: 4247,
            opts: SurfaceOptions { cols: 20, rows: 4, ..SurfaceOptions::default() },
            mux: Weak::new(),
            terminal_public_id: None,
            kitty_reservation: None,
            initial_kitty_limits: KittyGraphicsLimits::disabled(),
            resource_identity: None,
            lifetime: PtyLifetime::DaemonOwned,
            cell_pixels: (8, 16),
            initial_geometry: geometry,
            host_identity: None,
        },
        holder_local_launch(&terminal, Vec::new(), None).unwrap(),
    )
    .unwrap();
    (surface, terminal, program, dir)
}

fn end(surface: &Surface, terminal: &crate::holder_runtime::HolderTerminal, dir: &std::path::Path) {
    terminal.sink.exit(ExitStatus::Exited(0), 0);
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + Duration::from_secs(10)));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn holder_input_a_confirmed_write_returns_once_the_program_can_read_it() {
    let (surface, terminal, mut program, dir) = holder_surface("chi-ok");
    surface.write_bytes_confirmed(b"ready").expect("the PTY took the bytes");
    let mut got = [0u8; 5];
    Read::read_exact(&mut program, &mut got).unwrap();
    assert_eq!(&got, b"ready");
    end(&surface, &terminal, &dir);
}

/// The queue took the bytes, then dropped them when the program hung up:
/// the confirmed write fails instead of reporting them delivered, and the
/// next one fails as known not delivered.
#[test]
fn holder_input_a_confirmed_write_to_a_hung_up_terminal_fails() {
    let (surface, terminal, program, dir) = holder_surface("chi-hup");
    drop(program);
    // A master whose program hung up may still buffer some input; a
    // megabyte fills that buffer, and the master then reports the hang-up.
    let lost = vec![b'z'; 1024 * 1024];
    assert!(
        surface.write_bytes_confirmed(&lost).is_err(),
        "a megabyte to a hung-up program was reported delivered"
    );
    match surface.write_bytes_confirmed(b"late") {
        Err(ConfirmedInputFailure::Known(error)) => {
            assert_ne!(
                error.kind(),
                std::io::ErrorKind::WouldBlock,
                "a hang-up is not a full queue"
            );
        }
        other => panic!("input to a hung-up terminal was {other:?}"),
    }
    end(&surface, &terminal, &dir);
}

/// A queue full of input its program does not read refuses the confirmed
/// write whole: known not delivered, not indeterminate.
#[test]
fn holder_input_a_full_queue_refuses_a_confirmed_write_as_known() {
    let (surface, terminal, _program, dir) = holder_surface("chi-full");
    let input = terminal.input().expect("a launched holder terminal has an input queue").clone();
    input
        .send(&vec![b'p'; crate::pty_write::QUEUE_LIMIT_BYTES], crate::pty_write::InputLane::Bulk)
        .unwrap();
    match surface.write_bytes_confirmed(&vec![b'q'; 1024 * 1024]) {
        Err(ConfirmedInputFailure::Known(error)) => {
            assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        }
        other => panic!("a write the full queue refused was {other:?}"),
    }
    drop(input);
    end(&surface, &terminal, &dir);
}
