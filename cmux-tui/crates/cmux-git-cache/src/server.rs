//! The HTTP side: GitHub's smart-HTTP paths under `/github.com/`, answered from the mirror
//! when upstream confirmed the caller, else passed through.

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use futures_util::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::auth::{AuthCache, caller_key, short};
use crate::mirror::{Mirrors, git};
use crate::pkt;
use crate::route::{self, Action, Route};

#[derive(Clone, Debug)]
pub struct Config {
    pub listen: SocketAddr,
    /// `https://github.com`.
    pub upstream: String,
    /// The platform edge, which adds the machine's own repository token
    /// (`https://platform.cmux.internal/v1/cloud/git/github.com`): asked when upstream refuses a
    /// caller without credentials, as a checkout made through the edge expects.
    pub edge: Option<String>,
    /// The cache's tenant (the machine's team): part of every mirror path and grant.
    pub tenant: String,
    pub cache_root: PathBuf,
    /// Peer proxies (`http://HOST:PORT`), asked before upstream for missing objects.
    pub peers: Vec<String>,
    pub auth_ttl: Duration,
    pub max_body: usize,
}

impl Config {
    pub fn new(cache_root: PathBuf) -> Self {
        Self {
            listen: SocketAddr::from(([127, 0, 0, 1], crate::gitconfig::DEFAULT_PORT)),
            upstream: "https://github.com".to_owned(),
            edge: None,
            tenant: "local".to_owned(),
            cache_root,
            peers: Vec::new(),
            auth_ttl: Duration::from_secs(60),
            max_body: 64 << 20,
        }
    }
}

#[derive(Default)]
pub struct Stats {
    pub upstream_requests: AtomicU64,
    pub upstream_bytes: AtomicU64,
    pub local_serves: AtomicU64,
    pub local_bytes: AtomicU64,
    pub refused: AtomicU64,
}

pub struct State {
    pub cfg: Config,
    pub auth: AuthCache,
    pub mirrors: Mirrors,
    pub stats: Arc<Stats>,
    http: reqwest::Client,
    /// Repositories the edge answered for callers without credentials.
    via_edge: std::sync::Mutex<std::collections::HashSet<String>>,
}

impl State {
    pub fn new(cfg: Config) -> Result<Arc<Self>, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::limited(5))
            .user_agent("git/cmux-git-cache")
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Arc::new(Self {
            auth: AuthCache::new(cfg.auth_ttl),
            mirrors: Mirrors::new(cfg.cache_root.clone()),
            stats: Arc::new(Stats::default()),
            cfg,
            http,
            via_edge: std::sync::Mutex::new(std::collections::HashSet::new()),
        }))
    }

    /// Where this caller's requests for `route` go: the edge for an anonymous caller of a
    /// repository the edge answered, else upstream.
    fn base(&self, route: &Route, caller: &str) -> &str {
        if let Some(edge) = &self.cfg.edge
            && caller == "anon"
            && self
                .via_edge
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(&route.key())
        {
            return edge;
        }
        &self.cfg.upstream
    }

    fn use_edge(&self, route: &Route, caller: &str, status: StatusCode) -> bool {
        caller == "anon" && status == StatusCode::UNAUTHORIZED && self.cfg.edge.is_some() && {
            let set = self.via_edge.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            !set.contains(&route.key())
        }
    }

    fn mark_edge(&self, route: &Route) {
        self.via_edge.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(route.key());
    }

    fn peer_urls(&self, route: &Route) -> Vec<String> {
        self.cfg
            .peers
            .iter()
            .map(|p| route.url(&format!("{}/github.com", p.trim_end_matches('/')), ""))
            .collect()
    }
}

pub fn router(state: Arc<State>) -> Router {
    Router::new()
        .route("/_cmux/git-cache/health", axum::routing::get(health))
        .fallback(handle)
        .with_state(state)
}

async fn health(axum::extract::State(state): axum::extract::State<Arc<State>>) -> Response {
    let s = &state.stats;
    let body = serde_json::json!({
        "ok": true,
        "upstream": state.cfg.upstream,
        "tenant": state.cfg.tenant,
        "peers": state.cfg.peers,
        "upstreamRequests": s.upstream_requests.load(Ordering::Relaxed),
        "upstreamBytes": s.upstream_bytes.load(Ordering::Relaxed),
        "localServes": s.local_serves.load(Ordering::Relaxed),
        "localBytes": s.local_bytes.load(Ordering::Relaxed),
        "refused": s.refused.load(Ordering::Relaxed),
    });
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

const FORWARD_REQUEST: [&str; 7] = [
    "authorization",
    "git-protocol",
    "content-type",
    "content-encoding",
    "accept",
    "accept-encoding",
    "user-agent",
];
const FORWARD_RESPONSE: [&str; 6] =
    ["content-type", "content-encoding", "www-authenticate", "cache-control", "expires", "pragma"];

fn authorization(headers: &HeaderMap) -> Option<Vec<u8>> {
    headers.get(header::AUTHORIZATION).map(|v| v.as_bytes().to_vec())
}

async fn handle(
    axum::extract::State(state): axum::extract::State<Arc<State>>,
    req: Request,
) -> Response {
    let Some(route) = route::parse(req.uri().path()) else {
        return (StatusCode::NOT_FOUND, "cmux git cache: not a GitHub repository path\n")
            .into_response();
    };
    let query = req.uri().query().map(str::to_owned);
    let method = req.method().clone();
    let headers = req.headers().clone();
    match (&method, route.action) {
        (&Method::GET, Action::InfoRefs) => {
            info_refs(&state, &route, query.as_deref(), &headers).await
        }
        (&Method::POST, Action::UploadPack) => {
            upload_pack(&state, &route, &headers, req.into_body()).await
        }
        _ => {
            let tail = route_tail(route.action);
            let body = reqwest::Body::wrap_stream(req.into_body().into_data_stream());
            let base =
                state.base(&route, &caller_key(authorization(&headers).as_deref())).to_owned();
            passthrough(&state, &base, &route, method, tail, query.as_deref(), &headers, body)
                .await
                .0
        }
    }
}

fn route_tail(action: Action) -> &'static str {
    match action {
        Action::InfoRefs => "/info/refs",
        Action::UploadPack => "/git-upload-pack",
        Action::ReceivePack => "/git-receive-pack",
    }
}

/// Sends the request upstream and streams the answer back. Returns the status too.
#[allow(clippy::too_many_arguments)]
async fn passthrough(
    state: &State,
    base: &str,
    route: &Route,
    method: Method,
    tail: &str,
    query: Option<&str>,
    headers: &HeaderMap,
    body: reqwest::Body,
) -> (Response, StatusCode) {
    let mut url = route.url(base, tail);
    if let Some(q) = query {
        url.push('?');
        url.push_str(q);
    }
    let mut req = state.http.request(method, &url).body(body);
    for name in FORWARD_REQUEST {
        if let Some(value) = headers.get(name) {
            req = req.header(name, value.as_bytes());
        }
    }
    state.stats.upstream_requests.fetch_add(1, Ordering::Relaxed);
    let resp = match req.send().await {
        Ok(resp) => resp,
        Err(e) => {
            eprintln!("git-cache: {} upstream: {}", route.key(), e.without_url());
            return (
                (StatusCode::BAD_GATEWAY, "cmux git cache: upstream unreachable\n").into_response(),
                StatusCode::BAD_GATEWAY,
            );
        }
    };
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut out = Response::builder().status(status);
    for name in FORWARD_RESPONSE {
        if let Some(value) = resp.headers().get(name)
            && let Ok(value) = HeaderValue::from_bytes(value.as_bytes())
        {
            out = out.header(name, value);
        }
    }
    let stats = state.stats.clone();
    let stream = resp.bytes_stream().map(move |chunk| {
        if let Ok(bytes) = &chunk {
            stats.upstream_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        }
        chunk.map_err(std::io::Error::other)
    });
    (
        out.body(Body::from_stream(stream))
            .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response()),
        status,
    )
}

fn record(state: &State, route: &Route, caller: &str, status: StatusCode) {
    let (tenant, repo) = (&state.cfg.tenant, route.key());
    if status == StatusCode::OK {
        state.auth.grant(caller, tenant, &repo);
    } else if matches!(status.as_u16(), 401 | 403 | 404) {
        state.auth.revoke(caller, tenant, &repo);
        state.stats.refused.fetch_add(1, Ordering::Relaxed);
    }
}

async fn info_refs(
    state: &State,
    route: &Route,
    query: Option<&str>,
    headers: &HeaderMap,
) -> Response {
    let upload = query.is_some_and(|q| q.split('&').any(|kv| kv == "service=git-upload-pack"));
    let caller = caller_key(authorization(headers).as_deref());
    let get = |base: String| async move {
        passthrough(
            state,
            &base,
            route,
            Method::GET,
            "/info/refs",
            query,
            headers,
            reqwest::Body::from(Vec::new()),
        )
        .await
    };
    let (mut resp, mut status) = get(state.base(route, &caller).to_owned()).await;
    if upload && state.use_edge(route, &caller, status) {
        let edge = state.cfg.edge.clone().unwrap_or_default();
        let (edge_resp, edge_status) = get(edge).await;
        if edge_status == StatusCode::OK {
            state.mark_edge(route);
            (resp, status) = (edge_resp, edge_status);
        }
    }
    if upload {
        record(state, route, &caller, status);
    }
    resp
}

/// Upstream's answer to this caller's ref advertisement, without its body.
async fn confirm(state: &State, route: &Route, headers: &HeaderMap, caller: &str) -> bool {
    let tenant = &state.cfg.tenant;
    if state.auth.allowed(caller, tenant, &route.key()) {
        return true;
    }
    let ask = |base: String| async move {
        let url = route.url(&base, "/info/refs?service=git-upload-pack");
        let mut req = state.http.get(&url);
        for name in ["authorization", "git-protocol", "user-agent"] {
            if let Some(value) = headers.get(name) {
                req = req.header(name, value.as_bytes());
            }
        }
        state.stats.upstream_requests.fetch_add(1, Ordering::Relaxed);
        match req.send().await {
            Ok(resp) => {
                StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY)
            }
            Err(_) => StatusCode::BAD_GATEWAY,
        }
    };
    let mut status = ask(state.base(route, caller).to_owned()).await;
    if state.use_edge(route, caller, status)
        && ask(state.cfg.edge.clone().unwrap_or_default()).await == StatusCode::OK
    {
        state.mark_edge(route);
        status = StatusCode::OK;
    }
    record(state, route, caller, status);
    status == StatusCode::OK
}

fn decode(headers: &HeaderMap, raw: &[u8], max: usize) -> Option<Vec<u8>> {
    let gzip = headers
        .get(header::CONTENT_ENCODING)
        .is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"gzip"));
    if !gzip {
        return Some(raw.to_vec());
    }
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(raw).take(max as u64 + 1).read_to_end(&mut out).ok()?;
    (out.len() <= max).then_some(out)
}

async fn upload_pack(state: &State, route: &Route, headers: &HeaderMap, body: Body) -> Response {
    let raw = match axum::body::to_bytes(body, state.cfg.max_body).await {
        Ok(raw) => raw,
        Err(_) => {
            return (StatusCode::PAYLOAD_TOO_LARGE, "cmux git cache: request too large\n")
                .into_response();
        }
    };
    let auth = authorization(headers);
    let caller = caller_key(auth.as_deref());
    let upstream = |raw: Bytes| {
        let base = state.base(route, &caller).to_owned();
        async move {
            passthrough(
                state,
                &base,
                route,
                Method::POST,
                "/git-upload-pack",
                None,
                headers,
                reqwest::Body::from(raw),
            )
            .await
            .0
        }
    };
    let v2 =
        headers.get("git-protocol").is_some_and(|v| v.to_str().unwrap_or("").contains("version=2"));
    let Some(decoded) = decode(headers, &raw, state.cfg.max_body) else {
        return upstream(raw).await;
    };
    let pkt::Request::Fetch { wants } = pkt::classify(&decoded, v2) else {
        return upstream(raw).await;
    };
    let key = route.key();
    // Tenant safety: nothing from the cache before upstream said yes to this caller.
    if !confirm(state, route, headers, &caller).await {
        eprintln!("git-cache: {key} caller={} not confirmed: upstream answers", short(&caller));
        return upstream(raw).await;
    }
    let dir = state.mirrors.dir(&state.cfg.tenant, &key);
    let upstream_url = route.url(state.base(route, &caller), "");
    if !state
        .mirrors
        .ensure(&dir, &upstream_url, &state.peer_urls(route), auth.as_deref(), &wants)
        .await
    {
        eprintln!(
            "git-cache: {key} caller={} mirror short of wants: upstream answers",
            short(&caller)
        );
        return upstream(raw).await;
    }
    match serve_local(state, &dir, v2, decoded).await {
        Ok(resp) => {
            eprintln!(
                "git-cache: {key} caller={} wants={} served=local",
                short(&caller),
                wants.len()
            );
            resp
        }
        Err(e) => {
            eprintln!("git-cache: {key} local upload-pack: {e}: upstream answers");
            upstream(raw).await
        }
    }
}

/// `git upload-pack --stateless-rpc` on the mirror. An upload-pack that ends before its first
/// byte is an error the caller turns into a pass-through, so a request the local git cannot
/// answer still succeeds.
async fn serve_local(
    state: &State,
    dir: &std::path::Path,
    v2: bool,
    body: Vec<u8>,
) -> Result<Response, String> {
    let mut cmd = git();
    cmd.args(["upload-pack", "--stateless-rpc", "--strict"]).arg(dir);
    if v2 {
        cmd.env("GIT_PROTOCOL", "version=2");
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    tokio::spawn(async move {
        let _ = stdin.write_all(&body).await;
    });
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    let mut stderr = child.stderr.take().ok_or("no stderr")?;
    let mut first = vec![0u8; 64 << 10];
    let n = stdout.read(&mut first).await.map_err(|e| e.to_string())?;
    if n == 0 {
        let mut err = String::new();
        let _ = stderr.read_to_string(&mut err).await;
        let status = child.wait().await.map_err(|e| e.to_string())?;
        return Err(format!("{status}: {}", err.trim().lines().last().unwrap_or("no output")));
    }
    first.truncate(n);
    tokio::spawn(async move {
        let mut err = String::new();
        let _ = stderr.read_to_string(&mut err).await;
        if let Ok(status) = child.wait().await
            && !status.success()
        {
            eprintln!(
                "git-cache: upload-pack {status}: {}",
                err.trim().lines().last().unwrap_or("")
            );
        }
    });
    state.stats.local_serves.fetch_add(1, Ordering::Relaxed);
    let stats = state.stats.clone();
    stats.local_bytes.fetch_add(n as u64, Ordering::Relaxed);
    let rest = tokio_util::io::ReaderStream::new(stdout).map(move |chunk| {
        if let Ok(bytes) = &chunk {
            stats.local_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        }
        chunk
    });
    let stream =
        futures_util::stream::once(async move { Ok::<_, std::io::Error>(Bytes::from(first)) })
            .chain(rest);
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/x-git-upload-pack-result")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from_stream(stream))
        .map_err(|e| e.to_string())
}
