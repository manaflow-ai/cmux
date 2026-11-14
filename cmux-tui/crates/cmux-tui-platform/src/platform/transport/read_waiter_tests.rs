use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use super::{ReadWaiter, Stream};

fn queue(waiter: &ReadWaiter) -> Option<(i32, i32)> {
    waiter.queue.as_ref().map(|(queue, watched)| (queue.as_raw_fd(), *watched))
}

/// A reader keeps one kqueue for all its waits: no descriptor is made or
/// added for each read.
#[test]
fn one_kqueue_serves_every_wait_of_a_reader() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let mut waiter = ReadWaiter::new();
    assert_eq!(queue(&waiter), None);
    let mut first = None;
    for round in 0..100u8 {
        (&theirs).write_all(&[round]).unwrap();
        Stream::wait_readable(&ours, &mut waiter).unwrap();
        let mut byte = [0];
        (&ours).read_exact(&mut byte).unwrap();
        assert_eq!(byte, [round]);
        let now = queue(&waiter).unwrap();
        assert_eq!(now.1, ours.as_raw_fd());
        assert_eq!(*first.get_or_insert(now), now);
    }
}

/// A waiter given another socket waits for that socket only: bytes on
/// the first one do not end its wait.
#[test]
fn a_waiter_moved_to_another_socket_waits_for_that_socket() {
    let (first, first_peer) = UnixStream::pair().unwrap();
    let (second, second_peer) = UnixStream::pair().unwrap();
    let mut waiter = ReadWaiter::new();
    (&first_peer).write_all(b"x").unwrap();
    Stream::wait_readable(&first, &mut waiter).unwrap();

    second.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let started = Instant::now();
    let error = Stream::wait_readable(&second, &mut waiter).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    assert!(started.elapsed() >= Duration::from_millis(100), "{:?}", started.elapsed());
    assert_eq!(queue(&waiter).unwrap().1, second.as_raw_fd());

    (&second_peer).write_all(b"y").unwrap();
    Stream::wait_readable(&second, &mut waiter).unwrap();
}
