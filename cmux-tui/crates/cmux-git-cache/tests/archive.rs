//! Release assets and source archives through the proxy, against a fake GitHub (github.com,
//! the signed asset host and codeload on one listener). Proves a miss redirects to the
//! original URL, a warm read comes from disk with ranges, a changed archive is never served
//! from the cache, credentials bypass it, and an unreachable GitHub falls back to it.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};

const ASSET: &[u8] = b"release asset bytes 0123456789";
const TARBALL: &[u8] = b"codeload tarball bytes";

struct Fake {
    addr: Mutex<Option<SocketAddr>>,
    asset_gets: AtomicU64,
    etag: Mutex<String>,
}

async fn fake_github(State(f): State<Arc<Fake>>, req: Request) -> Response {
    let base = format!("http://{}", f.addr.lock().unwrap().unwrap());
    match req.uri().path() {
        "/o/r/releases/download/v1/a.bin" => {
            (StatusCode::FOUND, [(header::LOCATION, format!("{base}/assets/1?sig=x"))])
                .into_response()
        }
        "/assets/1" => {
            f.asset_gets.fetch_add(1, Ordering::SeqCst);
            ([(header::CONTENT_TYPE, "application/octet-stream")], ASSET).into_response()
        }
        "/o/r/archive/main.tar.gz" => {
            (StatusCode::FOUND, [(header::LOCATION, format!("{base}/o/r/tar.gz/main"))])
                .into_response()
        }
        "/o/r/tar.gz/main" => {
            let etag = f.etag.lock().unwrap().clone();
            if req.headers().get(header::IF_NONE_MATCH).is_some_and(|v| v == etag.as_str()) {
                return StatusCode::NOT_MODIFIED.into_response();
            }
            ([(header::ETAG, etag.as_str()), (header::CONTENT_TYPE, "application/x-gzip")], TARBALL)
                .into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn listen(router: Router) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    addr
}

struct World {
    _tmp: tempfile::TempDir,
    fake: Arc<Fake>,
    fake_base: String,
    proxy: String,
    state: Arc<cmux_git_cache::State>,
    client: reqwest::Client,
}

async fn world(upstream: Option<&str>) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let fake = Arc::new(Fake {
        addr: Mutex::new(None),
        asset_gets: AtomicU64::new(0),
        etag: Mutex::new("\"e1\"".to_owned()),
    });
    let addr = listen(Router::new().fallback(fake_github).with_state(fake.clone())).await;
    *fake.addr.lock().unwrap() = Some(addr);
    let fake_base = format!("http://{addr}");
    let mut cfg = cmux_git_cache::Config::new(tmp.path().join("cache"));
    cfg.upstream = upstream.unwrap_or(&fake_base).to_owned();
    cfg.codeload = upstream.unwrap_or(&fake_base).to_owned();
    let state = cmux_git_cache::State::new(cfg).unwrap();
    let proxy = format!("http://{}", listen(cmux_git_cache::router(state.clone())).await);
    let client =
        reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).build().unwrap();
    World { _tmp: tmp, fake, fake_base, proxy, state, client }
}

fn entries(root: &Path) -> usize {
    std::fs::read_dir(root.join("archives"))
        .map_or(0, |d| d.filter_map(Result::ok).filter(|e| e.path().extension().is_none()).count())
}

async fn wait_for_entries(w: &World, n: usize) {
    let root = w.state.cfg.cache_root.clone();
    for _ in 0..200 {
        if entries(&root) >= n {
            // The ETag lands just after the bytes.
            tokio::time::sleep(Duration::from_millis(50)).await;
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the cache never filled {n} entries");
}

async fn get(w: &World, path: &str, range: Option<&str>) -> reqwest::Response {
    let mut req = w.client.get(format!("{}{path}", w.proxy));
    if let Some(r) = range {
        req = req.header(header::RANGE, r);
    }
    req.send().await.unwrap()
}

fn location(resp: &reqwest::Response) -> String {
    resp.headers()[header::LOCATION].to_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn release_asset_cold_redirects_then_warm_serves_ranges_from_disk() {
    let w = world(None).await;
    let path = "/github.com/o/r/releases/download/v1/a.bin";
    let cold = get(&w, path, None).await;
    assert_eq!(cold.status(), 307);
    assert_eq!(location(&cold), format!("{}/o/r/releases/download/v1/a.bin", w.fake_base));
    wait_for_entries(&w, 1).await;

    let warm = get(&w, path, None).await;
    assert_eq!(warm.status(), 200);
    assert_eq!(warm.headers()[header::ACCEPT_RANGES], "bytes");
    assert_eq!(&warm.bytes().await.unwrap()[..], ASSET);
    let probe = get(&w, path, Some("bytes=0-0")).await;
    assert_eq!(probe.status(), 206);
    assert_eq!(probe.headers()[header::CONTENT_RANGE], format!("bytes 0-0/{}", ASSET.len()));
    let tail = get(&w, path, Some("bytes=8-")).await;
    assert_eq!(&tail.bytes().await.unwrap()[..], &ASSET[8..]);
    let head = w.client.head(format!("{}{path}", w.proxy)).send().await.unwrap();
    assert_eq!(head.headers()[header::CONTENT_LENGTH], ASSET.len().to_string());
    assert_eq!(get(&w, path, Some("bytes=999-")).await.status(), 416);

    assert_eq!(w.fake.asset_gets.load(Ordering::SeqCst), 1, "one fill, every warm read local");
    let health: serde_json::Value = w
        .client
        .get(format!("{}/_cmux/git-cache/health", w.proxy))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(health["archiveMisses"], 1);
    assert_eq!(health["archiveHits"], 4);
    assert_eq!(health["archiveFallbacks"], 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn codeload_is_served_only_while_its_etag_holds() {
    let w = world(None).await;
    let path = "/codeload.github.com/o/r/tar.gz/main";
    assert_eq!(get(&w, path, None).await.status(), 307);
    wait_for_entries(&w, 1).await;
    let warm = get(&w, path, None).await;
    assert_eq!(warm.status(), 200);
    assert_eq!(&warm.bytes().await.unwrap()[..], TARBALL);
    // github.com/O/R/archive redirects to the same codeload URL: the same entry.
    let via_archive = get(&w, "/github.com/o/r/archive/main.tar.gz", None).await;
    assert_eq!(via_archive.status(), 200);

    *w.fake.etag.lock().unwrap() = "\"e2\"".to_owned();
    let changed = get(&w, path, None).await;
    assert_eq!(changed.status(), 307, "a changed archive is never served from the cache");
    assert_eq!(location(&changed), format!("{}/o/r/tar.gz/main", w.fake_base));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn credentials_bypass_the_cache() {
    let w = world(None).await;
    let resp = w
        .client
        .get(format!("{}/github.com/o/r/releases/download/v1/a.bin", w.proxy))
        .header(header::AUTHORIZATION, "Bearer t")
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(&resp.bytes().await.unwrap()[..], ASSET);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(entries(&w.state.cfg.cache_root), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unreachable_github_falls_back_to_the_original_url() {
    let w = world(Some("http://127.0.0.1:9")).await;
    let resp = get(&w, "/github.com/o/r/releases/download/v1/a.bin", None).await;
    assert_eq!(resp.status(), 307);
    assert_eq!(location(&resp), "http://127.0.0.1:9/o/r/releases/download/v1/a.bin");
    assert_eq!(w.state.stats.archive_fallbacks.load(Ordering::Relaxed), 1);
}
