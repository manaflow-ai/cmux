//! Content-defined chunk boundaries: a gear rolling hash with FastCDC's normalized masks (Xia et al.,
//! USENIX ATC 2016). A boundary depends only on the bytes just before it, so inserting or removing bytes
//! moves only the chunks around the edit; every other chunk keeps its id.
//!
//! Sizes: at least [`MIN`], about [`AVG`], at most [`MAX`]. A whole input under [`MIN`] is one chunk.

/// The smallest chunk (except the last).
pub const MIN: usize = 16 * 1024;
/// The size boundaries aim for.
pub const AVG: usize = 64 * 1024;
/// The largest chunk.
pub const MAX: usize = 256 * 1024;

/// Before `AVG`: two bits harder than the average (fewer early cuts).
const MASK_SMALL: u64 = mask(18);
/// After `AVG`: two bits easier (cuts come sooner past the average).
const MASK_LARGE: u64 = mask(14);

/// A mask of `bits` one bits spread over the top of a u64 (FastCDC spreads them; the gear hash's high
/// bits mix best).
const fn mask(bits: u32) -> u64 {
    let mut m = 0u64;
    let mut i = 0;
    while i < bits {
        // Every third bit from the top, so the ones are spread across the word.
        m |= 1u64 << (63 - (i * 3) % 64);
        i += 1;
    }
    m
}

/// 256 fixed pseudo-random words (splitmix64 from a fixed seed): part of the wire contract, because both
/// ends must cut the same boundaries for ids to match. Never change them; a new table is a new version.
const GEAR: [u64; 256] = gear();

#[allow(clippy::indexing_slicing, reason = "const fn (no get_mut); i < 256 by the loop bound")]
const fn gear() -> [u64; 256] {
    let mut table = [0u64; 256];
    let mut state: u64 = 0x636d_7578_2d62_6e64; // "cmux-bnd"
    let mut i = 0;
    while i < 256 {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        table[i] = z ^ (z >> 31);
        i += 1;
    }
    table
}

/// The length of the first chunk of `data` (all of it when it is short).
pub fn cut(data: &[u8]) -> usize {
    let n = data.len();
    if n <= MIN {
        return n;
    }
    let end = n.min(MAX);
    let normal = end.min(AVG);
    let mut hash = 0u64;
    for (i, &b) in data.iter().enumerate().take(end).skip(MIN) {
        // A u8 always indexes the 256-word table; `get` keeps the hot loop free of panics.
        hash = (hash << 1).wrapping_add(GEAR.get(usize::from(b)).copied().unwrap_or(0));
        let mask = if i < normal { MASK_SMALL } else { MASK_LARGE };
        if hash & mask == 0 {
            return i + 1;
        }
    }
    end
}

/// Every chunk of `data`, in order, as slices that tile it.
pub fn chunks(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut rest = data;
    std::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        let (head, tail) = rest.split_at(cut(rest));
        rest = tail;
        Some(head)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise(len: usize, seed: u64) -> Vec<u8> {
        let mut s = seed;
        (0..len)
            .map(|_| {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                s as u8
            })
            .collect()
    }

    #[test]
    fn chunks_tile_the_input_within_bounds() {
        let data = noise(5 << 20, 7);
        let parts: Vec<&[u8]> = chunks(&data).collect();
        assert_eq!(parts.iter().map(|c| c.len()).sum::<usize>(), data.len());
        for c in &parts[..parts.len() - 1] {
            assert!((MIN..=MAX).contains(&c.len()), "{}", c.len());
        }
        let avg = data.len() / parts.len();
        assert!((AVG / 2..=AVG * 2).contains(&avg), "average {avg}");
    }

    #[test]
    fn an_insert_keeps_most_chunks() {
        let data = noise(4 << 20, 11);
        let mut edited = data.clone();
        edited.splice(1_000_000..1_000_000, b"an inserted line\n".iter().copied());
        let before: std::collections::HashSet<&[u8]> = chunks(&data).collect();
        let after: Vec<&[u8]> = chunks(&edited).collect();
        let kept = after.iter().filter(|c| before.contains(*c)).count();
        assert!(kept + 3 >= after.len(), "kept {kept} of {}", after.len());
    }

    #[test]
    fn short_and_empty_inputs() {
        assert_eq!(chunks(b"").count(), 0);
        assert_eq!(chunks(b"tiny").collect::<Vec<_>>(), vec![&b"tiny"[..]]);
        // Zeros never hit a mask: cut at MAX.
        let zeros = vec![0u8; MAX * 2 + 5];
        let lens: Vec<usize> = chunks(&zeros).map(<[u8]>::len).collect();
        assert_eq!(lens, vec![MAX, MAX, 5]);
    }

    #[test]
    fn the_gear_table_is_pinned() {
        // Part of the wire contract: both ends must cut the same boundaries.
        assert_eq!(GEAR[0], PIN_0);
        assert_eq!(GEAR[255], PIN_255);
    }

    const PIN_0: u64 = 7_174_251_847_174_439_464;
    const PIN_255: u64 = 13_977_865_298_708_290_251;
}
