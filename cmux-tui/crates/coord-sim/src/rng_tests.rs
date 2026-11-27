use super::*;

#[test]
fn same_seed_same_stream() {
    let (mut a, mut b) = (Rng::new(7), Rng::new(7));
    for _ in 0..100 {
        assert_eq!(a.next_u64(), b.next_u64());
    }
}

#[test]
fn below_stays_in_range() {
    let mut r = Rng::new(1);
    for n in [1u64, 2, 3, 1000, u64::MAX] {
        for _ in 0..1000 {
            assert!(r.below(n) < n);
        }
    }
}
