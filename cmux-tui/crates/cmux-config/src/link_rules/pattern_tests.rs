//! `browser.urlsToAlwaysOpenExternally` rules, pinned to the Swift
//! `BrowserExternalURLPatternMatcher` and `BrowserExternalURLRegexSafety`
//! they replace.

use super::pattern::{Matcher, matches, regex_accepts};

#[test]
fn plain_text_is_a_case_insensitive_substring() {
    assert!(matches(&["billing"], "https://app.example.com/BILLING/x"));
    assert!(matches(&["Example.COM/billing"], "https://example.com/billing"));
    assert!(!matches(&["billing"], "https://example.com/"));
    assert!(!matches::<&str>(&[], "https://example.com/"));
}

#[test]
fn globs_match_anywhere_with_star_and_question_mark() {
    assert!(matches(&["*zoom.us*"], "https://wiki.corp.example/?join=https://zoom.us/j/1"));
    assert!(matches(&["zoom.us/j/*"], "https://zoom.us/j/123"));
    assert!(matches(&["example.?om"], "https://example.com/"));
    assert!(!matches(&["example.?om"], "https://example.om/"));
    assert!(matches(&["a*b*c"], "xxaYYbZZcxx"));
    assert!(!matches(&["a*b*c"], "xxaYYcZZbxx"));
}

#[test]
fn re_prefix_is_a_bounded_case_insensitive_regex() {
    let rule = ["re:^https://docs\\.example\\.com/private/"];
    assert!(matches(&rule, "https://docs.example.com/private/a"));
    assert!(matches(&rule, "HTTPS://DOCS.EXAMPLE.COM/private/a"));
    assert!(!matches(&rule, "https://docs.example.com/public/a"));
    assert!(!matches(&rule, "https://docsXexample.com/private/a"));
    assert!(matches(
        &["RE:  ^https://[^/]*\\.corp\\.example\\.com/"],
        "https://a.corp.example.com/x"
    ));
    assert!(matches(&["re:example\\.com/.*/billing"], "https://example.com/a/b/billing"));
    assert!(matches(&["re:example\\.com/.+/billing"], "https://example.com/a/billing"));
    assert!(!matches(&["re:example\\.com/.+/billing"], "https://example.com//billing"));
}

#[test]
fn legacy_dot_star_rules_without_re_still_match() {
    assert!(matches(&["example\\.com/.*billing"], "https://example.com/team/billing"));
    assert!(!matches(&["example\\.com/.*billing"], "https://exampleXcom/team/billing"));
    assert!(matches(&["^https://example\\.com/"], "https://example.com/x"));
    assert!(!matches(&["^https://example\\.com/"], "http://x/https://example.com/"));
}

#[test]
fn unsafe_regexes_never_match() {
    assert!(!matches(&["re:(a+)+$"], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"));
    assert!(!matches(&["re:(a|b)*"], "ab"));
    assert!(!matches(&["re:(?=a)a"], "a"));
    assert!(!matches(&["re:(a)\\1"], "aa"));
    // A later safe rule still answers.
    assert!(matches(&["re:(a+)+$", "billing"], "https://x/billing"));
}

#[test]
fn regex_safety_accepts_the_bounded_subset() {
    for accepted in [
        "^https?://example\\.com/",
        "a+",
        "a{2,5}",
        "a{3}b{4}",
        "a?b+",
        "(ab)+",
        "a|b",
        "[a-z]+",
        "[(|*+]x",
        "a{16384}",
    ] {
        assert!(regex_accepts(accepted), "{accepted}");
    }
}

#[test]
fn regex_safety_refuses_unbounded_or_unsupported_shapes() {
    let long = "a".repeat(8_193);
    for refused in [
        "",
        long.as_str(),
        "a+b+c+", // three quantifiers
        "a+b*",   // two variable quantifiers
        "a|b|c",  // two alternations
        "(a+)+",  // a quantified group that holds a quantifier
        "(a|b)?", // a quantified group that holds an alternation
        "(?:a)",  // every (? form
        "(?i)a",
        "(a)\\1", // backreference
        "\\k<x>",
        "\\g1",
        "*a", // a quantifier with nothing before it
        "^*",
        "a**",
        "a{2,1}",
        "a{,3}",
        "a{x}",
        "a{16385}",
        "a{1,16385}",
        "a{3",
        "(a", // unclosed group
        "a)",
        "[a-z", // unclosed class
        "a\\",  // trailing escape
    ] {
        assert!(!regex_accepts(refused), "{refused}");
    }
}

#[test]
fn patterns_are_split_trimmed_deduplicated_and_bounded() {
    let matcher = Matcher::new(&["  billing  \n# comment\n\nbilling", "re:x", "", "  "]);
    assert_eq!(matcher.patterns(), ["billing", "re:x"]);

    let many: Vec<String> = (0..300).map(|n| format!("rule{n}")).collect();
    assert_eq!(Matcher::new(&many).patterns().len(), 256);

    let duplicates: Vec<&str> = std::iter::repeat_n("same", 600).chain(["late"]).collect();
    assert_eq!(Matcher::new(&duplicates).patterns(), ["same"]);
}

#[test]
fn oversized_rules_and_targets_never_match() {
    let long_rule = format!("{}x", "a".repeat(4_096));
    assert!(!matches(&[long_rule.as_str()], &format!("https://{long_rule}")));
    let long_target = format!("https://example.com/{}", "a".repeat(16_384));
    assert!(!matches(&["example.com"], &long_target));
    assert!(matches(&["example.com"], &long_target[..16_384]));
}

#[test]
fn a_costly_glob_gives_up_without_blocking_later_rules() {
    let target = format!("https://example.com/{}", "a".repeat(16_000));
    let costly = format!("{}b", "a*".repeat(64));
    assert!(!matches(&[costly.as_str()], &target));
    assert!(matches(&[costly.as_str(), "example.com"], &target));
}
