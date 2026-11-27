//! The cookie rules of the app's WebKit driver (`WebKitDriver+Cookies.swift`): which cookies a
//! clear covers, which cookies a `cookies.get` URL matches, the refusals of `cookies.set` and
//! `cookies.clear`, and a Playwright cookie's fields.
//!
//! Stays in Swift: `HTTPCookie`, the cookie store, URL parsing (the app passes a URL's scheme,
//! host and path), the driver params and `DriverJSON`, the backup files (see [`crate::cookie_backups`])
//! and their background thread. cmux-url-input has no URL parser, so none is reused here.

use serde::{Deserialize, Serialize};

fn trim_dots(domain: &str) -> String {
    domain.to_lowercase().trim_matches('.').to_owned()
}

/// Whether a clear on `host` (lowercase) covers a cookie of `domain`: the host's own cookies, its
/// parent domains' (they are sent to the host), and its subdomains'. A sibling subdomain is not
/// covered (`WebKitDriver.inScope`).
pub fn in_scope(domain: &str, host: &str) -> bool {
    let cookie_domain = trim_dots(domain);
    if cookie_domain.is_empty() {
        return false;
    }
    cookie_domain == host
        || host.ends_with(&format!(".{cookie_domain}"))
        || cookie_domain.ends_with(&format!(".{host}"))
}

/// A URL as Swift's `URL` reports it: the scheme, the host (None without one) and the path.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct UrlParts {
    #[serde(default)]
    pub scheme: Option<String>,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub path: String,
}

/// The fields of an `HTTPCookie` the rules read.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct CookieFacts {
    pub domain: String,
    pub path: String,
    #[serde(default)]
    pub secure: bool,
}

/// Whether `cookie` is sent to `url` (`WebKitDriver.cookie(_:matches:)`): the host is the
/// cookie's domain or a subdomain of it, a secure cookie needs https, and the path is the
/// cookie's or under it.
pub fn cookie_matches(cookie: &CookieFacts, url: &UrlParts) -> bool {
    let Some(host) = url.host.as_ref().map(|host| host.to_lowercase()) else { return false };
    let domain = trim_dots(&cookie.domain);
    if !(host == domain || host.ends_with(&format!(".{domain}"))) {
        return false;
    }
    if cookie.secure && url.scheme.as_deref() != Some("https") {
        return false;
    }
    let path = if url.path.is_empty() { "/" } else { url.path.as_str() };
    path == cookie.path
        || (path.starts_with(&cookie.path)
            && (cookie.path.ends_with('/') || path[cookie.path.len()..].starts_with('/')))
}

/// `cookies.get`: whether a cookie is listed for `urls` (all cookies when there are none).
pub fn cookie_listed(cookie: &CookieFacts, urls: &[UrlParts]) -> bool {
    urls.is_empty() || urls.iter().any(|url| cookie_matches(cookie, url))
}

/// The `name`, `domain` and `path` filters of `cookies.clear`, an empty one meaning none
/// (`flatMap { $0.isEmpty ? nil : $0 }`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct ClearFilter {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

/// A cookie of a store as `cookies.clear` filters it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct StoredCookie {
    pub name: String,
    pub domain: String,
    pub path: String,
}

/// Whether `cookies.clear` on `host` deletes `cookie`: in scope and equal to every filter given.
pub fn clear_matches(cookie: &StoredCookie, host: &str, filter: &ClearFilter) -> bool {
    let given = |value: &Option<String>| value.as_deref().filter(|text| !text.is_empty());
    in_scope(&cookie.domain, host)
        && given(&filter.name).is_none_or(|name| name == cookie.name)
        && given(&filter.domain).is_none_or(|domain| domain == cookie.domain)
        && given(&filter.path).is_none_or(|path| path == cookie.path)
}

/// The lowercased site `cookies.clear` scopes to for the tab's URL, or the refusal text: only an
/// http or https page with a host has one.
pub fn clear_site(scheme: Option<&str>, host: Option<&str>) -> Result<String, String> {
    match (scheme, host) {
        (Some("http" | "https"), Some(host)) if !host.is_empty() => Ok(host.to_lowercase()),
        _ => {
            let page = scheme.map_or("no page".to_owned(), |scheme| format!("a {scheme}: page"));
            Err(format!(
                "cookies.clear: the tab shows {page}, so it has no site to scope to; open the \
                 site first"
            ))
        }
    }
}

/// The refusal of `cookies.clear {all: true}`.
pub const CLEAR_ALL_REFUSED: &str = "cookies.clear: { all: true } would clear every site in the \
    user's browser profile, which a session may not do; clear the current tab's site instead";

/// The refusal of `cookies.set` for a cookie already expired (setting one deletes a cookie with
/// no undo), or None. `expires` is seconds since 1970; -1 is a session cookie.
pub fn set_refusal(expires: Option<f64>, now: f64) -> Option<&'static str> {
    match expires {
        Some(expires) if expires > -1.0 && expires <= now => Some(
            "cookies.set: an expired cookie would delete a cookie with no undo; use \
             clearCookies() instead",
        ),
        _ => None,
    }
}

/// `sameSite` as `cookies.get` reports it: the policy's raw value, capitalized (`lax` is `Lax`).
pub fn same_site_label(policy: &str) -> String {
    let mut chars = policy.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars.flat_map(char::to_lowercase)).collect(),
        None => String::new(),
    }
}

/// The result of reading a Playwright cookie (`httpCookie(_:)`), before the `HTTPCookie` is made.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaywrightCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub expires: f64,
    pub http_only: bool,
    pub secure: bool,
    pub same_site: Option<String>,
}

/// The fields of a Playwright cookie as `cookies.set` takes them, with `url` already parsed by
/// the app (`url_host` None: it did not parse or has no host, `url_path` the URL's path,
/// `url_given` that `url` was given).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PlaywrightFields {
    pub name: Option<String>,
    pub value: Option<String>,
    pub domain: Option<String>,
    pub path: Option<String>,
    pub expires: Option<f64>,
    pub http_only: bool,
    pub secure: bool,
    pub same_site: Option<String>,
    pub url: Option<String>,
    pub url_host: Option<String>,
    pub url_path: Option<String>,
}

/// The directory of a URL path (`deletingLastPathComponent().path`, "/" when empty).
fn directory_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    let dir = match trimmed.rfind('/') {
        Some(at) => &trimmed[..at],
        None => "",
    };
    if dir.is_empty() { "/".to_owned() } else { dir.to_owned() }
}

/// A Playwright cookie's fields as a cookie, or the refusal text (`httpCookie(_:)`): `url`, or
/// `domain` and `path`. With a `url`, its host is the domain, and without a `path` the path is
/// the URL's own when it ends in `/`, else its directory.
pub fn playwright_cookie(fields: &PlaywrightFields) -> Result<PlaywrightCookie, String> {
    let (Some(name), Some(value)) = (fields.name.clone(), fields.value.clone()) else {
        return Err("cookies.set: each cookie needs a name and a value".into());
    };
    let mut cookie = PlaywrightCookie {
        name: name.clone(),
        value,
        domain: fields.domain.clone().unwrap_or_default(),
        path: fields.path.clone().unwrap_or_else(|| "/".into()),
        expires: fields.expires.unwrap_or(-1.0),
        http_only: fields.http_only,
        secure: fields.secure,
        same_site: fields.same_site.clone(),
    };
    if let Some(raw) = &fields.url {
        let Some(host) = fields.url_host.as_deref().filter(|host| !host.is_empty()) else {
            return Err(format!("cookies.set: url: expected an http(s) URL, got {raw}"));
        };
        cookie.domain = host.to_owned();
        if fields.path.is_none() {
            let path = fields.url_path.clone().unwrap_or_default();
            cookie.path = if path.ends_with('/') { path } else { directory_of(&path) };
        }
    }
    if cookie.domain.is_empty() {
        return Err(format!("cookies.set: cookie {name} needs a url, or a domain and a path"));
    }
    Ok(cookie)
}
