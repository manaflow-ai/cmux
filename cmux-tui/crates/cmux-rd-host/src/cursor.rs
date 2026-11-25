//! The remote cursor as metadata (cap `cursor`, cmux-rd-proto `cursor`): a desktop opened
//! with cursor metadata leaves the cursor out of its pictures and reports it through
//! [`crate::desktop::Desktop::cursor`]; [`CursorChannel`] turns those readings into
//! `CursorPos` datagrams (latest wins) and one `cursor_shape` control message per new
//! shape. The viewer then wears the shape on its own pointer: one cursor, no round trip.

use crate::wire::Control;
use cmux_rd_proto::{base64_encode, shape_id, CursorPos};

/// One cursor shape in stream pixels: premultiplied RGBA8, rows top first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorImage {
    pub width: u32,
    pub height: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    pub rgba: Vec<u8>,
}

impl CursorImage {
    /// The shape's id ([`shape_id`]).
    pub fn id(&self) -> u32 {
        shape_id(self.width, self.height, self.hot_x, self.hot_y, &self.rgba)
    }
}

/// One reading of the desktop's cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorSample {
    /// The hotspot in stream pixels (outside the frame on another display).
    pub x: i32,
    pub y: i32,
    pub visible: bool,
    /// The id of the shape it wears (0 when the desktop cannot read shapes).
    pub shape: u32,
    /// The shape's pixels, when they differ from the previous sample's (a desktop reads
    /// and hashes a shape only when its source says it changed).
    pub image: Option<CursorImage>,
}

/// Between samples while the cursor moves (or moved in the last [`ACTIVE_US`]): a 120 Hz
/// display's frame interval, so the viewer's overlay never trails the picture by more.
const FAST_POLL_US: u64 = 8_000;
/// Between samples once the cursor has been still for [`ACTIVE_US`]: a shape that changes
/// under a still pointer (a busy app, a hover) still arrives within 100 ms.
const IDLE_POLL_US: u64 = 100_000;
/// How long after a change the channel keeps sampling fast.
const ACTIVE_US: u64 = 1_000_000;
/// A changed position is sent again this much later, once, if nothing newer came: the
/// latest datagram may be the one a lossy path drops.
const REPEAT_US: u64 = 60_000;
/// An unchanged position is sent again this often (a viewer that joined late, a loss).
const KEEPALIVE_US: u64 = 1_000_000;
/// Shapes the channel remembers having sent; past it the oldest is sent again when seen.
const SENT_SHAPES: usize = 64;

/// What one sample asks the session to send, in order: the shape first (control), then
/// the position (datagram).
#[derive(Debug, Default)]
pub struct CursorOut {
    pub shape: Option<Control>,
    pub datagram: Option<Vec<u8>>,
}

/// The cursor stream of one session.
#[derive(Debug, Default)]
pub struct CursorChannel {
    seq: u32,
    last: Option<CursorPos>,
    sent_shapes: std::collections::VecDeque<u32>,
    next_poll_us: u64,
    last_change_us: u64,
    last_send_us: u64,
    repeat_due: bool,
}

impl CursorChannel {
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether the session should read the cursor now.
    pub fn due(&self, now_us: u64) -> bool {
        now_us >= self.next_poll_us
    }

    /// When the session should read the cursor next.
    pub fn next_deadline_us(&self) -> u64 {
        self.next_poll_us
    }

    /// The desktop could not read the cursor this time: try again at the slow rate.
    pub fn missed(&mut self, now_us: u64) {
        self.next_poll_us = now_us + IDLE_POLL_US;
    }

    /// Takes one reading; returns what to send.
    pub fn on_sample(&mut self, sample: &CursorSample, now_us: u64) -> CursorOut {
        let mut out = CursorOut::default();
        if let Some(image) = &sample.image {
            let id = if sample.shape == 0 { image.id() } else { sample.shape };
            if !self.sent_shapes.contains(&id) {
                if self.sent_shapes.len() == SENT_SHAPES {
                    self.sent_shapes.pop_front();
                }
                self.sent_shapes.push_back(id);
                out.shape = Some(Control::CursorShape {
                    shape: id,
                    width: image.width,
                    height: image.height,
                    hot_x: image.hot_x,
                    hot_y: image.hot_y,
                    rgba: base64_encode(&image.rgba),
                });
            }
        }
        let pos =
            CursorPos { shape: sample.shape, x: sample.x, y: sample.y, visible: sample.visible };
        let changed = self.last != Some(pos);
        let send = changed
            || (self.repeat_due && now_us >= self.last_send_us + REPEAT_US)
            || now_us >= self.last_send_us + KEEPALIVE_US;
        if changed {
            self.last_change_us = now_us;
            self.repeat_due = true;
        } else if send {
            self.repeat_due = false;
        }
        if send {
            self.seq = self.seq.wrapping_add(1);
            self.last = Some(pos);
            self.last_send_us = now_us;
            out.datagram = Some(pos.datagram(self.seq));
        }
        let active = now_us < self.last_change_us + ACTIVE_US;
        self.next_poll_us = now_us + if active { FAST_POLL_US } else { IDLE_POLL_US };
        out
    }
}

#[cfg(test)]
#[path = "cursor_tests.rs"]
mod tests;
