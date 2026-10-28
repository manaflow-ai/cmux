//! Holder terminals start no thread of their own (H2, audit batch 3): their
//! output is read on the owner's read loop, as a direct PTY's is, and their
//! end comes from the holder sink, not from a `surface-<id>-wait` thread.

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;

use super::*;
use crate::holder_runtime::holder_local_launch;
use crate::holder_runtime::test_support::{nonblocking_pty, stand_in_service, stand_in_terminal};

const TERMINALS: u64 = 20;
const FIRST_ID: SurfaceId = 9_700;
const WAIT: Duration = Duration::from_secs(10);

#[test]
fn holder_terminals_read_on_the_owners_loop_and_end_without_a_thread_each() {
    let mux = Mux::new_for_test("holder-threads", SurfaceOptions::default());
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("holder-threads-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let service = stand_in_service(dir.join("h.sock"));
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let (master, program) = nonblocking_pty();
        let terminal = stand_in_terminal(service.clone(), index as u32 + 1, master);
        let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
        let surface = Surface::spawn_local(
            LocalSpawn {
                id: FIRST_ID + index,
                opts: SurfaceOptions { cols: 20, rows: 4, ..SurfaceOptions::default() },
                mux: Arc::downgrade(&mux),
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
        terminals.push((surface, terminal, program));
    }
    let own: Vec<String> = cmux_threads::snapshot()
        .into_iter()
        .map(|thread| thread.name)
        .filter(|name| {
            (FIRST_ID..FIRST_ID + TERMINALS).any(|id| {
                *name == format!("surface-{id}-reader") || *name == format!("surface-{id}-wait")
            })
        })
        .collect();
    let os_own: Vec<String> = std::fs::read_dir("/proc/self/task")
        .map(|tasks| {
            tasks
                .flatten()
                .filter_map(|task| std::fs::read_to_string(task.path().join("comm")).ok())
                .map(|comm| comm.trim().to_owned())
                .filter(|comm| comm.starts_with("surface-97") || comm.starts_with("surface-98"))
                .collect()
        })
        .unwrap_or_default();
    assert!(
        own.is_empty() && os_own.is_empty(),
        "holder terminals started threads: {own:?} {os_own:?}"
    );

    // Output reaches each screen; then each terminal ends with its status.
    for (index, (surface, terminal, _)) in terminals.iter().enumerate() {
        terminal.sink.data(0, format!("hello-{index}").as_bytes());
        let deadline = Instant::now() + WAIT;
        loop {
            let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
            if text.contains(&format!("hello-{index}")) {
                break;
            }
            assert!(Instant::now() < deadline, "terminal {index}'s output never showed");
            std::thread::sleep(Duration::from_millis(5));
        }
        terminal.sink.exit(ExitStatus::Exited(index as i32 % 5), 0);
    }
    for (index, (surface, _, _)) in terminals.iter().enumerate() {
        let pty = surface.as_pty().unwrap();
        assert!(
            pty.reader_completion.wait_until(Instant::now() + WAIT),
            "reader {index} never ended"
        );
        assert!(
            pty.reaper_completion.wait_until(Instant::now() + WAIT),
            "end {index} never recorded"
        );
        assert_eq!(
            surface.terminal_exit().map(|exit| exit.outcome),
            Some(crate::terminal_host_protocol::TerminalExitOutcome::Exit {
                code: index as i32 % 5
            }),
            "terminal {index}'s status"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}
