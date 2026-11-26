//! The remote cursor as metadata (cap `cursor`; was `RemoteCursorFeed.swift`
//! and the checks of `RemoteCursorShape.init?` and
//! `RemoteRdCursorShape.swift`): `cursor_shape` control messages and
//! `CursorPos` datagrams become cursor states. Positions are latest wins (an
//! older sequence number is dropped); shapes are cached by id, so a position
//! names its shape and a shape that arrives after its position updates the
//! state it named. The Swift shell keeps the images by id; this keeps which
//! ids are cached and which one the cursor wears.

use std::collections::VecDeque;

use cmux_rd_proto::{
    CURSOR_POS_LEN, DatagramKind, MAX_CURSOR_SIDE, base64_decode, cursor_seq_newer,
};
use serde::{Deserialize, Serialize};

/// `DatagramKind::CursorPos`.
pub const DATAGRAM_KIND: u8 = DatagramKind::CursorPos as u8;
/// cmux-rd-proto `HEADER_LEN`.
pub const HEADER_LEN: usize = cmux_rd_proto::HEADER_LEN;
/// cmux-rd-proto `CURSOR_POS_LEN`.
pub const PAYLOAD_LEN: usize = CURSOR_POS_LEN;
/// Shapes kept (the host re-sends one it evicted from its own memory of 64).
pub const MAX_SHAPES: usize = 64;

/// One `cursor_shape` whose pixels match its size: premultiplied RGBA8, rows
/// top first, the hotspot clamped into the image.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorImage {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub hot_x: u32,
    pub hot_y: u32,
    /// The pixels, base64 as they came.
    pub rgba: String,
}

/// `RemoteRdControl.cursorShape` then `RemoteCursorShape.init?`: none when
/// the pixels are not base64, do not match the size, or a side is outside
/// `1...MAX_CURSOR_SIDE`.
pub fn image(
    id: u32,
    width: u32,
    height: u32,
    hot_x: u32,
    hot_y: u32,
    rgba: &str,
) -> Option<CursorImage> {
    let side = 1..=MAX_CURSOR_SIDE;
    if !side.contains(&width) || !side.contains(&height) {
        return None;
    }
    let pixels = base64_decode(rgba)?;
    if pixels.len() != width as usize * height as usize * 4 {
        return None;
    }
    Some(CursorImage {
        id,
        width,
        height,
        hot_x: hot_x.min(width - 1),
        hot_y: hot_y.min(height - 1),
        rgba: rgba.to_owned(),
    })
}

/// The cursor the viewer draws (`RemoteCursorState`, shapes by id).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorState {
    pub x: i32,
    pub y: i32,
    pub visible: bool,
    /// The shape the position names; none for no shape.
    pub shape_hash: Option<u32>,
    /// The shape worn: the named one once cached, else the last one worn.
    pub shape: Option<u32>,
}

/// What one datagram was to the cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DatagramResult {
    /// Not a cursor datagram.
    NotCursor,
    /// A cursor datagram older than the newest applied, or malformed.
    Dropped,
    State {
        state: CursorState,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CursorFeed {
    /// Cached shape ids, oldest first.
    pub shapes: VecDeque<u32>,
    pub seq: Option<u32>,
    pub current: Option<CursorState>,
}

/// What caching one shape did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShapeResult {
    /// The id dropped from the cache to make room (the shell drops its image).
    pub evicted: Option<u32>,
    /// The current state, when it named this shape and now wears it.
    pub state: Option<CursorState>,
}

impl CursorFeed {
    pub fn has_shape(&self, id: u32) -> bool {
        self.shapes.contains(&id)
    }

    /// A `cursor_shape`: cached; the current state when it named this shape.
    pub fn receive_shape(&mut self, id: u32) -> ShapeResult {
        let mut out = ShapeResult::default();
        if !self.has_shape(id) {
            if self.shapes.len() == MAX_SHAPES {
                out.evicted = self.shapes.pop_front();
            }
            self.shapes.push_back(id);
        }
        if let Some(state) = &mut self.current
            && state.shape_hash == Some(id)
            && state.shape != Some(id)
        {
            state.shape = Some(id);
            out.state = Some(*state);
        }
        out
    }

    /// One datagram from the host.
    pub fn receive_datagram(&mut self, bytes: &[u8]) -> DatagramResult {
        if bytes.len() < 2 || bytes[1] != DATAGRAM_KIND {
            return DatagramResult::NotCursor;
        }
        if bytes.len() != HEADER_LEN + PAYLOAD_LEN || bytes[0] >> 4 != 1 {
            return DatagramResult::Dropped;
        }
        let frame = u32_at(bytes, 4);
        if let Some(seq) = self.seq
            && !cursor_seq_newer(frame, seq)
        {
            return DatagramResult::Dropped;
        }
        let p = HEADER_LEN;
        let id = u32_at(bytes, p);
        let x = u32_at(bytes, p + 4) as i32;
        let y = u32_at(bytes, p + 8) as i32;
        let flags = bytes[p + 12];
        if flags & !1 != 0 {
            return DatagramResult::Dropped;
        }
        self.seq = Some(frame);
        let named = (id != 0).then_some(id);
        let cached = named.filter(|id| self.has_shape(*id));
        // Until a named shape arrives, keep wearing the last one (no flash to the arrow).
        let shape = match (cached, named) {
            (Some(id), _) => Some(id),
            (None, Some(_)) => self.current.and_then(|c| c.shape),
            (None, None) => None,
        };
        let state = CursorState { x, y, visible: flags & 1 != 0, shape_hash: named, shape };
        self.current = Some(state);
        DatagramResult::State { state }
    }
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}
