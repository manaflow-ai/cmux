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
    for payload in [&b"k"[..], &[0u8; 1024][..], &b""[..]] {
        let mut frame = Frame::new(MessageKind::Input, payload.to_vec());
        frame.version = 7;
        let encoded = crate::terminal_host_protocol::encode_frame(&frame).unwrap();
        let header = crate::terminal_host_protocol::input_frame_header(
            7,
            MessageKind::Input,
            u32::try_from(payload.len()).unwrap(),
        );
        assert_eq!(
            &encoded[..header.len()],
            &header[..],
            "the header of a {}-byte key",
            payload.len()
        );
        assert_eq!(&encoded[header.len()..], payload);
    }
}

/// Another writer holds the connection (a large write of another client): the key does not wait for it. It goes to
/// the port, returns at once, and reaches the host once the other writer is done.
#[test]
fn a_key_while_another_writer_holds_the_connection_goes_to_the_port() {
    let (_mux, surface, mut host) = hosted_typing_surface("hosted-input-port-inline-busy", true);
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
    let (_mux, surface, mut host) =
        hosted_typing_surface("hosted-input-port-inline-stalled-host", true);
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

/// Never merge: does a poll() room check cost more in a process with many kernel event registrations, as the
/// daemon has (every tokio socket is a knote)? XNU's kqueue_dealloc walks every fd's knote list of the process under
/// proc_fdlock, and poll() makes and frees a kqueue per call. Measures poll(POLLOUT, 0) and kevent64(IMMEDIATE) on a
/// queue registered once, with 0, 256 and 1024 other sockets registered in another kqueue (as tokio registers them).
/// Fails on purpose so the step log shows the report.
#[cfg(target_vendor = "apple")]
#[test]
fn rds_cost_knote_scaling_bench() {
    use std::os::fd::AsRawFd as _;
    const N: usize = 20_000;
    fn percentiles(mut ns: Vec<u128>) -> String {
        ns.sort_unstable();
        let at = |p: usize| ns.get((ns.len() * p / 100).min(ns.len() - 1)).copied().unwrap_or(0);
        format!(
            "p50 {} p95 {} p99 {} max {} ns",
            at(50),
            at(95),
            at(99),
            ns.last().copied().unwrap_or(0)
        )
    }
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) };
    let want = 4096.min(limit.rlim_max);
    limit.rlim_cur = want;
    unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) };
    let mut report =
        format!("\nrds-cost KNOTE scaling bench (macOS, RLIMIT_NOFILE {want}, ns per call):\n");
    let (a, b) = std::os::unix::net::UnixStream::pair().unwrap();
    let fd = a.as_raw_fd();
    let other_queue = unsafe { libc::kqueue() };
    let mut others: Vec<(std::os::unix::net::UnixStream, std::os::unix::net::UnixStream)> =
        Vec::new();
    for registered in [0usize, 256, 1024] {
        while others.len() < registered {
            let (x, y) = std::os::unix::net::UnixStream::pair().unwrap();
            for sock in [x.as_raw_fd(), y.as_raw_fd()] {
                for filter in [libc::EVFILT_READ, libc::EVFILT_WRITE] {
                    let change = libc::kevent64_s {
                        ident: sock as u64,
                        filter,
                        flags: libc::EV_ADD | libc::EV_CLEAR,
                        fflags: 0,
                        data: 0,
                        udata: 0,
                        ext: [0; 2],
                    };
                    unsafe {
                        libc::kevent64(
                            other_queue,
                            &change,
                            1,
                            std::ptr::null_mut(),
                            0,
                            0,
                            std::ptr::null(),
                        )
                    };
                }
            }
            others.push((x, y));
        }
        let mut ns = Vec::with_capacity(N);
        for _ in 0..N {
            let mut ready = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let started = Instant::now();
            let _ = unsafe { libc::poll(&mut ready, 1, 0) };
            ns.push(started.elapsed().as_nanos());
        }
        report.push_str(&format!(
            "  {} other sockets ({} knotes): poll(POLLOUT, 0): {}\n",
            registered * 2,
            registered * 4,
            percentiles(ns)
        ));
        let kq = unsafe { libc::kqueue() };
        let change = libc::kevent64_s {
            ident: fd as u64,
            filter: libc::EVFILT_WRITE,
            flags: libc::EV_ADD | libc::EV_ENABLE,
            fflags: 0,
            data: 0,
            udata: 0,
            ext: [0; 2],
        };
        let _ =
            unsafe { libc::kevent64(kq, &change, 1, std::ptr::null_mut(), 0, 0, std::ptr::null()) };
        let mut ns = Vec::with_capacity(N);
        for _ in 0..N {
            let mut event = std::mem::MaybeUninit::<libc::kevent64_s>::uninit();
            let started = Instant::now();
            let _ = unsafe {
                libc::kevent64(
                    kq,
                    std::ptr::null(),
                    0,
                    event.as_mut_ptr(),
                    1,
                    libc::KEVENT_FLAG_IMMEDIATE,
                    std::ptr::null(),
                )
            };
            ns.push(started.elapsed().as_nanos());
        }
        report.push_str(&format!(
            "  {} other sockets ({} knotes): kevent64 IMMEDIATE on a queue registered once: {}\n",
            registered * 2,
            registered * 4,
            percentiles(ns)
        ));
        unsafe { libc::close(kq) };
    }
    unsafe { libc::close(other_queue) };
    drop(b);
    panic!("{report}");
}
