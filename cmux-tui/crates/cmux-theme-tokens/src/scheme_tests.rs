use super::*;

#[test]
fn line_of_counts_newlines_before_the_offset() {
    assert_eq!(line_of("a\nb\nc", 0), 1);
    assert_eq!(line_of("a\nb\nc", 2), 2);
    assert_eq!(line_of("a\nb\nc", 99), 3);
}

#[test]
fn base16_slot_reads_one_hex_digit() {
    assert_eq!(base16_slot("base0A: \"ffffff\""), Some((10, " \"ffffff\"")));
    assert_eq!(base16_slot("base0AA: x"), None);
    assert_eq!(base16_slot("base10: x"), None);
}
