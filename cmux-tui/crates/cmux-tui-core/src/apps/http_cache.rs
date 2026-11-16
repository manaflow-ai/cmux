//! The shared HTTP cache behind `net.fetch {cache: "shared"}`, which the
//! `http.json` signal source (`cmux.watch("http.json", {url})`) reads.
//!
//! One entry per URL for every app and mount: N widgets showing the same URL
//! cost one upstream request. The egress gate (`egress::admit`) runs before
//! the cache on every call, so an app reads a cached body only when it could
//! fetch that URL itself (its `net:<host>` grant, not sandboxed).
//!
//! Rules:
//! - A body is fresh for `max(FLOOR, s-maxage or max-age minus Age)`, at most
//!   `MAX_FRESH`; within it every read is a hit and nothing is sent.
//! - Requests for one URL coalesce: one fetch in flight, and the readers that
//!   arrive meanwhile get the kept body at once (stale while revalidating) or,
//!   with nothing kept, wait for that one fetch.
//! - A revalidation is conditional (`If-None-Match`, `If-Modified-Since`); a
//!   304 keeps the body.
//! - A failed fetch (transport error, non-2xx, a body over `MAX_BODY`) is
//!   remembered for `FLOOR`: one try per URL per floor however many read it.
//!   While a kept body is younger than `MAX_STALE` it is served instead.
//! - The cache never fetches by itself: no reader, no request. Entries nobody
//!   read for `MAX_STALE` are dropped, and at most `MAX_ENTRIES` URLs and
//!   `MAX_BYTES` of bodies are kept (least recently read go first).

use std::collections::HashMap;
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::egress::{self, EgressError, FetchRequest, FetchResponse, Fetcher};

/// The shortest time a body is kept fresh, and how long a failure is remembered.
pub const FLOOR: Duration = Duration::from_secs(60);
/// The longest time a body is kept fresh, whatever its Cache-Control says.
pub const MAX_FRESH: Duration = Duration::from_secs(24 * 60 * 60);
/// How old a kept body may be and still be served when a revalidation fails.
pub const MAX_STALE: Duration = Duration::from_secs(24 * 60 * 60);
/// The largest body the shared cache takes (`app.limit` above it).
pub const MAX_BODY: usize = 1024 * 1024;
pub const MAX_ENTRIES: usize = 128;
pub const MAX_BYTES: usize = 16 * 1024 * 1024;
/// How long a reader waits for another reader's fetch of the same URL.
const WAIT: Duration = Duration::from_secs(egress::TIMEOUT.as_secs() + 5);
/// Response headers a shared reply keeps (the rest are dropped with the body's origin).
const KEPT_HEADERS: &[&str] =
    &["cache-control", "content-type", "date", "etag", "expires", "last-modified"];

/// A kept 2xx response.
#[derive(Debug, Clone)]
struct Kept {
    response: FetchResponse,
    fetched: Instant,
    fetched_ms: u64,
    fresh_for: Duration,
}

impl Kept {
    fn fresh(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.fetched) < self.fresh_for
    }

    fn servable(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.fetched) < MAX_STALE
    }

    fn reply(&self, now: Instant, hit: bool, stale: bool) -> Shared {
        Shared {
            response: self.response.clone(),
            hit,
            stale,
            age: now.saturating_duration_since(self.fetched),
            fresh_for: self.fresh_for,
            fetched_ms: self.fetched_ms,
        }
    }
}

#[derive(Debug, Clone)]
struct Failure {
    at: Instant,
    outcome: Result<FetchResponse, EgressError>,
}

#[derive(Debug)]
struct Entry {
    kept: Option<Kept>,
    failure: Option<Failure>,
    inflight: bool,
    used: Instant,
}

impl Entry {
    fn new(now: Instant) -> Self {
        Self { kept: None, failure: None, inflight: false, used: now }
    }

    fn bytes(&self) -> usize {
        self.kept.as_ref().map_or(0, |k| k.response.body.len())
    }
}

/// One shared read's answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shared {
    pub response: FetchResponse,
    /// Answered from the cache with no request.
    pub hit: bool,
    /// A kept body served while (or because) its revalidation did not land.
    pub stale: bool,
    pub age: Duration,
    pub fresh_for: Duration,
    /// When the body was fetched (or last revalidated), Unix ms.
    pub fetched_ms: u64,
}

impl Shared {
    /// The `net.fetch` reply: the response and what the cache did.
    pub fn json(self) -> Value {
        let mut value = egress::response_json(self.response);
        value["value"]["cache"] = json!({
            "shared": true,
            "hit": self.hit,
            "stale": self.stale,
            "ageSeconds": self.age.as_secs(),
            "maxAgeSeconds": self.fresh_for.as_secs(),
            "fetchedAt": self.fetched_ms,
        });
        value
    }
}

#[derive(Default)]
pub struct HttpCache {
    entries: Mutex<HashMap<String, Entry>>,
    landed: Condvar,
}

/// A shared read is a plain GET of the URL: the app's own headers would make
/// one URL's answer differ per caller, so they are not sent.
pub fn shared_request(request: FetchRequest) -> Result<FetchRequest, EgressError> {
    if request.method != "GET" || request.body.is_some() {
        return Err(EgressError {
            code: "validation.invalid",
            message: "a shared fetch (cache: \"shared\") is a GET with no body".into(),
        });
    }
    Ok(FetchRequest {
        url: request.url,
        method: "GET".into(),
        headers: vec![("Accept".into(), "application/json".into())],
        body: None,
    })
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
}

/// How long a response stays fresh: `s-maxage` (this is a shared cache), else
/// `max-age`, less `Age`, never under `FLOOR` nor over `MAX_FRESH`.
pub fn freshness(headers: &[(String, String)]) -> Duration {
    let mut max_age = None;
    let mut s_maxage = None;
    for directive in header(headers, "cache-control").unwrap_or("").split(',') {
        let directive = directive.trim().to_ascii_lowercase();
        let seconds = |v: &str| v.trim_matches('"').parse::<u64>().ok();
        if let Some(v) = directive.strip_prefix("s-maxage=") {
            s_maxage = seconds(v);
        } else if let Some(v) = directive.strip_prefix("max-age=") {
            max_age = seconds(v);
        }
    }
    let age = header(headers, "age").and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(0);
    let secs = s_maxage.or(max_age).unwrap_or(0).saturating_sub(age);
    Duration::from_secs(secs).clamp(FLOOR, MAX_FRESH)
}

fn unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn too_large() -> EgressError {
    EgressError {
        code: "app.limit",
        message: format!(
            "the response is larger than {} KiB, the shared cache's limit",
            MAX_BODY / 1024
        ),
    }
}

impl HttpCache {
    /// Answers `request` (already admitted and made shared) from the cache,
    /// fetching it through `fetcher` only when nothing fresh is kept.
    pub fn get(
        &self,
        fetcher: &dyn Fetcher,
        request: FetchRequest,
        now: Instant,
    ) -> Result<Shared, EgressError> {
        let key = request.url.clone();
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let deadline = now + WAIT;
        let request = loop {
            let e = entries.entry(key.clone()).or_insert_with(|| Entry::new(now));
            e.used = e.used.max(now);
            if let Some(kept) = e.kept.as_ref().filter(|k| k.fresh(now)) {
                return Ok(kept.reply(now, true, false));
            }
            let stale = e.kept.as_ref().filter(|k| k.servable(now));
            if let Some(failure) =
                e.failure.as_ref().filter(|f| now.saturating_duration_since(f.at) < FLOOR)
            {
                if let Some(kept) = stale {
                    return Ok(kept.reply(now, true, true));
                }
                return failure.outcome.clone().map(|response| Shared {
                    response,
                    hit: true,
                    stale: false,
                    age: now.saturating_duration_since(failure.at),
                    fresh_for: FLOOR,
                    fetched_ms: 0,
                });
            }
            if e.inflight {
                if let Some(kept) = stale {
                    return Ok(kept.reply(now, true, true));
                }
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err(EgressError {
                        code: "operation.failed",
                        message: "timed out waiting for the shared fetch of this url".into(),
                    });
                }
                entries = self
                    .landed
                    .wait_timeout(entries, left)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
                continue;
            }
            e.inflight = true;
            let mut request = request.clone();
            if let Some(kept) = &e.kept {
                if let Some(etag) = header(&kept.response.headers, "etag") {
                    request.headers.push(("If-None-Match".into(), etag.to_string()));
                }
                if let Some(modified) = header(&kept.response.headers, "last-modified") {
                    request.headers.push(("If-Modified-Since".into(), modified.to_string()));
                }
            }
            break request;
        };
        drop(entries);
        // A fetcher that panics must not leave the URL in flight for good:
        // every later reader would wait on it and then fail.
        let fetched =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| fetcher.fetch(request)))
                .unwrap_or_else(|_| {
                    Err(EgressError {
                        code: "operation.failed",
                        message: "the fetch failed".into(),
                    })
                });
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        // Prune keeps an entry in flight, so this finds the one this read marked.
        let entry = entries.entry(key).or_insert_with(|| Entry::new(now));
        let answer = Self::land(entry, fetched, now);
        Self::prune(&mut entries, now);
        drop(entries);
        self.landed.notify_all();
        answer
    }

    /// Records a fetch's outcome in its entry and says what the reader gets.
    fn land(
        e: &mut Entry,
        fetched: Result<FetchResponse, EgressError>,
        now: Instant,
    ) -> Result<Shared, EgressError> {
        e.inflight = false;
        let fetched_ms = unix_ms();
        // A 304 answers a conditional revalidation: the kept body stays, and
        // fresher Cache-Control on the 304 moves its freshness.
        if let Ok(response) = &fetched
            && response.status == 304
            && let Some(kept) = e.kept.as_mut()
        {
            if header(&response.headers, "cache-control").is_some() {
                kept.fresh_for = freshness(&response.headers);
            }
            kept.fetched = now;
            kept.fetched_ms = fetched_ms;
            e.failure = None;
            return Ok(kept.reply(now, false, false));
        }
        let outcome = match fetched {
            Ok(response) if (200..300).contains(&response.status) => {
                if response.body.len() > MAX_BODY {
                    Err(too_large())
                } else {
                    let fresh_for = freshness(&response.headers);
                    let headers = response
                        .headers
                        .into_iter()
                        .filter(|(k, _)| KEPT_HEADERS.contains(&k.to_ascii_lowercase().as_str()))
                        .collect::<Vec<_>>();
                    let kept = Kept {
                        response: FetchResponse {
                            status: response.status,
                            headers,
                            body: response.body,
                        },
                        fetched: now,
                        fetched_ms,
                        fresh_for,
                    };
                    let reply = kept.reply(now, false, false);
                    e.kept = Some(kept);
                    e.failure = None;
                    return Ok(reply);
                }
            }
            Ok(mut response) => {
                if response.body.len() > MAX_BODY {
                    response.body.truncate(0);
                }
                Ok(response)
            }
            Err(error) => Err(error),
        };
        e.failure = Some(Failure { at: now, outcome: outcome.clone() });
        if let Some(kept) = e.kept.as_ref().filter(|k| k.servable(now)) {
            return Ok(kept.reply(now, false, true));
        }
        outcome.map(|response| Shared {
            response,
            hit: false,
            stale: false,
            age: Duration::ZERO,
            fresh_for: FLOOR,
            fetched_ms,
        })
    }

    /// Drops what nobody read for `MAX_STALE`, then the least recently read
    /// past `MAX_ENTRIES` or `MAX_BYTES`. An entry with a fetch in flight stays.
    fn prune(entries: &mut HashMap<String, Entry>, now: Instant) {
        entries.retain(|_, e| e.inflight || now.saturating_duration_since(e.used) < MAX_STALE);
        let mut bytes: usize = entries.values().map(Entry::bytes).sum();
        if entries.len() <= MAX_ENTRIES && bytes <= MAX_BYTES {
            return;
        }
        let mut order: Vec<(Instant, String)> =
            entries.iter().filter(|(_, e)| !e.inflight).map(|(k, e)| (e.used, k.clone())).collect();
        order.sort();
        for (_, key) in order {
            if entries.len() <= MAX_ENTRIES && bytes <= MAX_BYTES {
                break;
            }
            if let Some(e) = entries.remove(&key) {
                bytes -= e.bytes();
            }
        }
    }

    /// How many URLs are kept (tests and diagnostics).
    pub fn urls(&self) -> usize {
        self.entries.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

#[cfg(test)]
#[path = "http_cache_tests.rs"]
mod tests;
