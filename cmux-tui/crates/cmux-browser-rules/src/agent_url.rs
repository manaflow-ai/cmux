//! Pages an agent-driven tab never loads, shows or scripts (`AgentURLPolicy`): Chromium's own
//! WebUI, extension and DevTools pages (plans/cmux-next/passwords.md, section 2).
//! `chrome://password-manager` can put a device-auth prompt in front of the person and then hand a
//! saved password or a CSV export to its script; `chrome://extensions` and `chrome://settings`
//! change the profile. One rule for every agent path: navigate, Back/Forward targets, reload and
//! evaluate while one shows, and a commit that reaches one anyway.
//!
//! The same rule as the C++ `AgentRefusesURL` and cmux-browser-host's `policy::is_browser_page`;
//! all read schemas/agent-url-policy/vectors.json.

/// What an agent-driven tab shows instead of a refused page (`BrowserNewTabPage.blankURL`).
pub const REPLACEMENT_URL: &str = "about:blank";

pub const REFUSED_SCHEMES: &[&str] = &[
    "chrome",
    "chrome-extension",
    "chrome-untrusted",
    "chrome-search",
    "devtools",
    "chrome-devtools",
    "view-source",
    // cmux's internal pages (cmux://history, cmux://bookmarks, ...).
    "cmux",
];

/// Schemes whose inner URL names the origin.
pub const WRAPPER_SCHEMES: &[&str] = &["blob", "filesystem"];

/// The only `about:` pages Chromium does not turn into `chrome://` pages.
pub const PLAIN_ABOUT_PAGES: &[&str] = &["blank", "srcdoc"];

/// More nested wrappers than this are refused (fail closed); the C++ and Rust copies use the same
/// limit (schemas/agent-url-policy/vectors.json).
pub const MAX_WRAPPER_DEPTH: usize = 2;

/// Whether an agent-driven tab refuses `text` (a URL's `absoluteString`, or typed text).
pub fn refuses(text: &str) -> bool {
    refuses_within(text, 0)
}

fn refuses_within(text: &str, wrappers: usize) -> bool {
    if wrappers > MAX_WRAPPER_DEPTH {
        return true;
    }
    // Chromium drops tabs and newlines anywhere and trims leading spaces and control characters.
    let cleaned: String = text.chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect();
    let trimmed = cleaned.trim_start_matches(|c: char| (c as u32) <= 0x20);
    let Some((scheme, rest)) = trimmed.split_once(':') else {
        return false;
    };
    let scheme = scheme.to_lowercase();
    let mut chars = scheme.chars();
    if !chars.next().is_some_and(char::is_alphabetic)
        || !chars.all(|c| c.is_alphanumeric() || "+-.".contains(c))
    {
        return false;
    }
    if REFUSED_SCHEMES.contains(&scheme.as_str()) {
        return true;
    }
    if scheme == "cmux-page" {
        return is_reserved_page_host(rest);
    }
    if WRAPPER_SCHEMES.contains(&scheme.as_str()) {
        return refuses_within(rest, wrappers + 1);
    }
    if scheme == "about" {
        let page = rest.split(['?', '#']).next().unwrap_or("").to_lowercase();
        return !PLAIN_ABOUT_PAGES.contains(&page.as_str());
    }
    false
}

/// First-party pages (`cmux-page://cmux`, `cmux-page://cmux.<id>`: Settings, History, Passwords,
/// the agent pane; and single-label shared hosts such as `cmux-page://shell`) answer privileged
/// page ops; an agent never drives them. Third-party app pages (reverse-DNS ids, always dotted)
/// stay allowed. Fail closed: an empty host or one with a percent escape.
pub fn is_reserved_page_host(rest: &str) -> bool {
    let after_slashes = rest.trim_start_matches(['/', '\\']);
    let mut host = after_slashes.split(['/', '\\', '?', '#']).next().unwrap_or("");
    if host.contains('%') {
        return true;
    }
    if let Some((_, tail)) = host.rsplit_once('@') {
        host = tail;
    }
    if let Some((name, _)) = host.split_once(':') {
        host = name;
    }
    let name = host.to_lowercase();
    let name = name.trim_end_matches('.');
    // A third-party app id always has a dot; a single label ("shell") is a shared first-party host.
    name.is_empty() || name == "cmux" || name.starts_with("cmux.") || !name.contains('.')
}
