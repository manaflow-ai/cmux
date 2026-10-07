//! Redirects the host follows itself (SHELL-REDIRECT-LNA option 1, a9
//! 2026-10-05): the engine fetches each hop with `redirect: "manual"` and
//! reports the Location; the gate checks the next hop before it starts and
//! builds it per the Fetch spec.

use url::Url;

/// At most this many redirect hops after the first request.
pub const MAX_REDIRECTS: usize = 5;

/// One request of a fetch's chain.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Hop {
    pub(super) url: String,
    pub(super) method: String,
    /// `[name, value]` pairs, as the engine takes them.
    pub(super) headers: Vec<(String, String)>,
    pub(super) body: Option<String>,
}

/// Headers that describe a request body; they go with the body.
const BODY_HEADERS: &[&str] =
    &["content-type", "content-encoding", "content-language", "content-location"];

/// The hop after a redirect from `hop` (Fetch spec, HTTP-redirect fetch):
/// 301/302 turn POST into GET and 303 turns every method but GET and HEAD
/// into GET, each dropping the body and its headers; 307/308 keep both. A
/// cross-origin hop drops Authorization.
pub(super) fn next(hop: &Hop, status: u16, location: &str) -> Result<Hop, String> {
    let base = Url::parse(&hop.url).map_err(|e| format!("fetch: {}: {e}", hop.url))?;
    let url = base.join(location).map_err(|_| {
        format!("fetch: {} redirected to {location:?}, which is not a URL", hop.url)
    })?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(format!("fetch: {} redirected to {url}, which is not http or https", hop.url));
    }
    let mut next = Hop { url: url.to_string(), ..hop.clone() };
    let to_get = (matches!(status, 301 | 302) && hop.method == "POST")
        || (status == 303 && hop.method != "GET" && hop.method != "HEAD");
    if to_get {
        next.method = "GET".into();
        next.body = None;
        next.headers
            .retain(|(name, _)| !BODY_HEADERS.contains(&name.to_ascii_lowercase().as_str()));
    }
    if base.origin() != url.origin() {
        next.headers.retain(|(name, _)| !name.eq_ignore_ascii_case("authorization"));
    }
    Ok(next)
}
