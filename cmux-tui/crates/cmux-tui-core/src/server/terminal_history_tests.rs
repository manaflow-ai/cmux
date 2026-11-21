use super::truncate_text;

#[test]
fn read_range_text_is_cut_at_a_character_boundary() {
    assert_eq!(truncate_text("abc".into(), 8), ("abc".to_string(), false));
    assert_eq!(truncate_text("abcdef".into(), 4), ("abcd".to_string(), true));
    // "é" is two bytes: a cut inside it backs off to the boundary.
    assert_eq!(truncate_text("aé".into(), 2), ("a".to_string(), true));
}
