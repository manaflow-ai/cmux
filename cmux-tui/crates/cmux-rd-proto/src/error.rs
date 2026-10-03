use std::fmt;

/// Why a byte string is not a valid `cmux.rd/1` message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// The input ends before the field at `need` bytes.
    Truncated { need: usize, have: usize },
    /// The version nibble is not [`crate::VERSION`].
    Version(u8),
    /// The kind byte names no known datagram kind.
    Kind(u8),
    /// An input event tag is unknown.
    InputTag(u8),
    /// A field holds a value outside its range.
    Invalid(&'static str),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated { need, have } => write!(f, "truncated: need {need} bytes, have {have}"),
            Self::Version(v) => write!(f, "unsupported version {v}"),
            Self::Kind(k) => write!(f, "unknown datagram kind {k}"),
            Self::InputTag(t) => write!(f, "unknown input event tag {t}"),
            Self::Invalid(what) => write!(f, "invalid {what}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// A little-endian reader over a byte slice that reports truncation.
pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.at.checked_add(n).ok_or(DecodeError::Invalid("length"))?;
        if end > self.bytes.len() {
            return Err(DecodeError::Truncated { need: end, have: self.bytes.len() });
        }
        let out = &self.bytes[self.at..end];
        self.at = end;
        Ok(out)
    }

    pub(crate) fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    pub(crate) fn u16(&mut self) -> Result<u16, DecodeError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    pub(crate) fn u32(&mut self) -> Result<u32, DecodeError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub(crate) fn i32(&mut self) -> Result<i32, DecodeError> {
        Ok(self.u32()? as i32)
    }

    pub(crate) fn u64(&mut self) -> Result<u64, DecodeError> {
        let b = self.take(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        Ok(u64::from_le_bytes(a))
    }

    pub(crate) fn rest(&mut self) -> &'a [u8] {
        let out = &self.bytes[self.at..];
        self.at = self.bytes.len();
        out
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.at == self.bytes.len()
    }
}
