//! One rescue terminal's channel state: the shared credit rule
//! (`SendWindow`, `ReceiveWindow`) and the frames for the session host.
//! The rescue backend (`super::backend`) is its only writer.

use cmux_terminal_iface::{End, FrameBody, Lost, ReceiveWindow, SendWindow};
use std::collections::VecDeque;

/// Largest output data frame (the session host splits input the same way).
const MAX_FRAME_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Status {
    Open,
    /// The far end ended; its output that waits for credit goes first, then
    /// the one `end`. Only `out` credit is accepted.
    Ending,
    /// The `end` frame is queued or was taken.
    Ended,
    /// The session host closed the terminal: nothing more is delivered.
    Closed,
}

pub(super) struct Stream {
    pub(super) status: Status,
    /// Input from the session host (direction `in`).
    pub(super) input: ReceiveWindow,
    /// Output to the session host (direction `out`).
    output: SendWindow,
    /// Output chunks that wait for `out` credit, in order.
    ///
    /// TODO(credit): the transport has no backpressure, so a host that
    /// grants no credit lets this grow (as the old drained event list did).
    /// It is bounded when the `cloud.shell.open` stream (transport.rs) can
    /// stop reading.
    held: VecDeque<Vec<u8>>,
    /// Frames for the session host, not taken yet.
    frames: Vec<FrameBody>,
    /// The `end` that follows the held output (status `Ending`).
    end: Option<End>,
    /// The transport stream is closed or gone: never close it again.
    pub(super) released: bool,
}

impl Stream {
    pub(super) fn new(window_bytes: u32) -> Self {
        Self {
            status: Status::Open,
            input: ReceiveWindow::new(window_bytes),
            output: SendWindow::new(window_bytes),
            held: VecDeque::new(),
            frames: Vec::new(),
            end: None,
            released: false,
        }
    }

    /// Output from the far end (open streams only; no empty data frames).
    pub(super) fn output(&mut self, bytes: Vec<u8>) {
        if self.status == Status::Open && !bytes.is_empty() {
            self.held.push_back(bytes);
        }
    }

    /// The far end ended: the one `end` follows the output already received.
    pub(super) fn finish(&mut self, end: End) {
        if self.status == Status::Open {
            self.status = Status::Ending;
            self.end = Some(end);
            self.flush();
        }
    }

    /// A protocol violation (`gap`, `overlap`, `credit`): the channel ends
    /// at once with `lost`; held output is dropped.
    pub(super) fn violate(&mut self, lost: Lost) {
        self.held.clear();
        self.end = None;
        self.status = Status::Ended;
        self.frames.push(FrameBody::End(End::Lost(lost)));
    }

    /// `out` credit from the session host. Too much credit is a violation.
    pub(super) fn grant(&mut self, bytes: u32) {
        match self.output.grant(bytes) {
            Ok(()) => self.flush(),
            Err(lost) => self.violate(lost),
        }
    }

    /// A frame for the session host (an `in` credit grant).
    pub(super) fn queue(&mut self, frame: FrameBody) {
        self.frames.push(frame);
    }

    /// Moves held output into data frames within the `out` credit; after the
    /// last held byte of an ending stream, queues its `end`.
    pub(super) fn flush(&mut self) {
        while let Some(chunk) = self.held.front_mut() {
            let room = usize::try_from(self.output.available()).unwrap_or(usize::MAX);
            let n = room.min(chunk.len()).min(MAX_FRAME_BYTES);
            if n == 0 {
                break;
            }
            let rest = chunk.split_off(n);
            let bytes = std::mem::replace(chunk, rest);
            if chunk.is_empty() {
                self.held.pop_front();
            }
            // `n` is within the credit, so the send is never refused.
            let Ok(frame) = self.output.send(bytes) else { break };
            self.frames.push(frame);
        }
        if self.held.is_empty()
            && self.status == Status::Ending
            && let Some(end) = self.end.take()
        {
            self.status = Status::Ended;
            self.frames.push(FrameBody::End(end));
        }
    }

    pub(super) fn take(&mut self) -> Vec<FrameBody> {
        self.flush();
        std::mem::take(&mut self.frames)
    }

    /// The session host closed the terminal: undelivered output is dropped.
    pub(super) fn close(&mut self) {
        self.status = Status::Closed;
        self.held.clear();
        self.frames.clear();
        self.end = None;
    }
}
