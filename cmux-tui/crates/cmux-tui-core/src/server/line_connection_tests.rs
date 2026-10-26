//! The dual reader over a real socket pair: JSON lines get the replies they
//! got from `read_line`, frames pass only after the grant, and a frame or a
//! descriptor the connection may not take closes it with `bad_message`.

use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_ipc::{Aux, BadMessage, CallAux, CallFlags, FrameHeader, FrameKind, PriorityHint};
use serde_json::{Value, json};

use super::{ConnectionBadMessage, ConnectionEnd, FrameLane, UnroutedFrames, serve_connection};
use crate::server::*;

type Seen = Arc<Mutex<Vec<(FrameKind, u32, Vec<u8>)>>>;

/// A lane whose grant the test flips and that records every frame.
struct RecordingFrames {
    grant: Arc<AtomicBool>,
    seen: Seen,
}

impl FrameLane for RecordingFrames {
    fn granted(&self, _mux: &Mux, _client: u64) -> bool {
        self.grant.load(Ordering::SeqCst)
    }

    fn route(&mut self, frame: cmux_ipc::Frame) -> Result<(), ConnectionBadMessage> {
        let request = frame.header().call().map_or(0, |call| call.request_id);
        self.seen.lock().unwrap().push((frame.header().kind(), request, frame.payload().to_vec()));
        Ok(())
    }
}

struct Peer {
    socket: UnixStream,
    replies: BufReader<UnixStream>,
    served: JoinHandle<ConnectionEnd>,
}

fn connect(label: &str, lane: Option<RecordingFrames>) -> Peer {
    let mux = Mux::new_for_test(format!("line-conn-{label}"), crate::SurfaceOptions::default());
    let (socket, server) = UnixStream::pair().unwrap();
    let served = std::thread::spawn(move || {
        let stream: Box<dyn transport::Stream> = Box::new(server);
        let render = Arc::new(RenderService::new());
        let admission = admission::LocalAdmission;
        match lane {
            Some(mut lane) => serve_connection(
                mux,
                stream,
                render,
                None,
                ClientTransport::Unix,
                &admission,
                &mut lane,
            ),
            None => serve_connection(
                mux,
                stream,
                render,
                None,
                ClientTransport::Unix,
                &admission,
                &mut UnroutedFrames,
            ),
        }
    });
    let read_half = socket.try_clone().unwrap();
    read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Peer { socket, replies: BufReader::new(read_half), served }
}

impl Peer {
    fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    /// The next reply (events skipped); `None` once the daemon closed.
    fn reply(&mut self) -> Option<Value> {
        loop {
            let mut line = String::new();
            if self.replies.read_line(&mut line).unwrap() == 0 {
                return None;
            }
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() {
                return Some(value);
            }
        }
    }

    fn finish(self) -> ConnectionEnd {
        let _ = self.socket.shutdown(Shutdown::Write);
        self.served.join().unwrap()
    }
}

fn ping(id: u64) -> Vec<u8> {
    format!("{}\n", json!({"id": id, "cmd": "ping"})).into_bytes()
}

fn request_frame(request_id: u32, payload: &[u8]) -> Vec<u8> {
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: 0x0101,
        priority: PriorityHint::Control,
        flags: CallFlags::empty(),
    });
    let header =
        FrameHeader::new(FrameKind::Request, 0, u32::try_from(payload.len()).unwrap(), aux)
            .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

fn recording(granted: bool) -> (RecordingFrames, Arc<AtomicBool>, Seen) {
    let grant = Arc::new(AtomicBool::new(granted));
    let seen = Seen::default();
    (RecordingFrames { grant: grant.clone(), seen: seen.clone() }, grant, seen)
}

#[test]
fn line_connection_lines_get_the_replies_read_line_gave() {
    let mut peer = connect("lines", None);
    peer.send(&ping(1));
    let reply = peer.reply().unwrap();
    assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(1), json!(true)), "{reply}");
    // Whitespace-only lines are skipped, as before.
    peer.send(b"  \n\n");
    // The line reaches dispatch with its `\n`: serde places the end on line 2.
    peer.send(b"{\"id\":2,\"cmd\":\"ping\"\n");
    let refused = peer.reply().unwrap();
    let error = refused.to_string();
    assert!(error.contains("bad request") && error.contains("line 2 column 0"), "{refused}");
    peer.send(&ping(3));
    assert_eq!(peer.reply().unwrap()["id"], json!(3));
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn line_connection_an_unterminated_last_line_is_dispatched_at_eof() {
    let mut peer = connect("eof", None);
    peer.send(b"{\"id\":4,\"cmd\":\"ping\"}");
    peer.socket.shutdown(Shutdown::Write).unwrap();
    assert_eq!(peer.reply().unwrap()["id"], json!(4));
    assert_eq!(peer.served.join().unwrap(), ConnectionEnd::PeerClosed);
}

#[test]
fn line_connection_a_frame_before_negotiation_closes_with_bad_message() {
    let mut peer = connect("ungranted", None);
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    let mut bytes = request_frame(7, b"{}");
    bytes.extend(ping(2));
    peer.send(&bytes);
    assert_eq!(peer.reply(), None, "nothing after the frame is read");
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
}

#[test]
fn line_connection_a_lane_without_the_grant_sees_no_frame() {
    let (lane, _grant, seen) = recording(false);
    let mut peer = connect("refused-lane", Some(lane));
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    peer.send(&request_frame(7, b"{}"));
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn line_connection_interleaved_lines_and_frames_keep_their_order() {
    let (lane, _grant, seen) = recording(true);
    let mut peer = connect("interleaved", Some(lane));
    let mut bytes = ping(1);
    bytes.extend(request_frame(10, b"{\"a\":1}"));
    bytes.extend(ping(2));
    bytes.extend(request_frame(11, b""));
    bytes.extend(request_frame(12, &[0xFF; 40]));
    bytes.extend(ping(3));
    // One byte per write: every message boundary falls inside a read.
    for byte in &bytes {
        peer.send(std::slice::from_ref(byte));
    }
    for id in 1..=3 {
        assert_eq!(peer.reply().unwrap()["id"], json!(id));
    }
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
    assert_eq!(
        *seen.lock().unwrap(),
        vec![
            (FrameKind::Request, 10, b"{\"a\":1}".to_vec()),
            (FrameKind::Request, 11, Vec::new()),
            (FrameKind::Request, 12, vec![0xFF; 40]),
        ]
    );
}

#[test]
fn line_connection_frames_follow_a_grant_given_after_the_first_lines() {
    let (lane, grant, seen) = recording(false);
    let mut peer = connect("late-grant", Some(lane));
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    grant.store(true, Ordering::SeqCst);
    let mut bytes = request_frame(20, b"x");
    bytes.extend(ping(2));
    peer.send(&bytes);
    assert_eq!(peer.reply().unwrap()["id"], json!(2));
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
    assert_eq!(*seen.lock().unwrap(), vec![(FrameKind::Request, 20, b"x".to_vec())]);
}

#[test]
fn line_connection_a_descriptor_closes_with_bad_message() {
    let mut peer = connect("descriptor", None);
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    let passed = std::fs::File::open("/dev/null").unwrap();
    cmux_ipc::fds::send_all(peer.socket.as_raw_fd(), &ping(2), &[passed.as_raw_fd()]).unwrap();
    assert_eq!(peer.reply(), None, "the line that brought a descriptor is not served");
    assert_eq!(peer.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::UnexpectedFds));
}

#[test]
fn line_connection_an_oversized_line_still_closes() {
    let mut peer = connect("oversized", None);
    let mut line = vec![b' '; MAX_JSON_LINE_BYTES + 1];
    line.push(b'\n');
    // The daemon closes before the last bytes; their write may fail.
    let _ = peer.socket.write_all(&line);
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::LineTooLong {
            max: MAX_JSON_LINE_BYTES
        }))
    );
}
