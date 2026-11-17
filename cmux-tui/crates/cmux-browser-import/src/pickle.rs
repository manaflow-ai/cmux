//! Chromium `base::Pickle` payloads (`PickleReader.swift`): a uint32 payload size, then 4-byte
//! aligned fields (int32, int64, length-prefixed UTF-8 and UTF-16 strings). Every read is
//! bounds-checked; a short payload yields `None`.

pub struct Pickle<'a> {
    bytes: &'a [u8],
    offset: usize,
}

/// The little-endian uint32 at `index`, if four bytes are there.
pub fn uint32(bytes: &[u8], index: usize) -> Option<u32> {
    let four = bytes.get(index..index.checked_add(4)?)?;
    Some(u32::from_le_bytes(four.try_into().ok()?))
}

/// `count` rounded up to a multiple of 4.
fn aligned(count: usize) -> usize {
    count.saturating_add(3) & !3
}

impl<'a> Pickle<'a> {
    /// A pickle: its header's payload size must fit in the bytes after the header.
    pub fn new(bytes: &'a [u8]) -> Option<Self> {
        let size = usize::try_from(uint32(bytes, 0)?).ok()?;
        (size <= bytes.len().saturating_sub(4)).then_some(Pickle { bytes, offset: 4 })
    }

    /// A raw struct payload (not a pickle): fields from offset 0.
    pub fn raw(bytes: &'a [u8]) -> Self {
        Pickle { bytes, offset: 0 }
    }

    pub fn int32(&mut self) -> Option<i32> {
        let value = uint32(self.bytes, self.offset)?;
        self.offset = self.offset.saturating_add(4);
        Some(i32::from_le_bytes(value.to_le_bytes()))
    }

    pub fn int64(&mut self) -> Option<i64> {
        let low = self.int32()?;
        let high = self.int32()?;
        Some((i64::from(high) << 32) | i64::from(u32::from_le_bytes(low.to_le_bytes())))
    }

    /// The bytes of a length-prefixed field of `byte_count` bytes, then the offset moves past
    /// its padding.
    fn field(&mut self, byte_count: usize) -> Option<&'a [u8]> {
        let end = self.offset.checked_add(byte_count)?;
        let field = self.bytes.get(self.offset..end)?;
        self.offset = self.offset.saturating_add(aligned(byte_count));
        Some(field)
    }

    /// A UTF-8 string (invalid sequences become U+FFFD, as `String(decoding:as:)`).
    pub fn string(&mut self) -> Option<String> {
        let length = usize::try_from(self.int32()?).ok()?;
        Some(String::from_utf8_lossy(self.field(length)?).into_owned())
    }

    /// A UTF-16 string of `length` code units (unpaired surrogates become U+FFFD).
    pub fn string16(&mut self) -> Option<String> {
        let length = usize::try_from(self.int32()?).ok()?;
        let units: Vec<u16> = self
            .field(length.checked_mul(2)?)?
            .chunks_exact(2)
            .map(|pair| {
                u16::from_le_bytes([
                    pair.first().copied().unwrap_or(0),
                    pair.get(1).copied().unwrap_or(0),
                ])
            })
            .collect();
        Some(String::from_utf16_lossy(&units))
    }
}
