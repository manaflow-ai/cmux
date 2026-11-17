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
mod tests {
    use super::*;

    fn sample(x: i32, image: Option<CursorImage>) -> CursorSample {
        let shape = image.as_ref().map_or(7, CursorImage::id);
        CursorSample { x, y: 10, visible: true, shape, image }
    }

    fn arrow() -> CursorImage {
        CursorImage {
            width: 1,
            height: 2,
            hot_x: 0,
            hot_y: 0,
            rgba: vec![0, 0, 0, 255, 255, 255, 255, 255],
        }
    }

    #[test]
    fn a_new_shape_goes_once_before_its_first_position() {
        let mut ch = CursorChannel::new();
        let out = ch.on_sample(&sample(1, Some(arrow())), 0);
        let Some(Control::CursorShape { shape, width, height, rgba, .. }) = out.shape else {
            panic!("no shape");
        };
        assert_eq!((shape, width, height), (arrow().id(), 1, 2));
        assert_eq!(cmux_rd_proto::base64_decode(&rgba), Some(arrow().rgba));
        let (seq, pos) =
            CursorPos::from_datagram(&out.datagram.expect("position")).expect("decode");
        assert_eq!((seq, pos.shape, pos.x), (1, shape, 1));
        // The same shape again, as a desktop reports it after another shape came between.
        let again = ch.on_sample(&sample(2, Some(arrow())), 1_000);
        assert!(again.shape.is_none());
        assert!(again.datagram.is_some());
    }

    #[test]
    fn a_still_cursor_is_repeated_once_then_kept_alive_and_polled_slowly() {
        let mut ch = CursorChannel::new();
        assert!(ch.on_sample(&sample(1, None), 0).datagram.is_some());
        assert_eq!(ch.next_deadline_us(), FAST_POLL_US);
        // Unchanged before the repeat: nothing.
        assert!(ch.on_sample(&sample(1, None), 8_000).datagram.is_none());
        // The one repeat.
        let repeat = ch.on_sample(&sample(1, None), REPEAT_US).datagram.expect("repeat");
        assert_eq!(CursorPos::from_datagram(&repeat).expect("decode").0, 2);
        assert!(ch.on_sample(&sample(1, None), REPEAT_US + 100_000).datagram.is_none());
        // Still for a second: slow polls, then a keepalive.
        ch.on_sample(&sample(1, None), ACTIVE_US + 1);
        assert_eq!(ch.next_deadline_us(), ACTIVE_US + 1 + IDLE_POLL_US);
        assert!(ch.on_sample(&sample(1, None), REPEAT_US + KEEPALIVE_US).datagram.is_some());
    }

    #[test]
    fn every_change_is_sent_with_a_newer_sequence() {
        let mut ch = CursorChannel::new();
        let mut last = 0;
        for (i, x) in [1, 2, 3, 3, 4].into_iter().enumerate() {
            let now = i as u64 * 1_000;
            if let Some(d) = ch.on_sample(&sample(x, None), now).datagram {
                let (seq, pos) = CursorPos::from_datagram(&d).expect("decode");
                assert!(cmux_rd_proto::cursor_seq_newer(seq, last));
                assert_eq!(pos.x, x);
                last = seq;
            }
        }
        assert_eq!(last, 4, "the unchanged reading sent nothing");
        let hidden = CursorSample { visible: false, ..sample(4, None) };
        assert!(ch.on_sample(&hidden, 5_000).datagram.is_some(), "visibility is a change");
    }

    #[test]
    fn the_sent_shape_memory_is_bounded() {
        let mut ch = CursorChannel::new();
        for i in 0..(SENT_SHAPES as u32 + 1) {
            let image = CursorImage { hot_x: i, ..arrow() };
            assert!(ch.on_sample(&sample(1, Some(image)), u64::from(i)).shape.is_some());
        }
        // The first one was forgotten: seen again, it is sent again.
        assert!(ch.on_sample(&sample(1, Some(arrow())), 100).shape.is_some());
    }
}
