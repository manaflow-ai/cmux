use super::{fold, tokens};

#[test]
fn folds_case_and_latin_diacritics() {
    assert_eq!(fold("Résumé"), "resume");
    assert_eq!(fold("ÀÉÎÕÜ çñ"), "aeiou cn");
    assert_eq!(fold("Ångström"), "angstrom");
}

#[test]
fn folds_decomposed_input() {
    assert_eq!(fold("Re\u{301}sume\u{301}"), "resume");
}

#[test]
fn keeps_letters_without_a_decomposition() {
    assert_eq!(fold("ø œ ł"), "ø œ ł");
    assert_eq!(fold("日本語"), "日本語");
}

#[test]
fn tokens_split_on_any_whitespace_and_fold() {
    assert_eq!(tokens("  forums\tSWIFT\n"), vec!["forums", "swift"]);
    assert!(tokens("   ").is_empty());
}
