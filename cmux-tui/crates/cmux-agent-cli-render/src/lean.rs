//! The lean wire form of hybrid frames (`agent-cli-hybrid-v2`): one frame as one compact
//! byte string, so a viewer's link carries less than the PTY it replaces for every agent CLI.
//!
//! A v1 `agent-cli-frame` event repeats about 200 bytes of JSON keys and values per frame
//! (stream id, frame numbers, size, cursor) around a [`Delta`] that names every span's whole
//! style. A lean frame keeps per connection what the viewer already knows:
//!
//! - **Header**: a flags varint; the stream id, the size and the frame number only when they
//!   are new to the viewer (its first frame, a keyframe, a resume). A frame that follows the
//!   last one sent carries no number: it is that one plus one, on top of it.
//! - **Cursor**: only when it moved or changed visibility.
//! - **Styles**: a table the connection builds as it goes. A span names its style by index; an
//!   index one past the table's end brings a new style, which the table keeps. A connection
//!   starts with an empty table, so a viewer that reconnects starts over with the encoder.
//! - **Cells**: a printable ASCII cell is its byte; 0 is the empty half of a wide glyph; 1 is
//!   any other text (length, UTF-8); 2 is a run (count, then one cell repeated count times).
//!
//! [`LeanDecoder`] turns lean frames back into [`Frame`]s (the v1 encoding), which is what
//! `vt::frame_bytes` draws; `tests/parity.rs` checks every frame of the recorded sessions
//! through it and measures the link's bytes against the PTY's.

use crate::hybrid::{Delta, Span};
use crate::stream::Frame;
use crate::vt::Cursor;
use crate::{Cell, Color, Style};

/// The frame has no base: it draws over a blank screen.
const KEYFRAME: u64 = 1;
/// The stream id and the size follow.
const HEAD: u64 = 1 << 1;
/// The frame number follows (and its base, unless it is a keyframe).
const NUMBERED: u64 = 1 << 2;
/// The cursor's column and row follow.
const CURSOR: u64 = 1 << 3;
/// The cursor shows.
const CURSOR_VISIBLE: u64 = 1 << 4;

/// Cell tokens.
const EMPTY: u8 = 0;
const TEXT: u8 = 1;
const RUN: u8 = 2;
/// A run of fewer equal cells is written cell by cell.
const MIN_RUN: usize = 4;

/// One connection's encoder: what its viewer was sent so far.
#[derive(Debug, Default)]
pub struct LeanEncoder {
    styles: Vec<Style>,
    last: Option<u64>,
    cursor: Option<Cursor>,
    size: Option<(u16, u16)>,
}

impl LeanEncoder {
    pub fn new() -> LeanEncoder {
        LeanEncoder::default()
    }

    /// `frame` of stream `stream` (a terminal of `cols` x `rows`, its cursor at `cursor`) as a
    /// lean frame; `None` when `frame.data` is not a [`Delta`].
    pub fn encode(
        &mut self,
        stream: &str,
        cols: u16,
        rows: u16,
        frame: &Frame,
        cursor: Cursor,
    ) -> Option<Vec<u8>> {
        let delta = Delta::decode(&frame.data)?;
        let mut flags = 0;
        let follows = self.last.is_some()
            && frame.base == self.last
            && Some(frame.frame) == self.last.map(|n| n + 1);
        if frame.base.is_none() {
            flags |= KEYFRAME;
        }
        let head = self.last.is_none() || frame.base.is_none() || self.size != Some((cols, rows));
        if head {
            flags |= HEAD;
        }
        if !follows || head {
            flags |= NUMBERED;
        }
        if self.cursor != Some(cursor) {
            flags |= CURSOR;
        }
        if cursor.visible {
            flags |= CURSOR_VISIBLE;
        }
        let mut out = Vec::with_capacity(frame.data.len());
        put(&mut out, flags);
        if head {
            put(&mut out, stream.len() as u64);
            out.extend_from_slice(stream.as_bytes());
            put(&mut out, u64::from(cols));
            put(&mut out, u64::from(rows));
        }
        if flags & NUMBERED != 0 {
            put(&mut out, frame.frame);
            if let Some(base) = frame.base {
                put(&mut out, base);
            }
        }
        if flags & CURSOR != 0 {
            put(&mut out, u64::from(cursor.x));
            put(&mut out, u64::from(cursor.y));
        }
        let shift = i32::from(delta.shift);
        put(&mut out, ((shift << 1) ^ (shift >> 31)) as u64);
        put(&mut out, delta.spans.len() as u64);
        for span in &delta.spans {
            match span {
                Span::Set { row, col, cells } => {
                    put(&mut out, u64::from(*row));
                    put(&mut out, u64::from(*col));
                    put(&mut out, ((cells.len() as u64) << 1) | 1);
                    let style = cells.first().map(|cell| cell.style).unwrap_or_default();
                    self.put_style(&mut out, style);
                    put_cells(&mut out, cells);
                }
                Span::Clear { row, col, len } => {
                    put(&mut out, u64::from(*row));
                    put(&mut out, u64::from(*col));
                    put(&mut out, u64::from(*len) << 1);
                }
            }
        }
        self.last = Some(frame.frame);
        self.cursor = Some(cursor);
        self.size = Some((cols, rows));
        Some(out)
    }

    fn put_style(&mut self, out: &mut Vec<u8>, style: Style) {
        if let Some(index) = self.styles.iter().position(|known| *known == style) {
            put(out, index as u64);
            return;
        }
        put(out, self.styles.len() as u64);
        put_color(out, style.fg);
        put_color(out, style.bg);
        put(out, u64::from(style.attrs));
        self.styles.push(style);
    }
}

/// A lean frame read back: the v1 [`Frame`] it carries and what the header said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decoded {
    pub stream: String,
    pub cols: u16,
    pub rows: u16,
    pub frame: Frame,
    pub cursor: Cursor,
}

/// One connection's decoder, the viewer's side of a [`LeanEncoder`].
#[derive(Debug, Default)]
pub struct LeanDecoder {
    styles: Vec<Style>,
    stream: String,
    size: (u16, u16),
    last: Option<u64>,
    cursor: Cursor,
}

impl LeanDecoder {
    pub fn new() -> LeanDecoder {
        LeanDecoder::default()
    }

    /// The frame `bytes` carries; `None` when they are not a lean frame this connection can
    /// read (then the decoder is left as it was).
    pub fn decode(&mut self, bytes: &[u8]) -> Option<Decoded> {
        let mut next = self.clone_state();
        let decoded = next.read(&mut Reader { bytes, pos: 0 })?;
        *self = next;
        Some(decoded)
    }

    fn clone_state(&self) -> LeanDecoder {
        LeanDecoder {
            styles: self.styles.clone(),
            stream: self.stream.clone(),
            size: self.size,
            last: self.last,
            cursor: self.cursor,
        }
    }

    fn read(&mut self, r: &mut Reader<'_>) -> Option<Decoded> {
        let flags = r.varint()?;
        if flags & HEAD != 0 {
            let len = usize::try_from(r.varint()?).ok()?;
            self.stream = String::from_utf8(r.take(len)?.to_vec()).ok()?;
            self.size = (r.u16()?, r.u16()?);
        } else if self.last.is_none() {
            return None;
        }
        let (number, base) = if flags & NUMBERED != 0 {
            let number = r.varint()?;
            let base = if flags & KEYFRAME != 0 { None } else { Some(r.varint()?) };
            (number, base)
        } else {
            let last = self.last?;
            (last + 1, Some(last))
        };
        if flags & CURSOR != 0 {
            self.cursor.x = r.u16()?;
            self.cursor.y = r.u16()?;
        }
        self.cursor.visible = flags & CURSOR_VISIBLE != 0;
        let zigzag = r.u16()?;
        let shift = ((zigzag >> 1) as i16) ^ -((zigzag & 1) as i16);
        let count = r.varint()?;
        let mut spans = Vec::new();
        for _ in 0..count {
            let row = r.u16()?;
            let col = r.u16()?;
            let len = r.varint()?;
            let n = u16::try_from(len >> 1).ok()?;
            if len & 1 == 0 {
                spans.push(Span::Clear { row, col, len: n });
                continue;
            }
            let style = self.read_style(r)?;
            let mut cells = Vec::with_capacity(usize::from(n));
            while cells.len() < usize::from(n) {
                if r.peek()? == RUN {
                    r.byte()?;
                    let times = usize::try_from(r.varint()?).ok()?;
                    let text = r.text()?;
                    if times == 0 || cells.len() + times > usize::from(n) {
                        return None;
                    }
                    cells.extend((0..times).map(|_| Cell { text: text.clone(), style }));
                } else {
                    cells.push(Cell { text: r.text()?, style });
                }
            }
            spans.push(Span::Set { row, col, cells });
        }
        if r.pos != r.bytes.len() {
            return None;
        }
        self.last = Some(number);
        let delta = Delta { seq: 0, at_ms: 0, shift, spans };
        Some(Decoded {
            stream: self.stream.clone(),
            cols: self.size.0,
            rows: self.size.1,
            frame: Frame { frame: number, base, data: delta.encode() },
            cursor: self.cursor,
        })
    }

    fn read_style(&mut self, r: &mut Reader<'_>) -> Option<Style> {
        let index = usize::try_from(r.varint()?).ok()?;
        if let Some(style) = self.styles.get(index) {
            return Some(*style);
        }
        if index != self.styles.len() {
            return None;
        }
        let style = Style { fg: r.color()?, bg: r.color()?, attrs: r.u16()? };
        self.styles.push(style);
        Some(style)
    }
}

fn put(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn put_color(out: &mut Vec<u8>, color: Color) {
    match color {
        Color::Default => out.push(0),
        Color::Palette(index) => out.extend([1, index]),
        Color::Rgb(r, g, b) => out.extend([2, r, g, b]),
    }
}

fn put_text(out: &mut Vec<u8>, text: &str) {
    match text.as_bytes() {
        [byte @ 0x20..=0x7e] => out.push(*byte),
        [] => out.push(EMPTY),
        bytes => {
            out.push(TEXT);
            put(out, bytes.len() as u64);
            out.extend_from_slice(bytes);
        }
    }
}

/// A span's cells, equal neighbors of [`MIN_RUN`] or more as one run.
fn put_cells(out: &mut Vec<u8>, cells: &[Cell]) {
    let mut rest = cells;
    while let Some(first) = rest.first() {
        let same = rest.iter().take_while(|cell| cell.text == first.text).count();
        if same >= MIN_RUN {
            out.push(RUN);
            put(out, same as u64);
            put_text(out, &first.text);
        } else {
            for cell in rest.iter().take(same) {
                put_text(out, &cell.text);
            }
        }
        rest = rest.get(same..).unwrap_or_default();
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn byte(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.pos += 1;
        Some(byte)
    }

    fn take(&mut self, len: usize) -> Option<&[u8]> {
        let bytes = self.bytes.get(self.pos..self.pos.checked_add(len)?)?;
        self.pos += len;
        Some(bytes)
    }

    /// An unsigned LEB128 value; `None` when the bytes end first or it does not fit 64 bits
    /// (`crate::hybrid`'s reader, which says why).
    fn varint(&mut self) -> Option<u64> {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = self.byte()?;
            if shift == 63 && byte > 1 {
                return None;
            }
            value |= u64::from(byte & 0x7f).checked_shl(shift)?;
            if byte & 0x80 == 0 {
                return Some(value);
            }
            shift += 7;
        }
    }

    fn u16(&mut self) -> Option<u16> {
        u16::try_from(self.varint()?).ok()
    }

    fn color(&mut self) -> Option<Color> {
        match self.byte()? {
            0 => Some(Color::Default),
            1 => Some(Color::Palette(self.byte()?)),
            2 => Some(Color::Rgb(self.byte()?, self.byte()?, self.byte()?)),
            _ => None,
        }
    }

    fn text(&mut self) -> Option<String> {
        match self.byte()? {
            byte @ 0x20..=0x7e => Some(char::from(byte).to_string()),
            EMPTY => Some(String::new()),
            TEXT => {
                let len = usize::try_from(self.varint()?).ok()?;
                String::from_utf8(self.take(len)?.to_vec()).ok()
            }
            _ => None,
        }
    }
}

#[cfg(test)]
#[path = "lean_tests.rs"]
mod tests;
