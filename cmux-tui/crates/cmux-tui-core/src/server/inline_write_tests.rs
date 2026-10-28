//! The inline write fast path: on an idle connection replies
//! and input-lane echo frames leave on the producer's thread with no writer
//! turn; what the socket does not take is the writer's next write, in order;
//! nothing is written inline while an item waits or the writer is writing.
//! Test names start with `message_writer` (the task's `RUST(message_writer)`).

use super::super::{BatchPoll, write_batch_nonblocking};
use super::super::{BoundedOutbound, QueuedSink, SinkControl, write_counted_turn};
use super::InlineSocket;
use crate::diagnostics::IpcStats;
use crate::server::MessageWriter;
use cmux_ipc::lane_writer::BULK_FRAME_MAX;
use cmux_ipc::{Aux, FrameHeader, FrameKind, HEADER_LEN, StreamLane};
use serde_json::json;
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

/// The daemon's socket buffer size.
const SOCKET_BUFFER: libc::c_int = 512 * 1024;

/// A connected pair with the daemon's buffer sizes: the daemon's end, the
/// client's end.
fn socket_pair() -> (UnixStream, UnixStream) {
    let (server, client) = UnixStream::pair().unwrap();
    for socket in [&server, &client] {
        for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
            let size = SOCKET_BUFFER;
            // SAFETY: setsockopt reads one c_int from `size`, live for the call.
            unsafe {
                libc::setsockopt(
                    socket.as_raw_fd(),
                    libc::SOL_SOCKET,
                    option,
                    (&raw const size).cast(),
                    size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
        }
    }
    (server, client)
}

/// An outbound queue over `server` with an inline socket, and the writer
/// over it.
fn inline_outbound(server: &UnixStream) -> (Arc<BoundedOutbound>, MessageWriter) {
    let socket = Box::new(server.try_clone().unwrap());
    let inline = InlineSocket::new(socket, BULK_FRAME_MAX, Arc::new(IpcStats::default()));
    assert!(inline.is_some(), "a Unix socket takes inline writes");
    let outbound = Arc::new(BoundedOutbound::with_inline(BULK_FRAME_MAX, inline));
    let control = SinkControl::Unix(Box::new(server.try_clone().unwrap()));
    let writer =
        MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: Some(control) });
    (outbound, writer)
}

/// The writer thread's loop (server/line_connection.rs where there is no
/// mux-io loop) over `server`, counting the turns it took.
fn spawn_writer(
    outbound: &Arc<BoundedOutbound>,
    server: &UnixStream,
) -> (JoinHandle<()>, Arc<AtomicUsize>) {
    let turns = Arc::new(AtomicUsize::new(0));
    let (outbound, counted) = (outbound.clone(), turns.clone());
    let mut socket = server.try_clone().unwrap();
    let thread = std::thread::spawn(move || {
        let ipc = IpcStats::default();
        let mut batch = Vec::new();
        while let Some(mut turn) = outbound.recv_turn(&mut batch) {
            counted.fetch_add(1, Ordering::Relaxed);
            let rest = turn.rest.take();
            write_counted_turn(&mut socket, &ipc, rest.as_deref(), &batch).unwrap();
            batch.clear();
        }
    });
    (thread, turns)
}

/// Reads exactly `count` bytes from `client` on another thread.
fn spawn_reader(client: &UnixStream, count: usize) -> JoinHandle<Vec<u8>> {
    let mut client = client.try_clone().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    std::thread::spawn(move || {
        let mut bytes = vec![0; count];
        client.read_exact(&mut bytes).unwrap();
        bytes
    })
}

#[test]
fn message_writer_idle_echo_frames_and_replies_take_no_writer_turn() {
    let (server, client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    let (writer_thread, turns) = spawn_writer(&outbound, &server);
    let echo = writer.start_stream_on(StreamLane::Input, &json!({"event": "overflow"})).unwrap();
    let service = crate::server::RenderService::new();
    let payload = service.serialize(&"echo").unwrap();
    let frames = 1_000;
    let frame_bytes = HEADER_LEN + payload.len();
    let reply = json!({"id": 1, "ok": true}).to_string();
    let reader = spawn_reader(&client, frames * frame_bytes + frames * (reply.len() + 1));

    let mut expected = Vec::new();
    for index in 0..frames {
        let offset = Aux::Offset((index * payload.len()) as u64);
        let header = FrameHeader::new(FrameKind::Output, 1, payload.len() as u32, offset).unwrap();
        expected.extend_from_slice(&header.encode());
        expected.extend_from_slice(payload.as_bytes());
        writer.send_stream_frame(header, payload.clone(), &echo).unwrap();
    }
    for _ in 0..frames {
        expected.extend_from_slice(reply.as_bytes());
        expected.push(b'\n');
        writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
    }

    assert_eq!(reader.join().unwrap(), expected);
    assert_eq!(turns.load(Ordering::Relaxed), 0, "an idle connection woke its writer thread");
    // The task's metric: 0 mux-line-out wakeups, counted at the condvar, so a
    // wake with nothing to write (a notify after an inline write) fails too.
    assert_eq!(outbound.writer_wakeups(), 0, "an inline write woke the writer thread");
    outbound.close();
    writer_thread.join().unwrap();
}

#[test]
fn message_writer_a_full_socket_leaves_the_rest_to_the_writer_in_order() {
    let (server, client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    let line = |index: usize| json!({"id": index, "pad": "p".repeat(16 * 1024)});
    let lines = 200;
    let mut expected = Vec::new();
    // No writer thread and nobody reading: the socket fills, an inline send
    // takes part of a line or none, and every later line queues behind it.
    for index in 0..lines {
        expected.extend_from_slice(line(index).to_string().as_bytes());
        expected.push(b'\n');
        writer.send_control(&line(index)).unwrap();
    }
    let rest = outbound.state.lock().unwrap().writer.rest.as_ref().map(Vec::len);
    assert!(rest.is_some_and(|bytes| bytes > 0), "the full socket left no rest");

    let reader = spawn_reader(&client, expected.len());
    let (writer_thread, turns) = spawn_writer(&outbound, &server);
    assert_eq!(reader.join().unwrap(), expected, "the rest or a queued line left out of order");
    assert!(turns.load(Ordering::Relaxed) > 0);
    outbound.close();
    writer_thread.join().unwrap();
}

#[test]
fn message_writer_nothing_is_written_inline_while_an_item_waits_or_the_writer_writes() {
    let (server, client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    client.set_nonblocking(true).unwrap();
    let nothing_on_the_wire = || {
        let mut byte = [0_u8; 1];
        let read = (&client).read(&mut byte);
        assert!(
            read.as_ref().is_err_and(|error| error.kind() == std::io::ErrorKind::WouldBlock),
            "a message was written inline past the queue: {read:?}"
        );
    };

    // An ordered terminal always queues; a reply after it must wait for it.
    let stream = writer.start_stream_on(StreamLane::Bulk, &json!({"event": "overflow"})).unwrap();
    writer.send_ordered_terminal(&json!({"event": "end"}), &stream).unwrap();
    writer.send_control(&json!({"id": 2, "ok": true})).unwrap();
    nothing_on_the_wire();

    // The writer's turn holds the queued items (one batch);
    // while it lives the queue is not idle even once it is empty.
    let mut batch = Vec::new();
    let turn = outbound.recv_turn(&mut batch).unwrap();
    assert!(turn.rest.is_none() && !batch.is_empty());
    while outbound.try_pop().is_some() {}
    writer.send_control(&json!({"id": 3, "ok": true})).unwrap();
    nothing_on_the_wire();
    drop(turn);
    assert!(outbound.try_pop().is_some_and(|reply| reply.contains("\"id\":3")));

    // Idle again: the next reply leaves inline.
    writer.send_control(&json!({"id": 4, "ok": true})).unwrap();
    client.set_nonblocking(false).unwrap();
    let expected = format!("{}\n", json!({"id": 4, "ok": true}));
    assert_eq!(spawn_reader(&client, expected.len()).join().unwrap(), expected.as_bytes());
}

#[test]
fn message_writer_a_failed_inline_send_closes_the_queue() {
    let (server, client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    drop(client);
    assert!(writer.send_control(&json!({"id": 1, "ok": true})).is_err());
    assert!(!outbound.is_open(), "the queue stayed open after the socket failed");
}

#[test]
fn message_writer_abort_drops_the_rest_of_a_partial_message() {
    let (server, _client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    for index in 0..200 {
        writer.send_control(&json!({"id": index, "pad": "p".repeat(16 * 1024)})).unwrap();
    }
    assert!(outbound.state.lock().unwrap().writer.rest.is_some());
    outbound.abort();
    assert!(outbound.recv_turn(&mut Vec::new()).is_none(), "an aborted queue still wrote a rest");
}

/// The mux-io loop's turns (server/mux_io.rs `Connection::write`): the rest
/// a full socket left goes first, then the queued items, in order; a reply
/// sent while the loop holds a turn queues behind them; once a poll finds
/// the queue empty, a reply leaves inline again and rings nobody.
#[test]
fn message_writer_the_mux_io_loop_writes_the_rest_first_then_frees_inline() {
    let (server, client) = socket_pair();
    let (outbound, writer) = inline_outbound(&server);
    let rings = Arc::new(AtomicUsize::new(0));
    let counted = rings.clone();
    assert!(outbound.on_ready(move || {
        counted.fetch_add(1, Ordering::Relaxed);
    }));
    let line = |index: usize| json!({"id": index, "pad": "p".repeat(16 * 1024)});
    let mut expected = Vec::new();
    for index in 0..200 {
        expected.extend_from_slice(line(index).to_string().as_bytes());
        expected.push(b'\n');
        writer.send_control(&line(index)).unwrap();
    }
    assert!(outbound.state.lock().unwrap().writer.rest.is_some(), "the full socket left no rest");
    assert!(rings.load(Ordering::Relaxed) > 0, "the rest rang no doorbell");
    let during = json!({"id": "during"});
    expected.extend_from_slice(during.to_string().as_bytes());
    expected.push(b'\n');

    let reader = spawn_reader(&client, expected.len());
    server.set_nonblocking(true).unwrap();
    let mut socket = server.try_clone().unwrap();
    let (mut batch, mut rest, mut turns) = (Vec::new(), None, 0);
    loop {
        match outbound.try_recv_turn(&mut batch, &mut rest) {
            BatchPoll::Taken => {}
            BatchPoll::Empty => break,
            BatchPoll::Closed => panic!("the queue closed"),
        }
        if turns == 0 {
            assert!(rest.is_some(), "the rest did not come first");
            // The loop holds a turn: this reply queues behind it.
            writer.send_control(&during).unwrap();
        }
        turns += 1;
        let mut written = 0;
        while !write_batch_nonblocking(&mut socket, rest.as_deref(), &batch, &mut written).unwrap()
        {
            std::thread::yield_now();
        }
        rest = None;
    }
    assert_eq!(reader.join().unwrap(), expected, "the rest or a queued line left out of order");

    // Idle again: the next reply leaves inline, with no doorbell.
    let before = rings.load(Ordering::Relaxed);
    let after = json!({"id": "after"});
    writer.send_control(&after).unwrap();
    assert_eq!(rings.load(Ordering::Relaxed), before, "an idle reply rang the loop");
    let expected = format!("{after}\n");
    assert_eq!(spawn_reader(&client, expected.len()).join().unwrap(), expected.as_bytes());
}
