//! The binary codec of the hot messages (p05-ipc-183; design 3.3,
//! spec/transports.md "Binary payload layouts").
//!
//! The requests and results of `resize-attached-view`, `set-client-sizing`,
//! `scroll-surface` and `snapshot-request`, and the `size-state`,
//! `scroll-changed`, `surface-resized` and `digest` events run on every
//! resize, scroll and snapshot; their frames carry a fixed little-endian
//! layout instead of JSON, so neither end parses JSON for them. The schema
//! marks them
//! (`payload: "binary"` on a command, `encoding: "binary"` on an event, each
//! with a `layout_version`), build.rs writes their types and one typed
//! [`Layout`] constant per body from it (build-support/hot_codec.rs), and the
//! Swift app gets the same from CmuxNextWireGen's HotEmitter. Both sides are
//! checked against spec/fixtures/ipc-hot-codec/golden.json.
//!
//! A payload starts with its layout version. [`Layout::decode`] refuses any
//! other version, so a peer built from another schema revision is refused
//! rather than misread; frames are granted only at equal API revisions
//! anyway (frame_dispatch.rs), and `api-compat-check` refuses a layout change
//! without a version bump. This is Mojo's validated struct header (a version
//! and a size before the fields, mojo/public/cpp/bindings/lib/
//! validation_util.h, `ValidateStructHeaderAndClaimMemory`), cut to what two
//! ends of one revision need: no field is optional by version, every length
//! is bounded by the schema, and nothing is left over.
//!
//! The frame's `CallFlags::BINARY` selects the decoder: a frame with it
//! carries the layout, a frame without it the JSON object, which every
//! method takes. [`Layout::encode`] refuses a value its layout cannot carry
//! (a string over its `max_bytes`, an array over its `max_items`); the
//! sender then writes the same message as a JSON frame, without the flag.

use std::fmt;
use std::marker::PhantomData;

/// Which body of a message a layout carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HotPart {
    /// A command's request (a REQUEST frame).
    Request,
    /// A command's result (a REPLY frame).
    Result,
    /// An event's payload (a TYPED_EVENT frame), without its `event` member.
    Event,
}

/// What a binary layout is, without its type.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HotLayout {
    /// The command or event name.
    pub name: &'static str,
    pub part: HotPart,
    /// The `method_id` or `event_id`.
    pub wire_id: u16,
    /// The first payload byte.
    pub layout_version: u8,
    /// The generated type of the body.
    pub type_name: &'static str,
}

/// One binary layout and the type of its body.
#[derive(Debug)]
pub struct Layout<T> {
    pub info: HotLayout,
    body: PhantomData<fn() -> T>,
}

impl<T> Layout<T> {
    /// The layout `info` with body `T`; build.rs writes one per message.
    pub const fn new(info: HotLayout) -> Self {
        Self { info, body: PhantomData }
    }
}

impl<T: HotValue> Layout<T> {
    /// Appends the version byte and `value` to `out`. On an error `out` is
    /// as it was.
    pub fn encode(&self, value: &T, out: &mut Vec<u8>) -> Result<(), HotEncodeError> {
        let start = out.len();
        out.push(self.info.layout_version);
        let result = value.write(&mut HotWriter { out });
        if result.is_err() {
            out.truncate(start);
        }
        result
    }

    /// The body of `payload`: the version byte must be this layout's, and
    /// every byte after it must belong to the body.
    pub fn decode(&self, payload: &[u8]) -> Result<T, HotDecodeError> {
        let (&version, body) = payload.split_first().ok_or(HotDecodeError::Truncated)?;
        if version != self.info.layout_version {
            return Err(HotDecodeError::Version {
                name: self.info.name,
                expected: self.info.layout_version,
                found: version,
            });
        }
        let mut reader = HotReader { rest: body };
        let value = T::read(&mut reader)?;
        match reader.rest.len() {
            0 => Ok(value),
            extra => Err(HotDecodeError::TrailingBytes(extra)),
        }
    }
}

/// A value with a binary layout: every generated struct.
pub trait HotValue: Sized {
    /// Appends the value's fields in layout order.
    fn write(&self, w: &mut HotWriter<'_>) -> Result<(), HotEncodeError>;
    /// Reads the value's fields in layout order.
    fn read(r: &mut HotReader<'_>) -> Result<Self, HotDecodeError>;
}

/// A value its layout cannot carry; the sender writes JSON instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotEncodeError {
    /// A string longer than its field's `max_bytes`.
    StringTooLong { len: usize, max: u16 },
    /// An array longer than its `max_items`.
    ArrayTooLong { len: usize, max: u16 },
}

impl fmt::Display for HotEncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StringTooLong { len, max } => {
                write!(f, "a {len}-byte string is over its layout's {max} bytes")
            }
            Self::ArrayTooLong { len, max } => {
                write!(f, "a {len}-item array is over its layout's {max} items")
            }
        }
    }
}

impl std::error::Error for HotEncodeError {}

/// A payload that is not its layout; the connection treats it as a bad
/// message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotDecodeError {
    /// The payload ends inside a value.
    Truncated,
    /// The version byte is another schema revision's.
    Version { name: &'static str, expected: u8, found: u8 },
    /// A tag byte other than 0 (absent or null) and 1 (present).
    BadTag(u8),
    /// A boolean byte other than 0 and 1.
    BadBool(u8),
    /// An enum index past the type's values.
    BadEnum { type_name: &'static str, index: u8 },
    /// A string or array length over its bound.
    OverBound { len: usize, max: u16 },
    /// A string that is not UTF-8.
    InvalidUtf8,
    /// Bytes after the body.
    TrailingBytes(usize),
}

impl fmt::Display for HotDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => write!(f, "the payload ends inside a value"),
            Self::Version { name, expected, found } => {
                write!(f, "{name} layout version {found}, expected {expected}")
            }
            Self::BadTag(tag) => write!(f, "tag byte {tag} is neither 0 nor 1"),
            Self::BadBool(byte) => write!(f, "boolean byte {byte} is neither 0 nor 1"),
            Self::BadEnum { type_name, index } => write!(f, "{type_name} has no value {index}"),
            Self::OverBound { len, max } => write!(f, "length {len} is over its bound {max}"),
            Self::InvalidUtf8 => write!(f, "a string is not UTF-8"),
            Self::TrailingBytes(extra) => write!(f, "{extra} bytes after the body"),
        }
    }
}

impl std::error::Error for HotDecodeError {}

/// Appends values to a payload, little endian.
pub struct HotWriter<'a> {
    out: &'a mut Vec<u8>,
}

impl HotWriter<'_> {
    pub fn bool(&mut self, value: bool) -> Result<(), HotEncodeError> {
        self.out.push(u8::from(value));
        Ok(())
    }

    pub fn enumeration(&mut self, index: u8) -> Result<(), HotEncodeError> {
        self.out.push(index);
        Ok(())
    }

    pub fn u16(&mut self, value: u16) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn u32(&mut self, value: u32) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn u64(&mut self, value: u64) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn i32(&mut self, value: i32) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn i64(&mut self, value: i64) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn f32(&mut self, value: f32) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    pub fn f64(&mut self, value: f64) -> Result<(), HotEncodeError> {
        self.out.extend_from_slice(&value.to_le_bytes());
        Ok(())
    }

    /// A u16 byte length, then the UTF-8.
    pub fn str(&mut self, value: &str, max: u16) -> Result<(), HotEncodeError> {
        let len = value.len();
        let prefix = u16::try_from(len)
            .ok()
            .filter(|n| *n <= max)
            .ok_or(HotEncodeError::StringTooLong { len, max })?;
        self.u16(prefix)?;
        self.out.extend_from_slice(value.as_bytes());
        Ok(())
    }

    /// A u16 count, then each item.
    pub fn array<T>(
        &mut self,
        items: &[T],
        max: u16,
        mut item: impl FnMut(&mut Self, &T) -> Result<(), HotEncodeError>,
    ) -> Result<(), HotEncodeError> {
        let len = items.len();
        let count = u16::try_from(len)
            .ok()
            .filter(|n| *n <= max)
            .ok_or(HotEncodeError::ArrayTooLong { len, max })?;
        self.u16(count)?;
        items.iter().try_for_each(|value| item(self, value))
    }

    /// A tag byte (0 absent or null, 1 present), then the value if present.
    pub fn option<T>(
        &mut self,
        value: Option<&T>,
        write: impl FnOnce(&mut Self, &T) -> Result<(), HotEncodeError>,
    ) -> Result<(), HotEncodeError> {
        match value {
            None => {
                self.out.push(0);
                Ok(())
            }
            Some(value) => {
                self.out.push(1);
                write(self, value)
            }
        }
    }
}

/// Reads values off a payload, little endian.
pub struct HotReader<'a> {
    rest: &'a [u8],
}

impl<'a> HotReader<'a> {
    fn take<const N: usize>(&mut self) -> Result<[u8; N], HotDecodeError> {
        let (head, rest) = self.rest.split_first_chunk::<N>().ok_or(HotDecodeError::Truncated)?;
        self.rest = rest;
        Ok(*head)
    }

    fn bytes(&mut self, len: usize) -> Result<&'a [u8], HotDecodeError> {
        let (head, rest) = self.rest.split_at_checked(len).ok_or(HotDecodeError::Truncated)?;
        self.rest = rest;
        Ok(head)
    }

    pub fn bool(&mut self) -> Result<bool, HotDecodeError> {
        match self.take::<1>()? {
            [0] => Ok(false),
            [1] => Ok(true),
            [byte] => Err(HotDecodeError::BadBool(byte)),
        }
    }

    pub fn enumeration(&mut self) -> Result<u8, HotDecodeError> {
        self.take::<1>().map(|[index]| index)
    }

    pub fn u16(&mut self) -> Result<u16, HotDecodeError> {
        self.take().map(u16::from_le_bytes)
    }

    pub fn u32(&mut self) -> Result<u32, HotDecodeError> {
        self.take().map(u32::from_le_bytes)
    }

    pub fn u64(&mut self) -> Result<u64, HotDecodeError> {
        self.take().map(u64::from_le_bytes)
    }

    pub fn i32(&mut self) -> Result<i32, HotDecodeError> {
        self.take().map(i32::from_le_bytes)
    }

    pub fn i64(&mut self) -> Result<i64, HotDecodeError> {
        self.take().map(i64::from_le_bytes)
    }

    pub fn f32(&mut self) -> Result<f32, HotDecodeError> {
        self.take().map(f32::from_le_bytes)
    }

    pub fn f64(&mut self) -> Result<f64, HotDecodeError> {
        self.take().map(f64::from_le_bytes)
    }

    pub fn str(&mut self, max: u16) -> Result<String, HotDecodeError> {
        let len = self.length(max)?;
        let bytes = self.bytes(len)?;
        std::str::from_utf8(bytes).map(str::to_owned).map_err(|_| HotDecodeError::InvalidUtf8)
    }

    pub fn array<T>(
        &mut self,
        max: u16,
        mut item: impl FnMut(&mut Self) -> Result<T, HotDecodeError>,
    ) -> Result<Vec<T>, HotDecodeError> {
        // The count is bounded by the layout; the vector grows as items read,
        // so a count the payload cannot hold fails without reserving it.
        let len = self.length(max)?;
        (0..len).map(|_| item(self)).collect()
    }

    pub fn option<T>(
        &mut self,
        read: impl FnOnce(&mut Self) -> Result<T, HotDecodeError>,
    ) -> Result<Option<T>, HotDecodeError> {
        match self.take::<1>()? {
            [0] => Ok(None),
            [1] => read(self).map(Some),
            [tag] => Err(HotDecodeError::BadTag(tag)),
        }
    }

    fn length(&mut self, max: u16) -> Result<usize, HotDecodeError> {
        let len = self.u16()?;
        if len > max {
            return Err(HotDecodeError::OverBound { len: usize::from(len), max });
        }
        Ok(usize::from(len))
    }
}

include!(concat!(env!("OUT_DIR"), "/hot_codec.rs"));
