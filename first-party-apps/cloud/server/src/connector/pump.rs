//! The C13 pump of one connector link: a pure state machine between the
//! link's carrier socket (the viewer protocol stream) and the host's
//! `data`/`credit`/`end` frames (`dataPlane` of `cmux.terminal.connector/1`).
//! It does no I/O and never waits: the caller reads the carrier only up to
//! [`Pump::read_budget`], writes what [`Pump::take_carrier_bytes`] gives,
//! reports the bytes the carrier took, and sends [`Pump::take_frames`].
//!
//! Credit (the one rule, [`SendWindow`] and [`ReceiveWindow`]):
//! - out (carrier to host): the carrier is read only inside the host's
//!   credit, so a slow host stops the carrier read (backpressure).
//! - in (host to carrier): credit is granted only for bytes the carrier
//!   took, so host bytes held here (queued or being written) never pass one
//!   window. Data past the credit ends the channel with lost `credit`; a
//!   gap or an overlap ends it with lost `gap` or `overlap`.
//!
//! Each channel ends once: the first of a carrier end, a violation or a
//! close queues the one `end` after the last data; an `end` from the host
//! ends the channel with no `end` back.

use cmux_terminal_iface::{
    BackendError, Direction, End, FrameBody, Lost, ReceiveWindow, SendWindow, check_window,
};

/// The largest `data` frame the pump sends (the host's frame size).
pub const MAX_DATA_FRAME: usize = 64 * 1024;

/// One link's pump.
#[derive(Debug)]
pub struct Pump {
    /// Carrier to host.
    out: SendWindow,
    /// Host to carrier.
    inn: ReceiveWindow,
    /// Host bytes not handed to the carrier yet.
    to_carrier: Vec<u8>,
    /// Host bytes handed to the carrier and not reported written yet.
    in_flight: u64,
    frames: Vec<FrameBody>,
    ended: bool,
}

impl Pump {
    /// A new channel with the open answer's `window_bytes` in each
    /// direction; a window outside 64 KiB to 1 MiB is `invalid`.
    pub fn new(window_bytes: u32) -> Result<Self, BackendError> {
        let window = check_window(window_bytes)?;
        Ok(Self {
            out: SendWindow::new(window),
            inn: ReceiveWindow::new(window),
            to_carrier: Vec::new(),
            in_flight: 0,
            frames: Vec::new(),
            ended: false,
        })
    }

    /// The channel ended (its `end` is queued or the host ended it).
    pub fn is_ended(&self) -> bool {
        self.ended
    }

    /// Bytes the carrier may be read for now: the out credit, at most one
    /// frame. Zero after the end or when the credit is spent.
    pub fn read_budget(&self) -> usize {
        if self.ended {
            return 0;
        }
        usize::try_from(self.out.available()).unwrap_or(usize::MAX).min(MAX_DATA_FRAME)
    }

    /// Bytes read from the carrier become one `data` frame. More than
    /// [`Self::read_budget`] is `invalid` and takes nothing; after the end
    /// nothing is accepted.
    pub fn from_carrier(&mut self, bytes: Vec<u8>) -> Result<(), BackendError> {
        if self.ended {
            return Err(BackendError::not_open());
        }
        if bytes.is_empty() {
            return Ok(());
        }
        if bytes.len() > self.read_budget() {
            return Err(BackendError::invalid("the carrier was read past the out credit"));
        }
        let frame = self.out.send(bytes)?;
        self.frames.push(frame);
        Ok(())
    }

    /// One frame from the host. A protocol violation is handled here (the
    /// channel ends with its `lost`), so only a frame after the end is an
    /// error.
    pub fn push(&mut self, frame: FrameBody) -> Result<(), BackendError> {
        if self.ended {
            return Err(BackendError::not_open());
        }
        match frame {
            FrameBody::Data { offset, bytes } => match self.inn.receive(offset, bytes.len()) {
                Ok(()) => self.to_carrier.extend_from_slice(&bytes),
                Err(lost) => self.lose(lost),
            },
            FrameBody::Credit { direction: Direction::Out, bytes } => {
                if let Err(lost) = self.out.grant(bytes) {
                    self.lose(lost);
                }
            }
            // The host grants only the bytes this side sends (out).
            FrameBody::Credit { direction: Direction::In, .. } => {
                self.lose(Lost::new("credit direction", false));
            }
            FrameBody::End(_) => {
                self.ended = true;
                self.to_carrier.clear();
            }
        }
        Ok(())
    }

    /// Host bytes for the carrier, once each; nothing after the end.
    pub fn take_carrier_bytes(&mut self) -> Vec<u8> {
        if self.ended {
            return Vec::new();
        }
        let bytes = std::mem::take(&mut self.to_carrier);
        self.in_flight += bytes.len() as u64;
        bytes
    }

    /// The carrier took `bytes` of what [`Self::take_carrier_bytes`] gave:
    /// the host gets that much `in` credit. More than was given is `invalid`.
    pub fn carrier_wrote(&mut self, bytes: u64) -> Result<(), BackendError> {
        if bytes > self.in_flight {
            return Err(BackendError::invalid("the carrier wrote more than it was given"));
        }
        self.in_flight -= bytes;
        if self.ended || bytes == 0 {
            return Ok(());
        }
        if let Some(credit) = self.inn.consume(Direction::In, bytes)? {
            self.frames.push(credit);
        }
        Ok(())
    }

    /// The carrier ended (end of stream or an error): the channel ends with
    /// `lost` after the data already queued.
    pub fn carrier_closed(&mut self, lost: Lost) {
        self.lose(lost);
    }

    /// This side ends the channel (the host asked for a close).
    pub fn close(&mut self, lost: Lost) {
        self.lose(lost);
    }

    /// Frames for the host since the last call, in order; the `end` last.
    pub fn take_frames(&mut self) -> Vec<FrameBody> {
        std::mem::take(&mut self.frames)
    }

    fn lose(&mut self, lost: Lost) {
        if std::mem::replace(&mut self.ended, true) {
            return;
        }
        self.to_carrier.clear();
        self.frames.push(FrameBody::End(End::Lost(lost)));
    }
}
