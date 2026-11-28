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
