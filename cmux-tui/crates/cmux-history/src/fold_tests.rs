use super::{fold, tokens};
use crate::fold_table::{DIACRITIC_BASES, WIDTH_FORMS};

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
fn folds_width_forms() {
    assert_eq!(fold("ＳＷＩＦＴ"), "swift");
    assert_eq!(fold("ｶﾞ"), "カ");
    assert_eq!(fold("a\u{3000}b"), "a b");
}

#[test]
fn folds_greek_cyrillic_and_kana_marks() {
    assert_eq!(fold("Ά"), "α");
    assert_eq!(fold("ё"), "е");
    assert_eq!(fold("が"), "か");
}

#[test]
fn keeps_letters_without_a_decomposition() {
    assert_eq!(fold("ø ß œ"), "ø ß œ");
    assert_eq!(fold("日本語"), "日本語");
}

#[test]
fn tokens_split_on_any_whitespace_and_fold() {
    assert_eq!(tokens("  forums\tSWIFT\n"), vec!["forums", "swift"]);
    assert!(tokens("   ").is_empty());
}

#[test]
fn tables_are_sorted_for_binary_search() {
    for table in [DIACRITIC_BASES, WIDTH_FORMS] {
        assert!(table.windows(2).all(|pair| pair[0].0 < pair[1].0));
    }
}
