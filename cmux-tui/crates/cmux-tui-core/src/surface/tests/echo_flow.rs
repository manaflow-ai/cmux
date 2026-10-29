//! Exact echo flows on terminals whose master the daemon writes itself:
//! a holder terminal tells a holder that granted
//! WRITE_FLOW about the key press before its bytes, and the output the
//! holder streams next is that key's echo on the attach stream, once. A
//! holder older than the capability gets no mark. A write that never
//! reached the PTY arms nothing.

use std::fs::File;
use std::io::Read;
use std::os::fd::OwnedFd;
use std::os::unix::net::{UnixListener, UnixStream};

use cmux_holder::ExitStatus;
use cmux_holder::link::TerminalSink;
use cmux_holder::wire::{self, Kind, capability};

use super::*;
use crate::holder_runtime::holder_local_launch;
use crate::holder_runtime::test_support::{
    next_frame, nonblocking_pty, stand_in_service, stand_in_terminal, welcome_granting,
};
use bytes::Bytes;

const WAIT: Duration = Duration::from_secs(10);

fn spawn_options() -> LocalSpawn {
    let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
    LocalSpawn {
        id: 4246,
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
    }
}

/// The next output frame on `attach`, skipping any other frame.
fn next_output(attach: &AttachStream) -> AttachFrame {
    let deadline = Instant::now() + WAIT;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let frame = attach.stream.recv_timeout(left).expect("an output frame");
        if frame.output().is_some() {
            return frame;
        }
    }
}

/// The frames a stand-in holder got up to the test's SIGNAL on channel 999.
fn frames_until_sentinel(stream: &UnixStream, reader: &mut wire::Reader) -> Vec<wire::Frame> {
    let mut frames = Vec::new();
    loop {
        let frame = next_frame(stream, reader, "the test's SIGNAL");
        if frame.kind == Kind::Signal as u16 && frame.chan == 999 {
            return frames;
        }
        frames.push(frame);
    }
}

fn check_holder_echo_flow(granted: Option<u32>) {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("cef-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let stand_in = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(WAIT)).unwrap();
        let mut reader = wire::Reader::default();
        welcome_granting(&stream, &mut reader, &[], granted);
        (frames_until_sentinel(&stream, &mut reader), stream)
    });
    let service = stand_in_service(socket);
    let link = service.link().unwrap();
    let (master, mut shell) = nonblocking_pty();
    let terminal = stand_in_terminal(service, 5, master);
    let surface = Surface::spawn_local(
        spawn_options(),
        holder_local_launch(&terminal, Vec::new(), None).unwrap(),
    )
    .unwrap();
    let attach = surface.attach_stream().unwrap();

    surface.write_bytes_flow(b"a", 42).unwrap();
    let mut typed = [0u8; 1];
    shell.read_exact(&mut typed).unwrap();
    assert_eq!(&typed, b"a", "the key reached the shell");
    // The holder streams the shell's echo: it carries the key press, once.
    terminal.sink.data(0, b"a");
    assert_eq!(
        next_output(&attach),
        AttachFrame::FlowOutput { output: Bytes::from_static(b"a"), flow: 42 }
    );
    terminal.sink.data(1, b"b");
    assert_eq!(next_output(&attach), AttachFrame::Output(Bytes::from_static(b"b")), "only once");

    link.signal(999, 0).unwrap();
    let (frames, stream) = stand_in.join().expect("the stand-in saw the test's SIGNAL");
    let marks: Vec<_> = frames.iter().filter(|frame| frame.kind == Kind::Write as u16).collect();
    if granted.is_some_and(|granted| granted & capability::WRITE_FLOW != 0) {
        assert_eq!(marks.len(), 1, "one flow mark: {frames:?}");
        assert_eq!((marks[0].flags, marks[0].chan), (wire::FLAG_FLOW, 5));
        assert_eq!(
            wire::split_write(marks[0].flags, &marks[0].payload).unwrap(),
            (&[][..], Some(42)),
            "a mark with no input: the daemon wrote the key on its custody master"
        );
    } else {
        assert!(marks.is_empty(), "a holder without WRITE_FLOW got a WRITE: {frames:?}");
    }

    terminal.sink.exit(ExitStatus::Exited(0), 2);
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT));
    drop(stream);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn echo_flow_a_granted_holder_gets_the_mark_and_its_output_carries_the_flow() {
    check_holder_echo_flow(Some(capability::WRITE_FLOW));
}

#[test]
fn echo_flow_an_older_holder_gets_no_mark() {
    check_holder_echo_flow(None);
}

/// A local terminal whose writer fails: the key never reached the PTY, so
/// the output the PTY gives next is not its echo.
#[test]
fn echo_flow_a_failed_write_arms_nothing() {
    struct Failing;
    impl Write for Failing {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let (reader, mut child) = UnixStream::pair().unwrap();
    let master = File::from(OwnedFd::from(reader.try_clone().unwrap()));
    let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
    let (end_tx, end_rx) = std::sync::mpsc::channel::<()>();
    let surface = Surface::spawn_local(
        spawn_options(),
        LocalLaunch {
            master: Box::new(FdMasterPty { file: master, size: Mutex::new(geometry.pty_size()) }),
            reader: Box::new(reader),
            writer: Box::new(Failing),
            killer: Box::new(TestChildKiller),
            end: LocalEnd::Wait(Box::new(move || {
                let _ = end_rx.recv();
                TerminalEnd::ProcessEnded(TerminalExit::unknown("test ended"))
            })),
            pid: None,
            command: Vec::new(),
            cwd: None,
            supports_clear_history_key_fallback: false,
            holder: None,
        },
    )
    .unwrap();
    let attach = surface.attach_stream().unwrap();

    assert!(surface.write_bytes_flow(b"a", 42).is_err());
    child.write_all(b"unrelated").unwrap();
    assert_eq!(next_output(&attach), AttachFrame::Output(Bytes::from_static(b"unrelated")));

    drop(child);
    end_tx.send(()).unwrap();
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT));
}

/// A local terminal's key press records the daemon's receive
/// and PTY write before its echo, the read that echoes it stamps the read,
/// and the press's stamps are there for the attach writer once echoed.
#[test]
fn input_stages_a_local_key_press_stamps_receive_write_and_read() {
    let (reader, mut child) = UnixStream::pair().unwrap();
    child.set_read_timeout(Some(WAIT)).unwrap();
    let master = File::from(OwnedFd::from(reader.try_clone().unwrap()));
    let writer = reader.try_clone().unwrap();
    let geometry = PtyGeometry { cols: 20, rows: 4, cell_width: 8, cell_height: 16 };
    let (end_tx, end_rx) = std::sync::mpsc::channel::<()>();
    let surface = Surface::spawn_local(
        spawn_options(),
        LocalLaunch {
            master: Box::new(FdMasterPty { file: master, size: Mutex::new(geometry.pty_size()) }),
            reader: Box::new(reader),
            writer: Box::new(writer),
            killer: Box::new(TestChildKiller),
            end: LocalEnd::Wait(Box::new(move || {
                let _ = end_rx.recv();
                TerminalEnd::ProcessEnded(TerminalExit::unknown("test ended"))
            })),
            pid: None,
            command: Vec::new(),
            cwd: None,
            supports_clear_history_key_fallback: false,
            holder: None,
        },
    )
    .unwrap();
    let attach = surface.attach_stream().unwrap();
    let stages = surface.input_stages().unwrap();

    let received = crate::input_stages::now_ns();
    surface.write_key_flow(b"a", 42, received).unwrap();
    let mut key = [0u8; 1];
    child.read_exact(&mut key).unwrap();
    assert_eq!(&key, b"a");
    assert_eq!(stages.stages(42), None, "no echo yet");

    child.write_all(b"a").unwrap();
    assert_eq!(next_output(&attach).flow(), 42);
    let stamped = stages.stages(42).expect("the echo's stages");
    assert_eq!(stamped.received_ns, received);
    assert!(stamped.written_ns >= received, "{stamped:?}");
    assert!(stamped.read_ns >= stamped.written_ns, "{stamped:?}");

    // A send with no flow arms nothing.
    surface.write_key_flow(b"b", 0, received).unwrap();
    child.read_exact(&mut key).unwrap();
    assert_eq!(stages.stages(0), None);

    drop(child);
    end_tx.send(()).unwrap();
    let pty = surface.as_pty().unwrap();
    assert!(pty.reader_completion.wait_until(Instant::now() + WAIT));
}
