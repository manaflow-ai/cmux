//! The input port's inline write (#35413 A/B, s17fa on build 5cd1899b): with the input lane on, the daemon part of a
//! key was +0.025 / +0.17 / +0.53 ms at p50 / p95 / p99 over the lane off, all of it between the key's handoff and
//! the host's PTY write: the request thread put the key on the port and the port's own writer thread woke to write
//! it. A key to an idle port is now written on the request's own turn. When anything is in the way (another writer
//! holds the connection, the host socket is full, a frame is ahead of the key), the key goes to the port as before,
//! so it never waits for another writer or for a host that stopped reading, and the order holds.

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
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-key");
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

/// #35413 s17ga A/B (STATUS 13254): with the lane on, a key's write call (daemon.send.write -> daemon.send.written)
/// took 0.019-0.020 ms at p50 on cmux21, against 0.005 ms for the old path's write, and the daemon part's p50 was
/// worse with ON beyond the OFF rounds' spread. The inline write's room check was a poll(), which on XNU opens a
/// kernel event queue, registers a knote on the socket and frees both on every call (sys_generic.c poll_nocancel),
/// under the socket's lock each time. A connection's keys share one queue for their room checks.
#[cfg(target_vendor = "apple")]
#[test]
fn a_connections_keys_share_one_kernel_queue_for_their_room_check() {
    use crate::terminal_host_runtime::room_check_queues;
    const KEYS: usize = 100;
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-queue", true);
    let pty = surface.as_pty().expect("a terminal");
    // The writer is held: a key that went to the port instead of inline never reaches the host.
    let _resume = pty.input_port.pause_writes_for_test();
    host.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    let before = room_check_queues::count();
    for key in 0..KEYS {
        surface.write_bytes_replying(b"k", InputReply::Accepted).expect("the port took the key");
        // Each key is read before the next one, so the socket has room and the port stays idle.
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
            "key {key} was not written inline ({frame:?})"
        );
    }
    let opened = room_check_queues::count() - before;
    assert!(
        opened <= 1,
        "{KEYS} keys to one connection opened {opened} kernel event queues for their room checks: one per key"
    );
}

/// The inline write builds the frame header on the stack (no copy of the key): it must be the header `encode_frame`
/// writes for the same frame, byte for byte, or the host reads a corrupt stream.
#[test]
fn the_inline_frame_header_is_the_encoders_header() {
    for kind in [MessageKind::Input, MessageKind::Paste] {
        for payload in [&b"k"[..], &[0u8; 1024][..], &b""[..]] {
            let mut frame = Frame::new(kind, payload.to_vec());
            frame.version = 7;
            let encoded = crate::terminal_host_protocol::encode_frame(&frame).unwrap();
            let header = crate::terminal_host_protocol::input_frame_header(
                7,
                kind,
                u32::try_from(payload.len()).unwrap(),
            );
            assert_eq!(
                &encoded[..header.len()],
                &header[..],
                "the header of a {}-byte {kind:?}",
                payload.len()
            );
            assert_eq!(&encoded[header.len()..], payload);
        }
    }
}

/// Another writer holds the connection (a large write of another client): the key does not wait for it. It goes to
/// the port, returns at once, and reaches the host once the other writer is done.
#[test]
fn a_key_while_another_writer_holds_the_connection_goes_to_the_port() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-busy");
    let pty = surface.as_pty().expect("a terminal");
    let writer = connection_writer(pty);
    let held = writer.lock().unwrap();
    // The key goes from another thread: a key that waited for the held writer would otherwise deadlock this test.
    let took = std::thread::scope(|scope| {
        let keyed = scope.spawn(|| {
            let started = Instant::now();
            surface
                .write_bytes_replying(b"k", InputReply::Accepted)
                .expect("the port took the key");
            started.elapsed()
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while !keyed.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(2));
        }
        let returned = keyed.is_finished();
        if returned {
            wait_until("the port's writer took the key", || {
                pty.input_port.queued_frames_for_test() == 0
            });
        }
        drop(held);
        let took = keyed.join().unwrap();
        assert!(returned, "the key waited {took:?} for the writer another client held");
        took
    });
    assert!(
        took < Duration::from_millis(100),
        "the key waited {took:?} for the writer another client held"
    );
    assert_eq!(
        input_frames(&mut host, Duration::from_millis(300)),
        [b"k".to_vec()],
        "the key did not reach the host once"
    );
}

/// A host that stopped reading while the person keeps typing: no key's request waits for it, on any platform. While
/// the host socket has room the keys are written inline; once it has none they go to the port, whose writer then
/// waits on its own thread. When the host reads again, every key arrives once, in order. (#35872: the first version
/// of this test filled the socket with MSG_DONTWAIT sends and hung on macOS, where such a send still waits for room
/// on a stream socket; the inline write's send was the same.)
#[test]
fn keys_to_a_host_that_stopped_reading_never_block_their_requests() {
    const KEYS: usize = 1000;
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-stalled-host");
    let typed: Vec<Vec<u8>> = (0..KEYS).map(|key| format!("{key:04}").into_bytes()).collect();
    std::thread::scope(|scope| {
        let typing = scope.spawn(|| {
            let mut slowest = Duration::ZERO;
            for key in &typed {
                let started = Instant::now();
                surface
                    .write_bytes_replying(key, InputReply::Accepted)
                    .expect("the port took the key");
                slowest = slowest.max(started.elapsed());
            }
            slowest
        });
        // The host reads nothing meanwhile: a key whose request waits for it never returns.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !typing.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let finished = typing.is_finished();
        // The host reads again: what was written, and what a blocked request was writing.
        let read = input_frames(&mut host, Duration::from_secs(1));
        let slowest = typing.join().unwrap();
        assert!(
            finished,
            "a key's request waited for a host that stopped reading: {KEYS} keys did not return in 10 s"
        );
        assert!(
            slowest < Duration::from_secs(2),
            "a key's request took {slowest:?} while the host read nothing"
        );
        assert_eq!(
            read, typed,
            "the keys reached the host in another order, more than once, or not at all"
        );
    });
    // The host read everything: the socket has room again, so once the port is idle the next key goes inline (on
    // macOS this proves that the connection's room-check queue reports room again after the socket was full). With
    // the port's writer held, a key that went to the port instead would miss the read.
    let pty = surface.as_pty().expect("a terminal");
    wait_until("the port is idle", || pty.input_port.idle_for_test());
    let _held = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"next", InputReply::Accepted).expect("the key after the drain");
    assert_eq!(
        input_frames(&mut host, Duration::from_millis(300)),
        [b"next".to_vec()],
        "after the host read everything, the next key did not go inline"
    );
}

/// Order across the two paths: a key written inline, a write the port's writer holds, a key queued behind it, then
/// (once the port is idle again) a key written inline reach the host in that order, once each.
#[test]
fn keys_keep_their_order_between_the_inline_write_and_the_ports_writer() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-order");
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
    wait_until("the port is idle", || pty.input_port.idle_for_test());
    drop(resume);
    // The writer is held again: a "3" that went to the port's writer would wait there and miss the read below.
    let _held_again = pty.input_port.pause_writes_for_test();
    surface.write_bytes_replying(b"3", InputReply::Accepted).expect("the last key");
    assert_eq!(
        input_frames(&mut host, Duration::from_millis(300)),
        [b"1".to_vec(), b"w".to_vec(), b"2".to_vec(), b"3".to_vec()],
        "the keys and the write reached the host in another order, more than once, or \"3\" did not go inline"
    );
}
