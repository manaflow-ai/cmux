//! The descriptor readers (p05-ipc-147): one thread reads every watched
//! socket, a reader's end of file ends its watch, and dropping the owner
//! ends every watch.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(5);

/// Reports each read and its own drop.
struct Probe {
    stream: UnixStream,
    reads: Sender<(usize, Vec<u8>)>,
    index: usize,
    dropped: Sender<usize>,
}

impl FdReader for Probe {
    fn fd(&self) -> RawFd {
        self.stream.as_raw_fd()
    }

    fn readable(&mut self) -> bool {
        let mut bytes = [0_u8; 64];
        match self.stream.read(&mut bytes) {
            Ok(0) => false,
            Ok(read) => {
                let _ =
                    self.reads.send((self.index, bytes.get(..read).unwrap_or_default().to_vec()));
                true
            }
            Err(error) => error.kind() == ErrorKind::WouldBlock,
        }
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        let _ = self.dropped.send(self.index);
    }
}

/// The peers of `count` watched sockets, what their readers read, and the
/// indexes of the readers that dropped.
struct Probes {
    peers: Vec<UnixStream>,
    read: Receiver<(usize, Vec<u8>)>,
    dropped: Receiver<usize>,
}

fn probes(readers: &FdReaders, count: usize) -> Probes {
    let (reads, read) = channel();
    let (dropped, drop_seen) = channel();
    let peers = (0..count)
        .map(|index| {
            let (peer, stream) = UnixStream::pair().unwrap();
            stream.set_nonblocking(true).unwrap();
            readers
                .watch(Box::new(Probe {
                    stream,
                    reads: reads.clone(),
                    index,
                    dropped: dropped.clone(),
                }))
                .unwrap();
            peer
        })
        .collect();
    Probes { peers, read, dropped: drop_seen }
}

#[test]
fn every_watched_socket_is_read_on_one_thread_until_its_end_of_file() {
    let readers = FdReaders::default();
    let Probes { mut peers, read, dropped } = probes(&readers, 8);
    for (index, peer) in peers.iter_mut().enumerate() {
        peer.write_all(format!("hello {index}").as_bytes()).unwrap();
    }
    let mut seen = [false; 8];
    for _ in 0..8 {
        let (index, bytes) = read.recv_timeout(WAIT).expect("a read");
        assert_eq!(bytes, format!("hello {index}").into_bytes());
        seen[index] = true;
    }
    assert!(seen.iter().all(|seen| *seen), "a watched socket was not read");
    let readers_threads =
        cmux_threads::snapshot().into_iter().filter(|row| row.name == "mux-fd-readers").count();
    assert!(readers_threads >= 1, "the readers run on their own thread");

    // An end of file ends that watch alone: its reader drops, the others read on.
    drop(peers.remove(3));
    assert_eq!(dropped.recv_timeout(WAIT).expect("the ended reader dropped"), 3);
    peers[0].write_all(b"still").unwrap();
    assert_eq!(read.recv_timeout(WAIT).expect("a read"), (0, b"still".to_vec()));
}

#[test]
fn dropping_the_readers_ends_every_watch() {
    let readers = FdReaders::default();
    let Probes { peers: _peers, read: _read, dropped } = probes(&readers, 3);
    drop(readers);
    let mut ended: Vec<usize> =
        (0..3).map(|_| dropped.recv_timeout(WAIT).expect("a reader dropped")).collect();
    ended.sort_unstable();
    assert_eq!(ended, [0, 1, 2]);
}

/// A reader that panics on its read, or, once `in_fd` is set, on the
/// thread's next poll, outside every reader's read.
struct Panicking {
    stream: UnixStream,
    in_fd: Arc<AtomicBool>,
    dropped: Sender<()>,
}

impl FdReader for Panicking {
    fn fd(&self) -> RawFd {
        assert!(!self.in_fd.load(Ordering::SeqCst), "the readers' thread ends");
        self.stream.as_raw_fd()
    }

    fn readable(&mut self) -> bool {
        panic!("a reader panics");
    }
}

impl Drop for Panicking {
    fn drop(&mut self) {
        let _ = self.dropped.send(());
    }
}

/// The peer of a watched `Panicking`, its switch, and its drop.
fn panicking(readers: &FdReaders) -> (UnixStream, Arc<AtomicBool>, Receiver<()>) {
    let (peer, stream) = UnixStream::pair().unwrap();
    stream.set_nonblocking(true).unwrap();
    let in_fd = Arc::new(AtomicBool::new(false));
    let (dropped, drop_seen) = channel();
    readers.watch(Box::new(Panicking { stream, in_fd: in_fd.clone(), dropped })).unwrap();
    (peer, in_fd, drop_seen)
}

#[test]
fn a_panicking_reader_ends_its_own_watch_alone() {
    let readers = FdReaders::default();
    let Probes { mut peers, read, dropped } = probes(&readers, 2);
    let (mut bad, _, bad_dropped) = panicking(&readers);
    bad.write_all(b"boom").unwrap();
    bad_dropped.recv_timeout(WAIT).expect("the panicked reader dropped");

    // The other watches read on, and a later watch works.
    peers[1].write_all(b"after").unwrap();
    assert_eq!(read.recv_timeout(WAIT).expect("a read"), (1, b"after".to_vec()));
    let Probes { peers: mut later, read: later_read, .. } = probes(&readers, 1);
    later[0].write_all(b"later").unwrap();
    assert_eq!(later_read.recv_timeout(WAIT).expect("a read"), (0, b"later".to_vec()));
    assert!(dropped.try_recv().is_err(), "no other reader dropped");
}

#[test]
fn an_ended_thread_drops_every_reader_and_the_next_watch_starts_another() {
    let readers = FdReaders::default();
    let Probes { peers: _peers, read: _read, dropped } = probes(&readers, 2);
    let (_bad, in_fd, bad_dropped) = panicking(&readers);
    // The thread's next poll panics outside every reader's read; a watch
    // wakes it.
    in_fd.store(true, Ordering::SeqCst);
    let Probes { peers: _wake, .. } = probes(&readers, 1);
    let mut ended: Vec<usize> =
        (0..2).map(|_| dropped.recv_timeout(WAIT).expect("a reader dropped")).collect();
    ended.sort_unstable();
    assert_eq!(ended, [0, 1], "every reader of the ended thread dropped");
    bad_dropped.recv_timeout(WAIT).expect("the panicking reader dropped");

    // A watch after the end runs on a new thread. One that raced the
    // thread's end ends with it, so the next one is read.
    let deadline = std::time::Instant::now() + WAIT;
    loop {
        let Probes { peers: mut later, read: later_read, .. } = probes(&readers, 1);
        later[0].write_all(b"later").unwrap();
        if later_read.recv_timeout(Duration::from_millis(500)) == Ok((0, b"later".to_vec())) {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no watch was read after the thread ended");
    }
}
