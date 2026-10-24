//! Force output to remain unread while a local resize commits.

use super::*;
use std::fs::File;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;

#[test]
fn local_resize_parses_unread_output_on_the_old_grid() {
    const WAIT: Duration = Duration::from_secs(5);
    let mux = Mux::new_for_test("local-resize-order", SurfaceOptions::default());
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
    *surface.as_pty().unwrap().geometry_test_hook.lock().unwrap() = Some(Arc::new(move |step| {
        if step == PtyGeometryTestStep::LocalReaderReady {
            ready_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv_timeout(WAIT).unwrap();
        }
    }));

    // CUP clamps to column 20 on the old grid. Parsing at width 40 instead
    // would put X at column 30, even though the bytes preceded the resize.
    child.write_all(b"\x1b[1;30HX").unwrap();
    ready_rx.recv_timeout(WAIT).unwrap();
    let resize = surface.resize(40, 4);
    let text = surface.try_with_terminal(|term| term.viewport_text()).unwrap().unwrap();
    *surface.as_pty().unwrap().geometry_test_hook.lock().unwrap() = None;
    release_tx.send(()).unwrap();
    drop(child);
    end_tx.send(()).unwrap();
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT));
    assert!(pty.reaper_completion.wait_until(Instant::now() + WAIT));
    resize.unwrap();
    assert_eq!(text.lines().next().unwrap_or_default().find('X'), Some(19), "{text:?}");
}
