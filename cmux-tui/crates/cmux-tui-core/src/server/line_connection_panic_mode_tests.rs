//! An accepted Unix connection in the detector's panic mode, the Debug
//! default (`CMUX_DAEMON_BLOCKING` unset). Its reader (`mux-conn`) and its
//! writer (`mux-line-out`) disallow blocking, so a blocking call on either
//! is a panic that leaves the client with no reply and no close: the test
//! suite's daemon tests then waited for their 120 s timeout.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::*;

/// A mux served on its own socket through the daemon's accept path, so each
/// connection gets the daemon's reader and writer threads.
struct Served {
    mux: Arc<Mux>,
    path: PathBuf,
}

impl Served {
    fn new(label: &str) -> Self {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
        let mux =
            Mux::new_for_test(format!("panic-mode-{label}"), crate::SurfaceOptions::default());
        let path = serve(mux.clone(), None).unwrap();
        Served { mux, path }
    }

    fn connect(&self) -> (UnixStream, BufReader<UnixStream>) {
        let socket = UnixStream::connect(&self.path).unwrap();
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        (socket, BufReader::new(read_half))
    }
}

impl Drop for Served {
    fn drop(&mut self) {
        cleanup(&self.path);
    }
}

fn ping(id: u64) -> Vec<u8> {
    format!("{}\n", json!({"id": id, "cmd": "ping"})).into_bytes()
}

/// The next reply (events skipped); `None` when the daemon closed, an error
/// when it neither answered nor closed within the read timeout.
fn next_reply(replies: &mut BufReader<UnixStream>) -> std::io::Result<Option<Value>> {
    loop {
        let mut line = String::new();
        if replies.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("event").is_none() {
            return Ok(Some(value));
        }
    }
}

/// p02-threads 308 and 309: the accept-time peer identity (a canonicalize of
/// the peer's executable) and the writer's wait for its next item ran on
/// threads that disallow blocking, so every accepted connection panicked
/// both threads before its first reply.
#[test]
fn an_accepted_unix_connection_is_answered_in_panic_mode() {
    let served = Served::new("answer");
    let (mut socket, mut replies) = served.connect();
    socket.write_all(&ping(1)).unwrap();
    let reply = next_reply(&mut replies)
        .expect("the daemon answers or closes within the timeout")
        .expect("the daemon answers before it closes");
    assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(1), json!(true)), "{reply}");
    socket.write_all(&ping(2)).unwrap();
    let second = next_reply(&mut replies).unwrap().expect("a second request is answered too");
    assert_eq!(second["id"], json!(2), "{second}");
}

/// When the client closes, the reader drains the connection's requests and
/// the connection ends: the daemon closes its side and the connection's
/// slot is free again. The reader joined its dispatcher and its writer, a
/// wait for other threads on a thread that disallows blocking, so the
/// teardown panicked and the connection stayed registered and open.
#[test]
fn a_unix_connection_the_client_closes_ends_in_panic_mode() {
    let served = Served::new("close");
    let (mut socket, mut replies) = served.connect();
    socket.write_all(&ping(1)).unwrap();
    assert!(next_reply(&mut replies).unwrap().is_some(), "the daemon answers the request");
    socket.shutdown(Shutdown::Write).unwrap();
    let mut rest = Vec::new();
    replies.read_to_end(&mut rest).expect("the daemon closes the connection");
    let deadline = Instant::now() + Duration::from_secs(10);
    while served.mux.connection_stats().active() != 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(served.mux.connection_stats().active(), 0, "the connection's slot is released");
}

/// A frame lane whose route panics, as a request handler that reaches a
/// blocking call on the reader does in panic mode.
struct PanickingFrames;

impl super::FrameLane for PanickingFrames {
    fn granted(&self, _mux: &Mux, _client: u64) -> bool {
        true
    }

    fn route(
        &mut self,
        _frame: cmux_ipc::Frame,
        _connection: &super::FrameConnection<'_>,
    ) -> Result<bool, super::ConnectionBadMessage> {
        panic!("a handler on the connection's reader panicked");
    }
}

/// A frame header and payload the reader cuts and hands to its lane.
fn request_frame(request_id: u32, payload: &[u8]) -> Vec<u8> {
    let aux = cmux_ipc::Aux::Call(cmux_ipc::CallAux {
        request_id,
        method_id: 0x0101,
        priority: cmux_ipc::PriorityHint::Control,
        flags: cmux_ipc::CallFlags::empty(),
    });
    let header = cmux_ipc::FrameHeader::new(
        cmux_ipc::FrameKind::Request,
        0,
        u32::try_from(payload.len()).unwrap(),
        aux,
    )
    .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

/// A panic on the connection's reader fails that connection, not the
/// daemon: the connection is torn down as on any other end, so the client
/// reads the end of stream at once. The teardown ran only when the reader
/// returned, so a panicking reader left its client registered, its writer
/// waiting and its socket open, and the client waited forever (the suite's
/// 120 s timeouts after each blocking-call panic).
#[test]
fn a_panic_on_the_connections_reader_closes_the_connection() {
    let mux = Mux::new_for_test("panic-mode-reader-unwind", crate::SurfaceOptions::default());
    let (mut socket, server) = UnixStream::pair().unwrap();
    let served = {
        let mux = mux.clone();
        cmux_threads::spawn("panic-mode-reader-test", cmux_threads::ThreadQos::Default, move || {
            let stream: Box<dyn transport::Stream> = Box::new(server);
            let peer = origin_gate::AcceptedPeer::resolve(&mux, &*stream);
            super::serve_connection(
                mux,
                stream,
                peer,
                Arc::new(RenderService::new()),
                None,
                ClientTransport::Unix,
                &admission::LocalAdmission,
                &mut PanickingFrames,
            )
        })
        .unwrap()
    };
    let mut replies = BufReader::new(socket.try_clone().unwrap());
    replies.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    socket.write_all(&ping(1)).unwrap();
    assert!(next_reply(&mut replies).unwrap().is_some(), "the line before the frame is answered");
    socket.write_all(&request_frame(7, b"{}")).unwrap();
    let mut rest = Vec::new();
    replies.read_to_end(&mut rest).expect("the daemon closes the connection after the panic");
    assert!(served.join().is_err(), "the reader's panic still ends its thread as a panic");
    assert!(
        mux.control_clients.client_ids().is_empty(),
        "the panicked connection's client is gone"
    );
}
