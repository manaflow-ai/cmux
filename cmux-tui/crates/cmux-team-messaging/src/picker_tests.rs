use super::score;

#[test]
fn score_orders_exact_prefix_word_substring() {
    assert_eq!(score("@bob", &["bob"]), Some(0));
    assert_eq!(score("bo", &["bob"]), Some(1));
    assert_eq!(score("ag", &["bobs-agent"]), Some(2));
    assert_eq!(score("gen", &["bobs-agent"]), Some(3));
    assert_eq!(score("zed", &["bob"]), None);
    assert_eq!(score("  ", &["bob"]), Some(3));
}
