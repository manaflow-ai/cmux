//! Remote stderr shown to the person is trimmed and cut at a char boundary.

use super::*;

#[test]
fn short_output_is_trimmed_and_cleaned() {
    assert_eq!(sanitize("  a\r\0b \n"), "ab");
}

#[test]
fn long_output_is_cut_at_a_char_boundary() {
    let long = format!("{}é tail", "a".repeat(4_095));
    let cut = sanitize(&long);
    assert_eq!(cut, format!("{}…", "a".repeat(4_095)));
    let exact = "b".repeat(4_096);
    assert_eq!(sanitize(&exact), exact);
    assert_eq!(sanitize(&"c".repeat(4_097)), format!("{}…", "c".repeat(4_096)));
}
