use crate::error::{DecodeError, Reader};

/// Largest UTF-8 text in one [`InputEvent::Text`].
pub const MAX_TEXT_BYTES: usize = 256;

/// One viewer input event. Keys use USB HID usages (page << 16 | id), so the
/// meaning does not depend on the viewer's keyboard layout; committed IME text
/// travels as [`InputEvent::Text`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEvent {
    Key {
        usage: u32,
        down: bool,
    },
    /// Absolute pointer position in the stream's pixels.
    Pointer {
        x: i32,
        y: i32,
    },
    Button {
        button: u8,
        down: bool,
    },
    /// Scroll in hundredths of a line (or of a point with `precise`).
    Scroll {
        dx: i32,
        dy: i32,
        precise: bool,
    },
    Text(String),
}

/// Input events with consecutive sequence numbers starting at `first_seq`.
/// The viewer repeats unacknowledged events in later packets; the host applies
/// each sequence number once and in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputPacket {
    pub first_seq: u32,
    pub events: Vec<InputEvent>,
}

const TAG_KEY: u8 = 1;
const TAG_POINTER: u8 = 2;
const TAG_BUTTON: u8 = 3;
const TAG_SCROLL: u8 = 4;
const TAG_TEXT: u8 = 5;

impl InputEvent {
    fn encode_into(&self, out: &mut Vec<u8>) {
        match self {
            Self::Key { usage, down } => {
                out.push(TAG_KEY);
                out.extend_from_slice(&usage.to_le_bytes());
                out.push(u8::from(*down));
            }
            Self::Pointer { x, y } => {
                out.push(TAG_POINTER);
                out.extend_from_slice(&x.to_le_bytes());
                out.extend_from_slice(&y.to_le_bytes());
            }
            Self::Button { button, down } => {
                out.push(TAG_BUTTON);
                out.push(*button);
                out.push(u8::from(*down));
            }
            Self::Scroll { dx, dy, precise } => {
                out.push(TAG_SCROLL);
                out.extend_from_slice(&dx.to_le_bytes());
                out.extend_from_slice(&dy.to_le_bytes());
                out.push(u8::from(*precise));
            }
            Self::Text(text) => {
                out.push(TAG_TEXT);
                let bytes = truncate_utf8(text, MAX_TEXT_BYTES);
                out.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
                out.extend_from_slice(bytes);
            }
        }
    }

    fn decode(r: &mut Reader<'_>) -> Result<Self, DecodeError> {
        Ok(match r.u8()? {
            TAG_KEY => Self::Key { usage: r.u32()?, down: bool_byte(r.u8()?)? },
            TAG_POINTER => Self::Pointer { x: r.i32()?, y: r.i32()? },
            TAG_BUTTON => Self::Button { button: r.u8()?, down: bool_byte(r.u8()?)? },
            TAG_SCROLL => Self::Scroll { dx: r.i32()?, dy: r.i32()?, precise: bool_byte(r.u8()?)? },
            TAG_TEXT => {
                let len = r.u16()? as usize;
                if len > MAX_TEXT_BYTES {
                    return Err(DecodeError::Invalid("text length"));
                }
                let text = std::str::from_utf8(r.take(len)?)
                    .map_err(|_| DecodeError::Invalid("utf-8 text"))?;
                Self::Text(text.to_owned())
            }
            other => return Err(DecodeError::InputTag(other)),
        })
    }
}

fn bool_byte(b: u8) -> Result<bool, DecodeError> {
    match b {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(DecodeError::Invalid("bool")),
    }
}

/// The longest prefix of `text` that fits `max` bytes and ends on a character boundary.
fn truncate_utf8(text: &str, max: usize) -> &[u8] {
    if text.len() <= max {
        return text.as_bytes();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text.as_bytes()[..end]
}

impl InputPacket {
    /// Serializes the packet payload: `u32 first_seq`, `u8 n`, then `n` events.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.first_seq.to_le_bytes());
        let n = self.events.len().min(u8::MAX as usize);
        out.push(n as u8);
        for event in &self.events[..n] {
            event.encode_into(&mut out);
        }
        out
    }

    /// Parses a packet payload.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let first_seq = r.u32()?;
        let n = r.u8()? as usize;
        let mut events = Vec::with_capacity(n);
        for _ in 0..n {
            events.push(InputEvent::decode(&mut r)?);
        }
        if !r.is_empty() {
            return Err(DecodeError::Invalid("trailing bytes"));
        }
        Ok(Self { first_seq, events })
    }
}
