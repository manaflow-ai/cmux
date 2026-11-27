use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

use cmux_holder::wire::{self, Frame, Kind, Out};

use super::*;

/// The next frame the link sent on `stream`; panics when it ends.
fn next_frame(stream: &UnixStream, reader: &mut wire::Reader, what: &str) -> Frame {
    loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            return frame;
        }
        match reader.fill(stream.as_raw_fd()) {
            Ok(true) => {}
            other => panic!("the daemon sent no {what}: {other:?}"),
        }
    }
}

/// Answer a HELLO with a WELCOME listing `listed` (channel, terminal id).
fn welcome(stream: &UnixStream, reader: &mut wire::Reader, listed: &[(u32, [u8; 16])]) {
    let hello = next_frame(stream, reader, "HELLO");
    assert_eq!(hello.kind, Kind::Hello as u16);
    let fd = stream.as_raw_fd();
    let count = u32::try_from(listed.len()).unwrap();
    let payload = Out::default().u16(wire::VERSION).u32(count).0;
    wire::send_all(fd, &wire::encode(Kind::Welcome, 0, &payload), &[]).unwrap();
    for (chan, id) in listed {
        // Every LISTED passes its master: a stand-in, a pipe's end.
        let (master, _write_end) = io::pipe().unwrap();
        let entry = Out::default().i32(0).u64(0).u64(0).u8(0).bytes(id).0;
        let frame = wire::encode_with_fds(Kind::Listed, 0, *chan, &entry, 1);
        wire::send_all(fd, &frame, &[master.as_raw_fd()]).unwrap();
    }
}

/// Review 2 of pl-holder-11: a reconnect ends only the terminals this
/// daemon abandoned, never the other terminals the holder lists. Daemon
/// A's SPAWN of terminal `a` goes out and its link breaks before the
/// answer (as when another daemon B took the holder and A's SUPERSEDED
/// stayed behind queued output, so A sees a plain end and reconnects).
/// The holder then lists `a` (A's abandoned terminal) and two shells B
/// spawned. A's reconnect sends exactly one CLOSE, for `a`. Before, A
/// closed every listed terminal that was not in its `live` map: B's
/// shells too, and a terminal of A's own between its SPAWNED and its
/// `track`.
#[test]
fn a_reconnect_ends_only_the_terminals_this_daemon_abandoned() {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("chs-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (a, b1, b2) = ([0xa1; 16], [0xb1; 16], [0xb2; 16]);
    let stand_in = std::thread::spawn(move || {
        let (first, _) = listener.accept().unwrap();
        first.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = wire::Reader::default();
        welcome(&first, &mut reader, &[]);
        let spawn = next_frame(&first, &mut reader, "SPAWN");
        assert_eq!((spawn.kind, spawn.chan), (Kind::Spawn as u16, 1));
        let attach = next_frame(&first, &mut reader, "ATTACH");
        assert_eq!((attach.kind, attach.chan), (Kind::Attach as u16, 1));
        // The link ends before the SPAWNED: a plain end, no SUPERSEDED.
        first.shutdown(std::net::Shutdown::Both).unwrap();
        drop(first);

        let (second, _) = listener.accept().unwrap();
        second.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = wire::Reader::default();
        welcome(&second, &mut reader, &[(1, a), (2, b1), (3, b2)]);
        let mut closed = Vec::new();
        loop {
            let frame = next_frame(&second, &mut reader, "the test's SIGNAL");
            match Kind::from_u16(frame.kind) {
                Some(Kind::Close) => closed.push(frame.chan),
                Some(Kind::Signal) if frame.chan == 999 => break,
                _ => {}
            }
        }
        (closed, second)
    });

    let service = Arc::new(HolderService::new(socket, [0x44; 32]));
    let request = SpawnRequest { id: a, argv: vec![b"/bin/sh".to_vec()], ..Default::default() };
    assert!(service.spawn(&request, b"").is_err(), "the link broke before the SPAWNED");
    // The holder-restart thread or this call reconnects; either way the
    // link comes back only after the reconnect's CLOSEs went out.
    let link = service.link().expect("the reconnect to the same holder");
    link.signal(999, 0).unwrap();
    let (closed, second) = stand_in.join().expect("the stand-in saw the test's SIGNAL");
    assert_eq!(closed, vec![1], "only A's abandoned terminal is closed, not B's shells");
    assert_eq!(
        *service.abandoned.lock().unwrap(),
        HashMap::from([(1, a)]),
        "a terminal the holder still lists stays abandoned until it is gone"
    );

    // No restart may launch a holder once the stand-in's link ends.
    service.superseded.store(true, Ordering::Release);
    drop(link);
    drop(service);
    drop(second);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A holder that takes every link and drops it at once (it answers the
/// HELLO, then closes) must not be relinked in a tight loop. Before,
/// each lost link started a new `holder-restart` thread that connected
/// again at once: thousands of connects, HELLOs and threads a second
/// for as long as the holder did that. Now link ends that come without
/// a healthy link between them wait longer each time.
#[test]
fn a_holder_that_drops_every_link_is_relinked_with_growing_waits() {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let dir = std::env::temp_dir().join(format!("chf-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let accepted = Arc::new(AtomicU32::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let stand_in = {
        let (accepted, stop) = (accepted.clone(), stop.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if stop.load(Ordering::Acquire) {
                    break;
                }
                let Ok(stream) = stream else { continue };
                accepted.fetch_add(1, Ordering::AcqRel);
                stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                welcome(&stream, &mut wire::Reader::default(), &[]);
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        })
    };

    let service = Arc::new(HolderService::new(socket.clone(), [0x45; 32]));
    drop(service.link().expect("the first link"));
    std::thread::sleep(Duration::from_secs(1));
    let relinks = accepted.load(Ordering::Acquire);

    // Stop relinking before the stand-in stops answering: a connect that
    // fails would launch a real holder. A relink checks `superseded`
    // under `connecting` and holds it through its connect, so once this
    // takes the lock no relink can connect again.
    service.superseded.store(true, Ordering::Release);
    drop(service.connecting.lock().recover_poison());
    stop.store(true, Ordering::Release);
    drop(UnixStream::connect(&socket));
    stand_in.join().unwrap();
    drop(service);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(relinks >= 3, "the daemon still relinks a dropped holder: {relinks}");
    assert!(relinks <= 20, "{relinks} links in 1 s to a holder that drops each one");
}
