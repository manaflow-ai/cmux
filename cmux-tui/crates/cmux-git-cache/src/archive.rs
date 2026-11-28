//! GitHub release assets and source archives, cached on this machine.
//!
//! Paths (the URL without `https://`, as `cmux_transport_rewrite::cacheable` names them):
//! `/github.com/OWNER/REPO/releases/download/TAG/FILE`, `/github.com/OWNER/REPO/archive/...`
//! and `/codeload.github.com/OWNER/REPO/{tar.gz,zip,...}/REF`.
//!
//! A cache entry is served only when GitHub still names the same bytes:
//! - a release asset by the asset id GitHub redirects to
//!   (`release-assets.githubusercontent.com/.../<repo id>/<asset uuid>`, which is immutable:
//!   replacing an asset makes a new id);
//! - a codeload archive (and `archive/`, which redirects to codeload) by its strong ETag,
//!   checked with `If-None-Match` (a 304 carries no body).
//!
//! Anything else is a miss: the caller gets a 307 to the original URL, so it reads exactly
//! what it read before (ranges, speed and errors included), and the proxy fills the entry in
//! the background, once per key. An error anywhere (GitHub unreachable, an unexpected answer, a
//! disk error) is also a 307 to the original URL, counted in `archiveFallbacks`. A request
//! with `Authorization` is streamed from GitHub and never cached, so only anonymous, public
//! bytes enter the cache. Each serve is one `git-cache:` log line.

use std::collections::{HashMap, HashSet};
use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant, SystemTime};

use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

use crate::server::State;

/// How long a release URL's asset id answers without asking GitHub again: covers a ranged
/// download's probe and its parallel parts.
const FRESH: Duration = Duration::from_secs(60);
/// The whole archive cache's size; the least recently served entries go first.
pub const DEFAULT_CAP: u64 = 4 << 30;
/// One fill's time limit.
const FILL_TIMEOUT: Duration = Duration::from_secs(600);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Release,
    Archive,
    Codeload,
}

/// What a request names, and where GitHub answers it.
#[derive(Debug, PartialEq, Eq)]
struct Target {
    kind: Kind,
    /// `https://github.com/...` or `https://codeload.github.com/...` (the configured upstreams).
    upstream: String,
}

fn target(state: &State, path: &str) -> Option<Target> {
    let rest = path.strip_prefix('/')?;
    let public = format!("https://{rest}");
    cmux_transport_rewrite::cacheable(&public)?;
    if let Some(tail) = rest.strip_prefix("github.com/") {
        let kind =
            if tail.split('/').nth(2) == Some("releases") { Kind::Release } else { Kind::Archive };
        let upstream = format!("{}/{tail}", state.cfg.upstream.trim_end_matches('/'));
        return Some(Target { kind, upstream });
    }
    let tail = rest.strip_prefix("codeload.github.com/")?;
    let upstream = format!("{}/{tail}", state.cfg.codeload.trim_end_matches('/'));
    Some(Target { kind: Kind::Codeload, upstream })
}

#[derive(Clone, Debug)]
struct Entry {
    /// Cache key: `release:<asset URL without query>` or `codeload:<URL>`.
    key: String,
    /// Where a fill reads the bytes.
    fetch: String,
}

#[derive(Default)]
pub struct Archives {
    filling: std::sync::Mutex<HashSet<String>>,
    fresh: std::sync::Mutex<HashMap<String, (String, Instant)>>,
}

fn lock<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn dir(state: &State) -> PathBuf {
    state.cfg.cache_root.join("archives")
}

fn data_path(state: &State, key: &str) -> PathBuf {
    dir(state).join(hex::encode(Sha256::digest(key.as_bytes())))
}

fn meta_path(data: &Path) -> PathBuf {
    data.with_extension("meta")
}

/// The answer for an archive path, or `None` when `path` is not one.
pub async fn handle(
    state: &Arc<State>,
    method: &Method,
    path: &str,
    headers: &HeaderMap,
) -> Option<Response> {
    let target = target(state, path)?;
    if method != Method::GET && method != Method::HEAD {
        return Some(
            (StatusCode::METHOD_NOT_ALLOWED, "cmux git cache: GET or HEAD\n").into_response(),
        );
    }
    if headers.contains_key(header::AUTHORIZATION) {
        return Some(passthrough(state, method, &target.upstream, headers).await);
    }
    let started = Instant::now();
    Some(match resolve(state, &target).await {
        Ok((entry, true)) => {
            let data = data_path(state, &entry.key);
            match serve_file(state, &data, method, headers, &target.upstream, started).await {
                Ok(resp) => resp,
                Err(e) => fallback(state, &target.upstream, &format!("cache read: {e}")),
            }
        }
        Ok((entry, false)) => {
            state.stats.archive_misses.fetch_add(1, Ordering::Relaxed);
            state.write_stats();
            let filling = fill(state, entry);
            eprintln!(
                "git-cache: {} not cached, redirected to GitHub{}",
                target.upstream,
                if filling { "; filling the cache" } else { "" }
            );
            redirect(&target.upstream)
        }
        Err(e) => fallback(state, &target.upstream, &e),
    })
}

fn redirect(url: &str) -> Response {
    Response::builder()
        .status(StatusCode::TEMPORARY_REDIRECT)
        .header(header::LOCATION, url)
        .body(Body::empty())
        .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}

fn fallback(state: &State, url: &str, why: &str) -> Response {
    state.stats.archive_fallbacks.fetch_add(1, Ordering::Relaxed);
    state.write_stats();
    eprintln!("git-cache: {url}: {why}; redirected to GitHub");
    redirect(url)
}

fn without_query(url: &str) -> &str {
    url.split(['?', '#']).next().unwrap_or(url)
}

/// The entry this request names, and whether the cache holds it with GitHub's current bytes.
async fn resolve(state: &State, target: &Target) -> Result<(Entry, bool), String> {
    let fresh = lock(&state.archives.fresh)
        .get(&target.upstream)
        .filter(|(_, at)| at.elapsed() < FRESH)
        .map(|(key, _)| key.clone());
    if let Some(key) = fresh
        && data_path(state, &key).is_file()
    {
        return Ok((Entry { key, fetch: target.upstream.clone() }, true));
    }
    let (entry, hit) = match target.kind {
        Kind::Release => {
            let location = probe(state, &target.upstream).await?;
            let key = format!("release:{}", without_query(&location));
            let hit = data_path(state, &key).is_file();
            (Entry { key, fetch: location }, hit)
        }
        Kind::Archive => {
            let location = probe(state, &target.upstream).await?;
            let codeload = state.cfg.codeload.trim_end_matches('/');
            if !location.starts_with(&format!("{codeload}/")) {
                return Err(format!(
                    "archive redirected off codeload ({})",
                    without_query(&location)
                ));
            }
            validate_codeload(state, without_query(&location)).await?
        }
        Kind::Codeload => validate_codeload(state, &target.upstream).await?,
    };
    // Only a release asset's id is immutable; a codeload ETag is asked again each time.
    if hit && target.kind == Kind::Release {
        lock(&state.archives.fresh)
            .insert(target.upstream.clone(), (entry.key.clone(), Instant::now()));
    }
    Ok((entry, hit))
}

/// GitHub's redirect for `url`, not followed.
async fn probe(state: &State, url: &str) -> Result<String, String> {
    let resp = state.probe.get(url).send().await.map_err(|e| e.without_url().to_string())?;
    if !resp.status().is_redirection() {
        return Err(format!("GitHub answered {} instead of a redirect", resp.status()));
    }
    let location = resp
        .headers()
        .get(header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .ok_or("redirect without a location")?;
    let location = resp.url().join(location).map_err(|e| e.to_string())?;
    if location.scheme() != "https" && !location.as_str().starts_with("http://127.0.0.1:") {
        return Err("redirect to plain http".to_owned());
    }
    Ok(location.into())
}

/// A codeload archive is a hit when GitHub answers 304 to the stored ETag.
async fn validate_codeload(state: &State, url: &str) -> Result<(Entry, bool), String> {
    let entry = Entry { key: format!("codeload:{url}"), fetch: url.to_owned() };
    let data = data_path(state, &entry.key);
    let Some(etag) = read_meta(&data).and_then(|m| m.etag).filter(|_| data.is_file()) else {
        return Ok((entry, false));
    };
    let resp = state
        .probe
        .get(url)
        .header(header::IF_NONE_MATCH, &etag)
        .send()
        .await
        .map_err(|e| e.without_url().to_string())?;
    match resp.status().as_u16() {
        304 => Ok((entry, true)),
        // Changed: drop this answer's body unread and refill.
        200 => Ok((entry, false)),
        other => Err(format!("GitHub answered {other} to the ETag check")),
    }
}

struct Meta {
    etag: Option<String>,
    content_type: Option<String>,
}

fn read_meta(data: &Path) -> Option<Meta> {
    let text = std::fs::read_to_string(meta_path(data)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_owned);
    Some(Meta { etag: s("etag"), content_type: s("contentType") })
}

/// Starts filling `entry` unless a fill for it runs. Returns whether one runs now.
fn fill(state: &Arc<State>, entry: Entry) -> bool {
    if !lock(&state.archives.filling).insert(entry.key.clone()) {
        return true;
    }
    let owned = state.clone();
    state.scope.spawn_named("archive fill", async move {
        let state = owned;
        let started = Instant::now();
        let data = data_path(&state, &entry.key);
        let result = tokio::time::timeout(FILL_TIMEOUT, fill_once(&state, &entry, &data)).await;
        let result = result.unwrap_or_else(|_| Err("timed out".to_owned()));
        let shown = without_query(&entry.fetch);
        match result {
            Ok(size) => {
                eprintln!(
                    "git-cache: cached {shown} ({size} B in {} ms)",
                    started.elapsed().as_millis()
                );
                evict(&dir(&state), state.cfg.archive_cap, &data);
            }
            Err(e) => {
                let _ = std::fs::remove_file(data.with_extension("part"));
                eprintln!("git-cache: not cached {shown}: {e}");
            }
        }
        lock(&state.archives.filling).remove(&entry.key);
    });
    true
}

async fn fill_once(state: &State, entry: &Entry, data: &Path) -> Result<u64, String> {
    let resp =
        state.http.get(&entry.fetch).send().await.map_err(|e| e.without_url().to_string())?;
    if resp.status() != StatusCode::OK {
        return Err(format!("GitHub answered {}", resp.status()));
    }
    let etag = resp.headers().get(header::ETAG).and_then(|v| v.to_str().ok()).map(str::to_owned);
    if entry.key.starts_with("codeload:") && etag.as_deref().is_none_or(|e| e.starts_with("W/")) {
        return Err("no strong ETag to check it by".to_owned());
    }
    let content_type =
        resp.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).map(str::to_owned);
    let expected = resp.content_length();
    if expected.is_some_and(|n| n > state.cfg.archive_cap / 2) {
        return Err(format!("{} B is over half the cache", expected.unwrap_or(0)));
    }
    let dir = dir(state);
    tokio::fs::create_dir_all(&dir).await.map_err(|e| e.to_string())?;
    let part = data.with_extension("part");
    let mut file = tokio::fs::File::create(&part).await.map_err(|e| e.to_string())?;
    let mut size = 0u64;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.without_url().to_string())?;
        size += chunk.len() as u64;
        if size > state.cfg.archive_cap / 2 {
            return Err("over half the cache".to_owned());
        }
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
    }
    file.sync_all().await.map_err(|e| e.to_string())?;
    drop(file);
    if expected.is_some_and(|n| n != size) {
        return Err(format!("read {size} B of {}", expected.unwrap_or(0)));
    }
    let meta = serde_json::json!({
        "key": entry.key,
        "etag": etag,
        "contentType": content_type,
        "size": size,
    });
    // The bytes first, then their ETag: a reader between the two sees the old ETag, which no
    // longer matches GitHub's, so a miss, never old bytes under a new ETag.
    tokio::fs::rename(&part, data).await.map_err(|e| e.to_string())?;
    let meta_part = data.with_extension("meta-part");
    tokio::fs::write(&meta_part, meta.to_string()).await.map_err(|e| e.to_string())?;
    tokio::fs::rename(&meta_part, meta_path(data)).await.map_err(|e| e.to_string())?;
    Ok(size)
}

/// Removes the least recently served entries until the cache fits `cap` (never `keep`).
fn evict(dir: &Path, cap: u64, keep: &Path) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<(SystemTime, u64, PathBuf)> = read
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_none())
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            Some((m.modified().ok()?, m.len(), e.path()))
        })
        .collect();
    let mut total: u64 = entries.iter().map(|e| e.1).sum();
    entries.sort();
    for (_, len, path) in entries {
        if total <= cap {
            break;
        }
        if path == keep {
            continue;
        }
        if std::fs::remove_file(&path).is_ok() {
            let _ = std::fs::remove_file(meta_path(&path));
            total = total.saturating_sub(len);
            eprintln!("git-cache: evicted {} ({len} B)", path.display());
        }
    }
}

/// One `bytes=` range of a `size` byte file: `Ok(None)` for none (or one we ignore, as a
/// multi-range), `Err(())` when it cannot be satisfied.
fn byte_range(value: Option<&str>, size: u64) -> Result<Option<(u64, u64)>, ()> {
    let Some(spec) = value.and_then(|v| v.trim().strip_prefix("bytes=")) else { return Ok(None) };
    if spec.contains(',') {
        return Ok(None);
    }
    let Some((a, b)) = spec.split_once('-') else { return Ok(None) };
    let (a, b) = (a.trim(), b.trim());
    let range = if a.is_empty() {
        let n: u64 = b.parse().map_err(|_| ())?;
        if n == 0 || size == 0 {
            return Err(());
        }
        (size.saturating_sub(n), size - 1)
    } else {
        let first: u64 = a.parse().map_err(|_| ())?;
        let last = if b.is_empty() { u64::MAX } else { b.parse().map_err(|_| ())? };
        if first >= size || last < first {
            return Err(());
        }
        (first, last.min(size - 1))
    };
    Ok(Some(range))
}

async fn serve_file(
    state: &State,
    data: &Path,
    method: &Method,
    headers: &HeaderMap,
    url: &str,
    started: Instant,
) -> Result<Response, String> {
    let mut file = tokio::fs::File::open(data).await.map_err(|e| e.to_string())?;
    let size = file.metadata().await.map_err(|e| e.to_string())?.len();
    // Least recently served goes first on eviction.
    if let Ok(f) = std::fs::File::options().append(true).open(data) {
        let _ = f.set_modified(SystemTime::now());
    }
    let meta = read_meta(data);
    let content_type = meta
        .as_ref()
        .and_then(|m| m.content_type.clone())
        .unwrap_or_else(|| "application/octet-stream".to_owned());
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let mut out = Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(header::ACCEPT_RANGES, "bytes");
    if let Some(etag) = meta.and_then(|m| m.etag)
        && let Ok(v) = HeaderValue::from_str(&etag)
    {
        out = out.header(header::ETAG, v);
    }
    let (first, len) = match byte_range(range, size) {
        Err(()) => {
            return out
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{size}"))
                .body(Body::empty())
                .map_err(|e| e.to_string());
        }
        Ok(None) => {
            out = out.status(StatusCode::OK);
            (0, size)
        }
        Ok(Some((first, last))) => {
            out = out
                .status(StatusCode::PARTIAL_CONTENT)
                .header(header::CONTENT_RANGE, format!("bytes {first}-{last}/{size}"));
            (first, last - first + 1)
        }
    };
    out = out.header(header::CONTENT_LENGTH, len);
    state.stats.archive_hits.fetch_add(1, Ordering::Relaxed);
    state.write_stats();
    if method == Method::HEAD {
        eprintln!("git-cache: {url} served by cache (HEAD, {size} B)");
        return out.body(Body::empty()).map_err(|e| e.to_string());
    }
    file.seek(SeekFrom::Start(first)).await.map_err(|e| e.to_string())?;
    let log = ServeLog {
        url: url.to_owned(),
        span: (first, len, size),
        sent: 0,
        started,
        stats: state.stats.clone(),
    };
    let stream = tokio_util::io::ReaderStream::with_capacity(file.take(len), 256 << 10).scan(
        log,
        |log, chunk| {
            if let Ok(bytes) = &chunk {
                log.sent += bytes.len() as u64;
            }
            std::future::ready(Some(chunk))
        },
    );
    out.body(Body::from_stream(stream)).map_err(|e| e.to_string())
}

/// Logs one serve when its body ends (or the client goes away).
struct ServeLog {
    url: String,
    span: (u64, u64, u64),
    sent: u64,
    started: Instant,
    stats: Arc<crate::server::Stats>,
}

impl Drop for ServeLog {
    fn drop(&mut self) {
        self.stats.archive_bytes.fetch_add(self.sent, Ordering::Relaxed);
        let (first, len, size) = self.span;
        let part =
            if len == size { String::new() } else { format!(" (bytes {first}+{len} of {size})") };
        eprintln!(
            "git-cache: {} served by cache, {} B in {} ms{part}",
            self.url,
            self.sent,
            self.started.elapsed().as_millis()
        );
    }
}

const FORWARD_REQUEST: [&str; 6] =
    ["authorization", "range", "if-range", "accept", "accept-encoding", "user-agent"];
const FORWARD_RESPONSE: [&str; 7] = [
    "content-type",
    "content-length",
    "content-range",
    "accept-ranges",
    "etag",
    "last-modified",
    "content-disposition",
];

/// A request with credentials: streamed from GitHub, never cached.
async fn passthrough(state: &State, method: &Method, url: &str, headers: &HeaderMap) -> Response {
    let mut req = state.http.request(method.clone(), url);
    for name in FORWARD_REQUEST {
        if let Some(value) = headers.get(name) {
            req = req.header(name, value.as_bytes());
        }
    }
    let resp = match req.send().await {
        Ok(resp) => resp,
        Err(e) => return fallback(state, url, &e.without_url().to_string()),
    };
    eprintln!("git-cache: {url} with credentials: passed through ({})", resp.status());
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut out = Response::builder().status(status);
    for name in FORWARD_RESPONSE {
        if let Some(value) = resp.headers().get(name)
            && let Ok(value) = HeaderValue::from_bytes(value.as_bytes())
        {
            out = out.header(name, value);
        }
    }
    out.body(Body::from_stream(resp.bytes_stream()))
        .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}

#[cfg(test)]
#[path = "archive_tests.rs"]
mod tests;
