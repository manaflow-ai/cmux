//! FastCDC content-defined chunking (Xia et al., USENIX ATC 2016, with normalized chunking):
//! 16 KiB minimum, 64 KiB normal, 256 KiB maximum. A boundary depends only on the 64 bytes
//! before it, so an insert or a relinked section moves the boundaries near it and no others;
//! two builds of one tree share every chunk their bytes share.
//!
//! The gear table is fixed by a splitmix64 stream from seed 0, so every client and every
//! producer cuts the same bytes at the same places. Changing it, or the sizes below, changes
//! every id: that is a new protocol version, not a tweak.

/// The smallest chunk, except a file's last.
pub const MIN: usize = 16 << 10;
/// The size the masks aim for.
pub const AVG: usize = 64 << 10;
/// The largest chunk: a boundary is forced here.
pub const MAX: usize = 256 << 10;

const BITS: u32 = AVG.trailing_zeros();
/// Before the normal size: two more bits than AVG's, so a boundary is rarer (normalization).
const MASK_S: u64 = mask(BITS + 2);
/// After it: two fewer, so a boundary comes sooner.
const MASK_L: u64 = mask(BITS - 2);

/// `n` one bits at the top of the word, where the gear hash has mixed in the most bytes.
const fn mask(n: u32) -> u64 {
    ((1u64 << n) - 1) << (64 - n)
}

const GEAR: [u64; 256] = gear();

#[allow(
    clippy::indexing_slicing,
    reason = "i starts at zero and the loop bounds it by the 256-element table"
)]
const fn gear() -> [u64; 256] {
    let mut table = [0u64; 256];
    let mut state = 0u64;
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

/// The length of the first chunk of `data` (all of it when it is no longer than [`MIN`]).
pub fn cut(data: &[u8]) -> usize {
    let n = data.len();
    if n <= MIN {
        return n;
    }
    let end = n.min(MAX);
    let mut hash = 0u64;
    for (i, byte) in data.iter().enumerate().take(end).skip(MIN) {
        hash = (hash << 1).wrapping_add(gear_entry(*byte));
        let mask = if i < AVG { MASK_S } else { MASK_L };
        if hash & mask == 0 {
            return i + 1;
        }
    }
    end
}

#[allow(
    clippy::indexing_slicing,
    reason = "a u8 indexes every entry of the 256-element gear table"
)]
fn gear_entry(byte: u8) -> u64 {
    GEAR[usize::from(byte)]
}

/// The chunks of `data`, in order, as `(offset, len)`.
pub fn chunks(data: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::with_capacity(data.len() / AVG + 1);
    let mut at = 0;
    while let Some(rest) = data.get(at..).filter(|rest| !rest.is_empty()) {
        let len = cut(rest);
        out.push((at, len));
        at += len;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise(n: usize, seed: u64) -> Vec<u8> {
        let mut s = seed;
        (0..n)
            .map(|_| {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                s as u8
            })
            .collect()
    }

    #[test]
    fn sizes_stay_in_bounds_and_cover_the_input() {
        let data = noise(8 << 20, 7);
        let cs = chunks(&data);
        assert_eq!(cs.iter().map(|c| c.1).sum::<usize>(), data.len());
        for (i, (_, len)) in cs.iter().enumerate() {
            assert!(*len <= MAX);
            assert!(*len >= MIN || i == cs.len() - 1);
        }
        let mean = data.len() / cs.len();
        assert!((AVG / 2..AVG * 2).contains(&mean), "mean chunk {mean}");
    }

    #[test]
    fn an_insert_moves_only_nearby_boundaries() {
        let a = noise(4 << 20, 9);
        let mut b = a.clone();
        b.splice(1 << 20..1 << 20, noise(1000, 3));
        let ids = |d: &[u8]| -> std::collections::HashSet<[u8; 32]> {
            chunks(d).iter().map(|&(o, l)| *blake3::hash(&d[o..o + l]).as_bytes()).collect()
        };
        let (ia, ib) = (ids(&a), ids(&b));
        let new = ib.difference(&ia).count();
        assert!(new <= 3, "{new} new chunks of {}", ib.len());
    }
}
