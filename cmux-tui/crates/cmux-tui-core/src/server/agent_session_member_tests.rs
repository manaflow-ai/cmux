use super::*;

#[test]
fn a_member_name_is_one_short_line_or_the_fallback() {
    assert_eq!(display_name(Some("  Ana  ")), "Ana");
    assert_eq!(display_name(None), FALLBACK_NAME);
    assert_eq!(display_name(Some("")), FALLBACK_NAME);
    assert_eq!(display_name(Some("Ana\nOwner")), FALLBACK_NAME);
    assert_eq!(display_name(Some("A\u{202E}na")), FALLBACK_NAME);
    assert_eq!(display_name(Some(&"x".repeat(65))), FALLBACK_NAME);
}

#[test]
fn only_a_cloud_account_id_is_a_member() {
    assert!(valid_user("user_0123456789abcdef0123"));
    assert!(!valid_user("42"));
    assert!(!valid_user("user_"));
    assert!(!valid_user("user_a b"));
    assert!(!valid_user("tailnet:ana@example.com"));
    assert!(!valid_user("guest:abc"));
}
