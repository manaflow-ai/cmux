//! The input port's inline write (#35413 A/B, s17fa on build 5cd1899b): with the input lane on, the daemon part of a
//! key was +0.025 / +0.17 / +0.53 ms at p50 / p95 / p99 over the lane off, all of it between the key's handoff and
//! the host's PTY write: the request thread put the key on the port and the port's own writer thread woke to write
//! it. A key to an idle port is now written on the request's own turn. When anything is in the way (another writer
//! holds the connection, the host socket is full, a frame is ahead of the key), the key goes to the port as before,
//! so it never waits for another writer or for a host that stopped reading, and the order holds.

use std::os::fd::AsRawFd as _;

use super::hosted::{hosted_typing_surface, wait_until};
use super::*;

/// The `Input` payloads the host reads until it reads nothing for `quiet`.
fn input_frames(host: &mut std::os::unix::net::UnixStream, quiet: Duration) -> Vec<Vec<u8>> {
    host.set_read_timeout(Some(quiet)).unwrap();
    let mut payloads = Vec::new();
    while let Ok(Some(frame)) = crate::terminal_host_protocol::read_frame(
        host,
        crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
    ) {
        if frame.kind == MessageKind::Input {
            payloads.push(frame.payload);
        }
    }
    payloads
}

/// The writer of the terminal's current host connection.
fn connection_writer(pty: &PtySurface) -> Arc<Mutex<crate::terminal_host_runtime::HostStream>> {
    let runtime = pty.runtime.lock().unwrap();
    let PtyRuntime::Hosted(attachment) = &*runtime else {
        panic!("the fixture's terminal is hosted");
    };
    attachment.writer.clone()
}

#[test]
fn a_key_to_an_idle_port_is_on_the_host_socket_when_its_request_returns() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-key", true);
    let pty = surface.as_pty().expect("a terminal");
    // The writer is held before it writes anything: a key it had to write would not reach the socket.
    let _resume = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    host.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    let frame = crate::terminal_host_protocol::read_frame(
        &mut host,
        crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
    )
    .ok()
    .flatten();
    assert!(
        frame
            .as_ref()
            .is_some_and(|frame| frame.kind == MessageKind::Input && frame.payload == b"k"),
        "the key was not on the host socket when its request returned: it waited for the port's writer thread \
         ({frame:?})"
    );
}

/// Another writer holds the connection (a large write of another client): the key does not wait for it. It goes to
/// the port, returns at once, and reaches the host once the other writer is done.
#[test]
fn a_key_while_another_writer_holds_the_connection_goes_to_the_port() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-busy", true);
    let pty = surface.as_pty().expect("a terminal");
    let writer = connection_writer(pty);
    let held = writer.lock().unwrap();
    let started = Instant::now();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    let took = started.elapsed();
    assert!(
        took < Duration::from_millis(100),
        "the key waited {took:?} for the writer another client held"
    );
    wait_until("the port's writer took the key", || pty.input_port.queued_frames_for_test() == 0);
    drop(held);
    assert_eq!(
        input_frames(&mut host, Duration::from_millis(300)),
        [b"k".to_vec()],
        "the key did not reach the host once"
    );
}

/// The host stopped reading and its socket is full: the key does not block in the send. It goes to the port,
/// returns at once, and reaches the host, once, after everything written before it, when the host reads again.
#[test]
fn a_key_to_a_full_host_socket_goes_to_the_port() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-full", true);
    let pty = surface.as_pty().expect("a terminal");
    // Fill the socket with whole frames, as a host that reads nothing would leave it.
    // `Frame::new` writes the current protocol version, the fixture connection's.
    let filler = Frame::new(MessageKind::Input, vec![b'f'; 1000]);
    let filler = crate::terminal_host_protocol::encode_frame(&filler).unwrap();
    let mut filled = 0usize;
    {
        let writer = connection_writer(pty);
        let stream = writer.lock().unwrap();
        loop {
            // SAFETY: the stream's descriptor is open while the guard lives; `filler` is a live buffer.
            let sent = unsafe {
                libc::send(
                    stream.as_raw_fd(),
                    filler.as_ptr().cast(),
                    filler.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            if sent < 0 {
                break;
            }
            assert_eq!(sent as usize, filler.len(), "the socket took part of a filler frame");
            filled += 1;
        }
    }
    assert!(filled > 0, "the host socket took no filler frame");
    let started = Instant::now();
    surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
    let took = started.elapsed();
    assert!(
        took < Duration::from_millis(100),
        "the key waited {took:?} for a host that reads nothing"
    );
    let read = input_frames(&mut host, Duration::from_millis(500));
    assert_eq!(
        read.len(),
        filled + 1,
        "the host read {} frames, not {filled} fillers and the key",
        read.len()
    );
    assert_eq!(
        read.last().map(Vec::as_slice),
        Some(&b"k"[..]),
        "the key came before what was written first"
    );
}

/// Order across the two paths: a key written inline, a write the port's writer holds, a key queued behind it, then
/// (once the port is idle again) a key written inline reach the host in that order, once each.
#[test]
fn keys_keep_their_order_between_the_inline_write_and_the_ports_writer() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-order", true);
    let pty = surface.as_pty().expect("a terminal");
    surface.write_bytes_replying(b"1", InputReply::Accepted).expect("the first key");
    let resume = pty.input_port.pause_writes_for_test();
    std::thread::scope(|scope| {
        // A script's write waits for its frame; the port's writer takes it and holds it at the pause.
        let written = scope.spawn(|| surface.write_bytes(b"w"));
        wait_until("the writer took the write", || {
            pty.input_port.accepted_for_test() == 2 && pty.input_port.queued_frames_for_test() == 0
        });
        surface.write_bytes_replying(b"2", InputReply::Accepted).expect("the key behind the write");
        assert_eq!(
            pty.input_port.queued_frames_for_test(),
            1,
            "the key passed the write the port holds"
        );
        resume.send(()).unwrap();
        resume.send(()).unwrap();
        written.join().unwrap().expect("the script's write");
    });
    wait_until("the port is idle", || pty.input_port.queued_frames_for_test() == 0);
    drop(resume);
    surface.write_bytes_replying(b"3", InputReply::Accepted).expect("the last key");
    assert_eq!(
        input_frames(&mut host, Duration::from_millis(300)),
        [b"1".to_vec(), b"w".to_vec(), b"2".to_vec(), b"3".to_vec()],
        "the keys and the write reached the host in another order or more than once"
    );
}
