use super::*;

#[test]
fn the_embedded_table_reads() {
    let t = Table::embedded();
    assert!(t.synonyms.len() > 5 && t.unsafe_word("--dry-run-push") && !t.unsafe_word("status"));
    assert!(t.mates("show", false).contains(&"get"));
    assert!(t.unsafe_word("--rm") && t.unsafe_word("--Force") && !t.unsafe_word("--dry-run"));
}
