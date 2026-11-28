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

#[test]
fn a_read_right_after_a_drop_waits_past_the_away_wait_for_the_next_stream() {
    let link =
        Arc::new(Link::new(Duration::from_millis(100)).with_drop_grace(Duration::from_millis(800)));
    let mac = attach(&link);
    assert_eq!(link.read(1, 0, 4).unwrap(), b"file");
    // A paused machine's stream drops; it comes back after the away wait, inside the grace.
    mac.shutdown(std::net::Shutdown::Both).unwrap();
    let start = Instant::now();
    while link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    let waiting = {
        let link = link.clone();
        std::thread::spawn(move || link.read(3, 0, 6))
    };
    std::thread::sleep(Duration::from_millis(300));
    let back = attach(&link);
    assert_eq!(waiting.join().unwrap().unwrap(), b"file-3");

    // Past the grace a read with no stream fails after the away wait again.
    back.shutdown(std::net::Shutdown::Both).unwrap();
    while link.attached() {
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(900));
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    let waited = start.elapsed();
    assert!(
        waited >= Duration::from_millis(100) && waited < Duration::from_millis(700),
        "{waited:?}"
    );
}

#[test]
fn a_read_after_a_detach_gets_no_grace() {
    let link =
        Arc::new(Link::new(Duration::from_millis(100)).with_drop_grace(Duration::from_secs(30)));
    let _mac = attach(&link);
    link.detach();
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    assert!(start.elapsed() < Duration::from_secs(5));
}

struct Journal;

impl Source for Journal {
    fn read(&self, _: u32, _: u64, _: u32) -> Part {
        Part::status(wire::FAILED)
    }

    fn whole(&self, _: u32) -> Part {
        Part::status(wire::FAILED)
    }

    fn listing(&self, since: u64) -> Part {
        if since < 5 {
            return Part::status(CHANGED);
        }
        Part::ok(Patch { from: since, to: since + 1, changes: Vec::new() }.encode().unwrap())
    }
}

#[test]
fn a_listing_patch_is_asked_of_the_mac_and_a_missing_journal_means_a_full_listing() {
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let (machine, mac) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    std::thread::spawn(move || {
        let writer = mac.try_clone().unwrap();
        let _ = answer_asks(mac, writer, &Journal);
    });
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    let patch = link.listing_since(7).unwrap().unwrap();
    assert_eq!((patch.from, patch.to), (7, 8));
    assert_eq!(link.listing_since(1).unwrap(), None);
}

#[test]
fn a_mac_with_no_journal_answers_a_listing_ask_with_the_full_listing_signal() {
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let _mac = attach(&link);
    assert_eq!(link.listing_since(3).unwrap(), None);
}

/// A file that compresses well, so a packed answer carries it as zstd.
struct Text;

impl Source for Text {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let bytes = self.whole(entry).bytes;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Part::ok(bytes[start..end].to_vec())
    }

    fn whole(&self, entry: u32) -> Part {
        Part::ok(format!("line {entry} of a text file\n").repeat(500).into_bytes())
    }
}

#[test]
fn a_mac_that_packs_its_answers_is_read_the_same() {
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let (machine, mac) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    std::thread::spawn(move || {
        let writer = mac.try_clone().unwrap();
        let _ = answer_asks_packed(mac, writer, &Text);
    });
    let whole = Text.whole(3).bytes;
    assert_eq!(link.read(3, 10, 4000).unwrap(), whole[10..4010]);
    let batch = link.batch(&[3, 4]);
    assert_eq!(batch[0].as_deref().unwrap(), whole.as_slice());
    assert_eq!(batch[1].as_deref().unwrap(), Text.whole(4).bytes.as_slice());
    assert!(link.ping());
}

fn fast_link(hold_ms: u64) -> Arc<Link> {
    Arc::new(Link::with_heartbeat(
        Duration::from_millis(100),
        Duration::from_millis(50),
        Duration::from_millis(200),
        Duration::from_millis(hold_ms),
    ))
}

/// The machine's end of a stream whose far side reads and writes nothing until it is handed
/// back; the far side.
fn attach_silent(link: &Arc<Link>) -> UnixStream {
    let (machine, silent) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    silent
}

/// A carrier that keeps the connection open and moves nothing (a half-open TCP connection, a
/// stalled relay), where the Mac dials again: a read in flight on the dead stream is answered by
/// the new one. It waited 120 s and failed with EIO, and every read after it did the same.
#[test]
fn a_read_on_a_stream_that_goes_silent_is_answered_by_the_macs_next_stream() {
    let link = fast_link(5_000);
    let _silent = attach_silent(&link);
    let waiting = {
        let link = link.clone();
        std::thread::spawn(move || link.read(3, 0, 6))
    };
    let start = Instant::now();
    while !link.stalled() {
        assert!(start.elapsed() < Duration::from_secs(3), "a silent stream never stalled");
        std::thread::sleep(Duration::from_millis(10));
    }
    // The Mac gives the silent stream up and dials again.
    let _mac = attach(&link);
    assert_eq!(waiting.join().unwrap().unwrap(), b"file-3");
    assert!(start.elapsed() < Duration::from_secs(3));
    assert_eq!(link.read(4, 0, 6).unwrap(), b"file-4");
}

/// Nothing answers and no new stream comes: reads fail as `Away` once the stall hold is over,
/// not after two minutes, and later reads fail as fast.
#[test]
fn a_silent_stream_with_no_redial_fails_reads_as_away_after_the_hold() {
    let link = fast_link(300);
    let _silent = attach_silent(&link);
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    let waited = start.elapsed();
    assert!(waited < Duration::from_secs(3), "a silent stream held a read for {waited:?}");
    assert!(link.stalled());
    let start = Instant::now();
    assert_eq!(link.read(1, 0, 4), Err(FetchError::Away));
    assert!(start.elapsed() < Duration::from_secs(1));
}

/// A Mac that sleeps on an open stream and wakes inside the hold: the read that waited through
/// the sleep is answered, not failed.
#[test]
fn a_read_through_a_mac_that_sleeps_and_wakes_is_answered() {
    let link = fast_link(5_000);
    let mac = attach_silent(&link);
    let waiting = {
        let link = link.clone();
        std::thread::spawn(move || link.read(5, 0, 6))
    };
    let start = Instant::now();
    while !link.stalled() {
        assert!(start.elapsed() < Duration::from_secs(3), "a sleeping Mac never stalled");
        std::thread::sleep(Duration::from_millis(10));
    }
    // Awake: it answers what queued up (the read, the pings) and goes on.
    {
        let writer = mac.try_clone().unwrap();
        std::thread::spawn(move || {
            let _ = answer_asks(mac, writer, &Files);
        });
    }
    assert_eq!(waiting.join().unwrap().unwrap(), b"file-5");
    assert!(!link.stalled());
    assert_eq!(link.read(6, 0, 6).unwrap(), b"file-6");
}

/// The machine itself paused (a VM paused and resumed): the silence was its own, so the stream
/// is not stalled when it resumes and its next read is answered.
#[test]
fn a_pause_on_the_machine_side_does_not_stall_a_live_stream() {
    let link = fast_link(5_000);
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

/// A Mac's end that is asked nothing for its idle wait gives the stream up (the caller dials
/// again): the machine stops pinging a stalled stream, so the Mac learns it is dead.
#[test]
fn the_macs_end_gives_up_a_stream_that_brings_no_ask() {
    let (mac, _machine) = UnixStream::pair().unwrap();
    mac.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    let writer = mac.try_clone().unwrap();
    let start = Instant::now();
    assert!(answer_asks(mac, writer, &Files).is_err());
    assert!(start.elapsed() < Duration::from_secs(2));
}

/// Entry 1's answer waits for entry 2 to be asked: one answered at a time, it would wait it out.
struct Waits {
    asked_two: Mutex<bool>,
    two: Condvar,
}

impl Source for Waits {
    fn read(&self, entry: u32, _offset: u64, _len: u32) -> Part {
        if entry == 2 {
            *self.asked_two.lock().unwrap() = true;
            self.two.notify_all();
            return Part::ok(b"two".to_vec());
        }
        let asked = self.asked_two.lock().unwrap();
        let (asked, _) =
            self.two.wait_timeout_while(asked, Duration::from_secs(5), |asked| !*asked).unwrap();
        if *asked { Part::ok(b"one".to_vec()) } else { Part::status(wire::FAILED) }
    }

    fn whole(&self, entry: u32) -> Part {
        self.read(entry, 0, 3)
    }
}

#[test]
fn the_mac_answers_asks_at_once_so_a_slow_one_holds_up_no_other() {
    let link = Arc::new(Link::new(Duration::from_millis(500)));
    let (machine, mac) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    let source = Arc::new(Waits { asked_two: Mutex::new(false), two: Condvar::new() });
    std::thread::spawn(move || {
        let writer = mac.try_clone().unwrap();
        let _ = answer_asks(mac, writer, source.as_ref());
    });
    while !link.attached() {
        std::thread::yield_now();
    }
    let start = Instant::now();
    let one = {
        let link = link.clone();
        std::thread::spawn(move || link.read(1, 0, 3))
    };
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(link.batch(&[2])[0].as_deref().unwrap(), b"two");
    assert_eq!(one.join().unwrap().unwrap(), b"one");
    assert!(start.elapsed() < Duration::from_secs(4));
}
