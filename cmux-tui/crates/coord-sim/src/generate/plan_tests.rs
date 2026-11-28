use super::*;

#[test]
fn range_hist_stays_in_range() {
    let shape = Shape::load(None).unwrap();
    let mut rng = Rng::new(3);
    let lo = RangeHist::new(&shape.acpmux.gap_ms, 0, BURST_MS);
    let hi = RangeHist::new(&shape.acpmux.gap_ms, BURST_MS + 1, u64::MAX);
    for _ in 0..10_000 {
        assert!(lo.sample(&mut rng, 0) <= BURST_MS);
        assert!(hi.sample(&mut rng, 51) > BURST_MS);
    }
}

#[test]
fn family_filter() {
    assert!(Family::Claude.keeps("in:claude.assistant"));
    assert!(!Family::Claude.keeps("in:codex.response"));
    assert!(Family::Codex.keeps("out:codex.stdin"));
    assert!(!Family::Codex.keeps("out:claude.stdin"));
    assert!(Family::Codex.keeps("in:tool_call"));
}
