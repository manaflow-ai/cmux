use super::*;

#[test]
fn a_star_matches_any_run_and_literal_text_scores() {
    assert_eq!(
        pattern_score("https://jira.example/*", "https://jira.example/browse/X-1"),
        Some(21)
    );
    assert_eq!(
        pattern_score("https://*.example/browse/*", "https://JIRA.example/browse/x"),
        Some(24)
    );
    assert_eq!(pattern_score("https://jira.example/*", "https://jira.example.evil/x"), None);
    assert_eq!(pattern_score("https://jira.example/*", "http://jira.example/x"), None);
    assert_eq!(pattern_score("*", "anything"), Some(0));
    assert_eq!(pattern_score("a*b*c", "aXbYbZc"), Some(3));
}

#[test]
fn a_scheme_takes_every_link_of_it_below_any_pattern() {
    let entry =
        json!({ "export": "open", "schemes": ["jira"], "options": { "urls": ["jira://x/*"] } });
    assert_eq!(implementation_score(&entry, "JIRA://y"), Some(0));
    assert_eq!(implementation_score(&entry, "jira://x/1"), Some(9));
    assert_eq!(implementation_score(&entry, "https://x"), None);
}
