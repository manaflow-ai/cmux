//! Client attach streams on one connection (`attach-streams-v1`), their
//! binary frames (`attach-frames-v1`) and their request lanes, over a real
//! socket: plans/cmux-next/app-daemon-connection-DESIGN.md section 3.

use super::*;
use crate::server::attach_frames::{FRAME_HEADER_LEN, FrameHeader, FrameKind};
use std::net::Shutdown;

/// One message the client reads: a JSON line or a frame.
#[derive(Debug)]
enum Wire {
    Line(Value),
    Frame(FrameHeader, Vec<u8>),
}

impl Wire {
    fn frame(&self) -> Option<(&FrameHeader, &[u8])> {
        match self {
            Self::Frame(header, payload) => Some((header, payload)),
            Self::Line(_) => None,
        }
    }

    /// A frame's JSON meta (`meta_len u32 | meta | data`) and its data.
    fn meta(payload: &[u8]) -> (Value, &[u8]) {
        let len = u32::from_le_bytes(payload[..4].try_into().unwrap()) as usize;
        (serde_json::from_slice(&payload[4..4 + len]).unwrap(), &payload[4 + len..])
    }
}

/// Reads the daemon's byte stream as the app does: `0xFF` starts a frame,
/// anything else a JSON line.
struct WireReader {
    stream: Box<dyn transport::Stream>,
    buffer: Vec<u8>,
}

impl WireReader {
    fn new(stream: Box<dyn transport::Stream>) -> Self {
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Self { stream, buffer: Vec::new() }
    }

    fn fill(&mut self, len: usize) {
        let mut chunk = [0_u8; 64 * 1024];
        while self.buffer.len() < len {
            let read = self.stream.read(&mut chunk).expect("the daemon answered in time");
            assert!(read > 0, "the daemon closed the connection");
            self.buffer.extend_from_slice(&chunk[..read]);
        }
    }

    fn next(&mut self) -> Wire {
        self.fill(1);
        if self.buffer[0] == 0xFF {
            self.fill(FRAME_HEADER_LEN);
            let header: [u8; FRAME_HEADER_LEN] =
                self.buffer[..FRAME_HEADER_LEN].try_into().unwrap();
            let header = FrameHeader::decode(&header).expect("a valid frame header");
            let total = FRAME_HEADER_LEN + header.len as usize;
            self.fill(total);
            let payload = self.buffer[FRAME_HEADER_LEN..total].to_vec();
            self.buffer.drain(..total);
            return Wire::Frame(header, payload);
        }
        loop {
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=end).collect();
                return Wire::Line(serde_json::from_slice(&line[..end]).expect("a JSON line"));
            }
            let want = self.buffer.len() + 1;
            self.fill(want);
        }
    }

    /// The reply to request `id`, keeping every other message in `seen`.
    fn reply(&mut self, id: u64, seen: &mut Vec<Wire>) -> Value {
        loop {
            match self.next() {
                Wire::Line(value) if value["id"] == id => return value,
                other => seen.push(other),
            }
        }
    }
}

fn send(client: &mut Box<dyn transport::Stream>, value: Value) {
    writeln!(client, "{value}").unwrap();
    client.flush().unwrap();
}

struct Harness {
    mux: Arc<Mux>,
    client: Box<dyn transport::Stream>,
    reader: WireReader,
    handler: Option<JoinHandle<()>>,
    _socket: TestSocket,
}

impl Harness {
    fn connect(label: &str, capabilities: &[&str]) -> Self {
        let mux = test_mux();
        let socket = TestSocket::new(label);
        let listener = transport::listen(&socket.path).unwrap();
        let mut client = transport::connect(&socket.path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));
        let reader = WireReader::new(client.try_clone_box().unwrap());
        send(
            &mut client,
            json!({"id": 1, "cmd": "set-client-info", "name": "streams-test", "kind": "frontend",
                   "capabilities": capabilities}),
        );
        let mut harness = Self { mux, client, reader, handler: Some(handler), _socket: socket };
        let reply = harness.reader.reply(1, &mut Vec::new());
        assert_eq!(reply["ok"], true, "{reply}");
        harness
    }

    fn attach(&mut self, id: u64, stream: u16, surface: u64, seen: &mut Vec<Wire>) -> Value {
        send(
            &mut self.client,
            json!({"id": id, "cmd": "attach-surface", "attach_stream": stream, "surface": surface,
                   "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version()}),
        );
        self.reader.reply(id, seen)
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = self.client.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
        self.mux.shutdown();
    }
}

const BOTH: &[&str] = &["attach-streams-v1", "attach-frames-v1"];

#[test]
fn two_views_share_one_connection_their_frames_name_their_streams_and_each_ends_with_stream_end() {
    let mut harness = Harness::connect("streams-frames", BOTH);
    let first = harness.mux.new_workspace(None, Some((80, 24))).unwrap();
    let second = harness.mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut seen = Vec::new();
    assert_eq!(harness.attach(2, 7, first.id, &mut seen)["ok"], true);
    assert_eq!(harness.attach(3, 9, second.id, &mut seen)["ok"], true);

    // Each READY arrived before its reply, as a SNAPSHOT frame of its stream,
    // with raw (not base64) data.
    let readies: Vec<_> = seen
        .iter()
        .filter_map(Wire::frame)
        .filter(|(header, _)| header.kind == FrameKind::Snapshot)
        .map(|(header, payload)| (header.stream.get(), header.offset, Wire::meta(payload).0))
        .collect();
    assert_eq!(readies.iter().map(|ready| ready.0).collect::<Vec<_>>(), [7, 9], "{seen:?}");
    assert!(
        readies.iter().all(|ready| ready.2["phase"] == "ready" && ready.2.get("data").is_none())
    );
    let ready_offset = readies[0].1;
    assert!(
        seen.iter().all(|wire| !matches!(wire, Wire::Line(value) if value.get("event").is_some())),
        "no attach event travels as a JSON line on a frames connection: {seen:?}"
    );

    // Output of the first terminal is an OUTPUT frame of stream 7 at the READY's offset.
    first.inject_output_for_test(b"streamed output\r\n");
    let (offset, bytes) = loop {
        if let Wire::Frame(header, payload) = harness.reader.next()
            && header.kind == FrameKind::Output
        {
            assert_eq!(header.stream.get(), 7);
            break (header.offset, payload);
        }
    };
    assert_eq!(offset, ready_offset);
    assert_eq!(bytes, b"streamed output\r\n");

    // A second attach on an open id is refused; the open stream is untouched.
    let mut ignored = Vec::new();
    let refused = harness.attach(4, 9, first.id, &mut ignored);
    assert_eq!(refused["ok"], false);
    assert!(refused["error"].as_str().unwrap().contains("stream_in_use"), "{refused}");

    // cancel-stream ends stream 7: its stream-end is its last item.
    send(&mut harness.client, json!({"id": 5, "cmd": "cancel-stream", "attach_stream": 7}));
    let mut after_cancel = Vec::new();
    let reply = harness.reader.reply(5, &mut after_cancel);
    assert_eq!(reply["data"]["outcome"], "applied", "{reply}");
    let end = loop {
        let wire = after_cancel.pop().map_or_else(|| harness.reader.next(), |wire| wire);
        if let Wire::Frame(header, payload) = wire
            && header.kind == FrameKind::Event
        {
            let event: Value = serde_json::from_slice(&payload).unwrap();
            if event["event"] == "stream-end" {
                break (header.stream.get(), event);
            }
        }
    };
    assert_eq!(end.0, 7);
    assert_eq!(end.1["reason"], "ended");
    // The id is free again.
    assert_eq!(harness.attach(6, 7, first.id, &mut Vec::new())["ok"], true);
    // A cancel of a stream that is not open answers `ended`.
    send(&mut harness.client, json!({"id": 7, "cmd": "cancel-stream", "attach_stream": 4242}));
    assert_eq!(harness.reader.reply(7, &mut Vec::new())["data"]["outcome"], "ended");
}

#[test]
fn a_snapshot_request_for_an_ended_stream_resyncs_no_other_view_of_the_surface() {
    let mut harness = Harness::connect("streams-snapshot", BOTH);
    let surface = harness.mux.new_workspace(None, Some((80, 24))).unwrap();
    assert_eq!(harness.attach(2, 3, surface.id, &mut Vec::new())["ok"], true);
    assert_eq!(harness.attach(3, 4, surface.id, &mut Vec::new())["ok"], true);
    send(&mut harness.client, json!({"id": 4, "cmd": "cancel-stream", "attach_stream": 3}));
    let mut seen = Vec::new();
    assert_eq!(harness.reader.reply(4, &mut seen)["data"]["outcome"], "applied");
    // Stream 3's gap request arrives after its end: refused, and stream 4 keeps
    // its stream (no READY).
    send(
        &mut harness.client,
        json!({"id": 5, "cmd": "snapshot-request", "attach_stream": 3, "surface": surface.id,
               "reason": "gap"}),
    );
    let reply = harness.reader.reply(5, &mut seen);
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply["error"].as_str().unwrap().contains("not_attached"), "{reply}");
    // A plain request on stream 4 is a fence: everything the daemon sent
    // before its reply is in `seen`.
    send(&mut harness.client, json!({"id": 6, "cmd": "identify"}));
    harness.reader.reply(6, &mut seen);
    assert!(
        !seen
            .iter()
            .filter_map(Wire::frame)
            .any(|(header, _)| header.kind == FrameKind::Snapshot && header.stream.get() == 4),
        "the other view of the surface got a READY: {seen:?}"
    );
}

#[test]
fn a_client_with_streams_but_no_frames_gets_json_events_tagged_with_their_stream() {
    let mut harness = Harness::connect("streams-json", &["attach-streams-v1"]);
    let surface = harness.mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut seen = Vec::new();
    assert_eq!(harness.attach(2, 12, surface.id, &mut seen)["ok"], true);
    let ready = seen
        .iter()
        .find_map(|wire| match wire {
            Wire::Line(value) if value["event"] == "snapshot" => Some(value),
            _ => None,
        })
        .expect("a JSON READY");
    assert_eq!(ready["attach_stream"], 12, "{ready}");
    assert!(
        seen.iter().all(|wire| matches!(wire, Wire::Line(_))),
        "no frames without attach-frames-v1"
    );
}

#[test]
fn a_stream_attach_without_the_capability_is_refused() {
    let mut harness = Harness::connect("streams-refused", &[]);
    let surface = harness.mux.new_workspace(None, Some((80, 24))).unwrap();
    let reply = harness.attach(2, 3, surface.id, &mut Vec::new());
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply["error"].as_str().unwrap().contains("attach-streams-v1"), "{reply}");
}

/// Reads the daemon's stream with `recvmsg`, as the app does on a local
/// socket: descriptors that ride on a frame are kept in arrival order.
#[cfg(unix)]
struct DescriptorReader {
    socket: std::os::unix::net::UnixStream,
    buffer: Vec<u8>,
    descriptors: VecDeque<std::os::fd::OwnedFd>,
}

#[cfg(unix)]
impl DescriptorReader {
    fn fill(&mut self, len: usize) {
        use std::os::fd::{AsRawFd as _, FromRawFd as _};
        while self.buffer.len() < len {
            let mut chunk = [0_u8; 64 * 1024];
            let mut iov = libc::iovec { iov_base: chunk.as_mut_ptr().cast(), iov_len: chunk.len() };
            let mut control = [0_u8; 256];
            // SAFETY: a zeroed msghdr is a valid empty header.
            let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = control.len() as _;
            // SAFETY: msg points at live buffers.
            let read = unsafe { libc::recvmsg(self.socket.as_raw_fd(), &mut msg, 0) };
            assert!(read > 0, "the daemon answered in time: {}", std::io::Error::last_os_error());
            // SAFETY: walks the control messages recvmsg filled in.
            unsafe {
                let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
                while !cmsg.is_null() {
                    if (*cmsg).cmsg_level == libc::SOL_SOCKET
                        && (*cmsg).cmsg_type == libc::SCM_RIGHTS
                    {
                        let fd = std::ptr::read_unaligned(libc::CMSG_DATA(cmsg).cast::<i32>());
                        self.descriptors.push_back(std::os::fd::OwnedFd::from_raw_fd(fd));
                    }
                    cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
                }
            }
            self.buffer.extend_from_slice(&chunk[..read as usize]);
        }
    }

    fn next(&mut self) -> Wire {
        self.fill(1);
        if self.buffer[0] == 0xFF {
            self.fill(FRAME_HEADER_LEN);
            let header: [u8; FRAME_HEADER_LEN] =
                self.buffer[..FRAME_HEADER_LEN].try_into().unwrap();
            let header = FrameHeader::decode(&header).expect("a valid frame header");
            let total = FRAME_HEADER_LEN + header.len as usize;
            self.fill(total);
            let payload = self.buffer[FRAME_HEADER_LEN..total].to_vec();
            self.buffer.drain(..total);
            return Wire::Frame(header, payload);
        }
        loop {
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=end).collect();
                return Wire::Line(serde_json::from_slice(&line[..end]).expect("a JSON line"));
            }
            let want = self.buffer.len() + 1;
            self.fill(want);
        }
    }
}

#[cfg(unix)]
#[test]
fn a_local_ring_stream_reads_its_output_from_shared_memory_and_gets_only_ring_advances() {
    use crate::surface::output_ring::OutputRingReader;
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let socket = TestSocket::new("streams-ring");
    let listener = transport::listen(&socket.path).unwrap();
    let client = std::os::unix::net::UnixStream::connect(&socket.path).unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));
    let mut writer = client.try_clone().unwrap();
    let mut reader =
        DescriptorReader { socket: client, buffer: Vec::new(), descriptors: Default::default() };
    let mut send = |value: Value| {
        writeln!(writer, "{value}").unwrap();
        writer.flush().unwrap();
    };
    send(json!({"id": 1, "cmd": "set-client-info", "name": "ring-test", "kind": "frontend",
                "capabilities": ["attach-streams-v1", "attach-frames-v1", "terminal-output-ring-v1"]}));
    send(json!({"id": 2, "cmd": "attach-surface", "attach_stream": 5, "surface": surface.id,
                "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version()}));
    let mut ring = None;
    let mut ready_offset = None;
    loop {
        match reader.next() {
            Wire::Frame(header, payload) if header.kind == FrameKind::Ring => {
                assert_eq!(header.stream.get(), 5);
                let meta: Value = serde_json::from_slice(&payload).unwrap();
                assert_eq!(meta["layout"], 1);
                let descriptor =
                    reader.descriptors.pop_front().expect("the ring rides on its frame");
                ring = Some(OutputRingReader::map(&descriptor).unwrap());
            }
            Wire::Frame(header, _) if header.kind == FrameKind::Snapshot => {
                assert!(ring.is_some(), "the ring comes before the READY it continues");
                ready_offset = Some(header.offset);
            }
            Wire::Line(value) if value["id"] == 2 => {
                assert_eq!(value["ok"], true, "{value}");
                break;
            }
            _ => {}
        }
    }
    let ring = ring.expect("a RING frame");
    let start = ready_offset.expect("a READY");
    surface.inject_output_for_test(b"bytes in shared memory\r\n");
    let end = loop {
        match reader.next() {
            Wire::Frame(header, _) if header.kind == FrameKind::RingAdvance => break header.offset,
            Wire::Frame(header, _) => {
                assert_ne!(header.kind, FrameKind::Output, "a ring stream gets no output bytes")
            }
            _ => {}
        }
    };
    let (head, tail) = ring.slices(start, end).expect("the bytes are in the ring");
    assert_eq!([head, tail].concat(), b"bytes in shared memory\r\n");
    assert!(ring.unlapped(start));
    let _ = reader.socket.shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.shutdown();
}
