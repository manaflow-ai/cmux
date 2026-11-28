use super::*;

#[test]
fn dropped_names_pad_every_field() {
    assert_eq!(dropped_name(2026, 1, 2, 3, 4, 5), "Dropped Image 2026-01-02 at 03.04.05.png");
    assert_eq!(dropped_name(2026, 11, 26, 23, 59, 59), "Dropped Image 2026-11-26 at 23.59.59.png");
}

#[test]
fn rename_trims_and_skips_the_same_name() {
    assert_eq!(rename_target("a.png", "  a.png \n"), None);
    assert_eq!(rename_target("a.png", " b.png "), Some("b.png".into()));
}
