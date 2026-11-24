use super::de2000;

#[test]
fn sharma_reference_pairs() {
    // Pairs 1, 7 and 17 of Sharma, Wu and Dalal's test data.
    let cases = [
        ([50.0, 2.6772, -79.7751], [50.0, 0.0, -82.7485], 2.0425),
        ([50.0, 0.0, 0.0], [50.0, -1.0, 2.0], 2.3669),
        ([50.0, 2.5, 0.0], [73.0, 25.0, -18.0], 27.1492),
    ];
    for (a, b, want) in cases {
        assert!((de2000(a, b) - want).abs() < 1e-3, "{a:?} {b:?}");
    }
}
