//! The typed policy's corpus: the Swift tests of BrowserURLResolver, ported
//! case for case, so the Rust rule is proved equal before the app calls it.
//!
//! - `OmnibarSchemeURLWithSpacesTests` (CmuxNextBrowserTests)
//! - `OmnibarChromeParityTests`: intranet, public hosts, cmux app pages
//! - `MacScreenAddressTests` (CmuxNextAppTests)
//! - `webviews/test/fixtures/new-tab-intents.json`, the rows that reach the
//!   resolver (`NewTabIntent.url(for:home:)`; the `!` terminal rows, the
//!   Chromium page rows and the file-name filter are NewTabIntent's own).
//!
//! The last test holds cases read from BrowserURLResolver.swift where the
//! typed and the daemon policy differ; the app half's side-by-side Swift test
//! runs the same cases through the Swift copy before it is deleted.

use crate::{TypedInput, contains_pairing_link, normalize_url};

/// The fixture's home (`URL(filePath: "/Users/me", directoryHint: .isDirectory)`).
const HOME: &str = "/Users/me/";

fn webkit(input: &str) -> Option<String> {
    TypedInput { home: HOME, allows_chromium_schemes: false }.resolve(input)
}

fn chromium(input: &str) -> Option<String> {
    TypedInput { home: HOME, allows_chromium_schemes: true }.resolve(input)
}

fn assert_loads(input: &str, expected: &str) {
    assert_eq!(webkit(input).as_deref(), Some(expected), "input {input:?}");
}

fn assert_searches(input: &str) {
    assert_eq!(webkit(input), None, "input {input:?} should search");
}

/// OmnibarSchemeURLWithSpacesTests.aSchemeURLWithASpaceAfterItsHostLoads
#[test]
fn a_scheme_url_with_a_space_after_its_host_loads() {
    for (input, expected) in [
        (
            "https://www.google.com/search?q=hello world",
            "https://www.google.com/search?q=hello%20world",
        ),
        ("http://localhost:3000/a b/c", "http://localhost:3000/a%20b/c"),
        ("file:///Users/me/My Notes.html", "file:///Users/me/My%20Notes.html"),
        ("https://example.com/docs#a section", "https://example.com/docs#a%20section"),
    ] {
        assert_loads(input, expected);
    }
}

/// OmnibarSchemeURLWithSpacesTests.otherTextWithSpacesStillSearches
#[test]
fn other_text_with_spaces_still_searches() {
    for input in [
        "https://exa mple.com/",
        "http://foo bar",
        "https: is a protocol",
        "swift testing",
        "example.com/a b",
    ] {
        assert_searches(input);
    }
}

/// OmnibarChromeParityTests.intranetAddressesLoadOverHTTP
#[test]
fn intranet_addresses_load_over_http() {
    for (input, expected) in [
        ("192.168.1.20:3000", "http://192.168.1.20:3000"),
        ("10.0.0.5", "http://10.0.0.5"),
        ("100.89.225.106:18765/status", "http://100.89.225.106:18765/status"),
        ("172.16.4.2/admin", "http://172.16.4.2/admin"),
        ("devbox:8080", "http://devbox:8080"),
        ("devbox/", "http://devbox/"),
        ("router/setup", "http://router/setup"),
        ("nas.local", "http://nas.local"),
        ("grafana.internal:3000/d/abc", "http://grafana.internal:3000/d/abc"),
        ("[fd00::1]:8080", "http://[fd00::1]:8080"),
    ] {
        assert_loads(input, expected);
    }
}

/// OmnibarChromeParityTests.publicHostsAndSearchesAreUnchanged
#[test]
fn public_hosts_and_searches_are_unchanged() {
    assert_loads("example.com", "https://example.com");
    assert_loads("8.8.8.8", "https://8.8.8.8");
    assert_loads("localhost:3000", "http://localhost:3000");
    assert_searches("devbox");
    assert_searches("swift testing");
}

/// OmnibarChromeParityTests.onlyCmuxAppPagesLoadFromTheCmuxScheme
#[test]
fn only_cmux_app_pages_load_from_the_cmux_scheme() {
    assert_loads("cmux://stashed", "cmux://stashed");
    assert_loads("CMUX://Stashed/?q=1", "cmux://stashed");
    assert_searches("cmux://tab/tab_0123");
    assert_searches("cmux:stashed");
}

/// MacScreenAddressTests.macScreenAddressesNeverSearch
#[test]
fn mac_screen_addresses_never_search() {
    for input in [
        "cmux-vnc://pair?signal=https://s.example&room=00112233445566778899aabbccddeeff&secret=abcdefghijklmnopqrstuvwxyzABCDEF0123&name=Mac",
        "cmux://mac-screen",
        "cmux://mac-screen?device=0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff",
    ] {
        assert_loads(input, input);
    }
    assert_loads(
        "cmux-vnc://pair?room=aa&secret=bb&name=Mac",
        "cmux-vnc://pair?room=aa&secret=bb&name=Mac",
    );
}

/// MacScreenAddressTests.otherSchemesStillSearch
#[test]
fn other_schemes_still_search() {
    for input in ["cmux-vnc://other", "cmux://history-elsewhere", "javascript:alert(1)"] {
        assert_searches(input);
    }
}

/// MacScreenAddressTests.newTabNeverSearchesAsksOrLoadsAPairingLink and the
/// fixture's `refused` rows: `BrowserURLResolver.containsPairingLink`.
#[test]
fn pairing_links_are_found_anywhere_in_any_case() {
    for input in [
        "cmux-vnc://pair?room=h7dummyroom0000&secret=h7dummysecret0000",
        "  CMUX-VNC://pair?room=r&secret=s  ",
        "cmux-vnc:pair?room=r&secret=s",
        "connect to cmux-vnc://pair?room=r&secret=s please",
        "!cmux-vnc://pair?room=r&secret=s",
    ] {
        assert!(contains_pairing_link(input), "{input:?}");
    }
    for input in ["cmux-vnc://other", "cmux://mac-screen", "https://example.com/pair", "cmux-vnc:"]
    {
        assert!(!contains_pairing_link(input), "{input:?}");
    }
}

/// new-tab-intents.json `url` rows that NewTabIntent resolves with
/// BrowserURLResolver (WebKit rules), home `/Users/me`.
#[test]
fn new_tab_fixture_url_rows() {
    for (input, expected) in [
        ("github.com", "https://github.com"),
        ("GitHub.com/manaflow-ai/cmux", "https://GitHub.com/manaflow-ai/cmux"),
        ("vite.dev/guide", "https://vite.dev/guide"),
        ("  github.com  ", "https://github.com"),
        ("https://example.com/a?b=1#c", "https://example.com/a?b=1#c"),
        ("http://example.com", "http://example.com"),
        ("https://example.com/very/\nlong/path", "https://example.com/very/long/path"),
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost:3000/api/health", "http://localhost:3000/api/health"),
        ("app.localhost:5173", "http://app.localhost:5173"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("0.0.0.0:8000", "http://0.0.0.0:8000"),
        ("[::1]:8080", "http://[::1]:8080"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("foo.local:3000", "http://foo.local:3000"),
        ("devbox:8080", "http://devbox:8080"),
        ("go/gday", "http://go/gday"),
        ("go/", "http://go/"),
        ("Go/Team-Page?q=1", "http://Go/Team-Page?q=1"),
        ("wiki/Onboarding", "http://wiki/Onboarding"),
        ("nas.lan/share", "http://nas.lan/share"),
        ("10.0.0.5/admin", "http://10.0.0.5/admin"),
        ("example.com:8080/x", "https://example.com:8080/x"),
        ("about:blank", "about:blank"),
        ("file:///tmp/notes.txt", "file:///tmp/notes.txt"),
        ("/tmp", "file:///tmp"),
        ("~", "file:///Users/me/"),
        ("~/code", "file:///Users/me/code"),
        ("x.ai", "https://x.ai"),
        ("github.io", "https://github.io"),
        ("www.readme.md", "https://www.readme.md"),
        ("readme.md/guide", "https://readme.md/guide"),
        ("node.js:3000", "https://node.js:3000"),
        ("https://node.js", "https://node.js"),
        // NewTabIntent's file-name filter turns these into prompts; the
        // resolver itself loads them.
        ("node.js", "https://node.js"),
        ("readme.md", "https://readme.md"),
        ("main.rs", "https://main.rs"),
        ("package.json", "https://package.json"),
        ("App.tsx", "https://App.tsx"),
    ] {
        assert_loads(input, expected);
    }
}

/// new-tab-intents.json `prompt` rows: the resolver searches them.
#[test]
fn new_tab_fixture_prompt_rows() {
    for input in [
        "fix the build",
        "  fix the build  ",
        "what is a.b",
        "open github.com",
        "rust",
        "go",
        "go to gday",
        "1234/5678",
        "a.b",
        "user@example.com",
        "javascript:alert(1)",
        "mailto:a@b.com",
        "chrome://",
        "chrome://user@extensions",
        "cmux://session/abc",
        "example.\ncom",
        "why does ! fail",
        "このビルドを直して",
    ] {
        assert_searches(input);
    }
}

/// `~` resolves in a home given with or without a trailing slash
/// (`URL(filePath: "/Users/me")` in NewTabIntent, a directory URL elsewhere).
#[test]
fn home_with_or_without_a_trailing_slash() {
    let bare = TypedInput { home: "/Users/me", allows_chromium_schemes: false };
    assert_eq!(bare.resolve("~").as_deref(), Some("file:///Users/me/"));
    assert_eq!(bare.resolve("~/code").as_deref(), Some("file:///Users/me/code"));
    assert_eq!(bare.resolve("~/My Notes.md").as_deref(), Some("file:///Users/me/My%20Notes.md"));
}

/// Chromium tabs also take WebUI pages in canonical form; WebKit tabs only the
/// pages cmux shows itself (BrowserURLResolver.chromiumPage).
#[test]
fn chromium_pages_by_engine() {
    assert_eq!(chromium("chrome://extensions").as_deref(), Some("chrome://extensions/"));
    assert_eq!(chromium("about:version").as_deref(), Some("chrome://version/"));
    assert_eq!(
        chromium("chrome-extension://ABC/options.html").as_deref(),
        Some("chrome-extension://abc/options.html")
    );
    assert_searches("chrome://extensions");
    assert_searches("about:version");
    assert_searches("chrome-extension://abc/options.html");
    assert_loads("chrome://history", "chrome://history/");
    assert_loads("about:bookmarks", "chrome://bookmarks/");
    assert_loads("chrome://settings", "chrome://settings/");
    assert_loads("chrome://settings/passwords", "chrome://settings/passwords");
    assert_searches("chrome://settings/content");
}

/// Cases read from BrowserURLResolver.swift where the two policies differ
/// (the PR's P and B lists). The typed policy keeps the Swift behavior; the
/// daemon policy keeps its own. A later PR moves the B cases to Chrome's
/// behavior in both.
#[test]
fn the_typed_and_daemon_policies_differ_where_the_app_and_daemon_differ() {
    for (input, typed, daemon) in [
        ("data:text/html,x", None, "data:text/html,x"),
        ("mailto:a@b.c", None, "mailto:a@b.c"),
        ("ftp://example.com", None, "ftp://example.com"),
        ("user@example.com", None, "https://user@example.com"),
        ("foo.localhost:3000", Some("http://foo.localhost:3000"), "https://foo.localhost:3000"),
        ("127.0.0.2:8080", Some("http://127.0.0.2:8080"), "https://127.0.0.2:8080"),
        (
            "[2001:db8::1]",
            Some("https://[2001:db8::1]"),
            "https://www.google.com/search?q=%5B2001%3Adb8%3A%3A1%5D",
        ),
        ("3.14", None, "https://3.14"),
        ("example.com:99999", None, "https://example.com:99999"),
        ("?example.com", None, "https://?example.com"),
        ("/tmp/a.html", Some("file:///tmp/a.html"), "https:///tmp/a.html"),
        ("localhost:abc", None, "http://localhost:abc"),
        ("example.com.", None, "https://example.com."),
    ] {
        assert_eq!(webkit(input).as_deref(), typed, "typed {input:?}");
        assert_eq!(normalize_url(input), daemon, "daemon {input:?}");
    }
}
