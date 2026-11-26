//! The browser automation's cookie rules (`WebKitDriver+Cookies`), out of the app's
//! CmuxNextBrowserAutomation Swift: which cookies `cookies.get` answers for some URLs, how a
//! Playwright cookie of `cookies.set` becomes a stored one, which site and cookies a
//! `cookies.clear` covers, and what `cookies.restore` puts back.
//!
//! Pure: the app reads the tab's cookie store and applies the result. What stays in Swift: the
//! `WKHTTPCookieStore` reads and writes, `HTTPCookie(properties:)` (it can still refuse a cookie;
//! the app then answers this module's "needs a url" error), the encrypted backup files
//! ([`crate::cookie_backups`] holds their rules) and the `DriverError` codes.
//!
//! URLs are read with cmux-url-input's parser ([`cmux_url_input::parse_url`]), with
//! Foundation's `URL.host` and `URL.path` on top: brackets off an IP literal, the path
//! percent-decoded and its trailing slash dropped.

use cmux_url_input::parse_url;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// One backed-up cookie (`BackedUpCookie`): every field `HTTPCookie` needs to make it again.
/// The wire is its Swift `Codable` shape (a nil `sameSite` has no key).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackedUpCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    /// Seconds since 1970; -1 for a session cookie.
    pub expires: f64,
    pub http_only: bool,
    pub secure: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub same_site: Option<String>,
}

/// What one backup file holds, encrypted (`CookieBackupRecord`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CookieBackupRecord {
    pub site: String,
    /// The `BrowserProfileID` UUID of the store the cookies came from.
    pub profile: String,
    /// Milliseconds since 1970.
    pub created_at: f64,
    pub cookies: Vec<BackedUpCookie>,
}

/// The fields of a stored cookie the rules read (an `HTTPCookie`'s).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct StoredCookie {
    pub name: String,
    pub domain: String,
    pub path: String,
    pub secure: bool,
}

/// The parts of a URL `URL.scheme`, `URL.host` and `URL.path` give.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UrlFacts {
    /// As written.
    pub scheme: String,
    /// Without an IP literal's brackets; `None` for a URL with no authority.
    pub host: Option<String>,
    /// Percent-decoded, without a trailing slash (`/` stays `/`); empty for no path.
    pub path: String,
}

/// `URL(string:)` and its scheme, host and path; `None` for text that is not a URL.
///
/// ```
/// use cmux_browser_rules::cookies::url_facts;
/// let facts = url_facts("https://[::1]:8080/a%20b/").unwrap();
/// assert_eq!(facts.host.as_deref(), Some("::1"));
/// assert_eq!(facts.path, "/a b");
/// ```
pub fn url_facts(text: &str) -> Option<UrlFacts> {
    let parts = parse_url(text)?;
    let host = parts.host.map(|host| {
        host.strip_prefix('[').and_then(|inner| inner.strip_suffix(']')).unwrap_or(host).to_owned()
    });
    let decoded = percent_decode(parts.path);
    let path = match decoded.strip_suffix('/') {
        Some(stripped) if !stripped.is_empty() => stripped.to_owned(),
        _ => decoded,
    };
    Some(UrlFacts { scheme: parts.scheme.to_owned(), host, path })
}

/// `%HH` escapes as bytes, read as UTF-8 (an invalid sequence keeps its replacement character).
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let hex = |offset: usize| {
            bytes
                .get(index + offset)
                .and_then(|b| char::from(*b).to_digit(16))
                .and_then(|d| u8::try_from(d).ok())
        };
        if byte == b'%'
            && let (Some(high), Some(low)) = (hex(1), hex(2))
        {
            out.push(high * 16 + low);
            index += 3;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A cookie domain without its leading (and trailing) dots, lowercased.
fn bare_domain(domain: &str) -> String {
    domain.to_lowercase().trim_matches('.').to_owned()
}

/// `WebKitDriver.inScope`: whether a clear on `host` covers a cookie of `domain`: the host's
/// own cookies, its parent domains' (they are sent to the host), and its subdomains'. A sibling
/// subdomain is not covered.
///
/// ```
/// use cmux_browser_rules::cookies::in_scope;
/// assert!(in_scope(".example.com", "www.example.com"));
/// assert!(in_scope("a.www.example.com", "www.example.com"));
/// assert!(!in_scope("api.example.com", "www.example.com"));
/// ```
pub fn in_scope(domain: &str, host: &str) -> bool {
    let cookie_domain = bare_domain(domain);
    if cookie_domain.is_empty() {
        return false;
    }
    cookie_domain == host
        || host.ends_with(&format!(".{cookie_domain}"))
        || cookie_domain.ends_with(&format!(".{host}"))
}

/// `WebKitDriver.cookie(_:matches:)`: whether a browser sends `cookie` with a request for
/// `url`: its domain is the host or a parent of it, a secure cookie only over https, and its path
/// is the URL's path or a directory of it.
///
/// ```
/// use cmux_browser_rules::cookies::{StoredCookie, cookie_matches};
/// let cookie = StoredCookie { domain: ".example.com".into(), path: "/docs".into(), ..Default::default() };
/// assert!(cookie_matches(&cookie, "http://www.example.com/docs/a"));
/// assert!(!cookie_matches(&cookie, "http://www.example.com/docsx"));
/// ```
pub fn cookie_matches(cookie: &StoredCookie, url: &str) -> bool {
    let Some(facts) = url_facts(url) else {
        return false;
    };
    let Some(host) = facts.host.map(|host| host.to_lowercase()) else {
        return false;
    };
    let domain = bare_domain(&cookie.domain);
    if !(host == domain || host.ends_with(&format!(".{domain}"))) {
        return false;
    }
    if cookie.secure && facts.scheme != "https" {
        return false;
    }
    let path = if facts.path.is_empty() { "/" } else { facts.path.as_str() };
    path == cookie.path
        || path
            .strip_prefix(cookie.path.as_str())
            .is_some_and(|rest| cookie.path.ends_with('/') || rest.starts_with('/'))
}

/// `cookies.get`'s filter: the indexes of `cookies` that match one of `urls` (every cookie
/// when `urls` is empty). A URL that does not parse is left out, as `URL(string:)` drops it.
pub fn cookies_for_urls(cookies: &[StoredCookie], urls: &[String]) -> Vec<usize> {
    let urls: Vec<&String> = urls.iter().filter(|url| url_facts(url).is_some()).collect();
    cookies
        .iter()
        .enumerate()
        .filter(|(_, cookie)| urls.is_empty() || urls.iter().any(|url| cookie_matches(cookie, url)))
        .map(|(index, _)| index)
        .collect()
}

/// `cookies.set`: the Playwright cookies (`url`, or `domain` and `path`) as the cookies to set,
/// or the error that refuses the call (protocol text). A cookie already expired is refused:
/// setting one deletes a cookie with no undo (use `cookies.clear`).
pub fn cookies_to_set(items: &[Value], now: f64) -> Result<Vec<BackedUpCookie>, String> {
    let mut made = Vec::with_capacity(items.len());
    for item in items {
        let Value::Object(fields) = item else {
            return Err("cookies.set: cookies: expected an array of objects".into());
        };
        if let Some(expires) = fields.get("expires").and_then(Value::as_f64)
            && expires > -1.0
            && expires <= now
        {
            return Err("cookies.set: an expired cookie would delete a cookie with no undo; \
                        use clearCookies() instead"
                .into());
        }
        made.push(playwright_cookie(fields)?);
    }
    Ok(made)
}

/// `WebKitDriver.httpCookie`: a Playwright cookie as the cookie to store. A `url` gives the
/// domain (its host) and, with no `path`, the path: the URL's own when it ends in `/`, else its
/// directory (Foundation's `deletingLastPathComponent().path`).
pub fn playwright_cookie(fields: &Map<String, Value>) -> Result<BackedUpCookie, String> {
    let text = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
    let flag = |key: &str| fields.get(key) == Some(&Value::Bool(true));
    let (Some(name), Some(value)) = (text("name"), text("value")) else {
        return Err("cookies.set: each cookie needs a name and a value".into());
    };
    let mut cookie = BackedUpCookie {
        domain: text("domain").unwrap_or_default(),
        path: text("path").unwrap_or_else(|| "/".into()),
        expires: fields.get("expires").and_then(Value::as_f64).unwrap_or(-1.0),
        http_only: flag("httpOnly"),
        secure: flag("secure"),
        same_site: text("sameSite"),
        name,
        value,
    };
    if let Some(raw) = text("url") {
        let facts = url_facts(&raw);
        let Some((host, path)) = facts.and_then(|facts| {
            facts.host.filter(|host| !host.is_empty()).map(|host| (host, facts.path))
        }) else {
            return Err(format!("cookies.set: url: expected an http(s) URL, got {raw}"));
        };
        cookie.domain = host;
        if !fields.contains_key("path") {
            cookie.path = if path.ends_with('/') { path } else { directory_of(&path) };
        }
    }
    if cookie.domain.is_empty() {
        return Err(format!(
            "cookies.set: cookie {} needs a url, or a domain and a path",
            cookie.name
        ));
    }
    Ok(cookie)
}

/// `URL.deletingLastPathComponent().path` of a URL whose `path` is `path` (no trailing slash).
/// Foundation answers `/..` for a URL with no path at all (UNVERIFIED on a Mac in this port).
fn directory_of(path: &str) -> String {
    if path.is_empty() {
        return "/..".into();
    }
    match path.rsplit_once('/') {
        Some((before, _)) if !before.is_empty() => before.to_owned(),
        _ => "/".into(),
    }
}

/// `cookies.clear`'s site: the tab's lowercased host when it shows an http(s) page, else the
/// error (protocol text) that refuses the clear.
///
/// ```
/// use cmux_browser_rules::cookies::clear_site;
/// assert_eq!(clear_site(Some("https://WWW.Example.com/a")), Ok("www.example.com".into()));
/// assert!(clear_site(Some("about:blank")).unwrap_err().contains("a about: page"));
/// ```
pub fn clear_site(url: Option<&str>) -> Result<String, String> {
    let facts = url.and_then(url_facts);
    if let Some(facts) = &facts
        && (facts.scheme == "http" || facts.scheme == "https")
        && let Some(host) = facts.host.as_deref().filter(|host| !host.is_empty())
    {
        return Ok(host.to_lowercase());
    }
    let shows =
        facts.map_or_else(|| "no page".to_owned(), |facts| format!("a {}: page", facts.scheme));
    Err(format!(
        "cookies.clear: the tab shows {shows}, so it has no site to scope to; open the site first"
    ))
}

/// `cookies.clear`'s narrowing: an exact name, domain and path (empty means any).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ClearFilter {
    pub name: Option<String>,
    pub domain: Option<String>,
    pub path: Option<String>,
}

/// `cookies.clear`'s cookies: the indexes of `cookies` in scope of `host` ([`in_scope`]) that
/// pass `filter`. No public suffix list is needed: a browser never stores a cookie for a public
/// suffix, so no clear reaches another site.
pub fn clear_matches(cookies: &[StoredCookie], host: &str, filter: &ClearFilter) -> Vec<usize> {
    let given = |value: &Option<String>| value.clone().filter(|value| !value.is_empty());
    let (name, domain, path) = (given(&filter.name), given(&filter.domain), given(&filter.path));
    cookies
        .iter()
        .enumerate()
        .filter(|(_, cookie)| {
            in_scope(&cookie.domain, host)
                && name.as_ref().is_none_or(|name| *name == cookie.name)
                && domain.as_ref().is_none_or(|domain| *domain == cookie.domain)
                && path.as_ref().is_none_or(|path| *path == cookie.path)
        })
        .map(|(index, _)| index)
        .collect()
}

/// What `cookies.restore` does with a backup's cookies.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestorePlan {
    /// The indexes of the cookies to set again.
    pub restore: Vec<usize>,
    /// Cookies set since the clear with the same name, domain and path: kept.
    pub kept: usize,
    /// Cookies past their expiry: left out.
    pub expired: usize,
}

/// `cookies.restore`: a cookie past its expiry is left out; one whose name, domain and path a
/// cookie in the store has now is kept; the rest go back.
pub fn restore_plan(
    cookies: &[BackedUpCookie],
    existing: &[StoredCookie],
    now: f64,
) -> RestorePlan {
    let mut plan = RestorePlan::default();
    for (index, cookie) in cookies.iter().enumerate() {
        if cookie.expires > 0.0 && cookie.expires <= now {
            plan.expired += 1;
        } else if existing.iter().any(|stored| {
            stored.name == cookie.name
                && stored.domain == cookie.domain
                && stored.path == cookie.path
        }) {
            plan.kept += 1;
        } else {
            plan.restore.push(index);
        }
    }
    plan
}

/// The `sameSite` of a `cookies.get` row: `HTTPCookie.sameSitePolicy`'s raw value as
/// `String.capitalized` gives it (`lax` is `Lax`).
pub fn same_site_label(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut word_start = true;
    for c in raw.chars() {
        if c.is_alphanumeric() {
            if word_start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            word_start = false;
        } else {
            out.push(c);
            word_start = true;
        }
    }
    out
}
