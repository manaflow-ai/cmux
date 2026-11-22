//! Chromium internal pages, ported from CmuxNextBrowserCore
//! `Core/ChromiumInternalURL.swift` and `Core/ChromiumPageRoute.swift`.
//!
//! A typed `chrome://`, `chrome-extension://` or `about:` alias of a
//! `chrome://` page in Chromium's canonical form, so every spelling of one
//! page is one URL:
//!
//! - `chrome` and `chrome-extension` are standard schemes: scheme and host are
//!   lowercased, the slashes after the colon are optional, and an empty path
//!   becomes `/` (`chrome://extensions?id=x` is `chrome://extensions/?id=x`),
//!   as GURL canonicalizes them.
//! - `about:<page>` is `chrome://<page>`, as `url_formatter::FixupURL` maps it;
//!   `about:blank` and `about:srcdoc` are not aliases.
//! - Userinfo, a port, or a host with other characters than ASCII letters,
//!   digits, `-`, `_` and `.` is not an internal page.

use crate::text::split_before;
use crate::uri::parse_strict;

/// Where a Chromium internal page opens (spec decision CHROME-INTERNAL-PAGES):
/// cmux's own page when cmux has a page for the same data, else Chromium's
/// own WebUI in a Chromium tab.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChromiumPageRoute {
    /// cmux's own page for the same data (`cmux://history`, `cmux://bookmarks`).
    CmuxPage(&'static str),
    /// Settings, Browser section (`chrome://settings`, the root only).
    BrowserSettings,
    /// cmux's Passwords page (`chrome://password-manager`, `chrome://settings/passwords`).
    PasswordsPage,
    /// Chromium's own page, in canonical form.
    Chromium(String),
}

impl ChromiumPageRoute {
    /// True when cmux shows the page itself, so a WebKit tab can open it too.
    pub fn is_cmux_owned(&self) -> bool {
        !matches!(self, Self::Chromium(_))
    }
}

/// Hosts whose pages cmux shows itself, and the cmux page for each.
const CMUX_PAGES: [(&str, &str); 2] =
    [("history", "cmux://history"), ("bookmarks", "cmux://bookmarks")];

fn is_host_character(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')
}

/// `ChromiumInternalURL(text, scheme:)`: `scheme` is the lowercased scheme of
/// `text`. The canonical URL, or `None`.
pub(crate) fn internal_url_with_scheme(text: &str, scheme: &str) -> Option<String> {
    let (_, mut rest) = text.split_once(':')?;
    let canonical_scheme = match scheme {
        "chrome" | "chrome-extension" => scheme,
        "about" => {
            let (page, _) = split_before(rest, |c| matches!(c, '?' | '#'));
            let page = page.to_lowercase();
            if page == "blank" || page == "srcdoc" {
                return None;
            }
            "chrome"
        }
        _ => return None,
    };
    rest = rest.trim_start_matches('/');
    let (host, tail) = split_before(rest, |c| matches!(c, '/' | '?' | '#'));
    let host = host.to_lowercase();
    if host.is_empty() || !host.chars().all(is_host_character) {
        return None;
    }
    let slash = if tail.starts_with('/') { "" } else { "/" };
    let url = format!("{canonical_scheme}://{host}{slash}{tail}");
    let parts = parse_strict(&url)?;
    (parts.host == Some(host.as_str())).then_some(url)
}

/// `ChromiumInternalURL(typed:)`: typed text that names a Chromium internal
/// page, in canonical form; `None` for anything else (`about:blank` included:
/// every engine has it).
pub fn chromium_internal_url(text: &str) -> Option<String> {
    let (scheme, _) = text.split_once(':')?;
    let scheme = scheme.to_lowercase();
    if !matches!(scheme.as_str(), "chrome" | "chrome-extension" | "about") {
        return None;
    }
    internal_url_with_scheme(text, &scheme)
}

/// `ChromiumPageRoute(url)`: the route of a URL string, `None` when it is not
/// a `chrome://` page. Any spelling works: `CHROME://History`, `about:history`
/// and `chrome://history` route alike.
pub fn chromium_page_route(url: &str) -> Option<ChromiumPageRoute> {
    let page = chromium_internal_url(url)?;
    let parts = parse_strict(&page)?;
    if parts.scheme != "chrome" {
        return None;
    }
    let host = parts.host?;
    let path = parts.path;
    if let Some((_, address)) = CMUX_PAGES.iter().find(|(page_host, _)| *page_host == host) {
        return Some(ChromiumPageRoute::CmuxPage(address));
    }
    if host == "password-manager"
        || (host == "settings" && (path == "/passwords" || path.starts_with("/passwords/")))
    {
        return Some(ChromiumPageRoute::PasswordsPage);
    }
    if host == "settings" && path == "/" {
        return Some(ChromiumPageRoute::BrowserSettings);
    }
    Some(ChromiumPageRoute::Chromium(page))
}
