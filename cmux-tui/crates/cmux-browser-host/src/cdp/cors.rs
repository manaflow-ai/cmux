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

use serde_json::{Value, json};
use std::collections::HashMap;

/// The request header that carries the token (removed before sending).
pub const TOKEN_HEADER: &str = "x-cmux-fetch-token";

/// Redirect hops of one fetch whose preflights the host answers.
const MAX_REDIRECT_PREFLIGHTS: u8 = 5;

#[derive(Debug, Clone)]
struct Grant {
    target: String,
    first_url: String,
    /// The fetch's method and request header names (lowercase, sorted,
    /// the token's included): a preflight must ask for exactly these.
    method: String,
    header_names: Vec<String>,
    /// Preflights still answerable: the first hop's, then a few redirect
    /// hops'. A page that imitates one in the fetch's window gets at most
    /// these, for this tab and these exact method and headers.
    preflights: u8,
    /// The first hop claimed the token; later hops ride its network id.
    used: bool,
}

/// What the request worker does with a paused request.
#[derive(Debug, Clone, PartialEq)]
pub enum RequestAction {
    /// Continue unchanged.
    Continue,
    /// Continue with these headers (the token removed).
    ContinueWith { headers: Vec<Value> },
    /// Answer locally (a token request's preflight).
    Fulfill { status: u16, headers: Vec<Value> },
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
    pub fn active(&self) -> bool {
        !self.grants.is_empty()
    }

    /// A fresh token for one fetch on `target` whose first hop is `url`.
    pub fn issue(&mut self, token: String, target: &str, url: &str, method: &str, header_names: &[String]) {
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
                preflights: 1 + MAX_REDIRECT_PREFLIGHTS,
                used: false,
            },
        );
    }

    /// The fetch ended: its token and every relaxation it holds expire.
    pub fn revoke(&mut self, token: &str) {
        self.grants.remove(token);
        self.relaxed.retain(|_, (_, held)| held != token);
    }

    /// The token's relaxations so far (taken).
    pub fn take_log(&mut self, token: &str) -> Vec<Relaxed> {
        let (mine, rest) = std::mem::take(&mut self.log).into_iter().partition(|r| r.token == token);
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
        let _ = (target, network_id, method, url, headers, &self.relaxed);
        RequestAction::Continue
    }

    /// The response stage (not built yet).
    pub fn on_response(&mut self, network_id: &str, url: &str, headers: &[Value]) -> Option<Vec<Value>> {
        let _ = (network_id, url, headers);
        None
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
