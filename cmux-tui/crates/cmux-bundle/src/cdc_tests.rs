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
