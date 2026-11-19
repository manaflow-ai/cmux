use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::*;
use crate::wire::{CHANGED, OK};

struct Files;

impl Source for Files {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let bytes: Vec<u8> = format!("file-{entry}").into_bytes();
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Part::ok(bytes[start..end].to_vec())
    }

    fn whole(&self, entry: u32) -> Part {
        if entry == 99 {
            Part::status(CHANGED)
        } else {
            Part::ok(format!("file-{entry}").into_bytes())
        }
    }
}

fn attach(link: &Arc<Link>) -> UnixStream {
    let (machine, mac) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    let answering = mac.try_clone().unwrap();
    std::thread::spawn(move || {
        let writer = answering.try_clone().unwrap();
        let _ = answer_asks(answering, writer, &Files);
    });
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    mac
}

#[test]
fn reads_and_batches_are_answered_from_the_mac() {
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let _mac = attach(&link);
    assert_eq!(link.read(7, 2, 3).unwrap(), b"le-");
    let batch = link.batch(&[1, 99, 2]);
    assert_eq!(batch[0].as_deref().unwrap(), b"file-1");
    assert_eq!(batch[1], Err(FetchError::Changed));
    assert_eq!(batch[2].as_deref().unwrap(), b"file-2");
    assert!(link.ping());
    let _ = OK;
}

#[test]
fn a_read_with_no_mac_fails_as_away_after_the_wait_and_works_once_it_is_back() {
    let link = Arc::new(Link::new(Duration::from_millis(150)));
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    assert!(start.elapsed() >= Duration::from_millis(150));

    let mac = attach(&link);
    assert_eq!(link.read(1, 0, 4).unwrap(), b"file");
    // The Mac's stream drops; a read waits, and a new stream answers it.
    mac.shutdown(std::net::Shutdown::Both).unwrap();
    let waiting = {
        let link = link.clone();
        std::thread::spawn(move || link.read(2, 0, 6))
    };
    std::thread::sleep(Duration::from_millis(30));
    let _back = attach(&link);
    assert_eq!(waiting.join().unwrap().unwrap(), b"file-2");
}

/// A carrier that keeps the connection open and moves nothing (a half-open TCP connection, a
/// stalled relay): the Mac's end never sees the machine's asks and the machine never hears back.
/// Its asks fail over as `Away` within the stall wait instead of hanging for minutes, and the
/// Mac's next stream answers at once.
#[test]
fn a_stream_that_goes_silent_without_ending_stalls_and_the_next_stream_answers() {
    let link = Arc::new(Link::with_heartbeat(
        Duration::from_millis(100),
        Duration::from_millis(50),
        Duration::from_millis(200),
    ));
    // The machine's end of a stream whose far side never reads nor writes.
    let (machine, _silent) = UnixStream::pair().unwrap();
    {
        let served = link.clone();
        let writer = machine.try_clone().unwrap();
        std::thread::spawn(move || served.serve(machine, writer));
    }
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    let waited = start.elapsed();
    assert!(waited < Duration::from_secs(3), "a silent stream held a read for {waited:?}");
    assert!(link.stalled());
    // New asks do not go to the stalled stream: they wait for the Mac, then fail as `Away`.
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    // The Mac dials again: answered at once.
    let _mac = attach(&link);
    let start = Instant::now();
    while link.stalled() {
        assert!(start.elapsed() < Duration::from_secs(5), "the new stream never attached");
        std::thread::yield_now();
    }
    assert_eq!(link.read(3, 0, 6).unwrap(), b"file-3");
}

/// A Mac that sleeps (stops answering) and wakes on the same stream: its asks in flight fail as
/// `Away` once the stall wait passes, and the stream serves again as soon as it speaks.
#[test]
fn a_stalled_stream_that_speaks_again_serves_again() {
    let link = Arc::new(Link::with_heartbeat(
        Duration::from_millis(100),
        Duration::from_millis(50),
        Duration::from_millis(200),
    ));
    let (machine, mac) = UnixStream::pair().unwrap();
    {
        let served = link.clone();
        let writer = machine.try_clone().unwrap();
        std::thread::spawn(move || served.serve(machine, writer));
    }
    while !link.attached() {
        std::thread::yield_now();
    }
    // Asleep: nothing answers, so the read fails over and the stream stalls.
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    assert!(link.stalled());
    // Awake: the Mac answers what queued up (the pings, the old read) and goes on.
    {
        let writer = mac.try_clone().unwrap();
        std::thread::spawn(move || {
            let _ = answer_asks(mac, writer, &Files);
        });
    }
    let start = Instant::now();
    while link.stalled() {
        assert!(start.elapsed() < Duration::from_secs(5), "the woken stream stayed stalled");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(link.read(5, 0, 6).unwrap(), b"file-5");
}

/// The machine itself paused (a VM paused and resumed): the silence was its own, so the stream
/// is not stalled when it resumes and its next read is answered.
#[test]
fn a_pause_on_the_machine_side_does_not_stall_a_live_stream() {
    let link = Arc::new(Link::with_heartbeat(
        Duration::from_millis(100),
        Duration::from_millis(50),
        Duration::from_millis(200),
    ));
    let _mac = attach(&link);
    // Hold the link's lock past several beats, as a stopped process would.
    {
        let _held = link.lock();
        std::thread::sleep(Duration::from_millis(600));
    }
    std::thread::sleep(Duration::from_millis(20));
    assert!(!link.stalled());
    assert_eq!(link.read(4, 0, 6).unwrap(), b"file-4");
}
