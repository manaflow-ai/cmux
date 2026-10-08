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
fn folds_full_width_latin_and_ideographic_space() {
    assert_eq!(fold("ＳＷＩＦＴ ｓｗｉｆｔ"), "swift swift");
    assert_eq!(fold("a\u{3000}b"), "a b");
}

#[test]
fn folds_kana_dakuten_and_halfwidth_kana() {
    // Precomposed and halfwidth voiced kana lose the voicing mark.
    assert_eq!(fold("が"), "か");
    assert_eq!(fold("ガ"), "カ");
    assert_eq!(fold("ｶﾞ"), "カ");
    assert_eq!(fold("パ"), "ハ");
}

#[test]
fn folds_sharp_s_to_ss() {
    assert_eq!(fold("Straße"), "strasse");
    assert_eq!(fold("STRAẞE"), "strasse");
    assert_eq!(fold("Straße"), fold("STRASSE"));
}

#[test]
fn folds_greek_final_sigma_and_tonos() {
    assert_eq!(fold("ΟΔΟΣ"), "οδοσ");
    assert_eq!(fold("οδος"), "οδοσ");
    assert_eq!(fold("Ά"), "α");
}

#[test]
fn turkish_dotted_capital_i_folds_without_a_locale() {
    // Locale-free folding (Swift `locale: nil`): U+0130 case-folds to
    // "i" + U+0307 and the dot is a diacritic, so it becomes "i". The
    // dotless "ı" has no fold and stays.
    assert_eq!(fold("İstanbul"), "istanbul");
    assert_eq!(fold("ı"), "ı");
    assert_eq!(fold("I"), "i");
}

#[test]
fn folds_scripts_outside_latin_greek_cyrillic_and_kana() {
    // Vietnamese stacked marks, Hebrew points, Arabic hamza above.
    assert_eq!(fold("Tiếng Việt"), "tieng viet");
    assert_eq!(fold("שָׁלוֹם"), "שלום");
    assert_eq!(fold("أ"), "ا");
    assert_eq!(fold("ё"), "е");
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
