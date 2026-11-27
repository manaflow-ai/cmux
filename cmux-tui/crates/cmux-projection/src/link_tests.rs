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
        Part::status(crate::wire::FAILED)
    }

    fn whole(&self, _: u32) -> Part {
        Part::status(crate::wire::FAILED)
    }

    fn listing(&self, since: u64) -> Part {
        if since < 5 {
            return Part::status(CHANGED);
        }
        Part::ok(
            crate::listing_patch::Patch { from: since, to: since + 1, changes: Vec::new() }
                .encode()
                .unwrap(),
        )
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
