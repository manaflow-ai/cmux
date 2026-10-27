//! Holder terminals parse on their owner's VT pool (p01-process-120): many
//! terminals start no `surface-<id>-reader` thread, each one's output
//! reaches its screen in order however the holder link chunks it, a flood
//! in one terminal does not stop another's echo, and each still ends with
//! the status its holder reported.

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;

use super::*;
use crate::holder_runtime::test_support::{nonblocking_pty, stand_in_service, stand_in_terminal};
use crate::holder_runtime::{HolderTerminal, holder_local_launch};

const WAIT: Duration = Duration::from_secs(20);
const FIRST_ID: SurfaceId = 9_800;
const TERMINALS: u64 = 48;
const LINES: u32 = 300;

fn spawn_on(mux: &Arc<Mux>, id: SurfaceId) -> (Arc<Surface>, Arc<HolderTerminal>, std::fs::File) {
    let geometry = PtyGeometry { cols: 40, rows: 10, cell_width: 8, cell_height: 16 };
    let (master, shell) = nonblocking_pty();
    // No holder listens there: acknowledgements and snapshots go nowhere.
    let service = stand_in_service(
        std::env::temp_dir().join(format!("cmux-vt-pool-{}-{id}.sock", std::process::id())),
    );
    let chan = u32::try_from(id).unwrap();
    let terminal = stand_in_terminal(service, chan, master);
    let spawn = LocalSpawn {
        id,
        opts: SurfaceOptions { cols: 40, rows: 10, ..SurfaceOptions::default() },
        mux: Arc::downgrade(mux),
        terminal_public_id: None,
        kitty_reservation: None,
        initial_kitty_limits: KittyGraphicsLimits::disabled(),
        resource_identity: None,
        lifetime: PtyLifetime::DaemonOwned,
        cell_pixels: (8, 16),
        initial_geometry: geometry,
        host_identity: None,
    };
    let launch = holder_local_launch(&terminal, Vec::new(), None).unwrap();
    (Surface::spawn_local(spawn, launch).unwrap(), terminal, shell)
}

fn numbered(count: u32) -> Vec<u8> {
    (1..=count).flat_map(|line| format!("line-{line}\r\n").into_bytes()).collect()
}

fn wait_for_text(surface: &Surface, text: &str) -> String {
    let deadline = Instant::now() + WAIT;
    loop {
        let shown = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
        if shown.contains(text) || Instant::now() >= deadline {
            return shown;
        }
        std::thread::yield_now();
    }
}

fn reader_threads(ids: std::ops::Range<SurfaceId>) -> Vec<String> {
    cmux_threads::snapshot()
        .into_iter()
        .map(|thread| thread.name)
        .filter(|name| ids.clone().any(|id| *name == format!("surface-{id}-reader")))
        .collect()
}

#[test]
fn holder_terminals_parse_on_the_vt_pool_in_order_and_end_with_their_status() {
    let mux = Mux::new_for_test("vt-pool-holder", SurfaceOptions::default());
    let terminals: Vec<_> = (0..TERMINALS).map(|index| spawn_on(&mux, FIRST_ID + index)).collect();
    assert_eq!(reader_threads(FIRST_ID..FIRST_ID + TERMINALS), Vec::<String>::new());
    assert!(mux.vt_pool().started_shards() <= crate::vt_pool::MAX_SHARDS);

    // The holder link streams each terminal's output in chunks that cut
    // lines (and the CRLF) in two, interleaved across the terminals.
    let output = numbered(LINES);
    let mut offsets = vec![0usize; terminals.len()];
    while offsets.iter().any(|offset| *offset < output.len()) {
        for (index, (_, terminal, _)) in terminals.iter().enumerate() {
            let from = offsets[index];
            if from >= output.len() {
                continue;
            }
            let to = (from + 7 + index % 5).min(output.len());
            terminal.sink.data(from as u64, &output[from..to]);
            offsets[index] = to;
        }
    }
    let end = output.len() as u64;
    let expected: Vec<String> = (LINES - 8..=LINES).map(|line| format!("line-{line}")).collect();
    for (index, (surface, terminal, _)) in terminals.iter().enumerate() {
        let shown = wait_for_text(surface, &format!("line-{LINES}"));
        let lines: Vec<_> =
            shown.lines().map(str::trim_end).filter(|line| !line.is_empty()).collect();
        assert_eq!(lines, expected, "terminal {index}'s screen");
        terminal.sink.exit(ExitStatus::Exited(i32::try_from(index % 7).unwrap()), end);
    }
    for (index, (surface, _, _)) in terminals.iter().enumerate() {
        let pty = surface.as_pty().unwrap();
        assert!(pty.reader_completion.wait_until(Instant::now() + WAIT), "terminal {index}");
        let deadline = Instant::now() + WAIT;
        let ended = loop {
            if let Some(exit) = surface.terminal_exit() {
                break Some(exit.outcome);
            }
            if Instant::now() >= deadline {
                break None;
            }
            std::thread::yield_now();
        };
        let code = i32::try_from(index % 7).unwrap();
        assert_eq!(
            ended,
            Some(crate::terminal_host_protocol::TerminalExitOutcome::Exit { code }),
            "terminal {index}'s status"
        );
    }
    let deadline = Instant::now() + WAIT;
    while mux.vt_pool().sources() != 0 {
        assert!(Instant::now() < deadline, "ended terminals stayed on the VT pool");
        std::thread::yield_now();
    }
}

/// One terminal floods while another echoes a key: the echo reaches its
/// screen while the flood is still being parsed, on any shard.
#[test]
fn a_flooding_holder_terminal_does_not_stop_another_ones_echo() {
    let mux = Mux::new_for_test("vt-pool-flood", SurfaceOptions::default());
    let (_flood_surface, flood, _flood_shell) = spawn_on(&mux, FIRST_ID + 100);
    let (echo_surface, echo, _echo_shell) = spawn_on(&mux, FIRST_ID + 101);
    let feeding = Arc::new(AtomicBool::new(true));
    let feeder = std::thread::spawn({
        let feeding = feeding.clone();
        move || {
            // About 8 MiB of output while the test types.
            let chunk = vec![b'x'; 64 * 1024];
            let mut offset = 0u64;
            for _ in 0..128 {
                if !feeding.load(Ordering::Acquire) {
                    break;
                }
                flood.sink.data(offset, &chunk);
                offset += chunk.len() as u64;
            }
        }
    });
    for key in 0..20u32 {
        let typed = format!("key-{key}\r\n");
        let start = echo.sink.received();
        echo.sink.data(start, typed.as_bytes());
        let shown = wait_for_text(&echo_surface, &format!("key-{key}"));
        assert!(shown.contains(&format!("key-{key}")), "the echo never showed: {shown:?}");
    }
    feeding.store(false, Ordering::Release);
    feeder.join().unwrap();
}
