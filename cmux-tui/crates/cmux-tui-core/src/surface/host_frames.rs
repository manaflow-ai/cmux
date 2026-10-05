//! Terminal-host stream demultiplexer for one hosted surface connection.
//!
//! The host sends output, snapshots and targeted control responses on one
//! stream. The surface's host reader applies each output frame (VT parse,
//! journal update, render request) before it reads the next frame, so a
//! response queued behind an output backlog used to reach its waiter only
//! after that backlog. A receipted input write or termination request then
//! timed out after `CONTROL_RESPONSE_TIMEOUT` although the host had answered
//! at once.
//!
//! A reader thread now owns the socket. `InputAck` and `TerminateAck` carry
//! no state the output path needs, so the thread resolves them as they
//! arrive. On a smart-renderer connection it also resolves
//! `KittyGraphicsLimitsAck`: a smart host answers a Kitty limits update with
//! `ResyncRequired` and then the acknowledgement, and the surface's reader
//! stops reading the stream at `ResyncRequired`, so only this thread can
//! still deliver it. Older hosts send the replacement replay before the
//! acknowledgement and keep it in output order.
//!
//! Every other frame (including `ClearHistoryAck`, whose replay must stay
//! ordered with output, and resize and cell-pixel responses) goes to the
//! surface's reader in stream order through a queue bounded by payload
//! bytes. When the queue is full the thread stops reading, which keeps the
//! host's backpressure. Once the surface's reader abandons the stream
//! (`abandon`), the thread discards ordered frames instead of queueing them,
//! so a backlog can never delay an acknowledgement it still owes.
//!
//! A `ClipboardReadRequest` from a host that negotiated clipboard reads
//! becomes the connection's pending read and a `ClipboardReadCancel`
//! withdraws it (see `ControlResponses`); from any other host either ends
//! the connection. The end of the stream withdraws a pending read too.
//!
//! Failure ownership: at the end of the stream the thread fails only the
//! waiters it resolves itself; the surface's reader drains the queued frames
//! and then fails the ordered waiters. After `abandon` or a drop, the thread
//! fails every waiter at the end of the stream.

use std::collections::VecDeque;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};

use crate::terminal_host_protocol::{Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame};
use crate::terminal_host_runtime::ControlResponses;

/// Output bytes the reader thread may queue ahead of the surface's reader.
/// One frame is always admitted, however large.
const QUEUED_PAYLOAD_BUDGET: usize = 8 * 1024 * 1024;

/// What the surface's reader receives.
pub(super) enum HostFrame {
    Frame(Frame),
    /// The stream ended, failed to decode, or carried a response that must
    /// end the connection (unknown request, malformed ack).
    End,
}

#[derive(Default)]
struct QueueState {
    frames: VecDeque<HostFrame>,
    queued_payload: usize,
    ended: bool,
    /// The surface's reader no longer reads this queue (`abandon` or drop).
    abandoned: bool,
}

struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

/// Which responses the reader thread resolves itself for one connection.
#[derive(Clone, Copy)]
pub(super) struct EarlyResponses {
    smart_renderer: bool,
}

impl EarlyResponses {
    pub(super) fn new(smart_renderer: bool) -> Self {
        Self { smart_renderer }
    }

    /// Whether the reader thread resolves responses of `kind`.
    pub(super) fn resolves(self, kind: MessageKind) -> bool {
        match kind {
            MessageKind::InputAck | MessageKind::TerminateAck => true,
            MessageKind::KittyGraphicsLimitsAck => self.smart_renderer,
            _ => false,
        }
    }
}

/// The surface side of one connection's demultiplexer.
pub(super) struct HostFrames {
    queue: Arc<Queue>,
    control_responses: Arc<ControlResponses>,
    early: EarlyResponses,
    /// A handle on the reader thread's socket, shut down for reading when the
    /// connection is dropped so the thread's blocked read returns and the
    /// descriptor closes as the plain reader's did.
    shutdown: UnixStream,
}

impl HostFrames {
    /// Start the reader thread for `stream`. `protocol_version` is the
    /// connection's negotiated version; early-resolved acks must carry it.
    pub(super) fn spawn(
        name: String,
        stream: UnixStream,
        control_responses: Arc<ControlResponses>,
        protocol_version: u16,
        smart_renderer: bool,
    ) -> std::io::Result<Self> {
        let early = EarlyResponses::new(smart_renderer);
        let shutdown = stream.try_clone()?;
        let queue =
            Arc::new(Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() });
        let thread_queue = queue.clone();
        let thread_responses = control_responses.clone();
        std::thread::Builder::new().name(name).spawn(move || {
            read_stream(stream, &thread_responses, protocol_version, early, &thread_queue);
        })?;
        Ok(Self { queue, control_responses, early, shutdown })
    }

    /// The next frame in stream order; blocks until one arrives.
    pub(super) fn recv(&self) -> HostFrame {
        let mut state = self.queue.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                if let HostFrame::Frame(frame) = &frame {
                    state.queued_payload -= frame.payload.len();
                }
                self.queue.changed.notify_all();
                return frame;
            }
            if state.ended {
                return HostFrame::End;
            }
            state = self.queue.changed.wait(state).unwrap();
        }
    }

    /// The surface's reader stops reading this stream (for example at
    /// `ResyncRequired`) but the connection may stay open while it
    /// reconnects. Ordered waiters fail now. The thread keeps resolving early
    /// acknowledgements (a Kitty limits acknowledgement follows
    /// ResyncRequired), discards ordered frames, and fails every waiter when
    /// the stream ends.
    pub(super) fn abandon(&self) {
        {
            let mut state = self.queue.state.lock().unwrap();
            state.abandoned = true;
            state.frames.clear();
            state.queued_payload = 0;
            self.queue.changed.notify_all();
        }
        let early = self.early;
        self.control_responses.fail_all_except(|kind| early.resolves(kind));
    }
}

impl Drop for HostFrames {
    fn drop(&mut self) {
        self.abandon();
        let _ = self.shutdown.shutdown(std::net::Shutdown::Read);
    }
}

/// Responses to a request this connection sent, matched by request id; the
/// surface's reader consumes them before live staging.
pub(super) fn is_targeted_host_response(kind: MessageKind) -> bool {
    matches!(
        kind,
        MessageKind::Capability
            | MessageKind::ResizeAck
            | MessageKind::CellPixelSizeAck
            | MessageKind::KittyGraphicsLimitsAck
            | MessageKind::ClearHistoryAck
            | MessageKind::TerminateAck
            | MessageKind::DetachAck
            | MessageKind::InputAck
    )
}

fn resolves_early(frame: &Frame, protocol_version: u16, early: EarlyResponses) -> bool {
    early.resolves(frame.kind)
        && frame.request_id != 0
        && frame.version == protocol_version
        && frame.flags == 0
        && frame.sequence == 0
}

fn read_stream(
    mut stream: impl Read,
    control_responses: &ControlResponses,
    protocol_version: u16,
    early: EarlyResponses,
    queue: &Queue,
) {
    while let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) {
        // A host-originated clipboard read is outside the live sequence and
        // waits for the user, so it never enters the ordered queue.
        if frame.kind == MessageKind::ClipboardReadRequest {
            if control_responses.accept_clipboard_read_request(&frame, protocol_version) {
                continue;
            }
            break;
        }
        if frame.kind == MessageKind::ClipboardReadCancel {
            if control_responses.accept_clipboard_read_cancel(&frame, protocol_version) {
                continue;
            }
            break;
        }
        if resolves_early(&frame, protocol_version, early) {
            // A Kitty limits acknowledgement that arrives after its
            // requester's deadline is advisory: the requester already
            // degraded graphics and must not tear down a healthy connection.
            if frame.kind == MessageKind::KittyGraphicsLimitsAck
                && !control_responses.has_waiter(frame.request_id)
            {
                continue;
            }
            if control_responses.resolve_after(&frame, || {}) {
                continue;
            }
            // Any other acknowledgement nobody waits for, or one whose id
            // belongs to a waiter of another kind, ends the connection, as it
            // did when the surface's reader resolved it inline.
            break;
        }
        let mut state = queue.state.lock().unwrap();
        while !state.abandoned
            && !state.frames.is_empty()
            && state.queued_payload + frame.payload.len() > QUEUED_PAYLOAD_BUDGET
        {
            state = queue.changed.wait(state).unwrap();
        }
        if state.abandoned {
            continue;
        }
        state.queued_payload += frame.payload.len();
        state.frames.push_back(HostFrame::Frame(frame));
        queue.changed.notify_all();
    }
    control_responses.end_clipboard_reads();
    let mut state = queue.state.lock().unwrap();
    if state.abandoned {
        drop(state);
        control_responses.fail_all();
        return;
    }
    // The surface's reader still drains the queued frames, resolves their
    // ordered responses, and fails the rest after `End`.
    control_responses.fail_all_except(|kind| !early.resolves(kind));
    state.ended = true;
    queue.changed.notify_all();
}

#[cfg(test)]
mod tests {
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
        assert!(state.frames.is_empty() && state.queued_payload == 0);
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
}
