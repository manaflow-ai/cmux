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
//! no state the output path needs, so the thread resolves them as they arrive.
//! Every other frame, including responses that must stay ordered with output
//! (`ClearHistoryAck` applies a replay; resize and cell-pixel responses
//! follow the output they fence), goes to the surface's reader in stream order
//! through a queue bounded by payload bytes. When the queue is full the thread
//! stops reading, which keeps the host's backpressure.

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
    receiver_gone: bool,
}

struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

/// The surface side of one connection's demultiplexer.
pub(super) struct HostFrames {
    queue: Arc<Queue>,
    /// A handle on the reader thread's socket, shut down for reading when the
    /// connection is abandoned so the thread's blocked read returns and the
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
    ) -> std::io::Result<Self> {
        let shutdown = stream.try_clone()?;
        let queue =
            Arc::new(Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() });
        let thread_queue = queue.clone();
        std::thread::Builder::new().name(name).spawn(move || {
            read_stream(stream, &control_responses, protocol_version, &thread_queue);
        })?;
        Ok(Self { queue, shutdown })
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
}

impl Drop for HostFrames {
    fn drop(&mut self) {
        let _ = self.shutdown.shutdown(std::net::Shutdown::Read);
        let mut state = self.queue.state.lock().unwrap();
        state.receiver_gone = true;
        state.frames.clear();
        state.queued_payload = 0;
        self.queue.changed.notify_all();
    }
}

/// Whether `frame` is a response the output path never needs, resolved as
/// soon as it arrives.
fn resolves_early(frame: &Frame, protocol_version: u16) -> bool {
    matches!(frame.kind, MessageKind::InputAck | MessageKind::TerminateAck)
        && frame.request_id != 0
        && frame.version == protocol_version
        && frame.flags == 0
        && frame.sequence == 0
}

fn read_stream(
    mut stream: impl Read,
    control_responses: &ControlResponses,
    protocol_version: u16,
    queue: &Queue,
) {
    while let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) {
        if resolves_early(&frame, protocol_version) {
            // An ack nobody waits for ends the connection, as it did when
            // the surface's reader resolved it inline.
            if !control_responses.resolve_after(&frame, || {}) {
                break;
            }
            continue;
        }
        let mut state = queue.state.lock().unwrap();
        while !state.receiver_gone
            && !state.frames.is_empty()
            && state.queued_payload + frame.payload.len() > QUEUED_PAYLOAD_BUDGET
        {
            state = queue.changed.wait(state).unwrap();
        }
        if state.receiver_gone {
            return;
        }
        state.queued_payload += frame.payload.len();
        state.frames.push_back(HostFrame::Frame(frame));
        queue.changed.notify_all();
    }
    let mut state = queue.state.lock().unwrap();
    state.ended = true;
    queue.changed.notify_all();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(kind: MessageKind, request_id: u64, version: u16) -> Frame {
        let mut frame = Frame::new(kind, Vec::new());
        frame.request_id = request_id;
        frame.version = version;
        frame
    }

    #[test]
    fn only_valid_input_and_terminate_acks_resolve_early() {
        let version = Frame::new(MessageKind::InputAck, Vec::new()).version;
        assert!(resolves_early(&frame(MessageKind::InputAck, 7, version), version));
        assert!(resolves_early(&frame(MessageKind::TerminateAck, 7, version), version));
        assert!(!resolves_early(&frame(MessageKind::InputAck, 0, version), version));
        assert!(!resolves_early(&frame(MessageKind::ClearHistoryAck, 7, version), version));
        assert!(!resolves_early(&frame(MessageKind::ResizeAck, 7, version), version));
        assert!(!resolves_early(
            &frame(MessageKind::InputAck, 7, version.wrapping_add(1)),
            version
        ));
    }
}
