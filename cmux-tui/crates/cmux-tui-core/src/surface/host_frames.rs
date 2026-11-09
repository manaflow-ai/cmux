//! Terminal-host stream demultiplexer for one hosted surface connection.
//!
//! The host sends output, snapshots and targeted control responses on one
//! stream. The surface's host reader applies each output frame (VT parse,
//! journal update, render request) before it reads the next frame, so a
//! response queued behind an output backlog used to reach its waiter only
//! after that backlog. A receipted input write or termination request then
//! timed out after `CONTROL_RESPONSE_TIMEOUT` although the host had answered
//! at once (issue #39510).
//!
//! A reader thread now owns the socket. `InputAck`, `TerminateAck` and
//! `Capability` carry no state the output path needs, so the thread resolves
//! them as they arrive. A smart host applies `SetDefaults` by publishing
//! `ResyncRequired` and answers a following `MintCapability` behind it, so a
//! renderer mint right after a default-colors update depends on this thread
//! too. On a smart-renderer connection it also resolves
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
//! Failure ownership: at the end of the stream the thread fails only the
//! waiters it resolves itself; the surface's reader drains the queued frames
//! and then fails the ordered waiters. After `abandon` or a drop, the thread
//! fails every waiter at the end of the stream. A drop while replies it
//! resolves are still owed keeps the stream open until they arrive or time
//! out, so a mint sent just before a reconnect replaced the connection is
//! not lost to the drop's own shutdown.

use std::collections::VecDeque;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use crate::terminal_host_protocol::{Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame};
use crate::terminal_host_runtime::{CONTROL_RESPONSE_TIMEOUT, ControlResponses};

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
    frames: VecDeque<Frame>,
    queued_payload: usize,
    ended: bool,
    /// The surface's reader no longer reads this queue (`abandon` or drop).
    abandoned: bool,
    /// The demultiplexer was dropped with replies still owed: the thread
    /// ends once no waiter it resolves is left, or at this deadline.
    draining: Option<Instant>,
}

struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

/// Which responses the reader thread resolves itself for one connection.
#[derive(Clone, Copy)]
struct EarlyResponses {
    smart_renderer: bool,
}

impl EarlyResponses {
    /// Whether the reader thread resolves responses of `kind`.
    fn resolves(self, kind: MessageKind) -> bool {
        match kind {
            MessageKind::InputAck | MessageKind::TerminateAck | MessageKind::Capability => true,
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
        let early = EarlyResponses { smart_renderer };
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
                state.queued_payload -= frame.payload.len();
                self.queue.changed.notify_all();
                return HostFrame::Frame(frame);
            }
            if state.ended {
                return HostFrame::End;
            }
            state = self.queue.changed.wait(state).unwrap();
        }
    }

    /// The surface's reader stops reading this stream (for example at
    /// `ResyncRequired`) but the connection may stay open while it
    /// reconnects. Ordered waiters fail now. The thread keeps resolving
    /// early acknowledgements (a Kitty limits acknowledgement follows
    /// ResyncRequired), discards ordered frames, and fails every waiter when
    /// the stream ends.
    pub(super) fn abandon(&self) {
        let ended = {
            let mut state = self.queue.state.lock().unwrap();
            state.abandoned = true;
            state.frames.clear();
            state.queued_payload = 0;
            self.queue.changed.notify_all();
            state.ended
        };
        if ended {
            // The thread is gone: nothing would resolve a kept waiter.
            self.control_responses.fail_all();
            return;
        }
        let early = self.early;
        self.control_responses.fail_all_except(|kind| early.resolves(kind));
    }
}

impl Drop for HostFrames {
    /// A reply the host owes on this connection (a renderer mint sent just
    /// before a resync reconnect replaced it) still reaches its waiter: the
    /// thread keeps reading until no waiter it resolves is left or the drain
    /// deadline passes. A waiter that times out shuts the connection down
    /// itself (Kitty limits excepted), which also ends a read already in
    /// progress; the read timeout bounds reads that start later.
    fn drop(&mut self) {
        self.abandon();
        let early = self.early;
        let owed = {
            let mut state = self.queue.state.lock().unwrap();
            let owed = !state.ended
                && self.control_responses.has_waiter_where(|kind| early.resolves(kind));
            if owed {
                state.draining = Some(Instant::now() + CONTROL_RESPONSE_TIMEOUT);
            }
            owed
        };
        if owed && self.shutdown.set_read_timeout(Some(CONTROL_RESPONSE_TIMEOUT)).is_ok() {
            return;
        }
        let _ = self.shutdown.shutdown(std::net::Shutdown::Read);
    }
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
    loop {
        let draining = queue.state.lock().unwrap().draining;
        if draining.is_some_and(|deadline| {
            Instant::now() >= deadline
                || !control_responses.has_waiter_where(|kind| early.resolves(kind))
        }) {
            break;
        }
        let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) else { break };
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
        state.frames.push_back(frame);
        queue.changed.notify_all();
    }
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
    const LEGACY: EarlyResponses = EarlyResponses { smart_renderer: false };

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

    fn output(payload: impl Into<Vec<u8>>, version: u16) -> Frame {
        let mut output = Frame::new(MessageKind::Output, payload.into());
        output.version = version;
        output
    }

    #[test]
    fn early_responses_depend_on_kind_and_renderer() {
        let version = version();
        assert!(resolves_early(&frame(MessageKind::InputAck, 7, version), version, SMART));
        assert!(resolves_early(&frame(MessageKind::TerminateAck, 7, version), version, LEGACY));
        assert!(resolves_early(&frame(MessageKind::Capability, 7, version), version, LEGACY));
        assert!(resolves_early(
            &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
            version,
            SMART
        ));
        assert!(!resolves_early(
            &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
            version,
            LEGACY
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

    /// An InputAck behind queued output reaches its waiter while the output
    /// stays queued, in order, for the surface's reader.
    #[test]
    fn input_ack_behind_output_resolves_on_arrival() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let input = responses.wait_for_test(4, MessageKind::InputAck);
        let queue = queue();
        let stream = stream_of(&[
            output(b"first", version),
            output(b"second", version),
            frame(MessageKind::InputAck, 4, version),
        ]);
        read_stream(stream, &responses, version, LEGACY, &queue);
        assert_eq!(input.recv_timeout(Duration::from_secs(1)).unwrap().kind, MessageKind::InputAck);
        let state = queue.state.lock().unwrap();
        let payloads = state.frames.iter().map(|frame| frame.payload.clone()).collect::<Vec<_>>();
        assert_eq!(payloads, vec![b"first".to_vec(), b"second".to_vec()]);
        assert!(state.ended);
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
    /// ordered waiters; the mint's Capability must still reach its requester.
    #[test]
    fn capability_after_resync_reaches_its_waiter() {
        let version = version();
        for early in [SMART, LEGACY] {
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
        let queued = state.frames.front().expect("the ClearHistoryAck frame was not queued");
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
        let mut frames = vec![output(vec![b'x'; 1024 * 1024], version); 12];
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
        let stream = stream_of(&[
            frame(MessageKind::KittyGraphicsLimitsAck, 4, version),
            output(b"after", version),
        ]);
        read_stream(stream, &responses, version, SMART, &queue);
        let state = queue.state.lock().unwrap();
        assert_eq!(state.frames.len(), 1, "the frame after the late ack was not read");
    }

    /// An InputAck nobody waits for ends the connection, as it did when the
    /// surface's reader resolved it inline.
    #[test]
    fn unknown_input_ack_ends_the_stream() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let queue = queue();
        let stream =
            stream_of(&[frame(MessageKind::InputAck, 8, version), output(b"after", version)]);
        read_stream(stream, &responses, version, LEGACY, &queue);
        let state = queue.state.lock().unwrap();
        assert!(state.ended && state.frames.is_empty(), "the connection must end there");
    }
}
