//! The omnibar rules, pinned to the Swift they replace: OmnibarFilePathDisplayTests,
//! OmnibarCutsTests (the address at rest), OmnibarDropTests (`droppedTextIsCleaned`),
//! OmnibarChromeParityTests (`controlEnterAddsWWWAndCom`, the resolver cases) and
//! OmnibarChromeGapsTests (`showFullURLsKeepsSchemeAndWWW`), plus the cases `OmnibarRules` and
//! `BrowserURLDisplay` document in their comments.

use crate::omnibar::*;
use crate::ops;
use cmux_url_input::TypedInput;
use serde_json::json;

const HOME: &str = "/Users/someone";

fn resolver() -> TypedInput<'static> {
    TypedInput { home: HOME, allows_chromium_schemes: false }
}

fn row(kind: Kind, url: &str) -> Suggestion {
    Suggestion {
        kind,
        title: "Title".into(),
        detail: String::new(),
        url: url.into(),
        score: 0.0,
        content: None,
        inline_completable: true,
        tab_key: None,
    }
}

fn utf16_slice(text: &str, range: Range) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16(&units[range.location as usize..(range.location + range.length) as usize])
        .unwrap()
}

// MARK: OmnibarFilePathDisplayTests

#[test]
fn a_file_under_home_shows_the_tilde_form() {
    let url = "file:///Users/someone/fun/notes/README.md";
    assert_eq!(display_text(Some(url), HOME), "~/fun/notes/README.md");
}

#[test]
fn a_remote_desktop_tab_shows_no_address() {
    let desktop = "cmux://remote-view?host=vm-4a1ca3aa&target=virtual&mode=control&via=cloud-rd";
    assert_eq!(display_text(Some(desktop), HOME), "");
    assert_eq!(editing_text(Some(desktop)), "");
    let page = "https://example.com/a";
    assert_eq!(display_text(Some(page), HOME), "example.com/a");
    assert_eq!(editing_text(Some(page)), "https://example.com/a");
}

#[test]
fn home_itself_is_tilde() {
    assert_eq!(display_text(Some("file:///Users/someone/"), HOME), "~");
}

#[test]
fn a_sibling_of_home_keeps_the_whole_path() {
    assert_eq!(display_text(Some("file:///Users/someone2/a.md"), HOME), "/Users/someone2/a.md");
    assert_eq!(display_text(Some("file:///tmp/a%20b.md"), HOME), "/tmp/a b.md");
}

#[test]
fn editing_keeps_the_absolute_address() {
    let url = "file:///Users/someone/fun/README.md";
    assert_eq!(editing_text(Some(url)), url);
}

#[test]
fn a_trailing_slash_on_home_is_ignored_and_a_bare_root_home_shortens_nothing() {
    assert_eq!(tilde_path("/Users/someone/a", "/Users/someone/"), "~/a");
    assert_eq!(tilde_path("/a", "/"), "/a");
    assert_eq!(tilde_path("/a", ""), "/a");
    assert_eq!(tilde_path("/Users/someone//", HOME), "~");
}

// MARK: OmnibarCutsTests, the page's address at rest

#[test]
fn at_rest_the_field_shows_the_pages_address() {
    for (address, shown) in [
        (
            "https://github.com/manaflow-ai/cmux/pull/47051",
            "github.com/manaflow-ai/cmux/pull/47051",
        ),
        (
            "https://www.github.com/manaflow-ai/cmux/pull/1?tab=files#diff",
            "github.com/manaflow-ai/cmux/pull/1?tab=files#diff",
        ),
        ("http://example.com/login?next=%2Fhome", "http://example.com/login?next=/home"),
        ("http://localhost:3000/dashboard", "http://localhost:3000/dashboard"),
        ("https://claude.ai/", "claude.ai"),
    ] {
        assert_eq!(display_text(Some(address), HOME), shown, "{address}");
        let host = host_range(shown, Some(address)).unwrap_or_else(|| panic!("no host in {shown}"));
        assert!(host.length > 0, "{address}");
    }
}

#[test]
fn display_text_drops_credentials_www_and_the_bare_slash_and_keeps_chromium_schemes() {
    assert_eq!(display_text(Some("https://user:pw@www.example.com/"), HOME), "example.com");
    assert_eq!(display_text(Some("https://example.com"), HOME), "example.com");
    assert_eq!(display_text(Some("https://example.com:8443/a"), HOME), "example.com:8443/a");
    assert_eq!(display_text(Some("chrome://extensions/"), HOME), "chrome://extensions");
    assert_eq!(
        display_text(Some("chrome-extension://abc/page.html"), HOME),
        "chrome-extension://abc/page.html"
    );
    assert_eq!(display_text(Some("HTTP://Example.com/x"), HOME), "http://Example.com/x");
    assert_eq!(display_text(Some("https://www.com/x"), HOME), "www.com/x", "two labels keep www");
    assert_eq!(display_text(Some("https://[::1]:3000/"), HOME), "[::1]:3000");
    assert_eq!(display_text(Some("mailto:a@b.c"), HOME), "mailto:a@b.c");
    assert_eq!(display_text(Some("https://example.com/%zz"), HOME), "example.com/%zz");
    assert_eq!(display_text(None, HOME), "");
}

#[test]
fn the_new_tab_pages_show_nothing() {
    for url in ["about:blank", "chrome://newtab/", "CHROME://NEWTAB"] {
        assert_eq!(display_text(Some(url), HOME), "", "{url}");
        assert_eq!(editing_text(Some(url)), "", "{url}");
    }
    assert_eq!(editing_text(None), "");
}

#[test]
fn the_resting_text_is_the_host_alone() {
    assert_eq!(resting_text(Some("https://www.github.com/a/b?c#d"), HOME), "github.com");
    assert_eq!(resting_text(Some("http://localhost:3000/x"), HOME), "localhost:3000");
    assert_eq!(resting_text(Some("https://[::1]:8080/x"), HOME), "[::1]:8080");
    assert_eq!(resting_text(Some("file:///Users/someone/a.md"), HOME), "~/a.md");
    assert_eq!(resting_text(Some("chrome://extensions/"), HOME), "chrome://extensions");
    assert_eq!(resting_text(None, HOME), "");
}

// MARK: OmnibarChromeGapsTests, Always Show Full URLs

#[test]
fn show_full_urls_keeps_scheme_and_www() {
    let page = "https://www.example.com/a?b=1";
    assert_eq!(display_text(Some(page), HOME), "example.com/a?b=1");
    let full = editing_text(Some(page));
    assert_eq!(full, "https://www.example.com/a?b=1");
    let host = host_range(&full, Some(page)).unwrap();
    assert_eq!(utf16_slice(&full, host), "www.example.com");
    assert_eq!(host, Range { location: 8, length: 15 });
}

#[test]
fn the_host_range_follows_the_text_shown() {
    let page = "https://www.example.com/a";
    assert_eq!(host_range("example.com/a", Some(page)), Some(Range { location: 0, length: 11 }));
    assert_eq!(host_range("something else", Some(page)), None);
    assert_eq!(host_range("x", Some("file:///a")), None);
    assert_eq!(host_range("x", None), None);
    assert_eq!(
        host_range("[::1]:3000", Some("https://[::1]:3000/")),
        Some(Range { location: 0, length: 5 })
    );
    assert_eq!(
        host_range("HTTPS://Example.com/", Some("https://example.com/")),
        Some(Range { location: 8, length: 11 })
    );
}

// MARK: OmnibarDropTests

#[test]
fn dropped_text_is_cleaned() {
    for (dropped, expected) in [
        ("javascript:alert(1)", "alert(1)"),
        ("JavaScript: javascript:void(0)", "void(0)"),
        ("  two\n words  \t here ", "two words here"),
    ] {
        assert_eq!(dropped_text(dropped), expected, "{dropped:?}");
    }
    assert_eq!(dropped_text("   "), "");
    assert_eq!(dropped_text("javascript:"), "");
}

#[test]
fn pasted_text_goes_on_one_line_without_moving_utf16_offsets() {
    assert_eq!(single_line("a\nb\r\nc\u{2028}d\u{85}e"), "a b  c d e");
    let text = "a😀\nb";
    assert_eq!(utf16_length(&single_line(text)), utf16_length(text));
    assert_eq!(single_line("no breaks\t"), "no breaks\t");
}

// MARK: OmnibarChromeParityTests, Ctrl-Enter

#[test]
fn control_enter_adds_www_and_com() {
    for (text, expected) in [
        ("example", "https://www.example.com"),
        ("google/maps", "https://www.google.com/maps"),
        ("www.example", "https://www.example.com"),
    ] {
        assert_eq!(desired_tld_url(text, &resolver()).as_deref(), Some(expected), "{text}");
    }
}

#[test]
fn control_enter_leaves_text_with_a_tld_a_scheme_a_port_or_spaces_alone() {
    for text in
        ["example.org", "https://example", "example:80", "two words", "", "  ", "a@b", "ex_ample"]
    {
        assert_eq!(desired_tld_url(text, &resolver()), None, "{text:?}");
    }
    assert_eq!(
        desired_tld_url("  Example?q=1 ", &resolver()).as_deref(),
        Some("https://www.example.com?q=1")
    );
    assert_eq!(
        desired_tld_url("my-site#top", &resolver()).as_deref(),
        Some("https://www.my-site.com#top")
    );
}

// MARK: inline completion (OmnibarRules.inlineCompletion's documented rules)

#[test]
fn a_prefix_of_the_shown_url_or_the_full_url_completes() {
    let history = row(Kind::History {}, "https://www.github.com/manaflow-ai/cmux");
    assert_eq!(
        inline_completion(&history, "git", HOME).as_deref(),
        Some("hub.com/manaflow-ai/cmux")
    );
    assert_eq!(
        inline_completion(&history, "GIT", HOME).as_deref(),
        Some("hub.com/manaflow-ai/cmux")
    );
    assert_eq!(
        inline_completion(&history, "https://www.gi", HOME).as_deref(),
        Some("thub.com/manaflow-ai/cmux")
    );
    assert_eq!(
        inline_completion(&history, "github.com/manaflow-ai/cmux", HOME),
        None,
        "nothing left"
    );
    assert_eq!(inline_completion(&history, "zzz", HOME), None);
}

#[test]
fn the_full_form_drops_the_slash_of_a_bare_host() {
    let navigate = row(Kind::Navigate {}, "https://example.com/");
    assert_eq!(inline_completion(&navigate, "https://ex", HOME).as_deref(), Some("ample.com"));
    assert_eq!(inline_completion(&navigate, "ex", HOME).as_deref(), Some("ample.com"));
}

#[test]
fn a_trailing_space_an_empty_text_and_the_wrong_rows_never_complete() {
    let history = row(Kind::History {}, "https://example.com/a");
    assert_eq!(inline_completion(&history, "", HOME), None);
    assert_eq!(inline_completion(&history, "example ", HOME), None);
    let mut off = history.clone();
    off.inline_completable = false;
    assert_eq!(inline_completion(&off, "ex", HOME), None);
    for kind in [Kind::Search {}, Kind::Keyword {}, Kind::SwitchToTab {}, Kind::Answer {}] {
        assert_eq!(
            inline_completion(&row(kind, "https://example.com/a"), "ex", HOME),
            None,
            "{kind:?}"
        );
    }
    assert_eq!(
        inline_completion(&row(Kind::Bookmark {}, "https://example.com/a"), "ex", HOME).as_deref(),
        Some("ample.com/a")
    );
}

#[test]
fn a_completion_counts_characters_not_utf16_units() {
    let history = row(Kind::History {}, "https://example.com/caf%C3%A9");
    assert_eq!(inline_completion(&history, "example.com/ca", HOME).as_deref(), Some("fé"));
}

// MARK: fill text

#[test]
fn an_arrowed_row_fills_the_field_by_its_kind() {
    let mut search = row(Kind::Search {}, "https://google.com/search?q=x");
    search.title = "swift testing".into();
    assert_eq!(fill_text(&search), "swift testing");
    let mut keyword = row(Kind::Keyword {}, "https://example.com/");
    assert_eq!(fill_text(&keyword), "Title");
    keyword.content = Some("sent text".into());
    assert_eq!(fill_text(&keyword), "sent text");
    let mut answer = row(Kind::Answer {}, "https://example.com/");
    answer.content = Some("42".into());
    assert_eq!(fill_text(&answer), "42");
    for kind in [Kind::Navigate {}, Kind::History {}, Kind::Bookmark {}, Kind::SwitchToTab {}] {
        assert_eq!(fill_text(&row(kind, "https://example.com/a")), "https://example.com/a");
    }
    assert_eq!(fill_text(&row(Kind::History {}, "about:blank")), "");
}

// MARK: selection

#[test]
fn a_selection_is_clamped_and_a_caret_stays_a_caret() {
    let r = |location, length| Range { location, length };
    assert_eq!(clamped(r(3, 0), 10), r(3, 0), "a caret keeps its place");
    assert_eq!(clamped(r(3, 4), 10), r(3, 4));
    assert_eq!(clamped(r(8, 9), 10), r(8, 2));
    assert_eq!(clamped(r(20, 3), 10), r(10, 0));
    assert_eq!(clamped(r(-4, 3), 10), r(0, 3));
    assert_eq!(clamped(r(2, -3), 10), r(2, 0));
    assert_eq!(clamped(r(NOT_FOUND, 5), 10), r(10, 0));
    assert_eq!(utf16_length("a😀é"), 4);
}

// MARK: https upgrade

#[test]
fn a_scheme_less_text_that_resolves_to_the_https_url_is_its_upgrade() {
    let resolver = resolver();
    assert!(is_https_upgrade("example.com", "https://example.com", &resolver));
    assert!(is_https_upgrade("  example.com ", "https://example.com", &resolver));
    assert!(!is_https_upgrade("https://example.com", "https://example.com", &resolver));
    assert!(!is_https_upgrade("example.com", "http://example.com", &resolver));
    assert!(!is_https_upgrade("example.org", "https://example.com", &resolver));
    assert!(!is_https_upgrade("swift testing", "https://example.com", &resolver));
}

// MARK: the JSON ops

fn call(op: &str, request: serde_json::Value) -> serde_json::Value {
    ops::call(op, request).unwrap()
}

#[test]
fn the_ops_answer_in_swifts_codable_shape() {
    let row = json!({"kind": {"history": {}}, "title": "T", "detail": "", "url": "https://www.github.com/a/b",
                     "score": 1.0, "inlineCompletable": true});
    assert_eq!(
        call(
            "browser_rules_omnibar_inline_completion",
            json!({"row": row, "typed": "git", "home": HOME})
        ),
        json!("hub.com/a/b")
    );
    assert_eq!(
        call("browser_rules_omnibar_fill_text", json!({"row": row})),
        json!("https://www.github.com/a/b")
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_display_text",
            json!({"url": "https://www.github.com/a/b", "home": HOME})
        ),
        json!("github.com/a/b")
    );
    assert_eq!(call("browser_rules_omnibar_display_text", json!({"home": HOME})), json!(""));
    assert_eq!(
        call("browser_rules_omnibar_resting_text", json!({"url": "https://www.github.com/a"})),
        json!("github.com")
    );
    assert_eq!(
        call("browser_rules_omnibar_editing_text", json!({"url": "about:blank"})),
        json!("")
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_host_range",
            json!({"text": "https://www.example.com/a", "url": "https://www.example.com/a"})
        ),
        json!({"location": 8, "length": 15})
    );
    assert_eq!(call("browser_rules_omnibar_host_range", json!({"text": "x"})), json!(null));
    assert_eq!(
        call("browser_rules_omnibar_tilde_path", json!({"path": "/Users/someone/a", "home": HOME})),
        json!("~/a")
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_desired_tld_url",
            json!({"typed": "google/maps", "home": HOME})
        ),
        json!("https://www.google.com/maps")
    );
    assert_eq!(
        call("browser_rules_omnibar_desired_tld_url", json!({"typed": "a.b", "home": HOME})),
        json!(null)
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_is_https_upgrade",
            json!({"text": "example.com", "url": "https://example.com", "home": HOME})
        ),
        json!(true)
    );
    assert_eq!(call("browser_rules_omnibar_single_line", json!({"text": "a\nb"})), json!("a b"));
    assert_eq!(
        call("browser_rules_omnibar_dropped_text", json!({"text": " javascript: x "})),
        json!("x")
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_clamped",
            json!({"selection": {"location": 8, "length": 9}, "length": 10})
        ),
        json!({"location": 8, "length": 2})
    );
    assert_eq!(
        call(
            "browser_rules_omnibar_clamped",
            json!({"selection": {"location": i64::MAX, "length": 0}, "length": 10})
        ),
        json!({"location": 10, "length": 0})
    );
    assert_eq!(call("browser_rules_omnibar_utf16_length", json!({"text": "a😀"})), json!(3));
}

#[test]
fn a_row_with_defaults_and_a_bad_request() {
    let minimal = json!({"kind": {"search": {}}, "title": "q", "url": "https://x.test/"});
    assert_eq!(call("browser_rules_omnibar_fill_text", json!({"row": minimal})), json!("q"));
    let wrong = ops::call("browser_rules_omnibar_fill_text", json!({"row": {"kind": "search"}}));
    assert!(matches!(wrong, Err(ops::OpError::Invalid(_))));
}
