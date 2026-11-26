//! The host's cursor image on a screen stream (ScreenCursorShape.swift and
//! the cursor delivery in ScreenStream.swift): the shape's id, whether a
//! viewer can draw it, the viewer's `caps`, and which shape messages the
//! host still has to send. Reading and decoding the image stay Swift.

use serde::{Deserialize, Serialize};

use crate::geometry::Rect;

/// The longest side the host sends.
pub const MAX_SIDE: i64 = 256;
/// The shadow macOS draws under every cursor: opacity, blur, offset down (points).
pub const SHADOW: (f64, f64, f64) = (0.45, 2.0, 1.0);

pub const CAPABILITIES_TYPE: &str = "caps";
pub const CURSOR_SHAPE_TYPE: &str = "cursor";
pub const TELEPOINTERS_CAPABILITY: &str = "telepointers";
pub const CURSOR_SHAPE_CAPABILITY: &str = "cursor-shape";

/// Host → viewer `cursor`: sizes are fractions of the streamed display, the
/// hotspot a fraction of the cursor; `pw`, `ph` its size in points.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CursorShape {
    pub id: String,
    /// Base64 PNG, straight alpha.
    pub png: String,
    pub w: f64,
    pub h: f64,
    pub hx: f64,
    pub hy: f64,
    pub pw: f64,
    pub ph: f64,
}

/// A shape's id: FNV-1a 64 over its PNG, then the little endian bits of the
/// hotspot's x and y as doubles, in lowercase hex without padding.
pub fn shape_id(png: &[u8], hotspot_x: f64, hotspot_y: f64) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut mix = |byte: u8| {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    };
    png.iter().copied().for_each(&mut mix);
    for value in [hotspot_x, hotspot_y] {
        value.to_bits().to_le_bytes().into_iter().for_each(&mut mix);
    }
    format!("{hash:x}")
}

impl CursorShape {
    /// Whether the sizes and hotspot are ones a viewer can draw.
    pub fn is_drawable(&self) -> bool {
        let fraction = |v: f64| v.is_finite() && v > 0.0 && v <= 1.0;
        let hotspot = |v: f64| v.is_finite() && (0.0..=1.0).contains(&v);
        fraction(self.w)
            && fraction(self.h)
            && hotspot(self.hx)
            && hotspot(self.hy)
            && self.pw.is_finite()
            && self.ph.is_finite()
            && self.pw > 0.0
            && self.ph > 0.0
    }

    /// The ordered `cursor` message carrying this shape.
    pub fn message(&self) -> String {
        #[derive(Serialize)]
        struct Message<'a> {
            t: &'static str,
            cursor: &'a CursorShape,
        }
        serde_json::to_string(&Message { t: CURSOR_SHAPE_TYPE, cursor: self }).unwrap_or_default()
    }
}

/// The capabilities a viewer's message names: its `s` split on commas,
/// trimmed; none unless `t` is `caps`.
pub fn viewer_capabilities(t: &str, s: Option<&str>) -> Vec<String> {
    if t != CAPABILITIES_TYPE {
        return Vec::new();
    }
    s.unwrap_or("").split(',').map(|c| c.trim_matches([' ', '\t']).to_owned()).collect()
}

/// Whether a viewer's `caps` says it draws pointers itself.
pub fn viewer_draws_pointers(t: &str, s: Option<&str>) -> bool {
    viewer_capabilities(t, s).iter().any(|c| c == TELEPOINTERS_CAPABILITY)
}

/// Whether a viewer's `caps` says it draws the Mac's cursor image (only
/// beside telepointers).
pub fn viewer_draws_cursor_shapes(t: &str, s: Option<&str>) -> bool {
    let caps = viewer_capabilities(t, s);
    caps.iter().any(|c| c == TELEPOINTERS_CAPABILITY)
        && caps.iter().any(|c| c == CURSOR_SHAPE_CAPABILITY)
}

/// The shape ids a host remembers sending, newest last: a shape that left
/// it is sent again.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SentCursorShapes {
    pub ids: Vec<String>,
}

impl SentCursorShapes {
    pub const CAPACITY: usize = 64;

    /// Records `id`; true when the viewer needs it sent first.
    pub fn needs_send(&mut self, id: &str) -> bool {
        if let Some(index) = self.ids.iter().position(|i| i == id) {
            let id = self.ids.remove(index);
            self.ids.push(id);
            return false;
        }
        self.ids.push(id.to_owned());
        if self.ids.len() > Self::CAPACITY {
            let extra = self.ids.len() - Self::CAPACITY;
            self.ids.drain(..extra);
        }
        true
    }

    pub fn reset(&mut self) {
        self.ids.clear();
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PendingShape {
    pub id: String,
    pub text: String,
}

/// The ordered cursor messages and the last shape the link accepted. A
/// refused send keeps its payload for the next sample, and a fresh shape
/// supersedes an unsent one.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CursorShapeDelivery {
    pub sent: SentCursorShapes,
    pub shape: Option<String>,
    pub display: Option<Rect>,
    pub pending: Option<PendingShape>,
}

impl CursorShapeDelivery {
    /// Step one of a sample: takes what the reader saw (`None`: unchanged)
    /// on `display`, and returns the message to try sending, if any.
    pub fn prepare(&mut self, read: Option<&CursorShape>, display: Rect) -> Option<String> {
        if self.display != Some(display) {
            // Sizes are fractions of the display: another display's shapes are new ones.
            self.display = Some(display);
            self.sent.reset();
            self.shape = None;
            self.pending = None;
        }
        if let Some(read) = read {
            if self.sent.ids.contains(&read.id) {
                self.sent.needs_send(&read.id);
                self.pending = None;
                self.shape = Some(read.id.clone());
            } else {
                self.pending = Some(PendingShape { id: read.id.clone(), text: read.message() });
            }
        }
        self.pending.as_ref().map(|p| p.text.clone())
    }

    /// Step two: whether the link took the prepared message. Returns the id
    /// the telepointers name now.
    pub fn finish(&mut self, delivered: bool) -> Option<String> {
        if delivered {
            if let Some(pending) = self.pending.take() {
                self.sent.needs_send(&pending.id);
                self.shape = Some(pending.id);
            }
        }
        self.shape.clone()
    }

    /// One sample with the send inline, as the Swift host loop runs it.
    pub fn current(
        &mut self,
        read: Option<&CursorShape>,
        display: Rect,
        mut send_text: impl FnMut(&str) -> bool,
    ) -> Option<String> {
        let delivered = match self.prepare(read, display) {
            Some(text) => send_text(&text),
            None => false,
        };
        self.finish(delivered)
    }
}

#[cfg(test)]
#[path = "cursor_shape_tests.rs"]
mod tests;
