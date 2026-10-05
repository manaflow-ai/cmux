//! Clipboard-read broker (decision CLIPBOARD-READ-BROKER): the discovery
//! record gate, the owner handshake, and the host's deny-by-default read
//! lifecycle on a live parser with an injected clock.

use super::super::clipboard_read::{
    ClipboardClock, ClipboardReadState, decode_clipboard_read_request, encode_clipboard_read_reply,
};
use super::*;
use ghostty_vt::{ClipboardLocation, ClipboardReadRequest};
use std::sync::MutexGuard;

const OSC52_READ: &[u8] = b"\x1b]52;c;?\x07";
const REFUSED: &[u8] = b"\x1b]52;c;\x07";
const GRANTED_HI: &[u8] = b"\x1b]52;c;aGk=\x07";

/// Time moves only through `advance`; the timer wakes on `notify_timer`.
struct FakeClock {
    now: Mutex<Instant>,
}

impl FakeClock {
    fn advance(&self, by: Duration) {
        *self.now.lock().unwrap() += by;
    }
}

impl ClipboardClock for FakeClock {
    fn now(&self) -> Instant {
        *self.now.lock().unwrap()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, ClipboardReadState>,
        _timeout: Duration,
    ) -> MutexGuard<'a, ClipboardReadState> {
        changed.wait(state).unwrap()
    }
}

/// The PTY: one message per parser flush.
struct ChannelWriter(Sender<Vec<u8>>);

impl Write for ChannelWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let _ = self.0.send(bytes.to_vec());
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A host with the production parser worker, a fake clock and a captured PTY.
struct Harness {
    host: Arc<HostShared>,
    clock: Arc<FakeClock>,
    pty: Receiver<Vec<u8>>,
    cursor: u64,
}

impl Harness {
    fn new() -> Self {
        let clock = Arc::new(FakeClock { now: Mutex::new(Instant::now()) });
        let clipboard = ClipboardReads::new(clock.clone());
        let pending = Arc::new(Mutex::new(Vec::new()));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_clipboard_read: Some(clipboard.callback()),
            ..Callbacks::default()
        };
        let term = Terminal::new(80, 24, 0, callbacks).unwrap();
        let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
        let host = test_host_shared_with(term, parser_commands, clipboard);
        host.clipboard.start_timer(host.parser_commands.clone()).unwrap();
        let (pty_sender, pty) = mpsc_channel();
        *host.writer.lock().unwrap() = Box::new(ChannelWriter(pty_sender));
        let initial_colors = host.term.lock().unwrap().color_overrides();
        let parser_host = host.clone();
        let signals = ParserSignals {
            pending_responses: pending,
            title_changed: Arc::new(AtomicBool::new(false)),
            bell: Arc::new(AtomicBool::new(false)),
        };
        thread::spawn(move || run_host_parser(parser_host, receiver, initial_colors, signals));
        Self { host, clock, pty, cursor: 0 }
    }

    fn output(&mut self, bytes: &[u8]) {
        self.cursor += 1;
        self.host
            .parser_commands
            .send(ParserCommand::Output {
                bytes: bytes.to_vec(),
                source_cursor: self.cursor,
                accounted_bytes: 0,
            })
            .unwrap();
    }

    fn pty_reply(&self) -> Vec<u8> {
        self.pty.recv_timeout(Duration::from_secs(2)).expect("the parser flushed a PTY reply")
    }

    fn assert_pty_quiet(&self) {
        if let Ok(bytes) = self.pty.recv_timeout(Duration::from_millis(100)) {
            panic!("unexpected PTY reply {bytes:?}");
        }
    }

    fn connect(&self, role: ClientRole, rights: CapabilityRights) -> UnixStream {
        let token = match role {
            ClientRole::Admin => self.host.owner_token,
            _ => self
                .host
                .capabilities
                .mint(self.host.terminal_id, rights, Duration::from_secs(5))
                .unwrap(),
        };
        let (server_stream, mut client) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let server_host = self.host.clone();
        thread::spawn(move || {
            let _ = serve_client(server_host, server_stream);
        });
        let hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role,
            requested_rights: rights,
            terminal_id: self.host.terminal_id,
            token,
        };
        write_frame(&mut client, &hello.into_frame(1)).unwrap();
        let host_hello = read_required_frame(&mut client, "host hello").unwrap();
        assert_eq!(host_hello.kind, MessageKind::HostHello);
        assert_eq!(HostHello::decode(&host_hello.payload).unwrap().granted_rights, rights);
        assert_eq!(read_required_frame(&mut client, "snapshot").unwrap().kind, MessageKind::Snapshot);
        assert_eq!(read_required_frame(&mut client, "colors").unwrap().kind, MessageKind::Colors);
        client
    }

    fn owner(&self) -> UnixStream {
        self.connect(ClientRole::Admin, CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ)
    }

    fn renderer(&self) -> UnixStream {
        self.connect(ClientRole::Renderer, CapabilityRights::RENDERER)
    }
}

/// The next clipboard read sent to `client`, skipping live frames.
fn next_clipboard_request(client: &mut UnixStream) -> ClipboardReadRequest {
    loop {
        let frame = read_required_frame(client, "clipboard read request").unwrap();
        if frame.kind != MessageKind::ClipboardReadRequest {
            continue;
        }
        assert_eq!((frame.request_id, frame.sequence, frame.flags), (0, 0, 0));
        return decode_clipboard_read_request(&frame.payload).unwrap();
    }
}

/// Reads live frames up to the Output carrying `marker`; no clipboard read
/// may arrive before it.
fn read_until_output(client: &mut UnixStream, marker: &[u8]) {
    loop {
        let frame = read_required_frame(client, "marker output").unwrap();
        assert_ne!(frame.kind, MessageKind::ClipboardReadRequest, "unexpected clipboard read");
        if frame.kind == MessageKind::Output
            && frame.payload.windows(marker.len()).any(|window| window == marker)
        {
            return;
        }
    }
}

fn reply(client: &mut UnixStream, token: u64, text: Option<&[u8]>) {
    let frame = Frame::new(MessageKind::ClipboardReadReply, encode_clipboard_read_reply(token, text));
    write_frame(client, &frame).unwrap();
}

fn assert_disconnected(client: &mut UnixStream) {
    loop {
        match read_frame(client, MAX_FRAME_PAYLOAD) {
            Ok(Some(_)) => continue,
            Ok(None) => return,
            Err(crate::terminal_host_protocol::ProtocolError::Io(error)) => {
                assert!(
                    !matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ),
                    "the host kept the connection open"
                );
                return;
            }
            Err(error) => panic!("unexpected frame error {error:?}"),
        }
    }
}

#[test]
fn owner_read_reaches_only_the_owner_and_a_granted_reply_reaches_the_pty() {
    let mut h = Harness::new();
    let mut renderer = h.renderer();
    let mut owner = h.owner();
    h.output(OSC52_READ);
    let request = next_clipboard_request(&mut owner);
    assert_ne!(request.token, 0);
    assert_eq!(request.location, ClipboardLocation::Standard);
    h.assert_pty_quiet();
    h.output(b"marker-one");
    read_until_output(&mut renderer, b"marker-one");

    reply(&mut owner, request.token, Some(b"hi"));
    assert_eq!(h.pty_reply(), GRANTED_HI);
    // A token completes once; a repeated or unknown reply is ignored.
    reply(&mut owner, request.token, Some(b"again"));
    reply(&mut owner, request.token.wrapping_add(1), Some(b"other"));
    h.assert_pty_quiet();
}

#[test]
fn refused_and_oversized_replies_answer_an_empty_clipboard() {
    let mut h = Harness::new();
    let mut owner = h.owner();
    h.output(OSC52_READ);
    let request = next_clipboard_request(&mut owner);
    reply(&mut owner, request.token, None);
    assert_eq!(h.pty_reply(), REFUSED);

    h.output(OSC52_READ);
    let request = next_clipboard_request(&mut owner);
    let oversized = vec![b'x'; ghostty_vt::MAX_CLIPBOARD_READ_BYTES + 1];
    let mut payload = request.token.to_le_bytes().to_vec();
    payload.push(1);
    payload.extend_from_slice(&(oversized.len() as u32).to_le_bytes());
    payload.extend_from_slice(&oversized);
    write_frame(&mut owner, &Frame::new(MessageKind::ClipboardReadReply, payload)).unwrap();
    assert_eq!(h.pty_reply(), REFUSED);
}

#[test]
fn a_second_read_while_one_is_open_is_refused_at_once() {
    let mut h = Harness::new();
    let mut owner = h.owner();
    let both = [OSC52_READ, OSC52_READ].concat();
    h.output(&both);
    let request = next_clipboard_request(&mut owner);
    assert_eq!(h.pty_reply(), REFUSED, "the second read is refused without asking");
    h.output(b"marker-two");
    read_until_output(&mut owner, b"marker-two");

    reply(&mut owner, request.token, Some(b"hi"));
    assert_eq!(h.pty_reply(), GRANTED_HI);
}

#[test]
fn an_open_read_is_refused_after_sixty_seconds_on_the_injected_clock() {
    let mut h = Harness::new();
    let mut owner = h.owner();
    h.output(OSC52_READ);
    let request = next_clipboard_request(&mut owner);

    h.clock.advance(Duration::from_secs(59));
    h.host.clipboard.notify_timer();
    h.assert_pty_quiet();
    h.clock.advance(Duration::from_secs(2));
    h.host.clipboard.notify_timer();
    assert_eq!(h.pty_reply(), REFUSED);

    // The late answer is stale; the slot is free for the next read.
    reply(&mut owner, request.token, Some(b"hi"));
    h.assert_pty_quiet();
    h.output(OSC52_READ);
    let next = next_clipboard_request(&mut owner);
    assert_ne!(next.token, request.token);
}

#[test]
fn owner_disconnect_refuses_the_open_read_and_stops_deferral() {
    let mut h = Harness::new();
    let mut renderer = h.renderer();
    let owner = h.owner();
    let mut owner_reader = owner.try_clone().unwrap();
    h.output(OSC52_READ);
    next_clipboard_request(&mut owner_reader);

    owner.shutdown(std::net::Shutdown::Both).unwrap();
    assert_eq!(h.pty_reply(), REFUSED);

    // Without an owner, reads are ignored again: no request, no reply.
    h.output(OSC52_READ);
    h.output(b"marker-three");
    read_until_output(&mut renderer, b"marker-three");
    h.assert_pty_quiet();
}

#[test]
fn terminal_drain_refuses_the_open_read() {
    let mut h = Harness::new();
    let mut owner = h.owner();
    h.output(OSC52_READ);
    let request = next_clipboard_request(&mut owner);
    h.host.parser_commands.send(ParserCommand::Drain).unwrap();
    assert_eq!(h.pty_reply(), REFUSED);
    reply(&mut owner, request.token, Some(b"hi"));
    h.assert_pty_quiet();
}

/// An older daemon asks for plain ADMIN: the host keeps deferral off and
/// reads are ignored, as before the broker.
#[test]
fn a_plain_admin_owner_leaves_clipboard_reads_ignored() {
    let mut h = Harness::new();
    let mut owner = h.connect(ClientRole::Admin, CapabilityRights::ADMIN);
    h.output(OSC52_READ);
    h.output(b"marker-four");
    read_until_output(&mut owner, b"marker-four");
    h.assert_pty_quiet();
}

#[test]
fn a_clipboard_reply_without_the_right_closes_the_connection() {
    let h = Harness::new();
    for mut client in [h.renderer(), h.connect(ClientRole::Admin, CapabilityRights::ADMIN)] {
        reply(&mut client, 1, Some(b"hi"));
        assert_disconnected(&mut client);
    }
}

#[test]
fn owner_token_grants_clipboard_reads_only_with_full_admin() {
    let host = test_host_shared();
    let hello = |role, requested_rights| ClientHello {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        role,
        requested_rights,
        terminal_id: host.terminal_id,
        token: host.owner_token,
    };
    let clipboard = CapabilityRights::CLIPBOARD_READ;
    let full = CapabilityRights::ADMIN | clipboard;
    assert_eq!(authenticate_client(&host, &hello(ClientRole::Admin, full)).unwrap().granted_rights, full);
    let admin = CapabilityRights::ADMIN;
    assert_eq!(authenticate_client(&host, &hello(ClientRole::Admin, admin)).unwrap().granted_rights, admin);
    for (role, rights) in [
        (ClientRole::Admin, clipboard),
        (ClientRole::Admin, CapabilityRights::READ | clipboard),
        (ClientRole::Renderer, full),
    ] {
        assert!(authenticate_client(&host, &hello(role, rights)).is_err(), "{role:?} {rights:?}");
    }
}

#[test]
fn clipboard_record_field_round_trips_defaults_false_and_needs_v4() {
    let (record_path, mut record, lease) = record_fixture("clipboard-read");
    record.supports_clipboard_read = true;
    let json = serde_json::to_value(&record).unwrap();
    assert_eq!(serde_json::from_value::<TerminalHostRecord>(json.clone()).unwrap(), record);
    assert!(format!("{record:?}").contains("supports_clipboard_read: true"));
    validate_terminal_host_record(&record_path, &record).unwrap();

    let mut legacy_json = json;
    legacy_json.as_object_mut().unwrap().remove("supports_clipboard_read");
    let legacy = serde_json::from_value::<TerminalHostRecord>(legacy_json).unwrap();
    assert!(!legacy.supports_clipboard_read);

    let mut v3 = record.clone();
    v3.record_version = 3;
    v3.supports_input_ack = false;
    v3.supports_terminal_metadata = false;
    assert!(validate_terminal_host_record(&record_path, &v3).is_err());
    v3.supports_clipboard_read = false;
    validate_terminal_host_record(&record_path, &v3).unwrap();

    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

/// A host on the other end of `stream` that answers one owner handshake with
/// `grant(requested)` and returns the requested rights.
fn fake_owner_host(
    mut stream: UnixStream,
    record: TerminalHostRecord,
    grant: fn(CapabilityRights) -> CapabilityRights,
) -> anyhow::Result<CapabilityRights> {
    stream.set_read_timeout(Some(Duration::from_secs(1)))?;
    let hello_frame = read_required_frame(&mut stream, "owner hello")?;
    let version = hello_frame.version;
    let hello = ClientHello::decode(&hello_frame.payload)?;
    let response = HostHello {
        selected_version: version,
        granted_rights: grant(hello.requested_rights),
        terminal_id: hello.terminal_id,
        incarnation: HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?),
    };
    let mut host_hello = Frame::new(MessageKind::HostHello, response.encode());
    host_hello.version = version;
    host_hello.request_id = hello_frame.request_id;
    host_hello.flags = hello_frame.flags & (FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS);
    write_frame(&mut stream, &host_hello)?;
    let snapshot = HostSnapshot {
        cols: 80,
        rows: 24,
        cell_pixels: DEFAULT_CELL_PIXELS,
        replay: Vec::new(),
        kitty_image_aliases: Vec::new(),
        kitty_state: test_kitty_state(),
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid: None,
        command: vec!["/bin/sh".into()],
        cwd: None,
        osc_progress: String::new(),
    };
    let mut frames = vec![
        Frame::new(MessageKind::Snapshot, encode_snapshot_for_version(&snapshot, version, false)?),
        Frame::new(
            MessageKind::Colors,
            encode_terminal_color_overrides(&TerminalColorOverrides::default()),
        ),
    ];
    if hello_frame.flags & FLAG_SMART_RENDERER != 0 {
        frames.push(Frame::new(MessageKind::Ready, Vec::new()));
    }
    for mut frame in frames {
        frame.version = version;
        frame.sequence = 5;
        write_frame(&mut stream, &frame)?;
    }
    let release = read_required_frame(&mut stream, "viewer release")?;
    anyhow::ensure!(release.kind == MessageKind::ReleaseViewer);
    Ok(hello.requested_rights)
}

fn connect_to_fake_host(
    supports_clipboard_read: bool,
    protocol_version: u16,
    grant: fn(CapabilityRights) -> CapabilityRights,
) -> (anyhow::Result<HostAttachment>, anyhow::Result<CapabilityRights>) {
    let (record_path, mut record, lease) = record_fixture("clipboard-connect");
    record.supports_clipboard_read = supports_clipboard_read;
    let (daemon, host) = UnixStream::pair().unwrap();
    let host_record = record.clone();
    let host = thread::spawn(move || fake_owner_host(host, host_record, grant));
    let attachment = connect_record_at_version(
        record,
        record_path.clone(),
        Duration::from_secs(1),
        protocol_version,
        true,
        daemon,
    );
    let requested = host.join().unwrap();
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
    (attachment, requested)
}

#[test]
fn daemon_requests_clipboard_reads_only_from_an_advertising_current_host() {
    let full = CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ;
    for (supports, version, expected) in [
        (false, PROTOCOL_VERSION, CapabilityRights::ADMIN),
        (true, PROTOCOL_VERSION, full),
        (true, SMART_RENDERER_PROTOCOL_VERSION, CapabilityRights::ADMIN),
    ] {
        let (attachment, requested) = connect_to_fake_host(supports, version, |rights| rights);
        let attachment = attachment.expect("the owner handshake passes");
        assert_eq!(requested.unwrap(), expected, "record {supports}, protocol {version}");
        assert_eq!(attachment.clipboard_reads_negotiated(), expected == full);
    }
}

#[test]
fn daemon_requires_the_granted_rights_to_equal_its_request() {
    let (attachment, _) = connect_to_fake_host(true, PROTOCOL_VERSION, |_| CapabilityRights::ADMIN);
    assert!(attachment.is_err(), "a host that drops the clipboard right is rejected");
    let (attachment, _) = connect_to_fake_host(false, PROTOCOL_VERSION, |rights| {
        rights | CapabilityRights::CLIPBOARD_READ
    });
    assert!(attachment.is_err(), "a host that adds an unrequested right is rejected");
}
