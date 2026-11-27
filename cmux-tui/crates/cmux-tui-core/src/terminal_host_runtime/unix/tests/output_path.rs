//! The host's output path: the parser's legacy stream, which it builds only
//! while a legacy client is attached, and the client writer, which sends the
//! frames queued at one wake together, in order, releasing each frame's queue
//! bytes after its write.

use super::*;

/// A host with a running parser, and the tap of a legacy client that has
/// not joined yet.
struct LegacyHost {
    host: Arc<HostShared>,
    parser: thread::JoinHandle<()>,
    cursor: u64,
    tap: HostTap,
    frames: Receiver<Arc<Frame>>,
    _peer: UnixStream,
}

impl LegacyHost {
    fn start() -> Self {
        let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
        let host = test_host_shared_with(
            term,
            parser_commands,
            ClipboardReads::new(Arc::new(SystemClock)),
        );
        let initial_colors = host.term.lock().unwrap().color_overrides();
        let parser_host = host.clone();
        let signals = ParserSignals {
            pending_responses: Arc::new(Mutex::new(Vec::new())),
            title_changed: Arc::new(AtomicBool::new(false)),
            bell: Arc::new(AtomicBool::new(false)),
            program_status: Default::default(),
        };
        let parser =
            thread::spawn(move || run_host_parser(parser_host, receiver, initial_colors, signals));
        let (socket, peer) = UnixStream::pair().unwrap();
        let (sender, frames) = mpsc_channel();
        let tap = HostTap::new(sender, Arc::new(socket), usize::MAX);
        Self { host, parser, cursor: 0, tap, frames, _peer: peer }
    }

    /// Parses `bytes` as one PTY chunk and waits until it is applied.
    fn output(&mut self, bytes: &[u8]) {
        let (cursor, frame) =
            self.host.smart.publish_shared(Frame::new(MessageKind::Output, bytes.to_vec()));
        self.cursor = cursor;
        self.host
            .parser_commands
            .send(ParserCommand::Output { frame, source_cursor: cursor, accounted_bytes: 0 })
            .unwrap();
        let (barrier, applied) = sync_channel(1);
        self.host.parser_commands.send(ParserCommand::Barrier(barrier)).unwrap();
        applied.recv_timeout(Duration::from_secs(5)).unwrap();
    }

    /// Joins the legacy client the way `serve_client` does: under the
    /// terminal lock that its snapshot is taken under.
    fn attach_legacy(&self) {
        let _term = self.host.term.lock().unwrap();
        let _broadcast = self.host.broadcast_lock.lock().unwrap();
        self.host.taps.lock().unwrap().insert(1, self.tap.clone());
    }

    fn received(&self) -> Vec<(MessageKind, u32, Vec<u8>)> {
        self.frames
            .try_iter()
            .map(|frame| (frame.kind, frame.flags, frame.payload.clone()))
            .collect()
    }

    fn finish(self) {
        self.host.parser_commands.send(ParserCommand::Drain).unwrap();
        self.parser.join().expect("the parser applied every command");
    }
}

const SET_RED_PALETTE_ENTRY: &[u8] = b"\x1b]4;1;rgb:ff/00/00\x1b\\";
const SET_PWD: &[u8] = b"\x1b]7;file://host/tmp/first\x1b\\";

#[test]
fn a_legacy_client_that_joins_later_gets_only_changes_after_its_snapshot() {
    let mut host = LegacyHost::start();
    // No legacy client: the parser changes colors and the directory, and
    // publishes nothing on the legacy stream.
    host.output(SET_RED_PALETTE_ENTRY);
    host.output(SET_PWD);
    assert_eq!(host.host.sequence.load(Ordering::Acquire), 0);
    assert_eq!(host.host.smart.applied_cursor.load(Ordering::Acquire), host.cursor);

    host.attach_legacy();
    // The snapshot holds the red entry and the directory: plain output after
    // it carries no Colors and no Pwd.
    host.output(b"plain");
    assert_eq!(host.received(), [(MessageKind::Output, 0, b"plain".to_vec())]);

    // A change after the snapshot reaches the client, coupled as before.
    host.output(b"\x1b]4;1;rgb:00/ff/00\x1b\\");
    let frames = host.received();
    assert_eq!(frames.len(), 2, "{frames:?}");
    assert_eq!((frames[0].0, frames[0].1), (MessageKind::Output, FLAG_COLORS_FOLLOW));
    assert_eq!(frames[1].0, MessageKind::Colors);
    let colors = decode_terminal_color_overrides(&frames[1].2).unwrap();
    let green = colors.palette[1].expect("the entry the program set");
    assert_eq!((green.r, green.g, green.b), (0, 0xff, 0));

    host.output(b"\x1b]7;file://host/tmp/second\x1b\\");
    let frames = host.received();
    let pwd = frames.last().expect("a Pwd frame");
    assert_eq!(pwd.0, MessageKind::Pwd, "{frames:?}");
    assert!(String::from_utf8_lossy(&pwd.2).contains("/tmp/second"), "{frames:?}");
    host.finish();
}

#[test]
fn a_legacy_client_attached_throughout_gets_every_transition() {
    let mut host = LegacyHost::start();
    host.attach_legacy();
    host.output(SET_RED_PALETTE_ENTRY);
    let frames = host.received();
    assert_eq!(frames.len(), 2, "{frames:?}");
    assert_eq!((frames[0].0, frames[0].1), (MessageKind::Output, FLAG_COLORS_FOLLOW));
    assert_eq!(frames[1].0, MessageKind::Colors);
    host.output(SET_PWD);
    let frames = host.received();
    assert_eq!(
        frames.iter().map(|frame| frame.0).collect::<Vec<_>>(),
        [MessageKind::Output, MessageKind::Pwd]
    );
    assert_eq!(host.host.sequence.load(Ordering::Acquire), 4);
    host.finish();
}

/// Frames queued for one client, the writer's private wake sentinel last.
fn queue(tap: &HostTap, frames: &[Frame]) {
    for frame in frames {
        assert!(tap.try_send(frame.clone()));
    }
}

fn numbered_output(count: u64, len: usize) -> Vec<Frame> {
    (1..=count)
        .map(|sequence| {
            let mut frame = Frame::new(MessageKind::Output, vec![sequence as u8; len]);
            frame.sequence = sequence;
            frame
        })
        .collect()
}

fn read_all(mut peer: UnixStream) -> Vec<Frame> {
    let mut frames = Vec::new();
    while let Some(frame) = read_frame(&mut peer, MAX_FRAME_PAYLOAD).unwrap() {
        frames.push(frame);
    }
    frames
}

#[test]
fn the_writer_sends_every_queued_frame_in_order_and_releases_its_bytes() {
    let (socket, peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    // More frames and bytes than one batch takes, so the writer batches several times.
    let frames = numbered_output(3 * MAX_BATCH_FRAMES as u64 + 5, 3000);
    queue(&tap, &frames);
    tap.wake_writer();
    let reader = thread::spawn(move || read_all(peer));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    drop(stream);
    tap.close();
    assert_eq!(reader.join().unwrap(), frames);
    assert_eq!(tap.queued_bytes.load(Ordering::Acquire), 0);
    assert_eq!(tap.queued_output_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn the_writer_stops_after_exit_and_writes_nothing_queued_behind_it() {
    let (socket, peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    let mut frames = numbered_output(3, 10);
    let mut exit = Frame::new(MessageKind::Exit, Vec::new());
    exit.sequence = 4;
    frames.push(exit);
    queue(&tap, &frames);
    queue(&tap, &numbered_output(2, 7));
    let reader = thread::spawn(move || read_all(peer));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    tap.close();
    drop(stream);
    assert_eq!(reader.join().unwrap(), frames);
}

#[test]
fn a_lone_frame_leaves_without_waiting_for_more() {
    let (socket, mut peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    let writer = {
        let tap = tap.clone();
        thread::spawn(move || {
            let mut stream = socket;
            write_queued_frames(&mut stream, &receiver, &tap);
        })
    };
    let echo = numbered_output(1, 1);
    queue(&tap, &echo);
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    // The writer holds the only other frame source open: a writer that
    // waited for a fuller batch would time this read out.
    assert_eq!(read_frame(&mut peer, MAX_FRAME_PAYLOAD).unwrap().as_ref(), echo.first());
    tap.wake_writer();
    writer.join().unwrap();
}

#[test]
fn a_failed_write_ends_the_writer_and_releases_the_batch() {
    let (socket, peer) = UnixStream::pair().unwrap();
    drop(peer);
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    queue(&tap, &numbered_output(4, 100));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    assert_eq!(tap.queued_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn an_accepted_client_gets_a_send_buffer_that_holds_one_writer_batch() {
    let host = test_host_shared();
    let (accepted, client) = UnixStream::pair().unwrap();
    let probe = accepted.try_clone().unwrap();
    shared::host_accept::serve_accepted(&host, accepted).unwrap();
    let mut size: libc::c_int = 0;
    let mut len = size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: `probe` is an open socket for this call; getsockopt writes at
    // most `len` bytes into the live local `size`.
    let status = unsafe {
        libc::getsockopt(
            probe.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&raw mut size).cast(),
            &raw mut len,
        )
    };
    assert_eq!(status, 0);
    assert!(
        usize::try_from(size).unwrap() >= MAX_BATCH_BYTES,
        "send buffer {size} bytes; one writer batch is {MAX_BATCH_BYTES}"
    );
    // The client never says hello: its serving thread ends.
    drop(client);
}
