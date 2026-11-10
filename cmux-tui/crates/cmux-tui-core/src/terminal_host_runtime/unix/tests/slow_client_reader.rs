//! A client that stops reading its host connection for longer than the
//! host's write time-out: the host's writer gives up, and the client must
//! then see the end of the stream, so that it attaches again from a new
//! snapshot.

use super::*;

/// Less than a tap's output budget (`MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES`),
/// so the queue limit never closes this connection: only the write time-out
/// ends its writer. More than a Unix socket pair buffers on macOS or Linux,
/// so the writer does block.
const QUEUED_OUTPUT_FRAMES: usize = 32;
const QUEUED_OUTPUT_FRAME_BYTES: usize = 64 * 1024;

#[test]
fn write_timeout_ends_the_stream_of_a_client_that_stopped_reading() {
    let host = exited_host_fixture();
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let server_host = host.clone();
    let (served, serve_result) = mpsc_channel();
    thread::spawn(move || {
        let _ = served.send(serve_client(server_host, server_stream));
    });

    write_frame(&mut client_stream, &snapshot_boundary_client_hello(&host, false).unwrap())
        .unwrap();
    for (name, kind) in [
        ("host hello", MessageKind::HostHello),
        ("snapshot", MessageKind::Snapshot),
        ("colors", MessageKind::Colors),
    ] {
        assert_eq!(read_required_frame(&mut client_stream, name).unwrap().kind, kind);
    }

    // The client stops reading here, as a daemon that is stopped or that
    // waits on a lock does, while the terminal prints.
    for _ in 0..QUEUED_OUTPUT_FRAMES {
        host.broadcast(MessageKind::Output, vec![b'x'; QUEUED_OUTPUT_FRAME_BYTES]);
    }
    // The writer returns when its write made no progress for the time-out.
    serve_result
        .recv_timeout(HOST_CLIENT_WRITE_TIMEOUT + Duration::from_secs(10))
        .expect("the host's writer never gave up on a client that does not read")
        .unwrap();

    // The client reads again. It gets the frames the kernel still holds and
    // then the end of the stream: a clean end or a cut frame, never a wait.
    client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let end = loop {
        match read_frame(&mut client_stream, MAX_FRAME_PAYLOAD) {
            Ok(Some(_)) => {}
            end => break end,
        }
    };
    if let Err(crate::terminal_host_protocol::ProtocolError::Io(error)) = &end
        && matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
    {
        panic!(
            "the host's writer gave up on this client and left its connection open: the client \
             waits for frames that never come and never attaches again ({error})"
        );
    }
    assert!(host.taps.lock().unwrap().is_empty());
}
