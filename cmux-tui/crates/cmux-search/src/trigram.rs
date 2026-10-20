//! Trigrams of folded bytes, block posting lists (delta + varint) and their
//! intersection.

/// The trigram key of three folded bytes.
#[inline]
pub(crate) fn key(a: u8, b: u8, c: u8) -> u32 {
    (u32::from(a) << 16) | (u32::from(b) << 8) | u32::from(c)
}

/// The distinct trigrams of `folded`, sorted.
pub(crate) fn distinct(folded: &[u8]) -> Vec<u32> {
    let mut keys: Vec<u32> = folded.windows(3).map(|w| key(w[0], w[1], w[2])).collect();
    keys.sort_unstable();
    keys.dedup();
    keys
}

/// Appends `value` as a LEB128 varint.
#[inline]
pub(crate) fn put_varint(out: &mut Vec<u8>, mut value: u32) {
    while value >= 0x80 {
        out.push((value as u8) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

/// Decodes a delta + varint posting list of `count` sorted block ids into
/// `out` (cleared first). Stops early on truncated input.
pub(crate) fn decode(bytes: &[u8], count: usize, out: &mut Vec<u32>) {
    out.clear();
    out.reserve(count);
    let mut index = 0;
    let mut previous = 0u32;
    while out.len() < count && index < bytes.len() {
        let mut value = 0u32;
        let mut shift = 0;
        loop {
            let Some(&byte) = bytes.get(index) else { return };
            index += 1;
            value |= u32::from(byte & 0x7F) << shift;
            if byte & 0x80 == 0 {
                break;
            }
            shift += 7;
            if shift > 28 {
                return;
            }
        }
        previous = previous.wrapping_add(value);
        out.push(previous);
    }
}

/// Encodes sorted, distinct block ids as delta + varint.
pub(crate) fn encode(ids: &[u32], out: &mut Vec<u8>) {
    let mut previous = 0u32;
    for &id in ids {
        put_varint(out, id - previous);
        previous = id;
    }
}

/// Keeps in `into` only the ids also in `other` (both sorted). Gallops
/// through `other` when it is much longer than `into`.
pub(crate) fn intersect(into: &mut Vec<u32>, other: &[u32]) {
    if into.is_empty() {
        return;
    }
    if other.is_empty() {
        into.clear();
        return;
    }
    let mut kept = 0;
    let mut cursor = 0;
    for read in 0..into.len() {
        let id = into[read];
        cursor = gallop(other, cursor, id);
        if cursor >= other.len() {
            break;
        }
        if other[cursor] == id {
            into[kept] = id;
            kept += 1;
        }
    }
    into.truncate(kept);
}

/// The first index at or after `from` whose id is at least `target`.
fn gallop(ids: &[u32], from: usize, target: u32) -> usize {
    let mut step = 1;
    let mut low = from;
    let mut high = from;
    while high < ids.len() && ids[high] < target {
        low = high + 1;
        high += step;
        step *= 2;
    }
    let high = high.min(ids.len());
    low + ids[low..high].partition_point(|&id| id < target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmux_search_posting_lists_round_trip_and_intersect() {
        let ids = vec![0, 1, 5, 127, 128, 300, 16_384, 1_000_000];
        let mut bytes = Vec::new();
        encode(&ids, &mut bytes);
        let mut decoded = Vec::new();
        decode(&bytes, ids.len(), &mut decoded);
        assert_eq!(decoded, ids);
        let mut into = vec![1, 2, 5, 300, 999, 1_000_000];
        intersect(&mut into, &ids);
        assert_eq!(into, vec![1, 5, 300, 1_000_000]);
    }

    #[test]
    fn cmux_search_distinct_trigrams_are_sorted_and_unique() {
        assert_eq!(distinct(b"aaaa"), vec![key(b'a', b'a', b'a')]);
        assert!(distinct(b"ab").is_empty());
    }
}
