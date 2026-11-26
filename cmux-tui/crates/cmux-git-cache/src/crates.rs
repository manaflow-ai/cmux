//! The machine's crates.io cache: cargo's sparse index and `.crate` downloads, served from this
//! machine's disk (then a peer's), and from crates.io only for what nobody has.
//!
//! Each `cargo fetch` with a fresh `CARGO_HOME` (every CI job, every new chat) asked
//! index.crates.io and static.crates.io again: about 1.3-7.3 s per ripgrep-sized lockfile on a
//! Freestyle VM against 0.8-0.9 s on GCP (hq docs/findings/2026-11-25-freestyle-vs-gcp-workload-bench.md).
//!
//! Wiring: while the proxy listens it writes `cargo_config_text` (crates-io replaced by
//! `sparse+http://127.0.0.1:PORT/crates/index/`) to the path it was given; the Cloud machine
//! puts it at `/.cargo/config.toml`, which cargo reads from every working directory whatever
//! `CARGO_HOME` is, below a project's own `.cargo/config.toml`. The file is removed when the
//! proxy stops, so a machine without a running proxy reaches crates.io as before. Lockfiles
//! are unchanged: source replacement keeps the `crates-io` source and its checksums, and cargo
//! verifies every `.crate` against the index's checksum, so a bad cache entry fails as a
//! checksum error, never as a different crate.
//!
//! Order per request: a `.crate` (immutable) from disk, else a peer, else static.crates.io,
//! kept on disk. An index file from disk while it is younger than `INDEX_FRESH`, else
//! revalidated (If-None-Match) with a peer or index.crates.io; when neither answers, the stale
//! copy is served (counted in `cratesStale`), so cargo keeps working offline for what was seen.
//! Off: `/etc/cmux/crates-cache.disabled` (no cargo config is written), or the whole proxy's
//! switch.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use axum::Router;
use axum::body::Body;
use axum::extract::{Path as UrlPath, State as AxState};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;

use crate::server::State;

pub const HEADER: &str = "# cmux crates cache (managed, do not edit): written while the proxy listens, removed when it stops.";
/// Where a Cloud machine's proxy writes the cargo config: an ancestor of every working directory.
pub const ROOT_CARGO_CONFIG: &str = "/.cargo/config.toml";
pub const DISABLED_FILE: &str = "/etc/cmux/crates-cache.disabled";
pub const INDEX_UPSTREAM: &str = "https://index.crates.io";
pub const DL_UPSTREAM: &str = "https://static.crates.io/crates";
/// An index file this young is served without asking upstream. cargo asks again on its next run.
pub const INDEX_FRESH: Duration = Duration::from_secs(60);
const SOURCE: &str = "cmux-crates-cache";

#[derive(Default)]
pub struct CrateStats {
    pub local: AtomicU64,
    pub local_bytes: AtomicU64,
    pub peer: AtomicU64,
    pub upstream: AtomicU64,
    pub upstream_bytes: AtomicU64,
    pub revalidated: AtomicU64,
    pub stale: AtomicU64,
}

impl CrateStats {
    pub fn json(&self) -> serde_json::Value {
        let n = |c: &AtomicU64| c.load(Ordering::Relaxed);
        serde_json::json!({
            "cratesLocal": n(&self.local),
            "cratesLocalBytes": n(&self.local_bytes),
            "cratesPeer": n(&self.peer),
            "cratesUpstream": n(&self.upstream),
            "cratesUpstreamBytes": n(&self.upstream_bytes),
            "cratesRevalidated": n(&self.revalidated),
            "cratesStale": n(&self.stale),
        })
    }
}

/// The cargo config the proxy writes while it listens.
pub fn cargo_config_text(port: u16) -> String {
    format!(
        "{HEADER}\n[source.crates-io]\nreplace-with = \"{SOURCE}\"\n\n[source.{SOURCE}]\nregistry = \"sparse+http://127.0.0.1:{port}/crates/index/\"\n"
    )
}

/// Writes the cargo config unless the machine turned the crates cache off.
pub fn write_cargo_config(path: &Path, port: u16) -> std::io::Result<bool> {
    if Path::new(DISABLED_FILE).exists() {
        remove_cargo_config(path);
        return Ok(false);
    }
    crate::gitconfig::write_include(path, &cargo_config_text(port))?;
    Ok(true)
}

/// Removes the cargo config if it is ours (its header), so cargo goes to crates.io again.
pub fn remove_cargo_config(path: &Path) {
    if std::fs::read_to_string(path).is_ok_and(|t| t.starts_with(HEADER)) {
        let _ = std::fs::remove_file(path);
    }
}

pub fn routes() -> Router<Arc<State>> {
    Router::new()
        .route("/crates/index/config.json", get(index_config))
        .route("/crates/index/{*path}", get(index_file))
        .route("/crates/dl/{name}/{version}/download", get(download))
}

fn root(state: &State) -> PathBuf {
    state.cfg.cache_root.join("crates")
}

/// A crate name or version, or an index path made of them: no `..`, no absolute part, nothing
/// that is not a name character. crates.io names are ASCII alphanumerics, `-` and `_`;
/// versions add `.` and `+`.
fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.len() <= 128
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'+'))
}

fn safe_index_path(p: &str) -> bool {
    let parts: Vec<&str> = p.split('/').collect();
    (1..=4).contains(&parts.len()) && parts.iter().all(|s| safe_segment(s))
}

async fn index_config(headers: HeaderMap) -> Response {
    let host = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .filter(|h| {
            h.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b':' | b'-' | b'[' | b']'))
        })
        .unwrap_or("127.0.0.1");
    let body =
        serde_json::json!({ "dl": format!("http://{host}/crates/dl"), "api": "https://crates.io" });
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

struct Meta {
    etag: Option<String>,
    fetched: SystemTime,
}

fn meta_path(file: &Path) -> PathBuf {
    let mut name = file.file_name().unwrap_or_default().to_os_string();
    name.push(".etag");
    file.with_file_name(name)
}

async fn read_cached(file: &Path) -> Option<(Vec<u8>, Meta)> {
    let body = tokio::fs::read(file).await.ok()?;
    let fetched = tokio::fs::metadata(file).await.ok()?.modified().ok()?;
    let etag = tokio::fs::read_to_string(meta_path(file)).await.ok().filter(|e| !e.is_empty());
    Some((body, Meta { etag, fetched }))
}

async fn store(file: &Path, body: &[u8], etag: Option<&str>) {
    let Some(dir) = file.parent() else { return };
    // The cache's disk bound (room.rs): below the floor the crate is served, not kept.
    if !crate::room::has_room(dir) {
        return;
    }
    if tokio::fs::create_dir_all(dir).await.is_err() {
        return;
    }
    static N: AtomicU64 = AtomicU64::new(0);
    let part = file.with_extension(format!(
        "part{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    if tokio::fs::write(&part, body).await.is_ok() && tokio::fs::rename(&part, file).await.is_ok() {
        let _ = tokio::fs::write(meta_path(file), etag.unwrap_or("")).await;
    } else {
        let _ = tokio::fs::remove_file(&part).await;
    }
}

/// Marks a revalidated index file fresh again without rewriting it.
async fn touch(file: &Path) {
    let file = file.to_owned();
    let _ = tokio::task::spawn_blocking(move || {
        std::fs::File::options()
            .write(true)
            .open(&file)
            .and_then(|f| f.set_modified(SystemTime::now()))
    })
    .await;
}

fn answer(body: Vec<u8>, etag: Option<&str>, client: &HeaderMap, kind: &'static str) -> Response {
    if let (Some(ours), Some(theirs)) =
        (etag, client.get(header::IF_NONE_MATCH).and_then(|v| v.to_str().ok()))
        && ours == theirs
    {
        let mut r = StatusCode::NOT_MODIFIED.into_response();
        if let Ok(v) = ours.parse() {
            r.headers_mut().insert(header::ETAG, v);
        }
        return r;
    }
    let mut r = Response::new(Body::from(body));
    r.headers_mut().insert(header::CONTENT_TYPE, header::HeaderValue::from_static(kind));
    if let Some(v) = etag.and_then(|e| e.parse().ok()) {
        r.headers_mut().insert(header::ETAG, v);
    }
    r
}

enum Upstream {
    Body(Vec<u8>, Option<String>),
    NotModified,
    Missing,
    Failed(String),
}

async fn ask(state: &State, url: &str, etag: Option<&str>) -> Upstream {
    let mut req = state.http.get(url).timeout(Duration::from_secs(120));
    if let Some(e) = etag {
        req = req.header(header::IF_NONE_MATCH, e);
    }
    match req.send().await {
        Ok(r) if r.status() == StatusCode::NOT_MODIFIED => Upstream::NotModified,
        Ok(r) if r.status() == StatusCode::NOT_FOUND || r.status() == StatusCode::GONE => {
            Upstream::Missing
        }
        Ok(r) if r.status().is_success() => {
            let etag =
                r.headers().get(header::ETAG).and_then(|v| v.to_str().ok()).map(str::to_owned);
            match r.bytes().await {
                Ok(b) => Upstream::Body(b.to_vec(), etag),
                Err(e) => Upstream::Failed(e.to_string()),
            }
        }
        Ok(r) => Upstream::Failed(format!("HTTP {}", r.status())),
        Err(e) => Upstream::Failed(e.to_string()),
    }
}

/// Peers first (each a cmux git cache with the same routes), then crates.io.
fn sources(state: &State, tail: &str, upstream: String) -> Vec<(bool, String)> {
    let mut out: Vec<(bool, String)> = state
        .cfg
        .peers
        .iter()
        .map(|p| (true, format!("{}/crates/{tail}", p.trim_end_matches('/'))))
        .collect();
    out.push((false, upstream));
    out
}

async fn index_file(
    AxState(state): AxState<Arc<State>>,
    UrlPath(path): UrlPath<String>,
    headers: HeaderMap,
) -> Response {
    if !safe_index_path(&path) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let file = root(&state).join("index").join(&path);
    let cached = read_cached(&file).await;
    let cs = &state.crate_stats;
    if let Some((body, meta)) = &cached
        && meta.fetched.elapsed().is_ok_and(|age| age < INDEX_FRESH)
    {
        cs.local.fetch_add(1, Ordering::Relaxed);
        cs.local_bytes.fetch_add(body.len() as u64, Ordering::Relaxed);
        return answer(body.clone(), meta.etag.as_deref(), &headers, "text/plain");
    }
    let etag = cached.as_ref().and_then(|(_, m)| m.etag.clone());
    let mut why = String::new();
    for (peer, url) in
        sources(&state, &format!("index/{path}"), format!("{}/{path}", state.cfg.crates_index))
    {
        match ask(&state, &url, etag.as_deref()).await {
            Upstream::NotModified => {
                if let Some((body, meta)) = cached {
                    touch(&file).await;
                    cs.revalidated.fetch_add(1, Ordering::Relaxed);
                    return answer(body, meta.etag.as_deref(), &headers, "text/plain");
                }
            }
            Upstream::Body(body, tag) => {
                (if peer { &cs.peer } else { &cs.upstream }).fetch_add(1, Ordering::Relaxed);
                cs.upstream_bytes.fetch_add(body.len() as u64, Ordering::Relaxed);
                store(&file, &body, tag.as_deref()).await;
                return answer(body, tag.as_deref(), &headers, "text/plain");
            }
            Upstream::Missing if !peer => return StatusCode::NOT_FOUND.into_response(),
            Upstream::Missing => {}
            Upstream::Failed(e) => why = e,
        }
    }
    if let Some((body, meta)) = cached {
        cs.stale.fetch_add(1, Ordering::Relaxed);
        eprintln!("git-cache: crates index {path} served stale ({why})");
        return answer(body, meta.etag.as_deref(), &headers, "text/plain");
    }
    eprintln!("git-cache: crates index {path} unavailable ({why})");
    StatusCode::BAD_GATEWAY.into_response()
}

async fn download(
    AxState(state): AxState<Arc<State>>,
    UrlPath((name, version)): UrlPath<(String, String)>,
    headers: HeaderMap,
) -> Response {
    if !safe_segment(&name) || !safe_segment(&version) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let file = root(&state).join("dl").join(&name).join(format!("{version}.crate"));
    let cs = &state.crate_stats;
    if let Ok(body) = tokio::fs::read(&file).await {
        cs.local.fetch_add(1, Ordering::Relaxed);
        cs.local_bytes.fetch_add(body.len() as u64, Ordering::Relaxed);
        return answer(body, None, &headers, "application/gzip");
    }
    let mut why = String::new();
    let up = format!("{}/{name}/{name}-{version}.crate", state.cfg.crates_dl);
    for (peer, url) in sources(&state, &format!("dl/{name}/{version}/download"), up) {
        match ask(&state, &url, None).await {
            Upstream::Body(body, _) => {
                (if peer { &cs.peer } else { &cs.upstream }).fetch_add(1, Ordering::Relaxed);
                cs.upstream_bytes.fetch_add(body.len() as u64, Ordering::Relaxed);
                store(&file, &body, None).await;
                return answer(body, None, &headers, "application/gzip");
            }
            Upstream::Missing if !peer => return StatusCode::NOT_FOUND.into_response(),
            Upstream::Failed(e) => why = e,
            _ => {}
        }
    }
    eprintln!("git-cache: crate {name} {version} unavailable ({why})");
    StatusCode::BAD_GATEWAY.into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_replaces_crates_io() {
        let t = cargo_config_text(47380);
        assert!(t.starts_with(HEADER));
        assert!(t.contains("[source.crates-io]\nreplace-with = \"cmux-crates-cache\"\n"));
        assert!(t.contains("registry = \"sparse+http://127.0.0.1:47380/crates/index/\""));
    }

    #[test]
    fn segments_refuse_traversal() {
        assert!(safe_segment("serde_json"));
        assert!(safe_segment("1.0.0+wasi-0.2"));
        for bad in ["", ".", "..", "a/b", "a b", "%2e%2e"] {
            assert!(!safe_segment(bad), "{bad}");
        }
        assert!(safe_index_path("se/rd/serde"));
        assert!(safe_index_path("3/s/syn"));
        assert!(!safe_index_path("../etc/passwd"));
        assert!(!safe_index_path("a/../../b"));
        assert!(!safe_index_path("/abs"));
    }

    #[test]
    fn remove_only_ours() {
        let dir = tempfile::tempdir().unwrap();
        let ours = dir.path().join("config.toml");
        crate::gitconfig::write_include(&ours, &cargo_config_text(1)).unwrap();
        remove_cargo_config(&ours);
        assert!(!ours.exists());
        std::fs::write(&ours, "[build]\n").unwrap();
        remove_cargo_config(&ours);
        assert!(ours.exists());
    }
}
