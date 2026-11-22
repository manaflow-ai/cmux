//! The session host's side of one byte-terminal channel, for the rescue
//! tests: input goes out as data frames within the `in` credit, output
//! frames are checked with the shared `ReceiveWindow` (a gap, an overlap or
//! data past the credit fails the test), and `out` credit is granted as the
//! host reads, the way the daemon's channel table does.

#![allow(dead_code)]

use cmux_terminal_iface::{
    BackendError, ByteTerminal, Direction, End, ExitStatus, FrameBody, Lost, ReceiveWindow,
    SendWindow,
};

/// The largest data frame the host sends.
pub const MAX_FRAME: usize = 64 * 1024;

pub struct Host {
    pub terminal: Box<dyn ByteTerminal>,
    input: SendWindow,
    output: ReceiveWindow,
    /// Grant `out` credit for output as it is taken (false: a host that
    /// reads nothing back yet).
    pub grant: bool,
    /// Output received and not credited yet.
    unconsumed: u64,
}

impl Host {
    pub fn new(terminal: Box<dyn ByteTerminal>) -> Self {
        let window = terminal.window_bytes();
        Self {
            terminal,
            input: SendWindow::new(window),
            output: ReceiveWindow::new(window),
            grant: true,
            unconsumed: 0,
        }
    }

    /// One input data frame within the `in` credit.
    pub fn write(&mut self, bytes: &[u8]) -> Result<(), BackendError> {
        let frame = self.input.send(bytes.to_vec())?;
        self.terminal.push(frame)
    }

    /// One frame as given (offsets and credit unchecked).
    pub fn push(&mut self, frame: FrameBody) -> Result<(), BackendError> {
        self.terminal.push(frame)
    }

    /// The `offset` the next input frame of `len` bytes must carry.
    pub fn next_offset(&self, len: usize) -> u64 {
        self.input.offset() + len as u64
    }

    /// Frames since the last call: output data is checked and (with
    /// `grant`) credited, `in` credit is applied.
    pub fn take(&mut self) -> Vec<FrameBody> {
        let frames = self.terminal.take_frames();
        for frame in &frames {
            match frame {
                FrameBody::Data { offset, bytes } => {
                    assert!(!bytes.is_empty(), "a data frame carries bytes");
                    let checked = self.output.receive(*offset, bytes.len());
                    assert_eq!(checked, Ok(()), "output at {offset}");
                    self.unconsumed += bytes.len() as u64;
                }
                FrameBody::Credit { direction, bytes } => {
                    assert_eq!(*direction, Direction::In, "the backend grants only `in` credit");
                    assert_eq!(self.input.grant(*bytes), Ok(()), "`in` credit within the window");
                }
                FrameBody::End(_) => {}
            }
        }
        if self.grant {
            self.consume();
        }
        frames
    }

    /// Credits every byte of output received so far.
    pub fn consume(&mut self) {
        let bytes = std::mem::take(&mut self.unconsumed);
        let credit = self.output.consume(Direction::Out, bytes).expect("consume");
        if let Some(credit) = credit {
            // A terminal that ended refuses credit; the test reads the end.
            let _ended = self.terminal.push(credit);
        }
    }
}

/// The output bytes in `frames`, in order.
pub fn output(frames: &[FrameBody]) -> Vec<u8> {
    let mut out = Vec::new();
    for frame in frames {
        if let FrameBody::Data { bytes, .. } = frame {
            out.extend_from_slice(bytes);
        }
    }
    out
}

/// The offset after the last output frame in `frames`.
pub fn last_offset(frames: &[FrameBody]) -> Option<u64> {
    frames.iter().rev().find_map(|f| match f {
        FrameBody::Data { offset, .. } => Some(*offset),
        _ => None,
    })
}

/// The `end` frame in `frames`, if there is one.
pub fn end(frames: &[FrameBody]) -> Option<&End> {
    frames.iter().find_map(|f| match f {
        FrameBody::End(end) => Some(end),
        _ => None,
    })
}

pub fn exit(status: ExitStatus) -> FrameBody {
    FrameBody::End(End::Exit(status))
}

pub fn lost(reason: &str, retryable: bool) -> FrameBody {
    FrameBody::End(End::Lost(Lost::new(reason, retryable)))
}

pub fn not_open(result: Result<(), BackendError>) -> bool {
    matches!(result, Err(BackendError::Invalid { .. }))
}
