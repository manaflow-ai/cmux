//! Access rules of the preview proxy (`preview_proxy`). Every request
//! passes them before any byte reaches the dev server:
//!
//! - `Host` must be a loopback name (`localhost`, `*.localhost`), an
//!   address literal, or a name under one of the registry's public preview
//!   suffixes (the tunnel forwards its `<name>.preview.chatmux.dev` Host
//!   verbatim). Every other name is a DNS-rebound page and gets a 403.
//! - Proxied paths and upstream WebSocket upgrades need the per-preview
//!   capability: the `__chatmux_preview_<proxy port>` cookie, the
//!   `x-chatmux-capability` header, or a one-time
//!   `?__chatmux_capability=` navigation, which answers a 302 that sets the
//!   HttpOnly cookie and drops the parameter from the URL. A missing or
//!   wrong one gets a 401. The proxy strips every preview credential
//!   (query, Referer, header, cookies) before it forwards.
//! - Upgrades and unsafe methods that name an `Origin` must be
//!   same-origin, so a same-site sibling page cannot ride the cookie.
//! - The `/__chatmux__/*` control paths keep their own capability and
//!   Origin admission (`control_origin_allowed`).

use std::sync::Arc;

use crate::preview_proxy::{PeerRole, ProxyBody, full_body};
use crate::workspace::Refusal;

/// The public preview domain the chatmux tunnel serves proxies under.
pub const DEFAULT_PUBLIC_HOST_SUFFIX: &str = "preview.chatmux.dev";
/// Comma-separated extra public preview suffixes (self-hosted tunnels).
pub const PUBLIC_HOST_SUFFIXES_ENV: &str = "CHATMUX_PREVIEW_HOST_SUFFIXES";

/// The default suffix plus any listed in `CHATMUX_PREVIEW_HOST_SUFFIXES`.
pub(crate) fn default_public_host_suffixes() -> Vec<String> {
    let mut suffixes = vec![DEFAULT_PUBLIC_HOST_SUFFIX.to_owned()];
    if let Ok(extra) = std::env::var(PUBLIC_HOST_SUFFIXES_ENV) {
        suffixes.extend(extra.split(',').map(str::to_owned));
    }
    suffixes
}

/// Lowercase, without surrounding dots, deduplicated. A one-label suffix
/// ("dev") would admit every name under a public TLD and bring DNS
/// rebinding back, so it is ignored.
pub(crate) fn normalize_public_host_suffixes(
    suffixes: impl IntoIterator<Item = impl Into<String>>,
) -> Arc<[String]> {
    let mut normalized: Vec<String> = Vec::new();
    for suffix in suffixes {
        let suffix: String = suffix.into();
        let suffix = suffix.trim().trim_matches('.').to_ascii_lowercase();
        if suffix.contains('.') && !normalized.contains(&suffix) {
            normalized.push(suffix);
        }
    }
    normalized.into()
}

/// Copy `Cookie` and `Referer` from `from` into `to` without any preview
/// credential. Every `__chatmux_preview_*` cookie goes, not only this
/// proxy's: cookies are not port-scoped, so a loopback browser sends
/// sibling previews' too. Raw bytes, so non-ASCII app cookies survive.
pub(crate) fn copy_credential_free(from: &hyper::HeaderMap, to: &mut hyper::HeaderMap) {
    let kept = from
        .get_all(hyper::header::COOKIE)
        .iter()
        .flat_map(|value| value.as_bytes().split(|byte| *byte == b';'))
        .map(<[u8]>::trim_ascii)
        .filter(|item| !item.is_empty() && !item.starts_with(CAPABILITY_COOKIE_PREFIX.as_bytes()))
        .collect::<Vec<_>>();
    if !kept.is_empty()
        && let Ok(cookie) = hyper::header::HeaderValue::from_bytes(&kept.join(&b"; "[..]))
    {
        to.insert(hyper::header::COOKIE, cookie);
    }
    if let Some(referer) = from.get(hyper::header::REFERER)
        && let Some(cleaned) = referer_without_capability(referer)
    {
        to.insert(hyper::header::REFERER, cleaned);
    }
}

pub(crate) fn mint_preview_capability() -> Result<String, Refusal> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| {
        Refusal::failed(format!("could not allocate preview capability: {error}"))
    })?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) fn wants_websocket(request: &hyper::Request<hyper::body::Incoming>) -> bool {
    request
        .headers()
        .get(hyper::header::UPGRADE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

pub(crate) const CAPABILITY_QUERY: &str = "__chatmux_capability";
pub(crate) const CAPABILITY_HEADER: &str = "x-chatmux-capability";
pub(crate) const CAPABILITY_COOKIE_PREFIX: &str = "__chatmux_preview_";

/// The `Host` rule (module docs). Exactly one `Host` value; it must be a
/// bare `name[:port]` (no userinfo, path or whitespace). Address literals
/// pass: a rebound page always sends the domain name it loaded from.
pub(crate) fn request_host_allowed(headers: &hyper::HeaderMap, public_suffixes: &[String]) -> bool {
    let mut values = headers.get_all(hyper::header::HOST).iter();
    let (Some(value), None) = (values.next(), values.next()) else { return false };
    let Ok(value) = value.to_str() else { return false };
    let value = value.trim();
    if value.is_empty()
        || value.bytes().any(|byte| {
            matches!(byte, b'/' | b'\\' | b'@' | b'?' | b'#' | b'%') || byte.is_ascii_whitespace()
        })
    {
        return false;
    }
    let Ok(url) = url::Url::parse(&format!("http://{value}/")) else { return false };
    match url.host() {
        Some(url::Host::Ipv4(_) | url::Host::Ipv6(_)) => true,
        Some(url::Host::Domain(name)) => {
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            name == "localhost"
                || name.ends_with(".localhost")
                || public_suffixes.iter().any(|suffix| {
                    name.strip_suffix(suffix.as_str())
                        .is_some_and(|rest| rest.is_empty() || rest.ends_with('.'))
                })
        }
        None => false,
    }
}

pub(crate) enum ProxiedAccess {
    /// A valid cookie or header and no capability in the query.
    Granted,
    /// A valid `?__chatmux_capability=` (and nothing invalid).
    Bootstrap,
    Denied,
}

fn capability_matches(presented: &[u8], expected: &str) -> bool {
    use subtle::ConstantTimeEq as _;
    !expected.is_empty() && bool::from(presented.ct_eq(expected.as_bytes()))
}

/// The decoded value when one raw query item names the capability
/// parameter. Names are percent-decoded first, so `%5F_chatmux_capability`
/// is caught too.
fn capability_query_item(item: &str) -> Option<String> {
    let (name, value) = url::form_urlencoded::parse(item.as_bytes()).next()?;
    (name == CAPABILITY_QUERY).then(|| value.into_owned())
}

/// `(name, value)` byte pairs of every `Cookie` header. Raw bytes: a
/// non-ASCII cookie of the app must neither break the check nor be dropped
/// when the proxy strips its own cookies.
fn cookie_pairs(headers: &hyper::HeaderMap) -> Vec<(&[u8], &[u8])> {
    headers
        .get_all(hyper::header::COOKIE)
        .iter()
        .flat_map(|value| value.as_bytes().split(|byte| *byte == b';'))
        .map(<[u8]>::trim_ascii)
        .filter(|item| !item.is_empty())
        .map(|item| match item.iter().position(|byte| *byte == b'=') {
            Some(at) => (item[..at].trim_ascii(), item[at + 1..].trim_ascii()),
            None => (item, &item[item.len()..]),
        })
        .collect()
}

pub(crate) fn proxied_access(
    expected: &str,
    cookie_name: &str,
    request: &hyper::Request<hyper::body::Incoming>,
) -> ProxiedAccess {
    // A presented query capability must be right: a wrong one never falls
    // back to a cookie, so a link cannot carry a stale or forged value. A
    // right one always takes the bootstrap, so it leaves the URL (and
    // with it every later Referer) even when a cookie is already set.
    let mut query_presented = false;
    for item in request.uri().query().unwrap_or_default().split('&') {
        if let Some(value) = capability_query_item(item) {
            if !capability_matches(value.as_bytes(), expected) {
                return ProxiedAccess::Denied;
            }
            query_presented = true;
        }
    }
    if query_presented {
        return ProxiedAccess::Bootstrap;
    }
    let header_ok = request
        .headers()
        .get_all(CAPABILITY_HEADER)
        .iter()
        .any(|value| capability_matches(value.as_bytes().trim_ascii(), expected));
    let cookie_ok = cookie_pairs(request.headers())
        .into_iter()
        .any(|(name, value)| name == cookie_name.as_bytes() && capability_matches(value, expected));
    if header_ok || cookie_ok { ProxiedAccess::Granted } else { ProxiedAccess::Denied }
}

/// Browsers send the capability cookie on same-site requests, and a sibling
/// preview (`a.preview.chatmux.dev` next to `b.preview.chatmux.dev`, or any
/// `localhost` page) is same-site. So a request that can change state or
/// open a socket must come from this preview's own origin when it names
/// one: upgrades and every method but GET, HEAD and OPTIONS. A request
/// without `Origin` is a navigation or a non-browser client.
pub(crate) fn cross_origin_write(request: &hyper::Request<hyper::body::Incoming>) -> bool {
    let safe = matches!(
        *request.method(),
        hyper::Method::GET | hyper::Method::HEAD | hyper::Method::OPTIONS
    );
    if safe && !wants_websocket(request) {
        return false;
    }
    let Some(origin) = request.headers().get(hyper::header::ORIGIN) else { return false };
    let Some(origin) = origin.to_str().ok().and_then(|value| url::Url::parse(value).ok()) else {
        return true;
    };
    if !matches!(origin.scheme(), "http" | "https") {
        return true;
    }
    let Some(host) = request
        .headers()
        .get(hyper::header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| url::Url::parse(&format!("{}://{value}/", origin.scheme())).ok())
    else {
        return true;
    };
    let normalize = |name: &str| name.trim_end_matches('.').to_ascii_lowercase();
    origin.host_str().map(normalize) != host.host_str().map(normalize)
        || origin.port_or_known_default() != host.port_or_known_default()
}

/// The request's path and query without the capability parameter. A
/// leading run of slashes collapses to one, so the bootstrap `Location`
/// can never be a protocol-relative URL to another host.
pub(crate) fn path_without_capability(uri: &hyper::Uri) -> String {
    let path = format!("/{}", uri.path().trim_start_matches(['/', '\\']));
    let Some(query) = uri.query() else { return path };
    let kept = query
        .split('&')
        .filter(|item| !item.is_empty() && capability_query_item(item).is_none())
        .collect::<Vec<_>>();
    if kept.is_empty() { path } else { format!("{path}?{}", kept.join("&")) }
}

/// 302 to the same URL without the capability, setting the HttpOnly
/// cookie. `Secure` rides public (tunnel) names, which are always https.
pub(crate) fn bootstrap_response(
    capability: &str,
    cookie_name: &str,
    request: &hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    let secure = request
        .headers()
        .get(hyper::header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| url::Url::parse(&format!("http://{value}/")).ok())
        .is_some_and(|url| match url.host() {
            Some(url::Host::Domain(name)) => {
                let name = name.trim_end_matches('.').to_ascii_lowercase();
                name != "localhost" && !name.ends_with(".localhost")
            }
            _ => false,
        });
    let cookie = format!(
        "{}={}; Path=/; HttpOnly; SameSite=Lax{}",
        cookie_name,
        capability,
        if secure { "; Secure" } else { "" },
    );
    let mut response = hyper::Response::new(full_body(Vec::new()));
    *response.status_mut() = hyper::StatusCode::FOUND;
    let headers = response.headers_mut();
    if let (Ok(location), Ok(cookie)) = (
        hyper::header::HeaderValue::from_str(&path_without_capability(request.uri())),
        hyper::header::HeaderValue::from_str(&cookie),
    ) {
        headers.insert(hyper::header::LOCATION, location);
        headers.insert(hyper::header::SET_COOKIE, cookie);
    }
    headers
        .insert(hyper::header::CACHE_CONTROL, hyper::header::HeaderValue::from_static("no-store"));
    headers.insert(
        hyper::header::REFERRER_POLICY,
        hyper::header::HeaderValue::from_static("no-referrer"),
    );
    response
}

/// Browsers attach an `Origin` to every WebSocket handshake but apply no
/// same-origin policy to it, so any page the user visits can dial the
/// proxy's loopback port and drive the preview page over CDP. Admission:
///
/// - no Origin: a non-browser client (the tunnel health checks, tests);
/// - loopback Host (direct local access): the Origin must be a loopback
///   origin too, which refuses every public website;
/// - public Host (the TLS tunnel forwards Host verbatim): the Origin must be
///   https, which refuses DNS-rebinding pages (they cannot present TLS for
///   the rebound name). The page connector dials its own host, so the page
///   channel must also be same-origin. The DevTools frontend is served by
///   the chatmux web app, whose origin this relay is not told. The status
///   endpoint's cross-origin read grant reuses the Devtools admission.
pub(crate) fn control_origin_allowed(headers: &hyper::HeaderMap, role: PeerRole) -> bool {
    let Some(origin) = headers.get(hyper::header::ORIGIN) else {
        return true;
    };
    let Some(origin) = origin.to_str().ok().and_then(|value| url::Url::parse(value).ok()) else {
        return false;
    };
    if !matches!(origin.scheme(), "http" | "https") {
        return false;
    }
    let Some(host) = headers
        .get(hyper::header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| url::Url::parse(&format!("https://{value}")).ok())
    else {
        return false;
    };
    let (Some(origin_host), Some(request_host)) = (origin.host(), host.host()) else {
        return false;
    };
    if is_loopback_host(&request_host) {
        return is_loopback_host(&origin_host);
    }
    if origin.scheme() != "https" {
        return false;
    }
    match role {
        PeerRole::Page => {
            origin_host == request_host
                && origin.port_or_known_default() == host.port_or_known_default()
        }
        PeerRole::Devtools => true,
    }
}

fn is_loopback_host(host: &url::Host<&str>) -> bool {
    match host {
        url::Host::Domain(name) => {
            let name = name.trim_end_matches('.');
            name.eq_ignore_ascii_case("localhost")
                || name.to_ascii_lowercase().ends_with(".localhost")
        }
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    }
}

/// A control request proves it belongs to this preview by presenting the
/// capability `preview_open` returned (the injected connector receives it
/// in its script URL, the devtools frontend over the relay wire). Values
/// are compared in constant time so a guesser learns nothing from
/// response latency; the length is public (64 hex characters).
pub(crate) fn request_capability_allowed(
    request: &hyper::Request<hyper::body::Incoming>,
    expected: &str,
) -> bool {
    use subtle::ConstantTimeEq as _;
    request.uri().query().is_some_and(|query| {
        url::form_urlencoded::parse(query.as_bytes()).any(|(name, value)| {
            name == "capability" && bool::from(value.as_bytes().ct_eq(expected.as_bytes()))
        })
    })
}

/// The Referer without the capability parameter. An unparsable Referer
/// that still names the parameter is dropped.
fn referer_without_capability(
    referer: &hyper::header::HeaderValue,
) -> Option<hyper::header::HeaderValue> {
    let names_capability =
        |query: &str| query.split('&').any(|item| capability_query_item(item).is_some());
    let Ok(text) = referer.to_str() else { return Some(referer.clone()) };
    let Ok(mut url) = url::Url::parse(text) else {
        return (!names_capability(text.split_once('?').map_or("", |(_, query)| query)))
            .then(|| referer.clone());
    };
    let Some(query) = url.query().map(str::to_owned) else { return Some(referer.clone()) };
    if !names_capability(&query) {
        return Some(referer.clone());
    }
    let kept = query
        .split('&')
        .filter(|item| !item.is_empty() && capability_query_item(item).is_none())
        .collect::<Vec<_>>();
    url.set_query((!kept.is_empty()).then(|| kept.join("&")).as_deref());
    hyper::header::HeaderValue::from_str(url.as_str()).ok()
}
