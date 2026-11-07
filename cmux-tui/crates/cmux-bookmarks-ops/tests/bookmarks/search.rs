//! Search, ranking and the URL rules (ported from the app's Swift
//! `BookmarkRanker`, `BookmarkSearch` and `BookmarkURL`, which they replace).

use cmux_bookmarks_core::{Bookmark, Tree};
use cmux_bookmarks_ops::search::{
    display_text, favicon_key, fold, parse_typed, rank, score, search, url_key,
};

const NOW: u64 = 1_700_000_000_000;

fn node(id: u32, parent: &str, kind: &str, title: &str, url: Option<&str>) -> Bookmark {
    Bookmark {
        id: format!("bm_{id:032x}"),
        browser_profile_id: "default".into(),
        parent: parent.into(),
        kind: kind.into(),
        index: id as usize,
        title: title.into(),
        url: url.map(str::to_string),
        favicon_key: None,
        source_key: None,
        created_ms: NOW,
        last_used_ms: None,
        icon: None,
    }
}

#[test]
fn folds_case_diacritics_and_width() {
    assert_eq!(fold("Café ＡＢ"), "cafe ab");
}

#[test]
fn search_needs_every_term_in_title_or_url_and_keeps_tree_order() {
    let tree = Tree::from_listing(
        "default",
        [
            node(1, "bar", "url", "Rust book", Some("https://doc.rust-lang.org/book")),
            node(2, "bar", "folder", "Résumé drafts", None),
            node(3, "other", "url", "Docs", Some("https://rust.test/resume")),
        ],
    );
    let ids =
        |text: &str| search(&tree, text).into_iter().map(|node| node.title).collect::<Vec<_>>();
    assert_eq!(ids("rust"), ["Rust book", "Docs"]);
    assert_eq!(ids("resume"), ["Résumé drafts", "Docs"]);
    assert_eq!(ids("rust book"), ["Rust book"]);
    assert!(ids("  ").is_empty());
}

#[test]
fn rank_prefers_the_host_then_title_words_then_the_url() {
    let host = node(1, "bar", "url", "Code", Some("https://github.com/x"));
    let title = node(2, "bar", "url", "My github notes", Some("https://notes.test/a"));
    let url = node(3, "bar", "url", "Notes", Some("https://notes.test/github"));
    let folder = node(4, "bar", "folder", "github", None);
    let a = score(&host, "git", NOW).unwrap_or_default();
    let b = score(&title, "git", NOW).unwrap_or_default();
    let c = score(&url, "hub", NOW).unwrap_or_default();
    assert!(a > b && b > c, "{a} {b} {c}");
    assert_eq!(score(&folder, "git", NOW), None);
    assert_eq!(score(&host, "zzz", NOW), None);
    let ranked = rank([&url, &title, &host, &folder], "git", NOW, 10);
    let order = ranked.iter().map(|row| row.bookmark.title.as_str()).collect::<Vec<_>>();
    assert_eq!(order, ["Code", "My github notes", "Notes"]);
    assert!(ranked.iter().all(|row| row.score <= 999.0));
}

#[test]
fn rank_keeps_one_row_per_page_and_recent_use_raises_it() {
    let mut used = node(1, "bar", "url", "Example", Some("https://Example.com"));
    let plain = node(2, "bar", "url", "Example", Some("https://example.com/"));
    used.last_used_ms = Some(NOW - 1000);
    let ranked = rank([&plain, &used], "exa", NOW, 5);
    assert_eq!(ranked.len(), 1);
    assert_eq!(ranked[0].bookmark.id, used.id);
    assert_eq!(rank([&plain, &used], "exa", NOW, 0).len(), 0);
}

#[test]
fn url_rules() {
    assert_eq!(url_key("HTTPS://Example.COM"), "https://example.com/");
    assert_eq!(url_key("https://example.com/A?b#c"), "https://example.com/A?b#c");
    assert_eq!(url_key("mailto:A@B.com"), "mailto:A@B.com");
    assert_eq!(
        favicon_key("https://User@Example.com:8443/x").as_deref(),
        Some("https://example.com:8443")
    );
    assert_eq!(favicon_key("https://example.com/x").as_deref(), Some("https://example.com"));
    assert_eq!(favicon_key("about:blank"), None);
    assert_eq!(display_text("https://www.github.com/"), "github.com");
    assert_eq!(display_text("https://github.com/foo/"), "github.com/foo/");
    assert_eq!(display_text("file:///tmp/a"), "file:///tmp/a");
    assert_eq!(parse_typed("example.com").as_deref(), Some("https://example.com"));
    assert_eq!(parse_typed("localhost:3000").as_deref(), Some("http://localhost:3000"));
    assert_eq!(parse_typed(" https://a.test/x ").as_deref(), Some("https://a.test/x"));
    assert_eq!(parse_typed("two words"), None);
    assert_eq!(parse_typed("plain"), None);
}

/// A query uses at most `MAX_TERMS` terms (review F4): a huge repeated query costs no more per
/// node than a short one, and it still matches.
#[test]
fn a_query_uses_at_most_max_terms_terms() {
    let long = "git ".repeat(10_000);
    assert_eq!(
        cmux_bookmarks_ops::search::tokens(&long).len(),
        cmux_bookmarks_ops::search::MAX_TERMS
    );
    let github = node(1, "bar", "url", "GitHub", Some("https://github.com/"));
    let ranked = rank([&github], &long, 0, 5);
    assert_eq!(ranked.len(), 1);
}

/// Review 4 F3: only the host is lowercased; user info holding the host's text keeps its case.
#[test]
fn the_same_page_key_lowercases_only_the_host() {
    assert_eq!(
        url_key("https://EXAMPLE:pw@Example.COM:8080/a"),
        "https://EXAMPLE:pw@example.com:8080/a"
    );
    assert_eq!(url_key("https://Example.COM"), "https://example.com/");
    assert_eq!(url_key("https://User@[::1]:80/x"), "https://User@[::1]:80/x");
}
