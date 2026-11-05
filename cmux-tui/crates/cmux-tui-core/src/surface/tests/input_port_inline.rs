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

/// Never merge: the knote bench at the shape read from the live app daemon under the L6 typing load (cmux21, build
/// e8291edc, lskq and proc_pidinfo; s17hb-1-off at 02:44Z, s17hp-head-1 at 03:20Z): 264-266 knotes, 13-14 of them on
/// fds (highest fd 67-79) and 250-253 hashed (234-237 EVFILT_PROC, one per host child); 1052 open fds (768 sockets),
/// highest fd 1095. Not thousands: the host connections are blocking threads, not runtime sockets. Every poll() runs
/// kqueue_dealloc, which walks the process's fd knote lists and all its hashed knotes; between two keys the daemon
/// does other work, so that walk may run on cold cache lines. Measures poll(POLLOUT, 0) (the room check before
/// #35988) and kevent64(IMMEDIATE) on a queue registered once (after it), warm (back to back) and cold (the caches
/// swept by a 96 MB read before each call), with no other knotes, at the daemon's shape, with the fd knote list
/// grown to the highest fd, and with 1000 hashed knotes. Fails on purpose so the step log shows the report.
#[cfg(target_vendor = "apple")]
#[test]
fn rds_cost_knote_daemon_shape_bench() {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixStream;
    use std::process::{Child, Command, Stdio};
    const N: usize = 1_000;
    const SWEEP: usize = 96 << 20;
    struct Children(Vec<Child>);
    impl Drop for Children {
        fn drop(&mut self) {
            for child in &mut self.0 {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
    fn stats(ns: &mut [u128]) -> (String, u128) {
        ns.sort_unstable();
        let at = |p: usize| ns.get((ns.len() * p / 100).min(ns.len() - 1)).copied().unwrap_or(0);
        let line = format!(
            "p50 {} p95 {} p99 {} max {} ns",
            at(50),
            at(95),
            at(99),
            ns.last().copied().unwrap_or(0)
        );
        (line, at(50))
    }
    fn register(kq: i32, ident: u64, filter: i16, flags: u16, fflags: u32) {
        let change =
            libc::kevent64_s { ident, filter, flags, fflags, data: 0, udata: 0, ext: [0; 2] };
        let added =
            unsafe { libc::kevent64(kq, &change, 1, std::ptr::null_mut(), 0, 0, std::ptr::null()) };
        assert_eq!(
            added,
            0,
            "kevent64 EV_ADD filter {filter} ident {ident}: {}",
            std::io::Error::last_os_error()
        );
    }
    /// The process's knotes as lskq lists them: (all, on fds, hashed).
    fn knotes() -> (usize, usize, usize) {
        let Ok(out) =
            Command::new("/usr/bin/lskq").arg("-p").arg(std::process::id().to_string()).output()
        else {
            return (0, 0, 0);
        };
        let on_fds = ["READ", "WRITE", "VNODE", "EXCEPT", "SOCK", "AIO", "NW_CHANNEL"];
        let hashed =
            ["PROC", "SIGNAL", "TIMER", "MACHPORT", "USER", "VM", "MEMSTATUS", "FS", "WORKLOOP"];
        let (mut fd_count, mut hash_count) = (0, 0);
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let words: Vec<&str> = line.split_whitespace().collect();
            if words.iter().any(|word| on_fds.contains(word)) {
                fd_count += 1;
            } else if words.iter().any(|word| hashed.contains(word)) {
                hash_count += 1;
            }
        }
        (fd_count + hash_count, fd_count, hash_count)
    }
    /// The open fds and the highest one.
    fn fds() -> (usize, i32) {
        let (mut open, mut highest) = (0, -1);
        for fd in 0..8192 {
            if unsafe { libc::fcntl(fd, libc::F_GETFD) } != -1 {
                open += 1;
                highest = fd;
            }
        }
        (open, highest)
    }
    fn sweep(buffer: &[u8]) {
        let mut sum = 0u64;
        let mut i = 0;
        while i < buffer.len() {
            sum = sum.wrapping_add(u64::from(buffer[i]));
            i += 64;
        }
        let _ = std::hint::black_box(sum);
    }
    fn poll_once(fd: i32) -> u128 {
        let mut ready = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let started = Instant::now();
        let _ = unsafe { libc::poll(&mut ready, 1, 0) };
        started.elapsed().as_nanos()
    }
    fn kevent_once(kq: i32) -> u128 {
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
        started.elapsed().as_nanos()
    }
    fn measure(label: &str, fd: i32, kq: i32, buffer: &[u8], report: &mut String) {
        let (open, highest) = fds();
        let (all, on_fds, hashed) = knotes();
        let mut warm_poll = Vec::with_capacity(N);
        let mut warm_kevent = Vec::with_capacity(N);
        for _ in 0..N {
            warm_poll.push(poll_once(fd));
            warm_kevent.push(kevent_once(kq));
        }
        let mut cold_poll = Vec::with_capacity(N);
        let mut cold_kevent = Vec::with_capacity(N);
        for _ in 0..N {
            sweep(buffer);
            cold_poll.push(poll_once(fd));
            sweep(buffer);
            cold_kevent.push(kevent_once(kq));
        }
        let (warm_poll_line, _) = stats(&mut warm_poll);
        let (warm_kevent_line, _) = stats(&mut warm_kevent);
        let (cold_poll_line, cold_poll_p50) = stats(&mut cold_poll);
        let (cold_kevent_line, cold_kevent_p50) = stats(&mut cold_kevent);
        report.push_str(&format!(
            "  {label}: {open} open fds (highest {highest}); lskq: {all} knotes, {on_fds} on fds, {hashed} hashed\n    poll(POLLOUT, 0):    warm {warm_poll_line}; cold {cold_poll_line}\n    kevent64(IMMEDIATE): warm {warm_kevent_line}; cold {cold_kevent_line}\n    cold p50, poll - kevent64: {} ns\n",
            cold_poll_p50 as i128 - cold_kevent_p50 as i128
        ));
    }
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) };
    limit.rlim_cur = 4096.min(limit.rlim_max);
    unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) };
    let buffer = vec![1u8; SWEEP];
    let mut report = String::from(
        "\nrds-cost KNOTE bench at the live daemon's shape (macOS; warm = back to back, cold = the caches swept by a 96 MB read before each call; ns per call):\n",
    );
    // The typed host's socket and its room-check queue come first (fd 10 in the daemon).
    let (host, peer) = UnixStream::pair().unwrap();
    let fd = host.as_raw_fd();
    let room = unsafe { libc::kqueue() };
    register(room, fd as u64, libc::EVFILT_WRITE, libc::EV_ADD | libc::EV_ENABLE, 0);
    measure("no other knotes", fd, room, &buffer, &mut report);
    // The daemon's fd knotes, on its first fds: 9 EVFILT_VNODE (watched files) and 4 EVFILT_READ (sockets).
    let dir = std::env::temp_dir().join(format!("rds-knote-bench-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let watched = unsafe { libc::kqueue() };
    let mut files = Vec::new();
    for i in 0..9 {
        let path = dir.join(format!("watched-{i}"));
        std::fs::write(&path, b"x").unwrap();
        let file = std::fs::File::open(&path).unwrap();
        register(
            watched,
            file.as_raw_fd() as u64,
            libc::EVFILT_VNODE,
            libc::EV_ADD | libc::EV_CLEAR,
            libc::NOTE_WRITE | libc::NOTE_DELETE,
        );
        files.push(file);
    }
    let mut sockets = Vec::new();
    for _ in 0..2 {
        let (x, y) = UnixStream::pair().unwrap();
        register(
            watched,
            x.as_raw_fd() as u64,
            libc::EVFILT_READ,
            libc::EV_ADD | libc::EV_CLEAR,
            0,
        );
        register(
            watched,
            y.as_raw_fd() as u64,
            libc::EVFILT_READ,
            libc::EV_ADD | libc::EV_CLEAR,
            0,
        );
        sockets.push((x, y));
    }
    // One EVFILT_PROC knote per host child (234 in s17hp-head-1), and 16 more hashed knotes (EVFILT_USER here, for
    // the daemon's USER, MACHPORT and MEMSTATUS ones).
    let mut children = Children(Vec::new());
    for _ in 0..234 {
        let child = Command::new("/bin/sleep")
            .arg("120")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        register(
            watched,
            u64::from(child.id()),
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_CLEAR,
            libc::NOTE_EXIT,
        );
        children.0.push(child);
    }
    for ident in 1..=16u64 {
        register(watched, ident, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0);
    }
    // The rest of the daemon's fd table: 270 vnodes and 768 sockets, the sockets highest (fd 1089 in the daemon).
    let mut nulls = Vec::new();
    for _ in 0..260 {
        nulls.push(std::fs::File::open("/dev/null").unwrap());
    }
    let mut filler = Vec::new();
    for _ in 0..380 {
        filler.push(UnixStream::pair().unwrap());
    }
    measure("the daemon's shape", fd, room, &buffer, &mut report);
    // A knote once on the highest fd grows the process's fd knote list to cover it, and it never shrinks: as when
    // the load's keys to other terminals were checked on their (high) host sockets.
    let highest = filler.last().map(|(x, y)| x.as_raw_fd().max(y.as_raw_fd())).unwrap();
    let once = unsafe { libc::kqueue() };
    register(once, highest as u64, libc::EVFILT_READ, libc::EV_ADD, 0);
    unsafe { libc::close(once) };
    measure(
        "the daemon's shape, fd knote list grown to its highest fd",
        fd,
        room,
        &buffer,
        &mut report,
    );
    for ident in 1_000..1_750u64 {
        register(watched, ident, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0);
    }
    measure("the same with 1000 hashed knotes", fd, room, &buffer, &mut report);
    drop(children);
    unsafe { libc::close(watched) };
    unsafe { libc::close(room) };
    let _ = std::fs::remove_dir_all(&dir);
    drop((files, sockets, filler, nulls, peer));
    panic!("{report}");
}

/// Never merge: the daemon-shape bench (above) under the daemon's own load. At its knote count, cold, poll() cost
/// 4.75 us more than kevent64 at p50 (step 4a530efa4a2276db2caa564e), a third of the A/B's write-call difference.
/// The live app daemon under the L6 load (cmux21, build e8291edc, proc_pidinfo over 2 s, s17hp-head-2 at 03:41Z) ran
/// 390-560 threads, 365k-388k Unix calls and 142k-149k context switches a second, at about 180% CPU. poll() takes the
/// process's fd lock (to add its knote, and for its whole fd knote walk) and the knote hash lock (for its whole hash
/// walk); every fd call of the process takes the fd lock, and every EVFILT_USER wake (a runtime's waker) the hash
/// lock. kevent64 on a queue registered once takes neither for long. Builds the daemon's shape, then runs socket
/// ping-pong threads (fd calls and context switches) and EVFILT_USER wake threads paced to about the daemon's rates,
/// and measures poll(POLLOUT, 0) and kevent64(IMMEDIATE) warm and cold, idle and under that load, with the process's
/// own call and switch rates over each window. Fails on purpose so the step log shows the report.
#[cfg(target_vendor = "apple")]
#[test]
fn rds_cost_knote_daemon_load_bench() {
    use std::io::{Read as _, Write as _};
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixStream;
    use std::process::{Child, Command, Stdio};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    const N: usize = 1_000;
    const SWEEP: usize = 96 << 20;
    // 16 ping-pong pairs at 3.4k round trips a second each (4 fd calls and 2 switches per round trip) and 8 wakers at
    // 5k EVFILT_USER wakes a second each (2 calls and 1 switch per wake): about 300k calls and 150k switches a second.
    const PAIRS: usize = 16;
    const PAIR_PERIOD: Duration = Duration::from_micros(290);
    const WAKERS: usize = 8;
    const WAKE_PERIOD: Duration = Duration::from_micros(200);
    struct Children(Vec<Child>);
    impl Drop for Children {
        fn drop(&mut self) {
            for child in &mut self.0 {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
    fn stats(ns: &mut [u128]) -> (String, u128) {
        ns.sort_unstable();
        let at = |p: usize| ns.get((ns.len() * p / 100).min(ns.len() - 1)).copied().unwrap_or(0);
        let line = format!(
            "p50 {} p95 {} p99 {} max {} ns",
            at(50),
            at(95),
            at(99),
            ns.last().copied().unwrap_or(0)
        );
        (line, at(50))
    }
    fn register(kq: i32, ident: u64, filter: i16, flags: u16, fflags: u32) {
        let change =
            libc::kevent64_s { ident, filter, flags, fflags, data: 0, udata: 0, ext: [0; 2] };
        let added =
            unsafe { libc::kevent64(kq, &change, 1, std::ptr::null_mut(), 0, 0, std::ptr::null()) };
        assert_eq!(
            added,
            0,
            "kevent64 EV_ADD filter {filter} ident {ident}: {}",
            std::io::Error::last_os_error()
        );
    }
    fn task_info() -> libc::proc_taskinfo {
        let mut info = unsafe { std::mem::zeroed::<libc::proc_taskinfo>() };
        let size = std::mem::size_of::<libc::proc_taskinfo>() as i32;
        let read = unsafe {
            libc::proc_pidinfo(
                std::process::id() as i32,
                libc::PROC_PIDTASKINFO,
                0,
                (&mut info as *mut libc::proc_taskinfo).cast(),
                size,
            )
        };
        assert_eq!(read, size, "proc_pidinfo: {}", std::io::Error::last_os_error());
        info
    }
    fn sweep(buffer: &[u8]) {
        let mut sum = 0u64;
        let mut i = 0;
        while i < buffer.len() {
            sum = sum.wrapping_add(u64::from(buffer[i]));
            i += 64;
        }
        let _ = std::hint::black_box(sum);
    }
    fn poll_once(fd: i32) -> u128 {
        let mut ready = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let started = Instant::now();
        let _ = unsafe { libc::poll(&mut ready, 1, 0) };
        started.elapsed().as_nanos()
    }
    fn kevent_once(kq: i32) -> u128 {
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
        started.elapsed().as_nanos()
    }
    fn measure(label: &str, fd: i32, kq: i32, buffer: &[u8], report: &mut String) {
        let before = task_info();
        let started = Instant::now();
        let mut warm_poll = Vec::with_capacity(N);
        let mut warm_kevent = Vec::with_capacity(N);
        for _ in 0..N {
            warm_poll.push(poll_once(fd));
            warm_kevent.push(kevent_once(kq));
            // Keys are apart: give the load a turn between two checks.
            std::thread::sleep(Duration::from_micros(200));
        }
        let mut cold_poll = Vec::with_capacity(N);
        let mut cold_kevent = Vec::with_capacity(N);
        for _ in 0..N {
            sweep(buffer);
            cold_poll.push(poll_once(fd));
            sweep(buffer);
            cold_kevent.push(kevent_once(kq));
        }
        let after = task_info();
        let seconds = started.elapsed().as_secs_f64();
        let rate = |a: i32, b: i32| f64::from(b.wrapping_sub(a)) / seconds / 1000.0;
        let (warm_poll_line, warm_poll_p50) = stats(&mut warm_poll);
        let (warm_kevent_line, warm_kevent_p50) = stats(&mut warm_kevent);
        let (cold_poll_line, cold_poll_p50) = stats(&mut cold_poll);
        let (cold_kevent_line, cold_kevent_p50) = stats(&mut cold_kevent);
        report.push_str(&format!(
            "  {label}: process {:.0}k Unix calls/s, {:.0}k context switches/s, {} threads (over {seconds:.1} s, \
             the measuring thread's own calls and the cold sweeps included)\n    poll(POLLOUT, 0):    warm \
             {warm_poll_line}; cold {cold_poll_line}\n    kevent64(IMMEDIATE): warm {warm_kevent_line}; cold \
             {cold_kevent_line}\n    p50, poll - kevent64: warm {} ns, cold {} ns\n",
            rate(before.pti_syscalls_unix, after.pti_syscalls_unix),
            rate(before.pti_csw, after.pti_csw),
            after.pti_threadnum,
            warm_poll_p50 as i128 - warm_kevent_p50 as i128,
            cold_poll_p50 as i128 - cold_kevent_p50 as i128,
        ));
    }
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) };
    limit.rlim_cur = 4096.min(limit.rlim_max);
    unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) };
    let buffer = vec![1u8; SWEEP];
    let mut report = String::from(
        "\nrds-cost KNOTE bench at the live daemon's shape, idle and under its load (macOS; warm = 200 us apart, cold \
         = the caches swept by a 96 MB read before each call; ns per call):\n",
    );
    // The daemon's shape, as in rds_cost_knote_daemon_shape_bench: the typed host's socket and its room-check queue,
    // 9 EVFILT_VNODE and 4 EVFILT_READ knotes on low fds, 234 EVFILT_PROC and 16 EVFILT_USER knotes, 1041 fds.
    let (host, peer) = UnixStream::pair().unwrap();
    let fd = host.as_raw_fd();
    let room = unsafe { libc::kqueue() };
    register(room, fd as u64, libc::EVFILT_WRITE, libc::EV_ADD | libc::EV_ENABLE, 0);
    let dir = std::env::temp_dir().join(format!("rds-knote-load-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let watched = unsafe { libc::kqueue() };
    let mut files = Vec::new();
    for i in 0..9 {
        let path = dir.join(format!("watched-{i}"));
        std::fs::write(&path, b"x").unwrap();
        let file = std::fs::File::open(&path).unwrap();
        register(
            watched,
            file.as_raw_fd() as u64,
            libc::EVFILT_VNODE,
            libc::EV_ADD | libc::EV_CLEAR,
            libc::NOTE_WRITE | libc::NOTE_DELETE,
        );
        files.push(file);
    }
    let mut sockets = Vec::new();
    for _ in 0..2 {
        let (x, y) = UnixStream::pair().unwrap();
        for sock in [x.as_raw_fd(), y.as_raw_fd()] {
            register(watched, sock as u64, libc::EVFILT_READ, libc::EV_ADD | libc::EV_CLEAR, 0);
        }
        sockets.push((x, y));
    }
    let mut children = Children(Vec::new());
    for _ in 0..234 {
        let child = Command::new("/bin/sleep")
            .arg("300")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        register(
            watched,
            u64::from(child.id()),
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_CLEAR,
            libc::NOTE_EXIT,
        );
        children.0.push(child);
    }
    for ident in 1..=16u64 {
        register(watched, ident, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0);
    }
    let mut nulls = Vec::new();
    for _ in 0..260 {
        nulls.push(std::fs::File::open("/dev/null").unwrap());
    }
    let mut filler = Vec::new();
    for _ in 0..380 {
        filler.push(UnixStream::pair().unwrap());
    }
    measure("the daemon's shape, idle", fd, room, &buffer, &mut report);
    // The load.
    let stop = Arc::new(AtomicBool::new(false));
    let mut threads = Vec::new();
    for _ in 0..PAIRS {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        let stop_a = Arc::clone(&stop);
        threads.push(std::thread::spawn(move || {
            let mut byte = [0u8; 1];
            let mut next = Instant::now();
            while !stop_a.load(Ordering::Relaxed) {
                if a.write_all(&[1]).is_err() || a.read_exact(&mut byte).is_err() {
                    break;
                }
                next += PAIR_PERIOD;
                if let Some(wait) = next.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
            }
        }));
        threads.push(std::thread::spawn(move || {
            let mut byte = [0u8; 1];
            while b.read_exact(&mut byte).is_ok() {
                if b.write_all(&byte).is_err() {
                    break;
                }
            }
        }));
    }
    let mut wake_queues = Vec::new();
    for _ in 0..WAKERS {
        let kq = unsafe { libc::kqueue() };
        register(kq, 1, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0);
        wake_queues.push(kq);
        let stop_w = Arc::clone(&stop);
        threads.push(std::thread::spawn(move || {
            let mut event = std::mem::MaybeUninit::<libc::kevent64_s>::uninit();
            let timeout = libc::timespec { tv_sec: 0, tv_nsec: 50_000_000 };
            while !stop_w.load(Ordering::Relaxed) {
                unsafe {
                    libc::kevent64(kq, std::ptr::null(), 0, event.as_mut_ptr(), 1, 0, &timeout)
                };
            }
        }));
        let stop_t = Arc::clone(&stop);
        threads.push(std::thread::spawn(move || {
            let trigger = libc::kevent64_s {
                ident: 1,
                filter: libc::EVFILT_USER,
                flags: 0,
                fflags: libc::NOTE_TRIGGER,
                data: 0,
                udata: 0,
                ext: [0; 2],
            };
            let mut next = Instant::now();
            while !stop_t.load(Ordering::Relaxed) {
                unsafe {
                    libc::kevent64(kq, &trigger, 1, std::ptr::null_mut(), 0, 0, std::ptr::null())
                };
                next += WAKE_PERIOD;
                if let Some(wait) = next.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
            }
        }));
    }
    std::thread::sleep(Duration::from_millis(500));
    measure("the daemon's shape, under the load", fd, room, &buffer, &mut report);
    stop.store(true, Ordering::Relaxed);
    for thread in threads {
        let _ = thread.join();
    }
    for kq in wake_queues {
        unsafe { libc::close(kq) };
    }
    drop(children);
    unsafe { libc::close(watched) };
    unsafe { libc::close(room) };
    let _ = std::fs::remove_dir_all(&dir);
    drop((files, sockets, filler, nulls, peer));
    panic!("{report}");
}
