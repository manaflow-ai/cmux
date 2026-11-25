use super::*;
use crate::terminal_host_protocol::encode_frame;
use std::time::Duration;

const SMART: EarlyResponses = EarlyResponses { smart_renderer: true };

fn frame(kind: MessageKind, request_id: u64, version: u16) -> Frame {
    let mut frame = Frame::new(kind, Vec::new());
    frame.request_id = request_id;
    frame.version = version;
    frame
}

fn version() -> u16 {
    Frame::new(MessageKind::InputAck, Vec::new()).version
}

fn stream_of(frames: &[Frame]) -> std::io::Cursor<Vec<u8>> {
    let mut bytes = Vec::new();
    for frame in frames {
        bytes.extend(encode_frame(frame).unwrap());
    }
    std::io::Cursor::new(bytes)
}

fn queue() -> Queue {
    Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() }
}

#[test]
fn early_responses_depend_on_kind_and_renderer() {
    let version = version();
    let legacy = EarlyResponses::new(false);
    assert!(resolves_early(&frame(MessageKind::InputAck, 7, version), version, SMART));
    assert!(resolves_early(&frame(MessageKind::TerminateAck, 7, version), version, legacy));
    assert!(resolves_early(&frame(MessageKind::Capability, 7, version), version, legacy));
    assert!(resolves_early(
        &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
        version,
        SMART
    ));
    assert!(!resolves_early(
        &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
        version,
        legacy
    ));
    assert!(!resolves_early(&frame(MessageKind::InputAck, 0, version), version, SMART));
    assert!(!resolves_early(&frame(MessageKind::ClearHistoryAck, 7, version), version, SMART));
    assert!(!resolves_early(&frame(MessageKind::ResizeAck, 7, version), version, SMART));
    assert!(!resolves_early(
        &frame(MessageKind::InputAck, 7, version.wrapping_add(1)),
        version,
        SMART
    ));
}

/// A smart host answers a Kitty limits update with ResyncRequired and
/// then the acknowledgement. The surface's reader abandons the stream at
/// ResyncRequired; the acknowledgement must still reach its requester.
#[test]
fn kitty_ack_after_resync_reaches_its_waiter() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let kitty = responses.wait_for_test(9, MessageKind::KittyGraphicsLimitsAck);
    let queue = queue();
    queue.state.lock().unwrap().abandoned = true;
    let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
    resync.version = version;
    let stream = stream_of(&[resync, frame(MessageKind::KittyGraphicsLimitsAck, 9, version)]);
    read_stream(stream, &responses, version, SMART, &queue);
    assert_eq!(
        kitty.recv_timeout(Duration::from_secs(1)).unwrap().kind,
        MessageKind::KittyGraphicsLimitsAck
    );
}

/// `set-default-colors` makes a smart host publish ResyncRequired, and a
/// renderer mint sent right after it is answered behind that marker. The
/// surface's reader abandons the stream at ResyncRequired and fails its
/// ordered waiters; the mint's Capability must still reach its requester,
/// whether the requester registered before or after the abandon.
#[test]
fn capability_after_resync_reaches_its_waiter() {
    let version = version();
    for early in [SMART, EarlyResponses::new(false)] {
        let responses = ControlResponses::new_for_test();
        let mint = responses.wait_for_test(11, MessageKind::Capability);
        // The surface's reader abandons the stream (`HostFrames::abandon`).
        responses.fail_all_except(|kind| early.resolves(kind));
        let queue = queue();
        queue.state.lock().unwrap().abandoned = true;
        let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
        resync.version = version;
        let mut capability = frame(MessageKind::Capability, 11, version);
        capability.payload = vec![7; 32];
        read_stream(stream_of(&[resync, capability]), &responses, version, early, &queue);
        let reply = mint
            .recv_timeout(Duration::from_secs(1))
            .expect("the Capability reply after ResyncRequired was dropped");
        assert_eq!(reply.kind, MessageKind::Capability);
        assert_eq!(reply.payload, vec![7; 32]);
    }
}

/// At the end of the stream the thread fails only the waiters it owns: a
/// queued ClearHistoryAck is still resolved by the surface's reader.
#[test]
fn end_of_stream_leaves_queued_ordered_responses_to_the_surface_reader() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let clear = responses.wait_for_test(5, MessageKind::ClearHistoryAck);
    let input = responses.wait_for_test(6, MessageKind::InputAck);
    let queue = queue();
    let stream = stream_of(&[frame(MessageKind::ClearHistoryAck, 5, version)]);
    read_stream(stream, &responses, version, SMART, &queue);
    assert!(responses.has_waiter(5), "the ordered waiter was failed before its frame");
    assert!(!responses.has_waiter(6), "the thread must fail the early waiters it owns");
    assert!(input.recv_timeout(Duration::from_millis(10)).is_err());
    let state = queue.state.lock().unwrap();
    assert!(state.ended);
    let Some(HostFrame::Frame(queued)) = state.frames.front() else {
        panic!("the ClearHistoryAck frame was not queued");
    };
    assert!(responses.resolve(queued));
    assert_eq!(clear.recv().unwrap().kind, MessageKind::ClearHistoryAck);
}

/// A cell-pixel request whose caller stopped waiting (a deferred waiter)
/// still owns its acknowledgement when that acknowledgement is queued at
/// the end of the stream: the surface's reader resolves it in order.
#[test]
fn end_of_stream_keeps_a_deferred_cell_pixel_waiter_whose_ack_is_queued() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let _deferred = responses.wait_for_test(7, MessageKind::CellPixelSizeAck);
    assert!(responses.defer_cell_pixel(7, (9, 18)));
    let queue = queue();
    let stream = stream_of(&[
        frame(MessageKind::CellPixelSizeAck, 7, version),
        frame(MessageKind::Exit, 0, version),
    ]);
    read_stream(stream, &responses, version, SMART, &queue);
    assert!(
        responses.has_waiter(7),
        "the deferred cell-pixel waiter was failed before its queued acknowledgement"
    );
    let state = queue.state.lock().unwrap();
    assert!(state.ended);
    let Some(HostFrame::Frame(queued)) = state.frames.front() else {
        panic!("the CellPixelSizeAck frame was not queued");
    };
    assert!(responses.resolve(queued), "the queued acknowledgement found no waiter");
}

/// After `abandon`, ordered frames are discarded instead of queued, so a
/// backlog larger than the queue budget cannot delay an acknowledgement.
#[test]
fn abandoned_streams_discard_ordered_frames_and_still_resolve_acks() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let kitty = responses.wait_for_test(3, MessageKind::KittyGraphicsLimitsAck);
    let queue = queue();
    queue.state.lock().unwrap().abandoned = true;
    let mut output = Frame::new(MessageKind::Output, vec![b'x'; 1024 * 1024]);
    output.version = version;
    let mut frames = vec![output; 12];
    frames.push(frame(MessageKind::KittyGraphicsLimitsAck, 3, version));
    read_stream(stream_of(&frames), &responses, version, SMART, &queue);
    assert!(kitty.recv_timeout(Duration::from_secs(1)).is_ok());
    let state = queue.state.lock().unwrap();
    assert!(state.frames.is_empty() && state.queued_bytes == 0);
}

/// Empty frames (Bell, metadata) count against the queue budget too: a
/// host that floods them while the surface's reader is busy cannot grow
/// the queue without bound. The thread must stop reading at the budget,
/// as it does for output.
#[test]
fn empty_frames_count_against_the_queue_budget() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let queue = queue();
    let mut bell = Frame::new(MessageKind::Bell, Vec::new());
    bell.version = version;
    // More empty frames than the budget admits at their wire size alone.
    let admitted = QUEUED_BYTES_BUDGET / crate::terminal_host_protocol::HEADER_LEN;
    let stream = stream_of(&vec![bell; admitted + 2]);
    std::thread::scope(|scope| {
        let reader = scope.spawn(|| read_stream(stream, &responses, version, SMART, &queue));
        // The surface's reader drains nothing: the thread either stops
        // at the budget or reads the whole stream.
        let state = queue
            .changed
            .wait_while(queue.state.lock().unwrap(), |state| {
                !state.ended && state.budget_waits == 0
            })
            .unwrap();
        let (ended, queued) = (state.ended, state.frames.len());
        drop(state);
        // Release a waiting thread, as the surface reader's abandon does.
        queue.state.lock().unwrap().abandoned = true;
        queue.changed.notify_all();
        reader.join().unwrap();
        assert!(
            !ended && queued <= admitted,
            "the reader thread queued {queued} empty frames without stopping at the budget"
        );
    });
}

/// Counts the `read` calls made on a stream.
struct CountingReader<R> {
    inner: R,
    reads: Arc<std::sync::atomic::AtomicUsize>,
}

impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.inner.read(buf)
    }
}

/// A backlog of small frames is read with a few large reads, not two
/// per frame, and arrives whole and in order; a payload larger than the
/// read buffer arrives whole after them.
#[test]
fn a_backlog_of_small_frames_is_read_in_few_calls() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let queue = queue();
    let mut frames: Vec<Frame> = (0..1000u64)
        .map(|index| {
            let mut output = Frame::new(MessageKind::Output, format!("line {index}\r\n").into());
            output.version = version;
            output.sequence = index + 1;
            output
        })
        .collect();
    let mut large = Frame::new(MessageKind::Output, vec![b'y'; 3 * LINK_READ_BUFFER + 5]);
    large.version = version;
    large.sequence = 1001;
    frames.push(large);
    let reads = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let stream = CountingReader { inner: stream_of(&frames), reads: reads.clone() };
    read_stream(stream, &responses, version, SMART, &queue);
    let state = queue.state.lock().unwrap();
    let received: Vec<&Frame> = state
        .frames
        .iter()
        .map(|frame| match frame {
            HostFrame::Frame(frame) => frame,
            HostFrame::End | HostFrame::Idle => panic!("End and Idle are not queued"),
        })
        .collect();
    assert_eq!(received.len(), frames.len());
    for (received, sent) in received.iter().zip(&frames) {
        assert_eq!((received.sequence, &received.payload), (sent.sequence, &sent.payload));
    }
    let reads = reads.load(std::sync::atomic::Ordering::Relaxed);
    assert!(reads < 20, "{reads} read calls for 1001 frames");
}

/// Serves `chunks` the way a socket does: one read returns at most the
/// rest of the current chunk (what the host had written by then).
struct ChunkedStream {
    chunks: VecDeque<Vec<u8>>,
}

impl Read for ChunkedStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let Some(chunk) = self.chunks.front_mut() else { return Ok(0) };
        let count = chunk.len().min(buf.len());
        buf[..count].copy_from_slice(&chunk[..count]);
        chunk.drain(..count);
        if chunk.is_empty() {
            self.chunks.pop_front();
        }
        Ok(count)
    }
}

/// An idle terminal's link holds no large read buffer: about 800
/// terminals in a real session each kept a 64 KiB buffer (13 MB
/// resident idle, up to 51 MB after one burst each, never given back).
/// A burst is still read in few calls, and its frames arrive whole and
/// in order; after it drains, and for a single frame on an idle link,
/// the reader holds no heap buffer.
#[test]
fn an_idle_link_holds_no_large_read_buffer_after_a_burst() {
    let version = version();
    let frame = |sequence: u64, payload: Vec<u8>| {
        let mut frame = Frame::new(MessageKind::Output, payload);
        frame.version = version;
        frame.sequence = sequence;
        frame
    };
    let burst: Vec<Frame> =
        (0..20_000u64).map(|index| frame(index + 1, format!("line {index}\r\n").into())).collect();
    let prompt = frame(20_001, b"$ ".to_vec());
    let encoded = |frames: &[Frame]| stream_of(frames).into_inner();
    let reads = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let stream = CountingReader {
        inner: ChunkedStream {
            chunks: VecDeque::from([encoded(&burst), encoded(std::slice::from_ref(&prompt))]),
        },
        reads: reads.clone(),
    };
    let burst_bytes = encoded(&burst).len();
    let mut reader = LinkReader::new(stream);
    for sent in &burst {
        let received = read_frame(&mut reader, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!((received.sequence, &received.payload), (sent.sequence, &sent.payload));
    }
    let burst_reads = reads.load(std::sync::atomic::Ordering::Relaxed);
    assert!(
        burst_reads <= burst_bytes / LINK_READ_BUFFER + 3,
        "{burst_reads} read calls for a {burst_bytes} byte burst"
    );
    assert_eq!(reader.held_bytes(), 0, "the reader kept its read buffer after the burst drained");
    let received = read_frame(&mut reader, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!((received.sequence, &received.payload), (prompt.sequence, &prompt.payload));
    assert_eq!(reader.held_bytes(), 0, "one frame on an idle link took a large buffer");
    assert!(matches!(read_frame(&mut reader, MAX_FRAME_PAYLOAD), Ok(None)));
}

/// A Kitty limits acknowledgement whose requester already gave up does
/// not end the connection.
#[test]
fn late_kitty_ack_keeps_the_connection() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    let queue = queue();
    let mut output = Frame::new(MessageKind::Output, b"after".to_vec());
    output.version = version;
    let stream = stream_of(&[frame(MessageKind::KittyGraphicsLimitsAck, 4, version), output]);
    read_stream(stream, &responses, version, SMART, &queue);
    let state = queue.state.lock().unwrap();
    assert_eq!(state.frames.len(), 1, "the frame after the late ack was not read");
}

fn clipboard_request(token: u64, location: u8, version: u16) -> Frame {
    let mut payload = token.to_le_bytes().to_vec();
    payload.push(location);
    let mut frame = Frame::new(MessageKind::ClipboardReadRequest, payload);
    frame.version = version;
    frame
}

/// A host-originated clipboard read is outside the live sequence: the
/// reader thread hands it to the connection's inbox and broker handler
/// and keeps reading.
#[test]
fn negotiated_clipboard_read_requests_reach_the_inbox_outside_the_stream() {
    let version = version();
    let responses = ControlResponses::new_for_test();
    responses.negotiate_clipboard_reads_for_test();
    let signals = recording_handler(&responses);
    let queue = queue();
    let mut output = Frame::new(MessageKind::Output, b"after".to_vec());
    output.version = version;
    let stream = stream_of(&[clipboard_request(7, 1, version), output]);
    read_stream(stream, &responses, version, SMART, &queue);
    assert_eq!(
        signals.lock().unwrap().first(),
        Some(&crate::terminal_host_runtime::ClipboardReadSignal::Request(
            ghostty_vt::ClipboardReadRequest {
                token: 7,
                location: ghostty_vt::ClipboardLocation::Selection,
            }
        ))
    );
    let state = queue.state.lock().unwrap();
    assert_eq!(state.frames.len(), 1, "only the Output frame is ordered");
}

fn clipboard_cancel(token: u64, version: u16) -> Frame {
    let mut frame = Frame::new(MessageKind::ClipboardReadCancel, token.to_le_bytes().to_vec());
    frame.version = version;
    frame
}

fn recording_handler(
    responses: &ControlResponses,
) -> Arc<Mutex<Vec<crate::terminal_host_runtime::ClipboardReadSignal>>> {
    let signals = Arc::new(Mutex::new(Vec::new()));
    let recorded = signals.clone();
    responses.set_clipboard_read_handler(Arc::new(move |signal| {
        recorded.lock().unwrap().push(signal);
    }));
    signals
}

/// The host's cancel drops exactly the pending read it names and tells
/// the broker; a cancel for another token is stale and ignored.
#[test]
fn clipboard_signals_reach_the_handler_and_a_cancel_drops_its_read() {
    use crate::terminal_host_runtime::ClipboardReadSignal;
    let version = version();
    let responses = ControlResponses::new_for_test();
    responses.negotiate_clipboard_reads_for_test();
    let signals = recording_handler(&responses);
    let queue = queue();
    let mut output = Frame::new(MessageKind::Output, b"after".to_vec());
    output.version = version;
    let stream = stream_of(&[
        clipboard_request(7, 0, version),
        clipboard_cancel(8, version),
        clipboard_cancel(7, version),
        output,
    ]);
    read_stream(stream, &responses, version, SMART, &queue);
    assert_eq!(responses.pending_clipboard_read(), None);
    let request = ghostty_vt::ClipboardReadRequest {
        token: 7,
        location: ghostty_vt::ClipboardLocation::Standard,
    };
    assert_eq!(
        *signals.lock().unwrap(),
        vec![ClipboardReadSignal::Request(request), ClipboardReadSignal::Cancel(7)]
    );
    assert_eq!(queue.state.lock().unwrap().frames.len(), 1, "only the Output is ordered");
}

/// The host refuses the open read of a connection that ends, so the end
/// of the stream cancels the pending read too.
#[test]
fn the_end_of_the_stream_cancels_a_pending_clipboard_read() {
    use crate::terminal_host_runtime::ClipboardReadSignal;
    let version = version();
    let responses = ControlResponses::new_for_test();
    responses.negotiate_clipboard_reads_for_test();
    let signals = recording_handler(&responses);
    read_stream(
        stream_of(&[clipboard_request(9, 2, version)]),
        &responses,
        version,
        SMART,
        &queue(),
    );
    assert_eq!(responses.pending_clipboard_read(), None);
    assert_eq!(signals.lock().unwrap().last(), Some(&ClipboardReadSignal::Cancel(9)));
}

#[test]
fn unnegotiated_or_malformed_clipboard_cancels_end_the_stream() {
    let version = version();
    let mut with_request_id = clipboard_cancel(7, version);
    with_request_id.request_id = 3;
    let mut long = clipboard_cancel(7, version);
    long.payload.push(0);
    for (negotiated, cancel) in [
        (false, clipboard_cancel(7, version)),
        (true, clipboard_cancel(0, version)),
        (true, with_request_id),
        (true, long),
    ] {
        let responses = ControlResponses::new_for_test();
        if negotiated {
            responses.negotiate_clipboard_reads_for_test();
        }
        let queue = queue();
        let mut output = Frame::new(MessageKind::Output, b"after".to_vec());
        output.version = version;
        read_stream(stream_of(&[cancel, output]), &responses, version, SMART, &queue);
        let state = queue.state.lock().unwrap();
        assert!(state.ended && state.frames.is_empty(), "the connection must end there");
    }
}

/// A clipboard read on a connection that did not negotiate the right,
/// or a malformed one, ends the connection.
#[test]
fn unnegotiated_or_malformed_clipboard_read_requests_end_the_stream() {
    let version = version();
    let mut with_request_id = clipboard_request(7, 0, version);
    with_request_id.request_id = 3;
    let mut sequenced = clipboard_request(7, 0, version);
    sequenced.sequence = 9;
    for (negotiated, request) in [
        (false, clipboard_request(7, 0, version)),
        (true, clipboard_request(0, 0, version)),
        (true, clipboard_request(7, 3, version)),
        (true, with_request_id),
        (true, sequenced),
    ] {
        let responses = ControlResponses::new_for_test();
        if negotiated {
            responses.negotiate_clipboard_reads_for_test();
        }
        let queue = queue();
        let mut output = Frame::new(MessageKind::Output, b"after".to_vec());
        output.version = version;
        read_stream(stream_of(&[request, output]), &responses, version, SMART, &queue);
        assert_eq!(responses.pending_clipboard_read(), None);
        let state = queue.state.lock().unwrap();
        assert!(state.ended && state.frames.is_empty(), "the connection must end there");
    }
}

/// Threads of this process whose name is `name`.
#[cfg(target_os = "linux")]
fn threads_named(name: &str) -> usize {
    std::fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|task| std::fs::read_to_string(task.ok()?.path().join("comm")).ok())
        .filter(|comm| comm.trim() == name)
        .count()
}

#[cfg(unix)]
fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
fn parking_link(name: &str) -> (HostFrames, std::os::unix::net::UnixStream) {
    let (client, host) = std::os::unix::net::UnixStream::pair().unwrap();
    let frames = HostFrames::spawn_parking_after(
        name.into(),
        client,
        Arc::new(ControlResponses::new_for_test()),
        version(),
        true,
        Duration::from_millis(50),
    )
    .unwrap();
    (frames, host)
}

#[cfg(unix)]
fn output(sequence: u64, payload: &[u8]) -> Frame {
    let mut frame = Frame::new(MessageKind::Output, payload.to_vec());
    frame.sequence = sequence;
    frame
}

/// A quiet link gives up its thread to the shared poller, and the surface's
/// reader learns it may park; the next frame starts a thread again and
/// arrives in order, and so does the end of the stream.
#[cfg(unix)]
#[test]
fn a_quiet_link_parks_and_its_next_frame_wakes_it() {
    let (frames, mut host) = parking_link("hf-park-wake");
    wait_until("the link to park", || frames.queue.state.lock().unwrap().link_parked);
    #[cfg(target_os = "linux")]
    wait_until("the link thread to end", || threads_named("hf-park-wake") == 0);
    assert!(matches!(frames.recv(), HostFrame::Idle), "a parked empty link reads as Idle");

    for sequence in 1..=3 {
        crate::terminal_host_protocol::write_frame(&mut host, &output(sequence, b"x")).unwrap();
    }
    for sequence in 1..=3 {
        let mut next = frames.recv();
        while matches!(next, HostFrame::Idle) {
            std::thread::sleep(Duration::from_millis(1));
            next = frames.recv();
        }
        let HostFrame::Frame(frame) = next else { panic!("the stream ended") };
        assert_eq!(frame.sequence, sequence);
    }
    // It parks again, and its end still reaches the surface's reader.
    wait_until("the link to park again", || frames.queue.state.lock().unwrap().link_parked);
    drop(host);
    wait_until("the end", || matches!(frames.recv(), HostFrame::End));
}

/// The surface's reader parks behind a parked link and is resumed, on a
/// thread of its own, by the next frame.
#[cfg(unix)]
#[test]
fn a_parked_consumer_resumes_with_the_next_frame() {
    let (frames, mut host) = parking_link("hf-park-consumer");
    wait_until("the link to park", || frames.queue.state.lock().unwrap().link_parked);
    let (resumed_tx, resumed_rx) = std::sync::mpsc::channel();
    frames
        .consumer_slot()
        .park(resumed_tx, |tx| {
            let _ = tx.send(std::thread::current().name().map(str::to_owned));
        })
        .unwrap_or_else(|_| panic!("the consumer did not park"));
    assert!(resumed_rx.try_recv().is_err(), "the consumer resumed with nothing to read");
    crate::terminal_host_protocol::write_frame(&mut host, &output(1, b"wake")).unwrap();
    resumed_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the frame did not resume the consumer");
    let HostFrame::Frame(frame) = frames.recv() else { panic!("the frame was not queued") };
    assert_eq!(frame.payload, b"wake");
}

/// A consumer cannot park while a frame waits or the link reads.
#[cfg(unix)]
#[test]
fn a_consumer_does_not_park_past_a_queued_frame() {
    let (frames, mut host) = parking_link("hf-park-refuse");
    crate::terminal_host_protocol::write_frame(&mut host, &output(1, b"queued")).unwrap();
    wait_until("the frame to queue", || frames.queued_frames_for_test() == 1);
    assert!(frames.consumer_slot().park((), |()| {}).is_err());
}

/// A link dropped while parked with a reply still owed is resumed by the
/// shared poller at the drain deadline and ends, failing the waiter, as a
/// reading link's read timeout ended it.
#[cfg(unix)]
#[test]
fn a_parked_link_dropped_with_a_reply_owed_ends_at_the_deadline() {
    let (client, _host) = std::os::unix::net::UnixStream::pair().unwrap();
    let responses = Arc::new(ControlResponses::new_for_test());
    let frames = HostFrames::spawn_parking_after(
        "hf-park-drain".into(),
        client,
        responses.clone(),
        version(),
        true,
        Duration::from_millis(50),
    )
    .unwrap();
    let queue = frames.queue.clone();
    wait_until("the link to park", || {
        let state = queue.state.lock().unwrap();
        state.link_parked && state.parked_link.is_some()
    });
    let owed = responses.wait_for_test(5, MessageKind::Capability);
    let dropped = std::time::Instant::now();
    drop(frames);
    wait_until("the drained link to end", || {
        !responses.has_waiter_where(|_| true) && !queue.state.lock().unwrap().link_parked
    });
    assert!(dropped.elapsed() < CONTROL_RESPONSE_TIMEOUT + Duration::from_secs(5));
    drop(owed);
}
