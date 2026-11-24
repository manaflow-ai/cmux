//! FastCDC content-defined chunking (Xia et al., "The Design of Fast Content-Defined Chunking for
//! Data Deduplication Based Storage Systems", 2020): a gear rolling hash, cut where its top bits
//! are zero, with normalized chunking (a harder mask before the average size and an easier one
//! after) so chunk sizes cluster near the average.
//!
//! A cut depends only on the 64 bytes before it, so an insert or delete in the middle of a file
//! changes the chunks around the edit and the cuts fall in the same places again after it:
//! two archive versions share every chunk outside the edits.
//!
//! The cuts are part of `cas/1`'s dedup contract, not its wire: the gear table ([`GEAR`], a
//! SplitMix64 sequence from a fixed seed) and [`Params::CAS_V1`] never change within
//! `cmux.cas.v1` manifests. Changing either only costs dedup against older manifests; ids still
//! verify.

/// Chunk size bounds, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Params {
    /// No cut before this many bytes (unless the input ends).
    pub min: usize,
    /// The size chunks cluster around; a power of two.
    pub avg: usize,
    /// A cut at this many bytes if the hash made none.
    pub max: usize,
}

impl Params {
    /// `cas/1` artifacts: 16 KiB, 64 KiB, 256 KiB (RFD 0166 techniques, section 3).
    pub const CAS_V1: Self = Self { min: 16 << 10, avg: 64 << 10, max: 256 << 10 };

    fn masks(self) -> (u64, u64) {
        let bits = self.avg.max(4).ilog2();
        // Normalization level 2: two bits harder before the average, two easier after.
        (top_bits(bits + 2), top_bits(bits.saturating_sub(2).max(1)))
    }
}

impl Default for Params {
    fn default() -> Self {
        Self::CAS_V1
    }
}

const fn top_bits(n: u32) -> u64 {
    if n >= 64 { u64::MAX } else { !(u64::MAX >> n) }
}

const fn gear() -> [u64; 256] {
    let mut table = [0u64; 256];
    let mut state: u64 = 0x636d_7578_2d63_6173; // "cmux-cas"
    let mut i = 0;
    while i < 256 {
        state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        table[i] = z ^ (z >> 31);
        i += 1;
    }
    table
}

/// The gear table: 256 SplitMix64 values from the seed `"cmux-cas"`.
pub static GEAR: [u64; 256] = gear();

/// The length of the first chunk of `src`.
pub fn cut(src: &[u8], params: Params) -> usize {
    let Params { min, avg, max } = params;
    if src.len() <= min {
        return src.len();
    }
    let end = src.len().min(max);
    let center = avg.min(end);
    let (mask_small, mask_large) = params.masks();
    let mut hash: u64 = 0;
    let mut i = min;
    while i < center {
        hash = (hash << 1).wrapping_add(GEAR[usize::from(src[i])]);
        if hash & mask_small == 0 {
            return i + 1;
        }
        i += 1;
    }
    while i < end {
        hash = (hash << 1).wrapping_add(GEAR[usize::from(src[i])]);
        if hash & mask_large == 0 {
            return i + 1;
        }
        i += 1;
    }
    end
}

/// The chunks of one file, in order. Files are chunked one at a time, which is what forces a cut
/// at every file boundary.
#[derive(Debug, Clone)]
pub struct Chunker<'a> {
    rest: &'a [u8],
    params: Params,
}

impl<'a> Chunker<'a> {
    /// The chunks of `src`.
    pub fn new(src: &'a [u8], params: Params) -> Self {
        Self { rest: src, params }
    }
}

impl<'a> Iterator for Chunker<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<&'a [u8]> {
        if self.rest.is_empty() {
            return None;
        }
        let (chunk, rest) = self.rest.split_at(cut(self.rest, self.params));
        self.rest = rest;
        Some(chunk)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Deterministic bytes that do not compress or repeat (SplitMix64 from `seed`).
    pub(crate) fn noise(seed: u64, len: usize) -> Vec<u8> {
        let mut state = seed;
        let mut out = Vec::with_capacity(len + 8);
        while out.len() < len {
            state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            out.extend_from_slice(&(z ^ (z >> 31)).to_le_bytes());
        }
        out.truncate(len);
        out
    }

    fn lens(src: &[u8]) -> Vec<usize> {
        Chunker::new(src, Params::CAS_V1).map(<[u8]>::len).collect()
    }

    #[test]
    fn chunks_cover_the_input_within_bounds() {
        let p = Params::CAS_V1;
        let src = noise(1, 8 << 20);
        let chunks: Vec<&[u8]> = Chunker::new(&src, p).collect();
        assert_eq!(chunks.concat(), src);
        let (last, body) = chunks.split_last().unwrap();
        for c in body {
            assert!((p.min..=p.max).contains(&c.len()), "chunk of {} bytes", c.len());
        }
        assert!(!last.is_empty() && last.len() <= p.max);
        // Normalized chunking keeps the mean near the 64 KiB average.
        let mean = src.len() / chunks.len();
        assert!((40 << 10..=96 << 10).contains(&mean), "mean chunk {mean} bytes");
    }

    #[test]
    fn small_and_empty_inputs() {
        assert!(lens(&[]).is_empty());
        assert_eq!(lens(&[5; 100]), vec![100]);
        assert_eq!(lens(&noise(2, 16 << 10)), vec![16 << 10]);
        // Bytes with no content to cut on (all zeros) are cut at the maximum.
        assert_eq!(lens(&vec![0; 600 << 10]), vec![256 << 10, 256 << 10, 88 << 10]);
    }

    #[test]
    fn cuts_are_deterministic() {
        let src = noise(3, 2 << 20);
        assert_eq!(lens(&src), lens(&src.clone()));
        // The table is pinned: a change here moves every cut in every published manifest.
        assert_eq!((GEAR[0], GEAR[255]), (0x2008_47cc_27c9_2cf2, 0x7f35_7b8c_5930_62a4));
    }

    #[test]
    fn cuts_resync_after_an_edit() {
        let src = noise(4, 4 << 20);
        let mut edited = src.clone();
        edited.splice(1 << 20..1 << 20, b"an insertion in the middle".iter().copied());
        let ids = |s: &[u8]| -> std::collections::HashSet<Vec<u8>> {
            Chunker::new(s, Params::CAS_V1).map(<[u8]>::to_vec).collect()
        };
        let before = ids(&src);
        let after: Vec<Vec<u8>> =
            Chunker::new(&edited, Params::CAS_V1).map(<[u8]>::to_vec).collect();
        let changed = after.iter().filter(|c| !before.contains(*c)).count();
        // One insertion changes the chunk it lands in, and at most one more before the cuts
        // line up again.
        assert!(changed <= 2, "{changed} chunks changed for one insertion");
        // Cuts are the same before the edit.
        let (src_lens, edited_lens) = (lens(&src), lens(&edited));
        let shared_prefix = src_lens.iter().zip(&edited_lens).take_while(|(a, b)| a == b).count();
        assert!(shared_prefix >= 10, "only {shared_prefix} leading chunks kept");
    }
}
