//! The terminal input sink (p05-ipc-157): a consumer that does not read
//! never makes a submit wait, queued bytes arrive in order once it reads, a
//! full backlog refuses whole payloads, and a consumer that ends tells each
//! sender of its unwritten bytes once.

use std::io::Read;
use std::os::unix::net::UnixStream;
use std::sync::Mutex as StdMutex;

use super::*;

const WAIT: Duration = Duration::from_secs(10);

/// A sender that records what the sink tells it.
#[derive(Default)]
struct Recorded {
    failed: StdMutex<Vec<(InputFailure, usize)>>,
    written: StdMutex<usize>,
}

impl InputReceipt for Recorded {
    fn failed(&self, reason: InputFailure, bytes: usize) {
        self.failed.lock().unwrap().push((reason, bytes));
    }

    fn written(&self) {
        *self.written.lock().unwrap() += 1;
    }
}

impl Recorded {
    fn failures(&self) -> Vec<(InputFailure, usize)> {
        self.failed.lock().unwrap().clone()
    }
}

/// A sink over one end of a socket pair standing in for the PTY master,
/// with no owner (its own read loop); the other end is the child.
fn sink_pair() -> (Arc<PtyInputSink>, UnixStream) {
    let (master, child) = UnixStream::pair().unwrap();
    let sink = PtyInputSink::new(master.as_raw_fd(), Weak::new()).unwrap();
    // The sink keeps its own duplicate.
    drop(master);
    (sink, child)
}

fn receipt(recorded: &Arc<Recorded>) -> Option<Arc<dyn InputReceipt>> {
    Some(recorded.clone() as Arc<dyn InputReceipt>)
}

fn read_exactly(child: &mut UnixStream, len: usize) -> Vec<u8> {
    child.set_read_timeout(Some(WAIT)).unwrap();
    let mut received = vec![0; len];
    child.read_exact(&mut received).unwrap();
    received
}

fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn ten_thousand_inputs_to_a_child_that_does_not_read_never_wait_and_arrive_in_order() {
    let (sink, mut child) = sink_pair();
    let recorded = Arc::new(Recorded::default());
    let mut expected = Vec::new();
    let mut latencies = Vec::with_capacity(10_000);
    for index in 0..10_000u32 {
        let key = format!("k{index:05};");
        let started = Instant::now();
        sink.submit(key.as_bytes(), receipt(&recorded)).unwrap();
        latencies.push(started.elapsed());
        expected.extend_from_slice(key.as_bytes());
    }
    latencies.sort();
    let p99 = latencies[latencies.len() * 99 / 100];
    assert!(p99 < Duration::from_millis(2), "a submit waited: p99 {p99:?}");
    assert!(sink.backlog_bytes() > 0, "the socket took 70 KB without a reader");

    // The child reads at last: every byte, in order, and the sink parks.
    assert_eq!(read_exactly(&mut child, expected.len()), expected);
    wait_until("the backlog to drain", || sink.backlog_bytes() == 0);
    assert!(recorded.failures().is_empty());
    assert!(*recorded.written.lock().unwrap() > 0, "queued chunks report their delivery");

    // A parked sink writes the next input at once, still in order.
    sink.submit(b"after", None).unwrap();
    assert_eq!(read_exactly(&mut child, 5), b"after");
}

#[test]
fn a_full_backlog_refuses_the_whole_payload_and_keeps_what_it_holds() {
    let (sink, mut child) = sink_pair();
    let recorded = Arc::new(Recorded::default());
    let block = vec![b'x'; 64 * 1024];
    let mut accepted = 0;
    let refused = loop {
        match sink.submit(&block, receipt(&recorded)) {
            Ok(_) => accepted += block.len(),
            Err(error) => break error,
        }
        assert!(accepted <= INPUT_SINK_CAPACITY + (1 << 20), "the backlog has no bound");
    };
    assert!(matches!(refused, InputSinkError::Overflow { .. }), "{refused}");
    assert_eq!(refused.failure(), InputFailure::Overflow);
    assert_eq!(io::Error::from(refused).kind(), io::ErrorKind::WouldBlock);
    assert!(sink.backlog_bytes() <= INPUT_SINK_CAPACITY);
    // A refused payload is the caller's to report: no receipt hears of it.
    assert!(recorded.failures().is_empty());

    // Everything accepted arrives whole; nothing of the refused payload does.
    let received = read_exactly(&mut child, accepted);
    assert!(received.iter().all(|byte| *byte == b'x'));
    wait_until("the backlog to drain", || sink.backlog_bytes() == 0);
    child.set_nonblocking(true).unwrap();
    let mut rest = [0u8; 16];
    assert!(
        matches!(child.read(&mut rest), Err(error) if error.kind() == io::ErrorKind::WouldBlock)
    );
}

#[test]
fn a_child_that_ends_fails_each_senders_queued_bytes_once() {
    let (sink, child) = sink_pair();
    let first = Arc::new(Recorded::default());
    let second = Arc::new(Recorded::default());
    // Fill the socket, then queue interleaved chunks of two senders.
    let fill = vec![b'f'; 4096];
    while sink.backlog_bytes() == 0 {
        sink.submit(&fill, None).unwrap();
    }
    let mut first_bytes = 0;
    let mut second_bytes = 0;
    for _ in 0..1_000 {
        sink.submit(b"one", receipt(&first)).unwrap();
        sink.submit(b"second", receipt(&second)).unwrap();
        first_bytes += 3;
        second_bytes += 6;
    }
    drop(child);

    wait_until("the failure reports", || {
        !first.failures().is_empty() && !second.failures().is_empty()
    });
    assert_eq!(first.failures(), vec![(InputFailure::WriteFailed, first_bytes)]);
    assert_eq!(second.failures(), vec![(InputFailure::WriteFailed, second_bytes)]);
    let after = sink.submit(b"late", receipt(&first)).unwrap_err();
    assert!(matches!(after, InputSinkError::Closed(_)), "{after}");
    assert_eq!(first.failures().len(), 1, "a refusal is not reported again");
}

#[test]
fn closing_the_sink_fails_queued_input_and_refuses_more() {
    let (sink, mut child) = sink_pair();
    let recorded = Arc::new(Recorded::default());
    let fill = vec![b'f'; 4096];
    while sink.backlog_bytes() == 0 {
        sink.submit(&fill, None).unwrap();
    }
    sink.submit(b"queued", receipt(&recorded)).unwrap();
    sink.close();
    assert_eq!(recorded.failures(), vec![(InputFailure::WriteFailed, 6)]);
    assert!(matches!(sink.submit(b"x", None), Err(InputSinkError::Closed(_))));
    sink.close();
    assert_eq!(recorded.failures().len(), 1);

    // Nothing queued is written after the close.
    child.set_nonblocking(true).unwrap();
    let mut drained = Vec::new();
    let mut buffer = [0u8; 4096];
    let deadline = Instant::now() + Duration::from_millis(200);
    while Instant::now() < deadline {
        match child.read(&mut buffer) {
            Ok(count) => drained.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("{error}"),
        }
    }
    assert!(drained.iter().all(|byte| *byte == b'f'), "closed input reached the child");
}

#[test]
fn local_input_closes_its_sink_when_the_runtime_drops_it() {
    let (sink, _child) = sink_pair();
    let recorded = Arc::new(Recorded::default());
    let fill = vec![b'f'; 4096];
    while sink.backlog_bytes() == 0 {
        sink.submit(&fill, None).unwrap();
    }
    sink.submit(b"queued", receipt(&recorded)).unwrap();
    drop(LocalInput::new(sink.clone()));
    assert_eq!(recorded.failures(), vec![(InputFailure::WriteFailed, 6)]);
    assert!(matches!(sink.submit(b"x", None), Err(InputSinkError::Closed(_))));
}

fn patterned(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index % 251) as u8).collect()
}

#[test]
fn a_payload_larger_than_the_capacity_reaches_a_reading_child_whole() {
    let (sink, mut child) = sink_pair();
    let recorded = Arc::new(Recorded::default());
    let len = INPUT_SINK_CAPACITY + (1 << 20);
    let reader = std::thread::spawn(move || read_exactly(&mut child, len));
    let payload = patterned(len);
    sink.submit(&payload, receipt(&recorded)).unwrap();
    assert!(reader.join().unwrap() == payload, "the paste arrived cut or out of order");
    wait_until("the backlog to drain", || sink.backlog_bytes() == 0);
    assert!(recorded.failures().is_empty());
}

#[test]
fn a_backlog_holds_at_most_the_capacity_behind_its_first_payload() {
    let (sink, _child) = sink_pair();
    // More than the socket takes plus the capacity: the backlog passes it.
    sink.submit(&vec![b'l'; 2 * INPUT_SINK_CAPACITY], None).unwrap();
    assert!(sink.backlog_bytes() > INPUT_SINK_CAPACITY);
    let refused = sink.submit(b"k", None).unwrap_err();
    assert!(matches!(refused, InputSinkError::Overflow { len: 1, .. }), "{refused}");
}

#[test]
fn an_empty_payload_behind_a_backlog_is_written_at_once() {
    let (sink, _child) = sink_pair();
    let fill = vec![b'f'; 4096];
    while sink.backlog_bytes() == 0 {
        sink.submit(&fill, None).unwrap();
    }
    let recorded = Arc::new(Recorded::default());
    assert_eq!(sink.submit(b"", receipt(&recorded)).unwrap(), Submitted::Written);
    assert!(recorded.failures().is_empty());
}

/// A drain that parked once, then a submit whose write fails: the drain
/// leaves the read loop, so the runtime's end releases the sink and its
/// duplicate descriptor.
#[test]
fn a_write_failure_after_the_drain_parked_releases_the_sink() {
    let (sink, mut child) = sink_pair();
    let fill = vec![b'f'; 4096];
    let mut sent = 0;
    while sink.backlog_bytes() == 0 {
        sink.submit(&fill, None).unwrap();
        sent += fill.len();
    }
    read_exactly(&mut child, sent);
    wait_until("the drain to park", || sink.backlog_bytes() == 0);
    drop(child);

    let failed = sink.submit(b"after", None).unwrap_err();
    assert!(matches!(failed, InputSinkError::Closed(_)), "{failed}");
    drop(LocalInput::new(sink.clone()));
    wait_until("the drain to release the sink", || Arc::strong_count(&sink) == 1);
}
