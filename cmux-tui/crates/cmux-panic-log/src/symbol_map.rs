//! Function names of a stripped executable, read from its side symbol map.
//!
//! The release bundle strips `bin/cmux` fully (`scripts/strip-release-bundle.sh`),
//! so neither std's backtrace nor `dladdr` finds a name in it. Before the
//! strip, `scripts/write-app-symbol-map.py` writes its `__TEXT,__text`
//! functions into `Contents/Resources/cmux-tui-symbols.bin`, the format the
//! app's own `cmux-symbols.bin` has (and `AppSymbolMap.swift` reads):
//! little-endian, `b"CMXSYM1\0"`, u32 slice count, then per slice the 16-byte
//! `LC_UUID`, u32 payload size and the payload as raw DEFLATE: u32 symbol
//! count, one unsigned LEB128 offset delta per symbol (offsets from the
//! image's Mach-O header), then the names joined by NUL. The last entry has
//! an empty name: the end of `__TEXT,__text`.

use std::io::Read;

/// One slice's functions: ascending start offsets from the image header and
/// their (mangled) names.
pub struct SymbolMap {
    offsets: Vec<u64>,
    names: Vec<u8>,
    /// Where each name starts in `names`, one per offset.
    starts: Vec<u32>,
}

impl SymbolMap {
    /// The slice for `uuid` in a map file's bytes; `None` when there is none
    /// or the file does not decode.
    pub fn parse(blob: &[u8], uuid: &[u8; 16]) -> Option<Self> {
        let mut file = Reader { bytes: blob, at: 0 };
        if file.take(8)? != b"CMXSYM1\0" {
            return None;
        }
        let count = file.u32()?;
        for _ in 0..count {
            let slice = file.take(16)?;
            let size = file.u32()? as usize;
            let payload = file.take(size)?;
            if slice != uuid {
                continue;
            }
            let mut inflated = Vec::new();
            flate2::read::DeflateDecoder::new(payload).read_to_end(&mut inflated).ok()?;
            return Self::table(&inflated);
        }
        None
    }

    fn table(payload: &[u8]) -> Option<Self> {
        let mut payload = Reader { bytes: payload, at: 0 };
        let count = payload.u32()? as usize;
        // Each entry takes at least one byte, so a corrupt count never reserves more than the file.
        let capacity = count.min(payload.bytes.len());
        let mut offsets = Vec::with_capacity(capacity);
        let mut offset = 0u64;
        for _ in 0..count {
            offset = offset.wrapping_add(payload.leb128()?);
            offsets.push(offset);
        }
        let names = payload.bytes.get(payload.at..)?.to_vec();
        let mut starts = Vec::with_capacity(capacity);
        starts.push(0u32);
        for (index, byte) in names.iter().enumerate() {
            if *byte == 0 {
                starts.push(u32::try_from(index.checked_add(1)?).ok()?);
            }
        }
        (starts.len() == offsets.len()).then_some(Self { offsets, names, starts })
    }

    /// The function holding `offset` (from the image header): its mangled
    /// name and the offset into it; `None` before the first function or past
    /// the end of `__TEXT,__text`.
    pub fn function(&self, offset: u64) -> Option<(&str, u64)> {
        // The first function starting after `offset`; the one before holds it.
        let index = self.offsets.partition_point(|start| *start <= offset).checked_sub(1)?;
        let function_start = *self.offsets.get(index)?;
        let start = *self.starts.get(index)? as usize;
        let end = match self.starts.get(index.checked_add(1)?) {
            Some(next) => (*next as usize).checked_sub(1)?,
            None => self.names.len(),
        };
        let name = std::str::from_utf8(self.names.get(start..end)?).ok()?;
        (!name.is_empty()).then(|| (name, offset.saturating_sub(function_start)))
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(count)?;
        let slice = self.bytes.get(self.at..end)?;
        self.at = end;
        Some(slice)
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }

    fn leb128(&mut self) -> Option<u64> {
        let mut value = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = *self.take(1)?.first()?;
            value |= u64::from(byte & 0x7F).checked_shl(shift)?;
            if byte < 0x80 {
                return Some(value);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A map file of one slice, as `write-app-symbol-map.py` writes it.
    fn map_file(uuid: [u8; 16], symbols: &[(u64, &str)]) -> Vec<u8> {
        let mut body = (symbols.len() as u32).to_le_bytes().to_vec();
        let mut previous = 0;
        for (offset, _) in symbols {
            let mut delta = offset - previous;
            previous = *offset;
            loop {
                let byte = (delta & 0x7F) as u8;
                delta >>= 7;
                body.push(byte | if delta != 0 { 0x80 } else { 0 });
                if delta == 0 {
                    break;
                }
            }
        }
        body.extend(symbols.iter().map(|(_, name)| *name).collect::<Vec<_>>().join("\0").bytes());
        let mut encoder =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
        encoder.write_all(&body).unwrap();
        let payload = encoder.finish().unwrap();
        let mut file = b"CMXSYM1\0".to_vec();
        file.extend(1u32.to_le_bytes());
        file.extend(uuid);
        file.extend((payload.len() as u32).to_le_bytes());
        file.extend(payload);
        file
    }

    #[test]
    fn names_the_function_holding_an_offset() {
        let uuid = [7u8; 16];
        let file = map_file(
            uuid,
            &[(0x1000, "_ZN4cmux4main17h0123456789abcdefE"), (0x1200, "tokio_poll"), (0x2000, "")],
        );
        let map = SymbolMap::parse(&file, &uuid).expect("slice for uuid");
        assert_eq!(map.function(0x1000), Some(("_ZN4cmux4main17h0123456789abcdefE", 0)));
        assert_eq!(map.function(0x11ff), Some(("_ZN4cmux4main17h0123456789abcdefE", 0x1ff)));
        assert_eq!(map.function(0x1234), Some(("tokio_poll", 0x34)));
        // Before the first function and past the end of __text: no name.
        assert_eq!(map.function(0xfff), None);
        assert_eq!(map.function(0x2000), None);
    }

    #[test]
    fn another_build_or_a_bad_file_has_no_map() {
        let file = map_file([7u8; 16], &[(0x1000, "f"), (0x2000, "")]);
        assert!(SymbolMap::parse(&file, &[8u8; 16]).is_none());
        assert!(SymbolMap::parse(b"CMXSYM1\0garbage", &[7u8; 16]).is_none());
        assert!(SymbolMap::parse(b"", &[7u8; 16]).is_none());
    }
}
