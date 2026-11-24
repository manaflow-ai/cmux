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
