use super::Rng;

#[test]
fn a_seed_is_one_stream() {
    let draw = |seed| {
        let mut rng = Rng::new(seed);
        let mut part = rng.split(7);
        (rng.next_u64(), part.range(10, 20), part.chance(50))
    };
    assert_eq!(draw(42), draw(42));
    assert_ne!(draw(42).0, draw(43).0);
    let (_, ranged, _) = draw(1);
    assert!((10..=20).contains(&ranged));
}
