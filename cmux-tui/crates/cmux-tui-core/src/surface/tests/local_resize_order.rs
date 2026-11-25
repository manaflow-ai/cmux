//! Force output to remain unread while a local resize commits.

use super::*;
use std::fs::File;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;

#[test]
fn local_resize_parses_unread_output_on_the_old_grid() {
    check_local_resize_order(false);
}

#[test]
fn local_resize_bounds_the_drain_to_a_queued_snapshot() {
    check_local_resize_order(true);
}

fn check_local_resize_order(add_later_output: bool) {
    const WAIT: Duration = Duration::from_secs(5);
    let mux = Mux::new_for_test("local-resize-order", SurfaceOptions::default());
    let events = mux.subscribe();
    // A second subscriber that the test drains first: once it has the last
    // title, every title was published, and `events` has not been read yet,
    // as a busy subscriber under the full suite's load had not.
    let pace = mux.subscribe();
    let (reader, mut child) = UnixStream::pair().unwrap();
    let master = File::from(OwnedFd::from(reader.try_clone().unwrap()));
    let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
    let (end_tx, end_rx) = std::sync::mpsc::channel();
    let surface = Surface::spawn_local(
        LocalSpawn {
            id: 4244,
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
        LocalLaunch {
            master: Box::new(FdMasterPty { file: master, size: Mutex::new(geometry.pty_size()) }),
            reader: Box::new(reader),
            writer: Box::new(std::io::sink()),
            killer: Box::new(TestChildKiller),
            wait: Box::new(move || {
                let _ = end_rx.recv();
                TerminalEnd::ProcessEnded(TerminalExit::unknown("test ended"))
            }),
            pid: None,
            command: Vec::new(),
            cwd: None,
            supports_clear_history_key_fallback: false,
            holder: None,
        },
    )
    .unwrap();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let release_rx = Mutex::new(release_rx);
    let later_output = Mutex::new(child.try_clone().unwrap());
    *surface.as_pty().unwrap().geometry_test_hook.lock().unwrap() = Some(Arc::new(move |step| {
        if step == PtyGeometryTestStep::LocalReaderReady {
            ready_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv_timeout(WAIT).unwrap();
        } else if step == PtyGeometryTestStep::LocalDrainSnapshot && add_later_output {
            // Output arriving after the snapshot must not extend the drain
            // indefinitely or be consumed on the old grid.
            later_output.lock().unwrap().write_all(b"\x1b[2;30HY\x1b]2;after-resize\x07").unwrap();
        }
    }));

    // CUP clamps to column 20 on the old grid. Parsing at width 40 instead
    // would put X at column 30, even though the bytes preceded the resize.
    child.write_all(b"\x1b[1;30HX\x1b]2;resize-drained\x07").unwrap();
    ready_rx.recv_timeout(WAIT).unwrap();
    // Real mux callers can already hold state. Draining must not publish
    // observers on the resizer while it holds geometry or mux state.
    let resize = {
        let _state = mux.state.lock().unwrap();
        surface.resize(40, 4)
    };
    let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
    // The drain parsed the queued title before the later output, on the old
    // grid; the reader is still held here, so only the drain can have set it.
    let drained_title = surface.as_pty().unwrap().title.lock().unwrap().clone();
    *surface.as_pty().unwrap().geometry_test_hook.lock().unwrap() = None;
    release_tx.send(()).unwrap();
    // No new output or EOF: the resize's wake must publish the drained title
    // without trying a blocking read on the readiness it already consumed.
    let last_title = if add_later_output { "after-resize" } else { "resize-drained" };
    let deadline = Instant::now() + WAIT;
    loop {
        match pace.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(MuxEvent::TitleChanged { title, .. }) if title.as_ref() == last_title => break,
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    // The event bus keeps only a surface's newest title for a subscriber
    // that has not read yet (event_bus.rs, CoalescedEventKey::Title). Read
    // after `pace` saw the last title, `events` holds exactly that newest
    // title: the drained one was published first and then replaced. The
    // drain's own parse is checked through `drained_title` above; the order
    // of publication comes from the design (one pending list, one publisher)
    // and this test does not prove it.
    let mut titles: Vec<String> = Vec::new();
    loop {
        match events.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(MuxEvent::TitleChanged { title, .. }) => {
                titles.push(title.to_string());
                if title.as_ref() == last_title {
                    break;
                }
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    let later_text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
    drop(child);
    end_tx.send(()).unwrap();
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT));
    assert!(pty.reaper_completion.wait_until(Instant::now() + WAIT));
    resize.unwrap();
    assert_eq!(
        drained_title, "resize-drained",
        "the resize drained output without parsing its title"
    );
    assert_eq!(titles, [last_title], "a late subscriber sees exactly the newest title");
    assert_eq!(text.lines().next().unwrap_or_default().find('X'), Some(19), "{text:?}");
    if add_later_output {
        assert_eq!(
            later_text.lines().nth(1).unwrap_or_default().find('Y'),
            Some(29),
            "{later_text:?}"
        );
    }
}
