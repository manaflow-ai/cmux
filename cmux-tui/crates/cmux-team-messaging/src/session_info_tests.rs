use super::*;

#[test]
fn excerpt_flattens_and_cuts_on_a_char_boundary() {
    assert_eq!(excerpt("a\n\n b  c"), "a b c");
    let long = "é".repeat(ASK_EXCERPT_CHARS + 5);
    let e = excerpt(&long);
    assert_eq!(e.chars().count(), ASK_EXCERPT_CHARS);
    assert!(e.ends_with('…'));
}
