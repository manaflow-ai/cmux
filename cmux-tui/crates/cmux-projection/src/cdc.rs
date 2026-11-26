//! Content-defined chunking (FastCDC with normalized chunking, Xia et al., ATC 2016): where to
//! cut a file's bytes so that an edit moves only the cuts near it. A file cut at fixed offsets
//! shares nothing with its edited self past the edit; cut here, it shares every chunk but the
//! one or two the edit touched (RFD 0065: 41 to 91% of an edited file's bytes reused at a 64 KiB
//! average, about 0 at fixed 4 MiB).
//!
//! One chunker, two sizes: [`SYNC`] is `link sync push`'s (`cmux-tui`'s `sync_cli/store.rs`
//! calls [`cut`] with it, so its stored chunks keep their names), [`PROJECTION`] the 64 KiB
//! average RFD 0065 piece 13 picks for a projection's blobs over [`PROJECTION_MIN_FILE`].
//! The gear table is fixed, so the same bytes cut at the same places on every machine.

use std::sync::OnceLock;

/// A chunker's bounds: no chunk under `min` (but a file's last), none over `max`; between them
/// the cut is where the rolling hash's top `hard_bits` are zero before `avg` (harder) or its top
/// `easy_bits` after it (easier), which keeps chunk sizes near `avg`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Params {
    pub min: usize,
    pub avg: usize,
    pub max: usize,
    pub hard_bits: u32,
    pub easy_bits: u32,
}

/// `link sync push`'s chunks: 512 KiB to 8 MiB, 2 MiB average.
pub const SYNC: Params = Params {
    min: 512 * 1024,
    avg: 2 * 1024 * 1024,
    max: 8 * 1024 * 1024,
    hard_bits: 23,
    easy_bits: 19,
};

/// A projection's chunks (RFD 0065 piece 13): 16 KiB to 256 KiB, 64 KiB average, the same
/// normalization (average bits plus and minus 2) as [`SYNC`].
pub const PROJECTION: Params =
    Params { min: 16 * 1024, avg: 64 * 1024, max: 256 * 1024, hard_bits: 18, easy_bits: 14 };

/// The smallest blob a projection chunks (RFD 0065: files over 1 MiB, 18.5% of cmux's bytes;
/// whole-file hashing covers the rest).
pub const PROJECTION_MIN_FILE: u64 = 1024 * 1024;

/// The gear table of the rolling hash (splitmix64 from a fixed seed).
fn gear() -> &'static [u64; 256] {
    static GEAR: OnceLock<[u64; 256]> = OnceLock::new();
    GEAR.get_or_init(|| {
        let mut table = [0u64; 256];
        let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
        for entry in &mut table {
            state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            *entry = z ^ (z >> 31);
        }
        table
    })
}

/// The top `bits` bits of a u64.
const fn top(bits: u32) -> u64 {
    !0u64 << (64 - bits)
}

/// Where the first chunk of `data` ends. `data` is the rest of the file, or at least
/// `params.max` of it.
#[must_use]
pub fn cut(params: &Params, data: &[u8]) -> usize {
    if data.len() <= params.min {
        return data.len();
    }
    let end = data.len().min(params.max);
    let normal = end.min(params.avg);
    let gear = gear();
    let roll = |hash: u64, byte: &u8| {
        (hash << 1).wrapping_add(gear.get(usize::from(*byte)).copied().unwrap_or_default())
    };
    let (Some(hard), Some(easy)) = (data.get(params.min..normal), data.get(normal..end)) else {
        return end;
    };
    let hard_mask = top(params.hard_bits);
    let easy_mask = top(params.easy_bits);
    let mut hash = 0u64;
    for (at, byte) in (params.min..).zip(hard) {
        hash = roll(hash, byte);
        if hash & hard_mask == 0 {
            return at + 1;
        }
    }
    for (at, byte) in (normal..).zip(easy) {
        hash = roll(hash, byte);
        if hash & easy_mask == 0 {
            return at + 1;
        }
    }
    end
}

/// The `(offset, length)` of every chunk of `data`, in order, covering it exactly.
#[must_use]
pub fn spans(params: &Params, data: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::with_capacity(data.len() / params.avg + 1);
    let mut at = 0;
    while let Some(rest) = data.get(at..).filter(|rest| !rest.is_empty()) {
        let size = cut(params, rest);
        out.push((at, size));
        at += size;
    }
    out
}

#[cfg(test)]
#[path = "cdc_tests.rs"]
mod tests;
