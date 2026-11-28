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
