//! ChromiumInternalURL and ChromiumPageRoute, ported from CmuxNextBrowserCore:
//! the Chromium page rows of `webviews/test/fixtures/new-tab-intents.json`
//! (NewTabIntent calls `ChromiumInternalURL(typed:)` first) and the routes
//! the Swift type documents (spec decision CHROME-INTERNAL-PAGES).

use crate::{ChromiumPageRoute, chromium_internal_url, chromium_page_route};

#[test]
fn new_tab_fixture_chromium_rows() {
    for (input, expected) in [
        ("about:config", "chrome://config/"),
        ("chrome://extensions", "chrome://extensions/"),
        ("chrome://extensions/", "chrome://extensions/"),
        ("CHROME://Extensions", "chrome://extensions/"),
        ("chrome://extensions?id=abc", "chrome://extensions/?id=abc"),
        ("chrome:extensions", "chrome://extensions/"),
        ("chrome://settings/passwords", "chrome://settings/passwords"),
        ("about:extensions", "chrome://extensions/"),
        ("ABOUT:Version", "chrome://version/"),
        (
            "chrome-extension://ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP/options.html",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html",
        ),
    ] {
        assert_eq!(chromium_internal_url(input).as_deref(), Some(expected), "input {input:?}");
    }
}

#[test]
fn not_internal_pages() {
    for input in [
        "about:blank",
        "about:srcdoc",
        "ABOUT:Blank?x",
        "chrome://",
        "chrome://user@extensions",
        "chrome://extensions:8080",
        "chrome://ext ensions",
        "https://example.com",
        "devtools://devtools",
        "extensions",
    ] {
        assert_eq!(chromium_internal_url(input), None, "input {input:?}");
    }
}

#[test]
fn routes() {
    use ChromiumPageRoute::{BrowserSettings, Chromium, CmuxPage, PasswordsPage};
    for (url, route) in [
        ("chrome://history", CmuxPage("cmux://history")),
        ("CHROME://History/all", CmuxPage("cmux://history")),
        ("about:history", CmuxPage("cmux://history")),
        ("chrome://bookmarks/?id=1", CmuxPage("cmux://bookmarks")),
        ("chrome://settings", BrowserSettings),
        ("chrome://settings/", BrowserSettings),
        ("chrome://settings/passwords", PasswordsPage),
        ("chrome://settings/passwords/check", PasswordsPage),
        ("chrome://password-manager/settings", PasswordsPage),
        ("chrome://settings/content", Chromium("chrome://settings/content".to_string())),
        ("chrome://settings/passwordsx", Chromium("chrome://settings/passwordsx".to_string())),
        ("chrome://extensions", Chromium("chrome://extensions/".to_string())),
    ] {
        assert_eq!(chromium_page_route(url).as_ref(), Some(&route), "url {url:?}");
    }
    for url in ["chrome-extension://abc/options.html", "https://example.com", "about:blank"] {
        assert_eq!(chromium_page_route(url), None, "url {url:?}");
    }
}

/// `ChromiumPageRoute.isCmuxOwned`: a WebKit tab opens only the pages cmux
/// shows itself (history, bookmarks, Browser settings, Passwords).
#[test]
fn cmux_owned_pages() {
    for (url, owned) in [
        ("chrome://history", true),
        ("chrome://bookmarks", true),
        ("chrome://settings", true),
        ("chrome://settings/passwords", true),
        ("chrome://password-manager", true),
        ("chrome://settings/content", false),
        ("chrome://extensions", false),
        ("chrome://version", false),
    ] {
        let route = chromium_page_route(url);
        assert_eq!(route.map(|route| route.is_cmux_owned()), Some(owned), "url {url:?}");
    }
}
