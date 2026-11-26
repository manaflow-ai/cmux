//! The crates.io cache end to end over HTTP: a fake index and download host, the proxy in
//! front. A second read of a crate never reaches upstream, a revalidated index file comes back
//! from disk, an index file is served stale when upstream is down, and a path that could
//! leave the cache directory is refused.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};

#[derive(Default)]
struct Fake {
    hits: AtomicU64,
    down: AtomicBool,
}

async fn fake(State(f): State<Arc<Fake>>, req: Request) -> Response {
    f.hits.fetch_add(1, Ordering::Relaxed);
    if f.down.load(Ordering::Relaxed) {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    match req.uri().path() {
        "/index/se/rd/serde" => {
            if req.headers().get(header::IF_NONE_MATCH).is_some_and(|v| v == "\"v1\"") {
                return StatusCode::NOT_MODIFIED.into_response();
            }
            ([(header::ETAG, "\"v1\"")], "{\"name\":\"serde\"}\n").into_response()
        }
        "/dl/serde/serde-1.0.0.crate" => b"crate-bytes".to_vec().into_response(),
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn listen(router: Router) -> SocketAddr {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, router).await.unwrap() });
    addr
}

#[tokio::test]
async fn crates_are_kept_revalidated_and_served_stale() {
    let f = Arc::new(Fake::default());
    let up = listen(Router::new().fallback(fake).with_state(f.clone())).await;
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = cmux_git_cache::Config::new(dir.path().to_path_buf());
    cfg.crates_index = format!("http://{up}/index");
    cfg.crates_dl = format!("http://{up}/dl");
    let state = cmux_git_cache::State::new(cfg).unwrap();
    let proxy = listen(cmux_git_cache::router(state.clone())).await;
    let http = reqwest::Client::new();
    let get = |p: &str| http.get(format!("http://{proxy}{p}")).send();

    let cfgjson: serde_json::Value =
        get("/crates/index/config.json").await.unwrap().json().await.unwrap();
    assert_eq!(cfgjson["dl"], format!("http://{proxy}/crates/dl"));

    let dl = "/crates/dl/serde/1.0.0/download";
    assert_eq!(get(dl).await.unwrap().bytes().await.unwrap().as_ref(), b"crate-bytes");
    let after_first = f.hits.load(Ordering::Relaxed);
    assert_eq!(get(dl).await.unwrap().bytes().await.unwrap().as_ref(), b"crate-bytes");
    assert_eq!(f.hits.load(Ordering::Relaxed), after_first, "a kept crate never asks upstream");

    let idx = "/crates/index/se/rd/serde";
    let r = get(idx).await.unwrap();
    assert_eq!(r.headers()[header::ETAG], "\"v1\"");
    assert_eq!(r.text().await.unwrap(), "{\"name\":\"serde\"}\n");
    // Fresh: served from disk with no upstream request.
    let n = f.hits.load(Ordering::Relaxed);
    assert_eq!(get(idx).await.unwrap().status(), StatusCode::OK);
    assert_eq!(f.hits.load(Ordering::Relaxed), n);
    // cargo's own If-None-Match gets a 304 from the cache.
    let r = http
        .get(format!("http://{proxy}{idx}"))
        .header(header::IF_NONE_MATCH, "\"v1\"")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::NOT_MODIFIED);

    // Past the fresh window and upstream down: the stale copy, counted.
    let file = dir.path().join("crates/index/se/rd/serde");
    std::fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(3600))
        .unwrap();
    f.down.store(true, Ordering::Relaxed);
    let r = get(idx).await.unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    assert_eq!(r.text().await.unwrap(), "{\"name\":\"serde\"}\n");
    assert_eq!(state.crate_stats.stale.load(Ordering::Relaxed), 1);
    // A crate nobody has, upstream down: an error cargo reports, not a body.
    assert_eq!(
        get("/crates/dl/serde/2.0.0/download").await.unwrap().status(),
        StatusCode::BAD_GATEWAY
    );
    f.down.store(false, Ordering::Relaxed);
    assert_eq!(get("/crates/index/ab/cd/nope").await.unwrap().status(), StatusCode::NOT_FOUND);

    for bad in ["/crates/index/..%2f..%2fetc/passwd", "/crates/dl/..%2f/1/download"] {
        assert_eq!(get(bad).await.unwrap().status(), StatusCode::NOT_FOUND, "{bad}");
    }
}
