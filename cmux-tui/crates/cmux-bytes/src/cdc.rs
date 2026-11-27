//! Content-defined chunking (FastCDC with normalized chunking): cut points
//! follow content, so an insert early in a file moves only the chunks around
//! it and the rest dedup against what the receiver already holds.

/// Gear table: 256 pseudo-random u64s, fixed so cut points are stable across builds and peers.
#[allow(
    clippy::indexing_slicing,
    reason = "const fill of a 256-entry table: i < 256 by the loop bound"
)]
const GEAR: [u64; 256] = {
    let mut table = [0u64; 256];
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut i = 0;
    while i < 256 {
        // splitmix64
        x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        table[i] = z ^ (z >> 31);
        i += 1;
    }
    table
};

/// The gear value of one byte (a u8 always indexes the 256-entry table).
#[inline]
fn gear(b: u8) -> u64 {
    GEAR.get(usize::from(b)).copied().unwrap_or(0)
}

/// Chunk boundaries for a given average size.
#[derive(Clone, Copy, Debug)]
pub struct Chunker {
    min: usize,
    avg: usize,
    max: usize,
    mask_small: u64,
    mask_large: u64,
}

impl Chunker {
    pub fn new(avg: usize) -> Self {
        let avg = avg.clamp(1024, 16 << 20).next_power_of_two();
        let bits = avg.trailing_zeros();
        // Normalized chunking level 2: harder to cut before avg, easier after.
        let mask = |b: u32| -> u64 { ((1u64 << b) - 1) << (64 - b) };
        Self {
            min: avg / 4,
            avg,
            max: avg * 4,
            mask_small: mask(bits + 2),
            mask_large: mask(bits - 2),
        }
    }

    /// Length of the first chunk of `data`.
    pub fn cut(&self, data: &[u8]) -> usize {
        let n = data.len();
        if n <= self.min {
            return n;
        }
        let end = n.min(self.max);
        let normal = end.min(self.avg);
        let mut hash = 0u64;
        let mut i = self.min;
        for &b in data.get(self.min..normal).unwrap_or_default() {
            hash = (hash << 1).wrapping_add(gear(b));
            i += 1;
            if hash & self.mask_small == 0 {
                return i;
            }
        }
        for &b in data.get(normal..end).unwrap_or_default() {
            hash = (hash << 1).wrapping_add(gear(b));
            i += 1;
            if hash & self.mask_large == 0 {
                return i;
            }
        }
        end
    }

    /// All chunks of `data`, as (offset, len). At cas/1's sizes (64 KiB average) the cut is
    /// cas/1's own ([`cmux_cas::cdc`]), so a chunk's id is the one a CAS store already holds.
    pub fn chunks(&self, data: &[u8]) -> Vec<(usize, usize)> {
        if self.avg == cmux_cas::cdc::AVG {
            return cmux_cas::cdc::chunks(data);
        }
        let mut out = Vec::new();
        let mut at = 0;
        while at < data.len() {
            let len = self.cut(data.get(at..).unwrap_or_default());
            out.push((at, len));
            at += len;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise(n: usize, seed: u64) -> Vec<u8> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                x as u8
            })
            .collect()
    }

    #[test]
    fn an_insert_keeps_later_chunks() {
        let c = Chunker::new(8192);
        let a = noise(1 << 20, 7);
        let mut b = a.clone();
        b.splice(1000..1000, [1, 2, 3, 4, 5]);
        let ha: std::collections::HashSet<_> =
            c.chunks(&a).iter().map(|(o, l)| a[*o..o + l].to_vec()).collect();
        let shared = c.chunks(&b).iter().filter(|(o, l)| ha.contains(&b[*o..o + l])).count();
        assert!(shared + 2 >= c.chunks(&b).len(), "{shared} of {}", c.chunks(&b).len());
    }

    #[test]
    fn sizes_are_bounded_and_cover() {
        let c = Chunker::new(16384);
        let a = noise(3 << 20, 3);
        let chunks = c.chunks(&a);
        assert_eq!(chunks.iter().map(|(_, l)| l).sum::<usize>(), a.len());
        assert!(chunks[..chunks.len() - 1].iter().all(|(_, l)| *l >= 4096 && *l <= 65536));
        let avg = a.len() / chunks.len();
        assert!((8192..=32768).contains(&avg), "avg {avg}");
    }
}
