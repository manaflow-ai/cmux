//! The inline write fast path behind `MessageWriter` (p05-ipc-140): on an
//! idle local connection a producer's item reaches the socket on its own
//! thread, with no writer thread at all; what a full socket does not take
//! is left for the writer thread ahead of everything queued after it; and
//! nothing is written inline while the writer thread holds an item.

use super::*;
use crate::diagnostics::IpcStats;
use crate::platform::transport;
use crate::server::bounded_outbound::{
    BoundedOutbound, InlineWrite, OutboundItem, Pending, QueuedSink, WaitingWrite,
    socket_inline_writer, write_pending,
};
use cmux_ipc::lane_writer::BULK_FRAME_MAX;
use serde_json::json;
use std::io::{BufRead, BufReader, Read};
use std::os::unix::net::UnixStream;
use std::sync::atomic::AtomicUsize;

/// A connection's queue with the inline writer of `ours`, and its writer.
fn inline_connection(
    ours: &UnixStream,
    ipc: &Arc<IpcStats>,
) -> (Arc<BoundedOutbound>, MessageWriter) {
    let inline = socket_inline_writer(ours, ipc);
    assert!(inline.is_some(), "a connected Unix socket has an inline writer");
    let outbound = Arc::new(BoundedOutbound::with_inline_writer(BULK_FRAME_MAX, inline));
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (outbound, writer)
}

fn left_for_writer(outbound: &BoundedOutbound) -> bool {
    outbound.state.lock().unwrap().left_for_writer()
}

#[test]
fn an_idle_connection_writes_a_thousand_echo_outputs_with_no_writer_thread() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let ipc = Arc::new(IpcStats::default());
    let (outbound, writer) = inline_connection(&ours, &ipc);
    let echo = writer.start_stream_on(StreamLane::Input, &json!({"event": "overflow"})).unwrap();

    // No mux-line-out thread exists: every byte the peer reads was written
    // by this thread, inside the send. The peer reads each echo and reply
    // as it comes, as the app's reader does: the connection stays idle.
    let mut lines = BufReader::new(theirs).lines();
    for n in 0..1_000 {
        writer.send_stream_backpressured(&json!({"echo": n}), &echo).unwrap();
        writer.send_control(&json!({"id": n, "ok": true})).unwrap();
        assert!(!left_for_writer(&outbound), "item {n} was left for a writer thread");
        assert_eq!(lines.next().unwrap().unwrap(), json!({"echo": n}).to_string());
        assert_eq!(lines.next().unwrap().unwrap(), json!({"id": n, "ok": true}).to_string());
    }
    let writes = ipc.snapshot().writes;
    assert_eq!(writes.messages, 2_000);
    assert_eq!(writes.syscalls, 2_000, "one gathered sendmsg per item, delimiter included");
}

#[test]
fn a_full_socket_leaves_the_rest_for_the_writer_thread_ahead_of_later_items() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let ipc = Arc::new(IpcStats::default());
    let (outbound, writer) = inline_connection(&ours, &ipc);

    // Far more than a socket buffer holds: the inline send takes a prefix.
    let big = "b".repeat(8 << 20);
    writer.send_control(&big).unwrap();
    assert!(left_for_writer(&outbound), "the rest must wait for the writer thread");
    for n in 0..10 {
        writer.send_control(&json!({"id": n})).unwrap();
    }

    let mut socket: Box<dyn transport::Stream> = Box::new(ours.try_clone().unwrap());
    let drain = outbound.clone();
    let writer_thread = std::thread::spawn(move || {
        while let Some(pending) = drain.recv_pending() {
            write_pending(&mut WaitingWrite::new(&mut *socket), pending).unwrap();
        }
    });
    let mut reader = BufReader::new(theirs);
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    assert!(
        first.trim_end() == serde_json::to_string(&big).unwrap(),
        "the big line was cut or doubled ({} bytes)",
        first.len()
    );
    for n in 0..10 {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line.trim_end(), json!({"id": n}).to_string());
    }
    outbound.close();
    writer_thread.join().unwrap();
    drop(writer);
    drop(outbound);
    drop(ours);
    let mut rest = Vec::new();
    reader.get_mut().set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let _ = reader.read_to_end(&mut rest);
    assert!(rest.is_empty(), "{} bytes after the last item", rest.len());
    assert_eq!(ipc.snapshot().writes.messages, 1, "the big line counted once, by its inline write");
}

/// An inline writer that takes nothing while `full` and everything after,
/// counting its calls.
struct ScriptedSocket {
    calls: Arc<AtomicUsize>,
    full_calls: usize,
}

impl InlineWrite for ScriptedSocket {
    fn write_now(&self, item: &OutboundItem) -> std::io::Result<usize> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        let len = item.wire_parts()?.map_or(0, |parts| parts.len());
        Ok(if call < self.full_calls { 0 } else { len })
    }
}

fn scripted_connection(
    full_calls: usize,
) -> (Arc<AtomicUsize>, Arc<BoundedOutbound>, MessageWriter) {
    let calls = Arc::new(AtomicUsize::new(0));
    let socket = ScriptedSocket { calls: calls.clone(), full_calls };
    let outbound =
        Arc::new(BoundedOutbound::with_inline_writer(BULK_FRAME_MAX, Some(Box::new(socket))));
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (calls, outbound, writer)
}

fn is_reply(pending: &Pending, id: u64) -> bool {
    matches!(&pending.item, OutboundItem::Text(text) if text.contains(&format!("\"id\":{id}")))
}

#[test]
fn nothing_is_written_inline_while_the_writer_thread_holds_an_item() {
    let (calls, outbound, writer) = scripted_connection(1);

    // The socket is full: the first reply stays, unsent, for the writer thread.
    writer.send_control(&json!({"id": 1})).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    // Behind it nothing is written inline, also once the writer thread took it.
    writer.send_control(&json!({"id": 2})).unwrap();
    let first = outbound.recv_pending().unwrap();
    assert_eq!(first.written, 0);
    assert!(is_reply(&first, 1));
    writer.send_control(&json!({"id": 3})).unwrap();
    assert!(is_reply(&outbound.recv_pending().unwrap(), 2));
    assert!(is_reply(&outbound.recv_pending().unwrap(), 3));
    assert_eq!(calls.load(Ordering::SeqCst), 1, "an item was written beside the writer thread's");
}

#[test]
fn a_closed_queue_writes_nothing_inline() {
    let (calls, outbound, writer) = scripted_connection(0);

    writer.send_control(&json!({"id": 1})).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 1, "an idle queue writes inline");
    assert!(!left_for_writer(&outbound));
    outbound.close();
    assert!(writer.send_control(&json!({"id": 2})).is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 1, "a closed queue wrote");
}
