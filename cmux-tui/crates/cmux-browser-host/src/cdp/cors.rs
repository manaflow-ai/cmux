//! HOST-FETCH-CORS (a9, 2026-10-04, option a): `net.fetch` runs as a
//! `fetch()` in the tab's host world, which Chromium subjects to CORS; main's
//! URLSession has none. Parity, scoped to the host's own requests:
//!
//! 1. Every `net.fetch` call gets a fresh 128-bit token, sent as a request
//!    header from the host world and removed here before the request leaves
//!    the browser. A request without a live token is never touched.
//! 2. A preflight for a token request is answered here (204 with allow
//!    headers for exactly the requested method and headers), never sent.
//! 3. At the response stage, token requests only, the exact request origin
//!    is allowed with credentials. Never `*`, never another request.
//! 4. A token is single-use, bound to the tab and the URL of the first hop,
//!    and expires with its fetch.
//! 5. The request filter (policy, ranges) decides first; this runs after.
//!
//! Redirects are not followed by the browser (SHELL-REDIRECT-LNA option 1):
//! the host fetches with `redirect: "manual"`, reads the Location here at
//! the response stage, and runs each next hop as a new fetch with a new
//! token. No redirect hop is relaxed.

use serde_json::{Value, json};
use std::collections::HashMap;

/// The request header that carries the token (removed before sending).
pub const TOKEN_HEADER: &str = "x-cmux-fetch-token";

/// The fetch shell document's CSP (a9 2026-10-04; probe on Chromium 143:
/// `default-src 'none'` alone also blocked the host world's fetch).
const SHELL_CSP: &str =
    "default-src 'none'; connect-src http: https:; base-uri 'none'; form-action 'none'";

#[derive(Debug, Clone)]
struct Grant {
    target: String,
    first_url: String,
    /// The fetch's method and request header names (lowercase, sorted,
    /// the token's included): a preflight may ask for no other header (the
    /// browser leaves CORS-safelisted ones out of the list).
    method: String,
    header_names: Vec<String>,
    /// The one preflight the host answers for this fetch (this tab, URL,
    /// method and headers).
    preflights: u8,
    /// The request claimed the token (single use).
    used: bool,
}

/// What the request worker does with a paused request.
#[derive(Debug, Clone, PartialEq)]
pub enum RequestAction {
    /// Continue unchanged.
    Continue,
    /// Continue with these headers (the token removed).
    ContinueWith { headers: Vec<Value> },
    /// Answer locally (a token request's preflight, a fetch shell
    /// document); `body` is base64.
    Fulfill { status: u16, headers: Vec<Value>, body: String },
}

/// One relaxation, for the host's log.
#[derive(Debug, Clone, PartialEq)]
pub struct Relaxed {
    pub token: String,
    pub url: String,
    pub what: &'static str,
}

#[derive(Debug, Default)]
pub struct Cors {
    grants: HashMap<String, Grant>,
    /// Token requests by network id (stable across redirect hops): origin
    /// and token.
    relaxed: HashMap<String, (String, String)>,
    /// Relaxations not yet reported, per token.
    pub log: Vec<Relaxed>,
    /// A token request's redirect (status, Location as sent), read at the
    /// response stage: the fetch saw only an opaque redirect.
    redirects: HashMap<String, (u16, String)>,
    /// Fetch shells: a tab-less fetch runs in a background tab whose
    /// document (at the fetch URL's origin) the host answers locally, so
    /// the fetch has a real origin and the server sees no extra request.
    shells: HashMap<String, String>,
}

fn header<'a>(headers: &'a Value, name: &str) -> Option<&'a str> {
    headers
        .as_object()?
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .and_then(|(_, value)| value.as_str())
}

fn pairs(headers: &Value, without: &str) -> Vec<Value> {
    headers
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, _)| !key.eq_ignore_ascii_case(without))
        .map(|(key, value)| json!({"name": key, "value": value.as_str().unwrap_or("")}))
        .collect()
}

impl Cors {
    pub fn add_shell(&mut self, target: &str, url: &str) {
        self.shells.insert(target.to_owned(), url.to_owned());
    }

    pub fn remove_shell(&mut self, target: &str) {
        self.shells.remove(target);
    }

    pub fn active(&self) -> bool {
        !self.grants.is_empty()
    }

    /// A fresh token for one fetch on `target` whose first hop is `url`.
    pub fn issue(
        &mut self,
        token: String,
        target: &str,
        url: &str,
        method: &str,
        header_names: &[String],
    ) {
        let mut names: Vec<String> = header_names.iter().map(|n| n.to_ascii_lowercase()).collect();
        names.push(TOKEN_HEADER.to_owned());
        names.sort();
        names.dedup();
        self.grants.insert(
            token,
            Grant {
                target: target.to_owned(),
                first_url: url.to_owned(),
                method: method.to_ascii_uppercase(),
                header_names: names,
                preflights: 1,
                used: false,
            },
        );
    }

    /// The fetch ended: its token and every relaxation it holds expire.
    pub fn revoke(&mut self, token: &str) {
        self.grants.remove(token);
        self.relaxed.retain(|_, (_, held)| held != token);
        self.redirects.remove(token);
    }

    /// The token's relaxations so far (taken).
    pub fn take_log(&mut self, token: &str) -> Vec<Relaxed> {
        let (mine, rest) =
            std::mem::take(&mut self.log).into_iter().partition(|r| r.token == token);
        self.log = rest;
        mine
    }

    /// The request stage, after the request filter allowed the request.
    pub fn on_request(
        &mut self,
        target: &str,
        network_id: &str,
        method: &str,
        url: &str,
        headers: &Value,
    ) -> RequestAction {
        if method == "GET" && self.shells.get(target).is_some_and(|shell| shell == url) {
            // a9 shell-tab condition (a): empty, never stored, and the main
            // world loads nothing. Connects stay open because the host
            // world takes the main world's CSP; base-uri and form-action do
            // not fall back to default-src. No `sandbox`: it would make the
            // origin opaque and break the same-origin fetch.
            return RequestAction::Fulfill {
                status: 200,
                headers: vec![
                    json!({"name": "Content-Type", "value": "text/html"}),
                    json!({"name": "Cache-Control", "value": "no-store"}),
                    json!({"name": "Content-Security-Policy", "value": SHELL_CSP}),
                ],
                body: String::new(),
            };
        }
        if let Some(token) = header(headers, TOKEN_HEADER) {
            let stripped = RequestAction::ContinueWith { headers: pairs(headers, TOKEN_HEADER) };
            let origin = header(headers, "origin").unwrap_or("null").to_owned();
            let Some(grant) = self.grants.get_mut(token).filter(|g| g.target == target) else {
                // Guessed, replayed or expired: removed, nothing relaxed.
                return stripped;
            };
            if !grant.used && grant.first_url == url {
                grant.used = true;
                self.relaxed.insert(network_id.to_owned(), (origin, token.to_owned()));
            }
            return stripped;
        }
        // A preflight of a token request: the browser sends the header's
        // name, never its value, so it is matched by tab and URL of a live
        // grant whose request has not gone yet.
        let requested = header(headers, "access-control-request-headers").unwrap_or("");
        let mut names: Vec<String> = requested
            .split(',')
            .map(|n| n.trim().to_ascii_lowercase())
            .filter(|n| !n.is_empty())
            .collect();
        names.sort();
        names.dedup();
        let wanted =
            header(headers, "access-control-request-method").unwrap_or("GET").to_ascii_uppercase();
        if method == "OPTIONS" && names.iter().any(|n| n == TOKEN_HEADER) {
            let grant = self.grants.iter_mut().find(|(_, g)| {
                g.target == target
                    && g.preflights > 0
                    && g.method == wanted
                    && names.iter().all(|n| g.header_names.contains(n))
                    && !g.used
                    && g.first_url == url
            });
            if let Some((token, grant)) = grant {
                grant.preflights -= 1;
                let token = token.clone();
                let origin = header(headers, "origin").unwrap_or("null");
                self.log.push(Relaxed {
                    token,
                    url: url.to_owned(),
                    what: "preflight answered by the host",
                });
                return RequestAction::Fulfill {
                    status: 204,
                    headers: vec![
                        json!({"name": "Access-Control-Allow-Origin", "value": origin}),
                        json!({"name": "Access-Control-Allow-Credentials", "value": "true"}),
                        json!({"name": "Access-Control-Allow-Methods", "value": wanted.as_str()}),
                        json!({"name": "Access-Control-Allow-Headers", "value": requested}),
                        json!({"name": "Vary", "value": "Origin"}),
                    ],
                    body: String::new(),
                };
            }
        }
        RequestAction::Continue
    }

    /// The response stage of a token request: a redirect's status and
    /// Location are kept for its fetch.
    pub fn note_redirect(&mut self, network_id: &str, status: u16, headers: &[Value]) {
        if !(300..400).contains(&status) {
            return;
        }
        let Some((_, token)) = self.relaxed.get(network_id) else { return };
        let location = headers
            .iter()
            .find(|h| h["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case("location")))
            .and_then(|h| h["value"].as_str());
        if let Some(location) = location {
            self.redirects.insert(token.clone(), (status, location.to_owned()));
        }
    }

    /// The redirect a fetch's token request got (taken).
    pub fn take_redirect(&mut self, token: &str) -> Option<(u16, String)> {
        self.redirects.remove(token)
    }

    /// The response stage: the headers to continue with for a token
    /// request (exact origin, credentials, every header readable), or
    /// `None` to continue unchanged.
    pub fn on_response(
        &mut self,
        network_id: &str,
        url: &str,
        headers: &[Value],
    ) -> Option<Vec<Value>> {
        let (origin, token) = self.relaxed.get(network_id)?.clone();
        let cors = |name: &str| name.to_ascii_lowercase().starts_with("access-control-");
        let mut out: Vec<Value> =
            headers.iter().filter(|h| !cors(h["name"].as_str().unwrap_or(""))).cloned().collect();
        let exposed: Vec<&str> =
            headers.iter().filter_map(|h| h["name"].as_str()).filter(|n| !cors(n)).collect();
        let exposed = exposed.join(", ");
        out.push(json!({"name": "Access-Control-Allow-Origin", "value": origin}));
        out.push(json!({"name": "Access-Control-Allow-Credentials", "value": "true"}));
        out.push(json!({"name": "Access-Control-Expose-Headers", "value": exposed}));
        self.log.push(Relaxed {
            token,
            url: url.to_owned(),
            what: "response allowed for the host's fetch",
        });
        Some(out)
    }
}

/// A fresh 128-bit token, from the OS's randomness.
pub fn fresh_token() -> String {
    let mut bytes = [0u8; 16];
    #[cfg(unix)]
    {
        use std::io::Read;
        if let Ok(mut random) = std::fs::File::open("/dev/urandom") {
            let _ = random.read_exact(&mut bytes);
        }
    }
    if bytes == [0u8; 16] {
        // RandomState's keys come from the OS's randomness too.
        use std::hash::{BuildHasher, Hasher};
        for half in 0..2 {
            let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
            hasher.write_usize(half);
            bytes[half * 8..half * 8 + 8].copy_from_slice(&hasher.finish().to_le_bytes());
        }
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
#[path = "cors_tests.rs"]
mod tests;
