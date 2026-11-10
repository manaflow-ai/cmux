//! A daemon that stops reading a terminal host for longer than the host's
//! write time-out (2 s) while the terminal prints. On Nov 10 a session daemon
//! held a lock for 1.7 s on a Mac at load 250, and terminals then showed a
//! frozen picture at an old size until the person typed in them: the host's
//! writer had given up on the daemon and left the connection open, so the
//! daemon waited for frames that never came.
//!
//! A real daemon and a real terminal host. The daemon is stopped (SIGSTOP)
//! for more than [`STALL`]; the shell prints [`PRINTED_BYTES`] and a marker, and a
//! renderer changes the grid. When the daemon runs again its picture of the
//! terminal must become the current one, with no input from anybody.

use super::*;

/// How long the daemon stays stopped after the terminal printed: longer than
/// the host's write time-out, as a daemon that waits on a lock, a Mac that
/// sleeps, or a stopped process.
const STALL: Duration = Duration::from_secs(5);
/// More than a Unix socket buffers, so the host's write to the stopped daemon
/// blocks; less than the 8 MiB of output a host queues for one client, so
/// the queue limit never closes the connection: only the write time-out acts.
const PRINTED_BYTES: usize = 4_000_000;
const MARKER: &str = "stale-picture-done";
const NEW_GRID: (u16, u16) = (100, 30);

enum Seen {
    Marker,
    NewGrid,
}

#[test]
fn a_stalled_daemon_shows_the_current_screen_and_size_again_with_no_input() {
    let harness = RecoveryHarness::start("stalled-daemon-reader");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let before_record = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    // The renderer reads all the time: it is the test's view of the host, and
    // its own connection must stay healthy while the daemon's stalls.
    let renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    let mut renderer_writer = renderer.stream.try_clone().unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();
    let drain = std::thread::spawn(move || {
        let mut stream = renderer.stream;
        let mut tail = Vec::new();
        let mut marker_seen = false;
        while let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) {
            match frame.kind {
                MessageKind::Output if !marker_seen => {
                    tail.extend_from_slice(&frame.payload);
                    if contains_bytes(&tail, MARKER.as_bytes()) {
                        marker_seen = true;
                        let _ = seen_tx.send(Seen::Marker);
                    }
                    let keep = tail.len().saturating_sub(MARKER.len());
                    tail.drain(..keep);
                }
                MessageKind::Resized
                    if frame.payload.get(..2) == Some(&NEW_GRID.0.to_le_bytes()[..])
                        && frame.payload.get(2..4) == Some(&NEW_GRID.1.to_le_bytes()[..]) =>
                {
                    let _ = seen_tx.send(Seen::NewGrid);
                }
                _ => {}
            }
        }
    });

    // Only the daemon stops. The host, the shell and the renderer run on.
    harness.signal_daemon(libc::SIGSTOP);
    // The typed line holds `stale-%s-done`; only the program's output holds
    // the marker, so the echo of the line never counts as the output.
    write_frame(
        &mut renderer_writer,
        &Frame::new(
            MessageKind::Input,
            format!(
                "/usr/bin/head -c {PRINTED_BYTES} /dev/zero; printf 'stale-%s-done\\n' picture\n"
            )
            .into_bytes(),
        ),
    )
    .unwrap();
    assert!(
        matches!(seen_rx.recv_timeout(test_timeout(Duration::from_secs(30))), Ok(Seen::Marker)),
        "the host never published the end of the output to its renderer"
    );
    // The grid changes while the daemon does not read, as a pane that was
    // split or resized in the stall.
    let mut size = Vec::new();
    size.extend_from_slice(&NEW_GRID.0.to_le_bytes());
    size.extend_from_slice(&NEW_GRID.1.to_le_bytes());
    write_frame(&mut renderer_writer, &Frame::new(MessageKind::ViewerSize, size)).unwrap();
    assert!(
        matches!(seen_rx.recv_timeout(test_timeout(Duration::from_secs(10))), Ok(Seen::NewGrid)),
        "the host never changed its grid to {NEW_GRID:?}"
    );
    // The host's write to the daemon makes no progress from here on.
    std::thread::sleep(STALL);
    harness.signal_daemon(libc::SIGCONT);
    let resumed_at = Instant::now();

    // From here nothing is sent to the terminal: no key, no resize, no
    // request that the host answers. The daemon must find by itself that
    // its picture is old.
    let deadline = resumed_at + test_timeout(Duration::from_secs(10));
    loop {
        let state =
            request(&harness.socket, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        let grid = (state["cols"].as_u64(), state["rows"].as_u64());
        let screen =
            request(&harness.socket, serde_json::json!({"cmd": "read-screen", "surface": surface}))
                ["text"]
                .as_str()
                .unwrap()
                .to_string();
        let current_grid = grid == (Some(u64::from(NEW_GRID.0)), Some(u64::from(NEW_GRID.1)));
        if current_grid && screen.contains(MARKER) {
            eprintln!(
                "stalled-daemon-reader: current screen and size {} ms after the daemon ran again",
                resumed_at.elapsed().as_millis()
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the daemon's picture of the terminal stayed old after a {STALL:?} stall, with no \
             input: grid {grid:?} (the host has {NEW_GRID:?}), end of the output on the screen: \
             {}",
            screen.contains(MARKER)
        );
        std::thread::sleep(Duration::from_millis(25));
    }

    // The same host and the same shell: the daemon attached again, it did
    // not start the terminal again.
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation);
    let after_record = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after_record.host_pid, before_record.host_pid);
    assert_eq!(after_record.host_start_nonce, before_record.host_start_nonce);

    let _ = renderer_writer.shutdown(std::net::Shutdown::Both);
    drain.join().unwrap();
    close_terminal_surface(&harness.socket, surface, 4);
    wait_for_no_host_records(&harness.host_root());
}
