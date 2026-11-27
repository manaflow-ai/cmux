use super::*;

#[test]
fn hsl_round_trips_the_primaries() {
    for hex in [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF, 0x808080] {
        let c = Rgb::hex(hex);
        let (h, s, l) = hsl(c);
        assert_eq!(from_hsl(h, s, l).to_hex(), hex, "{hex:06x}");
    }
}

#[test]
fn median_cut_splits_two_tones_by_share() {
    let mut colors = vec![[10u8, 20, 40]; 70];
    colors.extend(vec![[220u8, 110, 30]; 30]);
    let swatches = median_cut(colors, 8);
    assert_eq!(swatches.len(), 2, "{swatches:?}");
    assert_eq!(swatches[0].0.to_hex(), 0x0A1428);
    assert!((swatches[0].1 - 0.7).abs() < 1e-9);
}
