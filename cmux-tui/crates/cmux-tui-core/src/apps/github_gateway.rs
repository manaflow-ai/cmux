//! The GitHub read gateway: `integration.request {provider: "github"}` for
//! apps, answered in the daemon. An app holds `integration:github:read`
//! (one user approval, `grants.rs`); the credential never reaches it. The
//! request runs as the person's own `gh` sign-in on this machine (the feed's
//! runner, `feed_client::ProcessGh`), so the token stays inside `gh`, and
//! private repos the person can read are readable.
//!
//! - GET only, and only the read paths of [`admit_path`]: an app cannot
//!   reach the rest of the API (writes, settings, tokens) with this scope.
//! - Conditional requests: each answered path keeps its ETag and body in a
//!   bounded LRU ([`MAX_ENTRIES`], [`MAX_CACHE_BYTES`]); the next read of it
//!   sends `If-None-Match`, and a 304 (which costs no rate limit) replays the
//!   kept body.
//! - Reply (ABI.md): `{value: <GitHub JSON>, integration: {provider,
//!   status, notModified, rateRemaining, route}}`; `cmux.call` resolves with
//!   `value`, `callRaw` also sees `integration`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_feed_core::client::github::parse_http;
use serde_json::{Value, json};

use crate::feed_client::GhRunner;

/// Paths whose answers are kept.
pub(super) const MAX_ENTRIES: usize = 256;
/// Bytes of kept bodies, all entries together.
pub(super) const MAX_CACHE_BYTES: usize = 8 * 1024 * 1024;
/// The largest body kept (a bigger one is answered but not kept).
pub(super) const MAX_ENTRY_BYTES: usize = 1024 * 1024;
/// `gh` processes the gateway runs at once, across every app.
pub(super) const MAX_INFLIGHT: usize = 8;
/// The longest path (with its query) an app may ask for.
const MAX_PATH_BYTES: usize = 2048;

/// The ABI error body.
fn error(code: &str, message: impl Into<String>, retryable: bool) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": retryable })
}

fn invalid_path(path: &str, why: &str) -> Value {
    json!({
        "code": "validation.invalid",
        "message": format!("the GitHub gateway does not read {why}"),
        "details": { "path": path },
        "retryable": false,
    })
}

fn name_segment(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// A commit SHA or a branch or tag name in one segment (its slashes as
/// `%2F`).
fn ref_segment(s: &str) -> bool {
    // Every part between the `%2F`s is a plain name part; any other `%`
    // escape is left in a part and refused there.
    s.replace("%2f", "%2F").split("%2F").all(|part| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    })
}

fn number_segment(s: &str) -> bool {
    !s.is_empty() && s.len() <= 12 && s.bytes().all(|b| b.is_ascii_digit())
}

/// Admits an app's path and returns the `gh api` endpoint (no leading
/// slash). The read paths:
/// `/user`, `/search/issues`, `/repos/{o}/{r}/pulls`,
/// `/repos/{o}/{r}/pulls/{n}`, `/repos/{o}/{r}/pulls/{n}/reviews`,
/// `/repos/{o}/{r}/commits/{ref}/check-runs`,
/// `/repos/{o}/{r}/commits/{ref}/status`, each with an optional query.
/// The query is printable ASCII with no `#` or braces (`gh` would fill
/// `{owner}` placeholders from its working directory).
pub(super) fn admit_path(path: &str) -> Result<String, Value> {
    if path.len() > MAX_PATH_BYTES {
        return Err(invalid_path(path, "paths longer than 2 KiB"));
    }
    let Some(rest) = path.strip_prefix('/') else {
        return Err(invalid_path(path, "a path that does not start with /"));
    };
    let (route, query) = match rest.split_once('?') {
        Some((route, query)) => (route, Some(query)),
        None => (rest, None),
    };
    if let Some(query) = query
        && !query.bytes().all(|b| (0x21..0x7f).contains(&b) && !matches!(b, b'#' | b'{' | b'}'))
    {
        return Err(invalid_path(path, "a query with spaces, #, braces or control characters"));
    }
    let segments: Vec<&str> = route.split('/').collect();
    let repo = |o: &str, r: &str| name_segment(o) && name_segment(r);
    let allowed = match segments.as_slice() {
        ["user"] => true,
        ["search", "issues"] => true,
        ["repos", o, r, "pulls"] => repo(o, r),
        ["repos", o, r, "pulls", n] => repo(o, r) && number_segment(n),
        ["repos", o, r, "pulls", n, "reviews"] => repo(o, r) && number_segment(n),
        ["repos", o, r, "commits", git_ref, "check-runs" | "status"] => {
            repo(o, r) && ref_segment(git_ref)
        }
        _ => false,
    };
    if !allowed {
        return Err(invalid_path(path, "this path (see ABI.md for the read paths)"));
    }
    Ok(rest.to_owned())
}

/// `gh api` arguments for one conditional GET.
pub(super) fn gh_args(endpoint: &str, etag: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> =
        ["api", "--include", "-X", "GET", endpoint].map(str::to_owned).to_vec();
    args.push("-H".into());
    args.push("Accept: application/vnd.github+json".into());
    if let Some(etag) = etag {
        args.push("-H".into());
        args.push(format!("If-None-Match: {etag}"));
    }
    args
}

/// `x-ratelimit-remaining` of `gh api --include` output.
fn rate_remaining(output: &[u8]) -> Option<u64> {
    let end = output
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .or_else(|| output.windows(2).position(|w| w == b"\n\n"))?;
    String::from_utf8_lossy(output.get(..end)?)
        .lines()
        .filter_map(|line| line.split_once(':'))
        .filter(|(name, _)| name.trim().eq_ignore_ascii_case("x-ratelimit-remaining"))
        .find_map(|(_, value)| value.trim().parse().ok())
}

struct Entry {
    etag: String,
    body: Arc<Value>,
    bytes: usize,
    used: u64,
}

/// The ETag cache: least recently used out first, bounded in entries and
/// bytes (the scan for the oldest is over at most [`MAX_ENTRIES`]).
#[derive(Default)]
struct Cache {
    entries: HashMap<String, Entry>,
    bytes: usize,
    clock: u64,
}

impl Cache {
    fn etag(&mut self, key: &str) -> Option<String> {
        self.clock += 1;
        let clock = self.clock;
        self.entries.get_mut(key).map(|e| {
            e.used = clock;
            e.etag.clone()
        })
    }

    fn hit(&mut self, key: &str) -> Option<Arc<Value>> {
        self.clock += 1;
        let clock = self.clock;
        self.entries.get_mut(key).map(|e| {
            e.used = clock;
            e.body.clone()
        })
    }

    fn remove(&mut self, key: &str) {
        if let Some(old) = self.entries.remove(key) {
            self.bytes -= old.bytes;
        }
    }

    fn put(&mut self, key: &str, etag: String, body: Arc<Value>, bytes: usize) {
        self.remove(key);
        if bytes > MAX_ENTRY_BYTES {
            return;
        }
        while self.entries.len() >= MAX_ENTRIES || self.bytes + bytes > MAX_CACHE_BYTES {
            let Some(oldest) =
                self.entries.iter().min_by_key(|(_, e)| e.used).map(|(k, _)| k.clone())
            else {
                break;
            };
            self.remove(&oldest);
        }
        self.clock += 1;
        self.bytes += bytes;
        self.entries.insert(key.to_owned(), Entry { etag, body, bytes, used: self.clock });
    }
}

/// The daemon's GitHub gateway (one per supervisor, shared by every app).
pub struct GitHubGateway {
    gh: Arc<dyn GhRunner>,
    cache: Mutex<Cache>,
    inflight: AtomicUsize,
}

impl GitHubGateway {
    pub fn new(gh: Arc<dyn GhRunner>) -> Self {
        Self { gh, cache: Mutex::new(Cache::default()), inflight: AtomicUsize::new(0) }
    }

    /// The cache; a poisoned lock still holds a consistent cache (every
    /// update finishes before it unlocks).
    fn cache(&self) -> MutexGuard<'_, Cache> {
        self.cache.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Paths kept and their bytes (tests and diagnostics).
    #[cfg(test)]
    pub(super) fn cached(&self) -> (usize, usize) {
        let cache = self.cache();
        (cache.entries.len(), cache.bytes)
    }

    /// Answers one admitted `integration.request` (the grant check ran):
    /// the ABI reply or the ABI error body.
    pub fn request(&self, params: &Value) -> Result<Value, Value> {
        let method = params.get("method").and_then(Value::as_str).unwrap_or("GET");
        if !method.eq_ignore_ascii_case("GET") {
            return Err(error(
                "operation.unsupported",
                "the GitHub gateway reads only (method GET)",
                false,
            ));
        }
        let Some(path) = params.get("path").and_then(Value::as_str) else {
            return Err(error("validation.invalid", "path is required", false));
        };
        let endpoint = admit_path(path)?;
        if self.inflight.fetch_add(1, Ordering::AcqRel) >= MAX_INFLIGHT {
            self.inflight.fetch_sub(1, Ordering::AcqRel);
            return Err(error("app.limit", "too many GitHub reads in flight", true));
        }
        let answer = self.read(&endpoint);
        self.inflight.fetch_sub(1, Ordering::AcqRel);
        answer
    }

    fn read(&self, endpoint: &str) -> Result<Value, Value> {
        let etag = self.cache().etag(endpoint);
        // gh runs outside the lock; reads of other paths go on meanwhile.
        let output = self.gh.run(&gh_args(endpoint, etag.as_deref())).map_err(|why| {
            let retryable = why.contains("timed out");
            json!({
                "code": "integration.unavailable",
                "message": "GitHub is not signed in on this machine (gh auth login), or gh did not answer",
                "details": { "provider": "github", "reason": why },
                "retryable": retryable,
            })
        })?;
        let response = parse_http(&output);
        let rate = rate_remaining(&output);
        let meta = |status: u16, not_modified: bool| {
            json!({
                "provider": "github",
                "status": status,
                "notModified": not_modified,
                "rateRemaining": rate,
                "route": "gh",
            })
        };
        if response.status == 304 {
            let mut cache = self.cache();
            if let Some(body) = cache.hit(endpoint) {
                return Ok(json!({ "value": Value::clone(&body), "integration": meta(304, true) }));
            }
            // Evicted while gh ran: read it again without the condition.
            drop(cache);
            let output = self.gh.run(&gh_args(endpoint, None)).map_err(|why| {
                json!({ "code": "integration.unavailable", "message": "gh did not answer", "details": { "provider": "github", "reason": why }, "retryable": true })
            })?;
            return self.answer(endpoint, parse_http(&output), rate_remaining(&output));
        }
        self.answer(endpoint, response, rate)
    }

    fn answer(
        &self,
        endpoint: &str,
        response: cmux_feed_core::client::github::Response,
        rate: Option<u64>,
    ) -> Result<Value, Value> {
        let status = response.status;
        if status == 401 {
            return Err(json!({
                "code": "integration.unavailable",
                "message": "GitHub refused the sign-in on this machine (gh auth login)",
                "details": { "provider": "github", "status": status },
                "retryable": false,
            }));
        }
        if !(200..300).contains(&status) {
            let message = serde_json::from_slice::<Value>(&response.body)
                .ok()
                .and_then(|v| v.get("message").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_else(|| format!("GitHub answered HTTP {status}"));
            return Err(json!({
                "code": "integration.http",
                "message": message,
                "details": { "provider": "github", "status": status, "rateRemaining": rate },
                "retryable": status == 429 || status >= 500,
            }));
        }
        let body: Value = if response.body.iter().all(u8::is_ascii_whitespace) {
            Value::Null
        } else {
            serde_json::from_slice(&response.body).map_err(|_| {
                error("operation.failed", "GitHub answered with a body that is not JSON", true)
            })?
        };
        let body = Arc::new(body);
        {
            let mut cache = self.cache();
            match response.etag {
                Some(etag) => cache.put(endpoint, etag, body.clone(), response.body.len()),
                None => cache.remove(endpoint),
            }
        }
        Ok(json!({
            "value": Value::clone(&body),
            "integration": {
                "provider": "github",
                "status": status,
                "notModified": false,
                "rateRemaining": rate,
                "route": "gh",
            },
        }))
    }
}

#[cfg(test)]
#[path = "github_gateway_tests.rs"]
mod tests;
