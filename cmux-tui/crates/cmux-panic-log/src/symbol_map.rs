//! Function names of a stripped executable, read from its side symbol map.
//!
//! The release bundle strips `bin/cmux` fully (`scripts/strip-release-bundle.sh`),
//! so neither std's backtrace nor `dladdr` finds a name in it. Before the
//! strip, `scripts/write-app-symbol-map.py` writes its `__TEXT,__text`
//! functions into `Contents/Resources/cmux-tui-symbols.bin`, the format the
//! app's own `cmux-symbols.bin` has (and `AppSymbolMap.swift` reads):
//! little-endian, `b"CMXSYM2\0"`, u32 slice count, then per slice the 16-byte
//! `LC_UUID`, u32 payload size and the payload as raw DEFLATE: u32 symbol
//! count, one unsigned LEB128 offset delta per symbol (offsets from the
//! image's Mach-O header), one byte per symbol (how many leading bytes its
//! name shares with the name before it), then each name's remaining bytes and
//! a NUL. A Rust legacy name's `17h<hash>E` tail (a `_ZN` name's last path
//! component) is stored as the one byte 0x01 and read back as
//! `17h0000000000000000E`: the demangler prints no hash, and the hashes were
//! 4 MB of the map. A name holding a 0x01 byte, or a client without
//! the second magic in its binary (an older one), gets the first format. The last entry has an empty
//! name: the end of `__TEXT,__text`. The first format, `b"CMXSYM1\0"`, held
//! the whole names joined by NUL; it still reads.

use std::io::Read;

/// The second format's magic. The release strip's writer looks for these bytes in `bin/cmux`
/// (`write-app-symbol-map.py --reader`) and writes the first format for a client without them:
/// one built before this format, which a nightly can bundle as its fallback tree.
static SHARED_PREFIX_MAGIC: [u8; 8] = *b"CMXSYM2\0";

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
        let magic = file.take(8)?;
        // Through black_box, so the magic stays in the binary as bytes the writer finds, not an
        // immediate the compare folds it into.
        let shared_prefixes = magic == std::hint::black_box(&SHARED_PREFIX_MAGIC);
        if !shared_prefixes && magic != b"CMXSYM1\0" {
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
            return Self::table(&inflated, shared_prefixes);
        }
        None
    }

    fn table(payload: &[u8], shared_prefixes: bool) -> Option<Self> {
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
        let names = if shared_prefixes {
            Self::expand(payload.bytes.get(payload.at..)?, count)?
        } else {
            payload.bytes.get(payload.at..)?.to_vec()
        };
        let mut starts = Vec::with_capacity(capacity);
        starts.push(0u32);
        for (index, byte) in names.iter().enumerate() {
            if *byte == 0 {
                starts.push(u32::try_from(index.checked_add(1)?).ok()?);
            }
        }
        (starts.len() == offsets.len()).then_some(Self { offsets, names, starts })
    }

    /// The names of a shared-prefix block (`count` prefix lengths, then `count` NUL-ended rests)
    /// as the first format held them: whole names joined by NUL, the last without one.
    fn expand(block: &[u8], count: usize) -> Option<Vec<u8>> {
        const HASH_MARK: u8 = 0x01;
        const NO_HASH: &[u8] = b"17h0000000000000000E";
        let (shared, rests) = block.split_at_checked(count)?;
        let mut rests = rests.split(|byte| *byte == 0);
        let mut names = Vec::with_capacity(block.len().saturating_mul(3));
        // The previous name as stored (with its hash mark), which the next one shares a prefix of.
        let mut previous: Vec<u8> = Vec::new();
        for (index, shared) in shared.iter().enumerate() {
            let rest = rests.next()?;
            previous.truncate(usize::from(*shared));
            if previous.len() != usize::from(*shared) {
                return None;
            }
            previous.extend_from_slice(rest);
            if index != 0 {
                names.push(0);
            }
            match previous.split_last() {
                Some((&HASH_MARK, name)) => {
                    names.extend_from_slice(name);
                    names.extend_from_slice(NO_HASH);
                }
                _ => names.extend_from_slice(&previous),
            }
        }
        Some(names)
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
#[path = "symbol_map_tests.rs"]
mod tests;
