//! The read loop: many sources on two threads at idle, one
//! source's bytes in order across runs and kicks, the end of a stream
//! finishes its source once, and a dropped owner keeps reading live sources.

use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use super::*;

const WAIT: Duration = Duration::from_secs(10);

/// A socket read like a PTY: nonblocking, what is there per run.
struct Pipe {
    stream: UnixStream,
    received: Sender<Vec<u8>>,
    finished: Sender<()>,
}

impl ReadSource for Pipe {
    fn run(&mut self) -> ReadFlow {
        let mut buffer = [0u8; 7];
        for _ in 0..READS_PER_RUN {
            match self.stream.read(&mut buffer) {
                Ok(0) => return ReadFlow::Finished,
                Ok(count) => self.received.send(buffer[..count].to_vec()).unwrap(),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    return ReadFlow::Continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return ReadFlow::Finished,
            }
        }
        ReadFlow::Continue
    }

    fn finish(self: Box<Self>) {
        self.finished.send(()).unwrap();
    }
}

struct Registered {
    writer: UnixStream,
    received: Receiver<Vec<u8>>,
    finished: Receiver<()>,
    kick: ReadKick,
}

fn register(reads: &TerminalReads) -> Registered {
    let (reader, writer) = UnixStream::pair().unwrap();
    reader.set_nonblocking(true).unwrap();
    let (received_tx, received) = channel();
    let (finished_tx, finished) = channel();
    let fd = reader.as_raw_fd();
    let source = Pipe { stream: reader, received: received_tx, finished: finished_tx };
    let kick = reads.register(fd, Box::new(source)).unwrap_or_else(|_| panic!("registered"));
    Registered { writer, received, finished, kick }
}

fn receive(registered: &Registered, len: usize) -> Vec<u8> {
    let deadline = Instant::now() + WAIT;
    let mut bytes = Vec::new();
    while bytes.len() < len {
        let left = deadline.saturating_duration_since(Instant::now());
        bytes.extend(registered.received.recv_timeout(left).expect("the bytes were read"));
    }
    bytes
}

fn wait_for(reads: &TerminalReads, done: impl Fn(ReadLoopStats) -> bool) -> ReadLoopStats {
    let deadline = Instant::now() + WAIT;
    loop {
        let stats = reads.stats();
        if done(stats) || Instant::now() >= deadline {
            return stats;
        }
        std::thread::yield_now();
    }
}

#[test]
fn fifty_sources_read_on_two_threads_at_idle() {
    let reads = TerminalReads::new();
    let mut sources: Vec<_> = (0..50).map(|_| register(&reads)).collect();
    for (index, source) in sources.iter_mut().enumerate() {
        source.writer.write_all(format!("terminal {index}").as_bytes()).unwrap();
    }
    for (index, source) in sources.iter().enumerate() {
        let expected = format!("terminal {index}");
        assert_eq!(receive(source, expected.len()), expected.as_bytes());
    }
    let stats = wait_for(&reads, |stats| stats.workers <= PARKED_READ_WORKERS);
    assert_eq!(stats.sources, 50);
    // The loop thread and at most one parked worker, whatever the count.
    assert!(stats.workers <= PARKED_READ_WORKERS, "{stats:?}");
    assert!(stats.workers <= MAX_READ_WORKERS);
}

#[test]
fn one_sources_output_keeps_its_order_across_runs_and_kicks() {
    let reads = TerminalReads::new();
    let mut source = register(&reads);
    let mut expected = Vec::new();
    for chunk in 0..400u32 {
        let bytes = format!("<{chunk}>");
        source.writer.write_all(bytes.as_bytes()).unwrap();
        expected.extend_from_slice(bytes.as_bytes());
        if chunk % 3 == 0 {
            // A resize's drain kicks while a run may be in progress.
            source.kick.kick();
        }
    }
    assert_eq!(receive(&source, expected.len()), expected);
}

#[test]
fn a_kick_runs_a_source_with_nothing_to_read() {
    let reads = TerminalReads::new();
    let source = register(&reads);
    source.kick.kick();
    // The run reads nothing, sees WouldBlock and arms again; it still reads
    // what comes later.
    let mut writer = source.writer.try_clone().unwrap();
    writer.write_all(b"after").unwrap();
    assert_eq!(receive(&source, 5), b"after");
}

#[test]
fn the_end_of_a_stream_finishes_its_source_once_and_unwatches_it() {
    let reads = TerminalReads::new();
    let mut source = register(&reads);
    source.writer.write_all(b"last").unwrap();
    assert_eq!(receive(&source, 4), b"last");
    drop(source.writer);
    source.finished.recv_timeout(WAIT).expect("the source finished");
    assert!(source.finished.recv_timeout(Duration::from_millis(50)).is_err(), "finished twice");
    assert_eq!(wait_for(&reads, |stats| stats.sources == 0).sources, 0);
    // A kick after the end does nothing.
    source.kick.kick();
}

#[test]
fn a_dropped_owner_keeps_reading_live_sources_until_they_end() {
    let reads = TerminalReads::new();
    let mut source = register(&reads);
    drop(reads);
    source.writer.write_all(b"still read").unwrap();
    assert_eq!(receive(&source, 10), b"still read");
    drop(source.writer);
    source.finished.recv_timeout(WAIT).expect("the source finished after its owner");
}

#[test]
fn a_panicking_run_drops_its_source_and_spares_the_others() {
    struct Panics;
    impl ReadSource for Panics {
        fn run(&mut self) -> ReadFlow {
            panic!("a read run failed")
        }
        fn finish(self: Box<Self>) {}
    }
    let reads = TerminalReads::new();
    let (panicking, mut trigger) = UnixStream::pair().unwrap();
    let kick = reads
        .register(panicking.as_raw_fd(), Box::new(Panics))
        .unwrap_or_else(|_| panic!("registered"));
    trigger.write_all(b"x").unwrap();
    kick.kick();
    assert_eq!(wait_for(&reads, |stats| stats.sources == 0).sources, 0);
    let mut healthy = register(&reads);
    healthy.writer.write_all(b"ok").unwrap();
    assert_eq!(receive(&healthy, 2), b"ok");
    drop(panicking);
}

#[test]
fn panicking_finishes_never_use_up_the_workers() {
    struct PanicsAtEnd {
        stream: UnixStream,
    }
    impl ReadSource for PanicsAtEnd {
        fn run(&mut self) -> ReadFlow {
            let mut buffer = [0u8; 16];
            match self.stream.read(&mut buffer) {
                Ok(0) => ReadFlow::Finished,
                _ => ReadFlow::Continue,
            }
        }
        fn finish(self: Box<Self>) {
            panic!("an end-of-stream publication failed")
        }
    }
    let reads = TerminalReads::new();
    for _ in 0..=MAX_READ_WORKERS {
        let (reader, writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let fd = reader.as_raw_fd();
        reads
            .register(fd, Box::new(PanicsAtEnd { stream: reader }))
            .unwrap_or_else(|_| panic!("registered"));
        drop(writer);
        assert_eq!(wait_for(&reads, |stats| stats.sources == 0).sources, 0);
    }
    let stats = wait_for(&reads, |stats| stats.workers <= PARKED_READ_WORKERS);
    assert!(stats.workers <= PARKED_READ_WORKERS, "a panicked finish kept its slot: {stats:?}");
    let mut healthy = register(&reads);
    healthy.writer.write_all(b"still read").unwrap();
    assert_eq!(receive(&healthy, 10), b"still read");
}

/// A source whose publication waits, as a query response does on a PTY
/// whose child never reads its input.
struct BlocksInPublish {
    stream: UnixStream,
    entered: Sender<()>,
    release: Receiver<()>,
}

impl ReadSource for BlocksInPublish {
    fn run(&mut self) -> ReadFlow {
        let mut buffer = [0u8; 16];
        match self.stream.read(&mut buffer) {
            Ok(0) => return ReadFlow::Finished,
            Ok(_) => {}
            Err(_) => return ReadFlow::Continue,
        }
        will_block(|| {
            self.entered.send(()).unwrap();
            self.release.recv_timeout(WAIT).expect("released");
        });
        ReadFlow::Continue
    }

    fn finish(self: Box<Self>) {}
}

#[test]
fn sources_blocked_in_publication_never_keep_the_others_unread() {
    let reads = TerminalReads::new();
    let (entered_tx, entered) = channel();
    let mut releases = Vec::new();
    let mut writers = Vec::new();
    for _ in 0..=MAX_READ_WORKERS {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let (release_tx, release) = channel();
        let fd = reader.as_raw_fd();
        let source = BlocksInPublish { stream: reader, entered: entered_tx.clone(), release };
        reads.register(fd, Box::new(source)).unwrap_or_else(|_| panic!("registered"));
        writer.write_all(b"?").unwrap();
        releases.push(release_tx);
        writers.push(writer);
    }
    for _ in 0..=MAX_READ_WORKERS {
        entered.recv_timeout(WAIT).expect("every blocked source got a worker");
    }
    assert_eq!(reads.stats().blocked, MAX_READ_WORKERS + 1);
    let mut healthy = register(&reads);
    healthy.writer.write_all(b"read anyway").unwrap();
    assert_eq!(receive(&healthy, 11), b"read anyway");

    for release in &releases {
        release.send(()).unwrap();
    }
    let stats =
        wait_for(&reads, |stats| stats.blocked == 0 && stats.workers <= PARKED_READ_WORKERS);
    assert_eq!(stats.blocked, 0, "{stats:?}");
    assert!(stats.workers <= PARKED_READ_WORKERS, "the extra workers exit at idle: {stats:?}");
}

#[test]
fn will_block_off_a_read_worker_only_runs_its_call() {
    assert_eq!(will_block(|| 7), 7);
}
