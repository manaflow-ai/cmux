//! Parity tests for `history`: the Swift has no unit test of its own for these types, so the
//! expectations are worked out from the Swift source (every branch of each function).

use crate::history::{self, HistoryEntry, quick};

const NOW: f64 = 1_000_000.0;
const HOME: &str = "/Users/me";

fn entry(url: &str, title: Option<&str>, visits: i64, age_days: f64) -> HistoryEntry {
    HistoryEntry {
        url: url.into(),
        title: title.map(Into::into),
        visit_count: visits,
        typed_count: 0,
        last_visit: NOW - age_days * 86_400.0,
    }
}

fn score(entry: &HistoryEntry, text: &str) -> Option<f64> {
    history::score(entry, text, NOW, HOME)
}

fn show(url: &str) -> String {
    history::display_text(Some(url), HOME)
}

#[test]
fn display_text_drops_scheme_www_and_bare_slash() {
    assert_eq!(show("https://www.github.com/"), "github.com");
    assert_eq!(show("https://github.com/manaflow-ai/cmux"), "github.com/manaflow-ai/cmux");
    assert_eq!(show("https://github.com/a/"), "github.com/a/");
    assert_eq!(show("https://github.com"), "github.com");
    assert_eq!(show("https://github.com/?q=1#top"), "github.com/?q=1#top");
    assert_eq!(show("https://user:pw@example.com:8080/x"), "example.com:8080/x");
}

#[test]
fn display_text_keeps_www_on_a_two_label_host_and_http() {
    assert_eq!(show("https://www.com/"), "www.com");
    assert_eq!(show("http://www.example.com/a"), "http://example.com/a");
    assert_eq!(show("HTTP://Example.com/"), "http://Example.com");
}

#[test]
fn display_text_keeps_chromium_schemes_and_decodes_escapes() {
    assert_eq!(show("chrome://extensions/"), "chrome://extensions");
    assert_eq!(show("chrome-extension://abc/page.html"), "chrome-extension://abc/page.html");
    assert_eq!(show("https://example.com/a%20b"), "example.com/a b");
    assert_eq!(show("https://example.com/%zz"), "example.com/%zz");
    assert_eq!(show("https://example.com/%ff"), "example.com/%ff");
}

#[test]
fn display_text_is_empty_for_blank_pages_and_remote_desktop() {
    assert_eq!(history::display_text(None, HOME), "");
    assert_eq!(show("about:blank"), "");
    assert_eq!(show("chrome://newtab/"), "");
    assert_eq!(show("CHROME://NEWTAB"), "");
    assert_eq!(show("cmux://remote-view?id=1"), "");
}

#[test]
fn display_text_shows_a_file_path_under_tilde() {
    assert_eq!(show("file:///Users/me/notes/a%20b.md"), "~/notes/a b.md");
    assert_eq!(show("file:///Users/me"), "~");
    assert_eq!(show("file:///Users/me2/x"), "/Users/me2/x");
    assert_eq!(history::display_text(Some("file:///Users/me/x"), ""), "/Users/me/x");
    assert_eq!(history::tilde_path("/Users/me/x", "/Users/me//"), "~/x");
    assert_eq!(history::tilde_path("/Users/me/", "/Users/me"), "~");
    assert_eq!(history::tilde_path("/x", "/"), "/x");
}

#[test]
fn display_text_returns_the_text_without_a_host() {
    assert_eq!(show("mailto:a@b.com"), "mailto:a@b.com");
    assert_eq!(show("https:///path"), "https:///path");
    assert_eq!(show("https://[::1]:3000/"), "[::1]:3000");
}

#[test]
fn dedupe_key_treats_scheme_www_and_trailing_slash_as_equal() {
    let key = |url| history::dedupe_key(url, HOME);
    assert_eq!(key("http://www.Example.com/"), "example.com");
    assert_eq!(key("https://example.com"), "example.com");
    assert_eq!(key("https://example.com/a/"), "example.com/a");
    assert_eq!(key("https://example.com/a"), key("http://example.com/a/"));
    assert_eq!(key("https://example.com/A"), "example.com/a");
}

#[test]
fn score_is_none_without_tokens_or_a_match() {
    let e = entry("https://github.com/", Some("GitHub"), 1, 0.0);
    assert_eq!(score(&e, ""), None);
    assert_eq!(score(&e, "   \t"), None);
    assert_eq!(score(&e, "zzz"), None);
    assert_eq!(score(&e, "git zzz"), None);
}

#[test]
fn score_tiers_rank_host_prefix_over_url_prefix_over_title_word_over_substring() {
    let host = entry("https://github.com/", None, 1, 0.0);
    let url = entry("https://example.com/github", None, 1, 0.0);
    let word = entry("https://example.com/", Some("My GitHub"), 1, 0.0);
    let sub = entry("https://example.com/", Some("mygithub"), 1, 0.0);
    // Same URL length for url/word/sub is not needed: compare the match terms by hand.
    let base = |e: &HistoryEntry, m: f64| {
        let url_text = history::display_text(Some(&e.url), HOME).to_lowercase();
        m + 0.0 + 120.0 + (40.0 - url_text.chars().count() as f64 / 4.0).max(0.0)
    };
    assert_eq!(score(&host, "git"), Some(base(&host, 600.0)));
    assert_eq!(score(&url, "example"), Some(base(&url, 450.0)));
    assert_eq!(score(&word, "github"), Some(base(&word, 300.0)));
    assert_eq!(score(&sub, "github"), Some(base(&sub, 150.0)));
}

#[test]
fn score_title_prefix_counts_as_a_word_start_and_only_the_first_token_takes_host_prefix() {
    let e = entry("https://github.com/", Some("GitHub"), 1, 0.0);
    let url_text = "github.com".chars().count() as f64;
    let tail = 120.0 + (40.0 - url_text / 4.0);
    // "git" host prefix 600; "hub" substring 150: mean 375.
    assert_eq!(score(&e, "git hub"), Some(375.0 + tail));
    // "hub" first is not a prefix of host or url: title substring 150.
    assert_eq!(score(&e, "hub"), Some(150.0 + tail));
}

#[test]
fn score_adds_frequency_recency_and_brevity() {
    let e = entry("https://a.co/", None, 8, 14.0);
    // frequency log2(8)*40 = 120, recency 120/e, brevity 40 - 4/4 = 39.
    let expected = 600.0
        + 8.0_f64.log2() * 40.0
        + 120.0 * (-(14.0_f64 * 86_400.0 / 86_400.0) / 14.0).exp()
        + 39.0;
    let got = score(&e, "a.co").unwrap();
    assert!((got - expected).abs() < 1e-9, "{got} vs {expected}");
    // A zero visit count counts as one, a future visit as no age.
    let zero = entry("https://a.co/", None, 0, -3.0);
    assert_eq!(score(&zero, "a.co"), Some(600.0 + 0.0 + 120.0 + 39.0));
    // Deep URLs lose their brevity to zero.
    let long = format!("https://a.co/{}", "x".repeat(200));
    let e = entry(&long, None, 1, 0.0);
    assert_eq!(score(&e, "a.co"), Some(600.0 + 120.0));
}

#[test]
fn score_lowercases_text_and_title_and_ignores_scheme_www() {
    let e = entry("https://www.GitHub.com/", Some("The GITHUB"), 1, 0.0);
    assert!(score(&e, "GIT").is_some());
    assert_eq!(score(&e, "git"), score(&e, "  git  "));
}

#[test]
fn text_rules_split_tokens_words_and_url_prefix() {
    assert_eq!(history::query_tokens("  Foo\tBAR  baz "), ["foo", "bar", "baz"]);
    assert_eq!(history::query_tokens("a b c d e f g h i j").len(), 8);
    assert_eq!(history::words("github.com/manaflow-ai"), ["github", "com", "manaflow", "ai"]);
    assert_eq!(history::words("Ünï 42!x"), ["ünï", "42", "x"]);
    assert!(history::words("--").is_empty());
    assert_eq!(history::url_prefix("  HTTPS://www.Foo.com/x "), "foo.com/x");
    assert_eq!(history::url_prefix("https://http://a"), "a");
    assert_eq!(history::url_prefix("http://www.a"), "a");
    assert_eq!(history::url_prefix("ftp://a"), "ftp://a");
}

#[test]
fn quick_match_means_the_token_terms() {
    let t = |s: &[&str]| s.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let tokens = t(&["git", "hub"]);
    let spaced = t(&[" git", " hub"]);
    assert_eq!(
        quick::match_term(&tokens, &spaced, "github.com", "github.com/", " my hub"),
        Some(450.0)
    );
    assert_eq!(quick::match_term(&t(&["x"]), &t(&[" x"]), "a", "a", " x y"), Some(300.0));
    assert_eq!(quick::match_term(&t(&["x"]), &t(&[" x"]), "a", "ax", " b"), Some(150.0));
    assert_eq!(quick::match_term(&t(&["q"]), &t(&[" q"]), "a", "b", " c"), None);
    assert_eq!(quick::match_term(&[], &[], "a", "b", " c"), None);
}

#[test]
fn quick_terms() {
    assert_eq!(quick::usage(8, 0), 120.0);
    assert_eq!(quick::usage(0, 2), 200.0);
    assert_eq!(quick::recency(NOW, NOW), 120.0);
    assert_eq!(quick::recency(NOW + 5.0, NOW), 120.0);
    assert_eq!(quick::brevity(0), 40.0);
    assert_eq!(quick::brevity(400), 0.0);
    assert_eq!(quick::score(600.0, 8, 1, NOW, NOW, 40), 600.0 + 320.0 + 120.0 + 30.0);
    assert!(quick::allows_inline_completion(true, 1, 1));
    assert!(quick::allows_inline_completion(true, 4, 0));
    assert!(!quick::allows_inline_completion(true, 3, 0));
    assert!(!quick::allows_inline_completion(false, 9, 9));
    assert_eq!(quick::MAX_RECENCY, 120.0);
}
