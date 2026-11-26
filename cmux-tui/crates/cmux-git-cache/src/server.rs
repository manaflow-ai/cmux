//! The HTTP side: GitHub's smart-HTTP paths under `/github.com/`, answered from the mirror
//! when upstream confirmed the caller, else passed through.

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::Request;
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use cmux_process::Stdio;
use futures_util::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::auth::{AuthCache, caller_key, short};
use crate::mirror::{Mirrors, git};
use crate::pkt;
use crate::route::{self, Action, Route};
use crate::switch::Caller;

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
    /// Where the counters go as JSON after each serve, fallback and bypass (NOW reads it):
    /// `stats.json` beside the include by default.
    pub stats_file: Option<PathBuf>,
    /// crates.io's sparse index and download bases (`crates`).
    pub crates_index: String,
    pub crates_dl: String,
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
            stats_file: None,
            crates_index: crate::crates::INDEX_UPSTREAM.to_owned(),
            crates_dl: crate::crates::DL_UPSTREAM.to_owned(),
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
    /// Requests the cache meant to answer that github.com answered instead (an error, a mirror
    /// short of objects, an upstream it could not reach for the ref advertisement).
    pub fallbacks: AtomicU64,
    /// Ref advertisements sent to github.com because the caller has `CMUX_GIT_CACHE=0`.
    pub bypassed: AtomicU64,
    /// Fetches github.com answered because the mirror did not hold them yet.
    pub misses: AtomicU64,
    /// Upstream packs written into the mirror as they streamed to a clone (`Mirrors::keep`).
    pub kept_packs: AtomicU64,
    pub kept_bytes: AtomicU64,
}

impl Stats {
    pub fn json(&self) -> serde_json::Value {
        let n = |c: &AtomicU64| c.load(Ordering::Relaxed);
        serde_json::json!({
            "upstreamRequests": n(&self.upstream_requests),
            "upstreamBytes": n(&self.upstream_bytes),
            "localServes": n(&self.local_serves),
            "localBytes": n(&self.local_bytes),
            "refused": n(&self.refused),
            "fallbacks": n(&self.fallbacks),
            "bypassed": n(&self.bypassed),
            "misses": n(&self.misses),
            "keptPacks": n(&self.kept_packs),
            "keptBytes": n(&self.kept_bytes),
        })
    }
}

/// Writes the counters to its file (atomically: a temp file renamed over it), for NOW.
struct StatsWriter(Option<PathBuf>);

impl StatsWriter {
    fn write(&self, stats: &Stats) {
        let Some(path) = &self.0 else { return };
        let mut body = stats.json();
        body["at"] = serde_json::json!(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs())
        );
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, body.to_string())
            .and_then(|()| std::fs::rename(&tmp, path))
            .is_err()
        {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

/// The router as a service (what `axum::serve` takes).
pub fn app(state: Arc<State>) -> axum::routing::IntoMakeService<Router> {
    router(state).into_make_service()
}

pub struct State {
    pub cfg: Config,
    pub auth: AuthCache,
    pub mirrors: Mirrors,
    pub stats: Arc<Stats>,
    pub(crate) http: reqwest::Client,
    pub crate_stats: crate::crates::CrateStats,
    /// Repositories the edge answered for callers without credentials.
    via_edge: std::sync::Mutex<std::collections::HashSet<String>>,
    /// Owns each local upload-pack's stdin writer and reaper.
    scope: cmux_scope::Scope,
}

impl State {
    pub fn new(cfg: Config) -> Result<Arc<Self>, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        // Every upstream this server reaches is its operator's config (the --upstream, --edge, --peer,
        // --crates-index and --crates-dl flags, or the defaults the operator ran with), so each is a named host.
        for host in [&cfg.upstream, &cfg.crates_index, &cfg.crates_dl]
            .into_iter()
            .chain(cfg.edge.iter())
            .chain(&cfg.peers)
        {
            cmux_egress::allow_named(host);
        }
        let http = cmux_egress::client_builder("cmux_git_cache::server")
            .connect_timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::limited(5))
            .user_agent("git/cmux-git-cache")
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Arc::new(Self {
            auth: AuthCache::new(cfg.auth_ttl),
            mirrors: Mirrors::new(cfg.cache_root.clone()),
            stats: Arc::new(Stats::default()),
            crate_stats: crate::crates::CrateStats::default(),
            cfg,
            http,
            via_edge: std::sync::Mutex::new(std::collections::HashSet::new()),
            scope: cmux_scope::Scope::new("git-cache server"),
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

    fn write_stats(&self) {
        StatsWriter(self.cfg.stats_file.clone()).write(&self.stats);
    }

    /// github.com answers a request the cache meant to: counted, logged, recorded for NOW.
    fn fallback(&self, key: &str, reason: &str) {
        self.stats.fallbacks.fetch_add(1, Ordering::Relaxed);
        eprintln!("git-cache: {key} served by github.com (fallback: {reason})");
        self.write_stats();
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
        .merge(crate::crates::routes())
        .fallback(handle)
        .with_state(state)
}

async fn health(axum::extract::State(state): axum::extract::State<Arc<State>>) -> Response {
    let mut body = state.stats.json();
    if let (Some(m), serde_json::Value::Object(c)) =
        (body.as_object_mut(), state.crate_stats.json())
    {
        m.extend(c);
    }
    body["ok"] = true.into();
    body["upstream"] = state.cfg.upstream.clone().into();
    body["tenant"] = state.cfg.tenant.clone().into();
    body["peers"] = state.cfg.peers.clone().into();
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
    let mut headers = req.headers().clone();
    let caller = crate::switch::classify(authorization(&headers).as_deref());
    if caller == Caller::Off {
        // The person's own credential, carried inside the off marker, goes to github.com.
        let upstream = authorization(&headers).and_then(|a| crate::switch::off_upstream(&a));
        headers.remove(header::AUTHORIZATION);
        if let Some(value) = upstream.and_then(|v| HeaderValue::from_str(&v).ok()) {
            headers.insert(header::AUTHORIZATION, value);
        }
    } else if caller == Caller::Anon {
        headers.remove(header::AUTHORIZATION);
    }
    let off = caller == Caller::Off;
    match (&method, route.action) {
        (_, action) if off => {
            if action == Action::InfoRefs {
                state.stats.bypassed.fetch_add(1, Ordering::Relaxed);
                eprintln!(
                    "git-cache: {} served by github.com ({}=0 or {}=0 in the caller)",
                    route.key(),
                    crate::switch::ENV,
                    crate::switch::TRANSPORT_ENV
                );
                state.write_stats();
            }
            let tail = route_tail(action);
            let body = reqwest::Body::wrap_stream(req.into_body().into_data_stream());
            let base = state.cfg.upstream.clone();
            passthrough(&state, &base, &route, method, tail, query.as_deref(), &headers, body)
                .await
                .0
        }
        // Ask git's credential helper first: it carries the chat's switch (`switch`).
        (&Method::GET, Action::InfoRefs) if caller == Caller::Unasked => (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Basic realm=\"cmux git cache\"")],
            "",
        )
            .into_response(),
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

/// Sends git to `url` (github.com's own ref advertisement). git follows the first request's
/// redirect and fetches the rest of this clone from there.
fn redirect(url: &str, query: Option<&str>) -> Response {
    let location = match query {
        Some(q) => format!("{url}?{q}"),
        None => url.to_owned(),
    };
    Response::builder()
        .status(StatusCode::FOUND)
        .header(header::LOCATION, location)
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::empty())
        .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
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
    forward(state, base, route, method, tail, query, headers, body, None).await
}

/// `passthrough`, and with `tee` a copy of a 200 answer's bytes goes there as they stream by
/// (the caller's pace is the slower of the two; the copy ends when the answer does or the
/// caller hangs up).
#[allow(clippy::too_many_arguments)]
async fn forward(
    state: &State,
    base: &str,
    route: &Route,
    method: Method,
    tail: &str,
    query: Option<&str>,
    headers: &HeaderMap,
    body: reqwest::Body,
    tee: Option<tokio::sync::mpsc::Sender<Bytes>>,
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
    let tee = tee.filter(|_| status == StatusCode::OK);
    let stream = resp.bytes_stream().then(move |chunk| {
        let tee = tee.clone();
        let stats = stats.clone();
        async move {
            if let Ok(bytes) = &chunk {
                stats.upstream_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
                if let Some(tee) = tee {
                    let _ = tee.send(bytes.clone()).await;
                }
            }
            chunk.map_err(std::io::Error::other)
        }
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
    if status == StatusCode::BAD_GATEWAY {
        // Any error of ours (upstream unreachable from here, the edge down): git asks
        // github.com itself, which also carries the rest of this clone.
        state.fallback(&route.key(), "ref advertisement failed here");
        return redirect(&route.url(&state.cfg.upstream, "/info/refs"), query);
    }
    resp
}

/// Upstream's answer to this caller's ref advertisement, without its body.
async fn confirm(state: &State, route: &Route, headers: &HeaderMap, caller: &str) -> StatusCode {
    let tenant = &state.cfg.tenant;
    if state.auth.allowed(caller, tenant, &route.key()) {
        return StatusCode::OK;
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
    status
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

async fn upload_pack(
    state: &Arc<State>,
    route: &Route,
    headers: &HeaderMap,
    body: Body,
) -> Response {
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
    let started = std::time::Instant::now();
    // Tenant safety: nothing from the cache before upstream said yes to this caller.
    let confirmed = confirm(state, route, headers, &caller).await;
    if confirmed != StatusCode::OK {
        eprintln!("git-cache: {key} caller={} not confirmed: upstream answers", short(&caller));
        if !matches!(confirmed.as_u16(), 401 | 403 | 404) {
            state.fallback(&key, &format!("access check answered {confirmed}"));
        }
        return upstream(raw).await;
    }
    let dir = state.mirrors.dir(&state.cfg.tenant, &key);
    let upstream_url = route.url(state.base(route, &caller), "");
    let mut held = state
        .mirrors
        .ensure(&dir, &upstream_url, &state.peer_urls(route), auth.as_deref(), &wants)
        .await;
    let mut keeper = None;
    if !held {
        // One clone at a time writes upstream's pack into the mirror; the others wait for it
        // and are then served here instead of downloading the same pack again.
        keeper = pkt::whole_clone(&decoded, v2).then(|| state.mirrors.try_keep(&dir)).flatten();
        if keeper.is_none()
            && state.mirrors.wait_keep(&dir, crate::mirror::KEEP_WAIT).await
            && Mirrors::has_all(&dir, &wants).await
        {
            held = true;
        }
    }
    if !held {
        // Not an error of the cache's (that is a fallback): a mirror that does not hold this
        // yet. github.com answers, and the mirror keeps the answer or fills behind it.
        state.stats.misses.fetch_add(1, Ordering::Relaxed);
        state.write_stats();
        eprintln!(
            "git-cache: {key} served by github.com (mirror short of {} wants; {})",
            wants.len(),
            if keeper.is_some() { "keeping its pack" } else { "filling behind it" }
        );
        let Some(guard) = keeper else {
            state.mirrors.fill_later(dir, upstream_url, auth);
            return upstream(raw).await;
        };
        let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(64);
        let base = state.base(route, &caller).to_owned();
        let body = reqwest::Body::from(raw);
        let (resp, status) = forward(
            state,
            &base,
            route,
            Method::POST,
            "/git-upload-pack",
            None,
            headers,
            body,
            Some(tx),
        )
        .await;
        if status == StatusCode::OK {
            let st = state.clone();
            state.scope.spawn_until_cancelled("keep upstream pack", async move {
                let started = std::time::Instant::now();
                match Mirrors::keep(&dir, v2, &wants, rx).await {
                    Ok(bytes) => {
                        st.stats.kept_packs.fetch_add(1, Ordering::Relaxed);
                        st.stats.kept_bytes.fetch_add(bytes, Ordering::Relaxed);
                        st.write_stats();
                        eprintln!(
                            "git-cache: {key} kept github.com's pack ({} MiB, {:.1} s): the next clone here is local",
                            bytes >> 20,
                            started.elapsed().as_secs_f64()
                        );
                    }
                    Err(e) => eprintln!("git-cache: {key} pack not kept: {e}"),
                }
                drop(guard);
                st.mirrors.fill_later(dir, upstream_url, auth);
            });
        } else {
            drop(guard);
        }
        return resp;
    }
    let served = Served { key: key.clone(), caller: short(&caller).to_owned(), started };
    match serve_local(state, &dir, v2, decoded, served).await {
        Ok(resp) => resp,
        Err(e) => {
            state.fallback(&key, &format!("local upload-pack: {e}"));
            upstream(raw).await
        }
    }
}

/// Waits for `child` on a blocking thread (its stdout and stderr already read to their end).
async fn reap(mut child: cmux_process::Child) -> Result<std::process::ExitStatus, String> {
    tokio::task::spawn_blocking(move || child.wait().map_err(|e| e.to_string()))
        .await
        .map_err(|e| e.to_string())?
}

/// `git upload-pack --stateless-rpc` on the mirror. An upload-pack that ends before its first
/// byte is an error the caller turns into a pass-through, so a request the local git cannot
/// answer still succeeds.
/// Who a local serve is for, and when its request came in (for the "served by cache" line).
struct Served {
    key: String,
    caller: String,
    started: std::time::Instant,
}

/// `inner` with its last 4 bytes held back; at its end, `trailer` runs, and when those bytes
/// are the final flush (`0000`) its line goes in before them.
fn with_trailer<S, F>(
    inner: S,
    trailer: F,
) -> impl futures_util::Stream<Item = std::io::Result<Bytes>>
where
    S: futures_util::Stream<Item = std::io::Result<Bytes>> + Unpin,
    F: FnOnce() -> Option<Vec<u8>>,
{
    futures_util::stream::unfold(
        (inner, Vec::<u8>::new(), Some(trailer)),
        |(mut inner, mut held, mut trailer)| async move {
            loop {
                let t = trailer.take()?;
                match inner.next().await {
                    Some(Ok(chunk)) => {
                        held.extend_from_slice(&chunk);
                        trailer = Some(t);
                        let keep = held.len().saturating_sub(4);
                        if keep == 0 {
                            continue;
                        }
                        let tail = held.split_off(keep);
                        let out = std::mem::replace(&mut held, tail);
                        return Some((Ok(Bytes::from(out)), (inner, held, trailer)));
                    }
                    Some(Err(e)) => return Some((Err(e), (inner, held, None))),
                    None => {
                        let line = t();
                        let mut out = Vec::new();
                        if held == b"0000" {
                            out.extend(line.unwrap_or_default());
                        }
                        out.append(&mut held);
                        return Some((Ok(Bytes::from(out)), (inner, held, None)));
                    }
                }
            }
        },
    )
}

async fn serve_local(
    state: &State,
    dir: &std::path::Path,
    v2: bool,
    body: Vec<u8>,
    served: Served,
) -> Result<Response, String> {
    let sideband = pkt::sideband_pack(&body, v2);
    let mut cmd = git();
    cmd.args(["upload-pack", "--stateless-rpc", "--strict"]).arg(dir);
    if v2 {
        cmd.env("GIT_PROTOCOL", "version=2");
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let to_tokio = |e: std::io::Error| e.to_string();
    let mut stdin = tokio::process::ChildStdin::from_std(child.stdin.take().ok_or("no stdin")?)
        .map_err(to_tokio)?;
    let mut stdout = tokio::process::ChildStdout::from_std(child.stdout.take().ok_or("no stdout")?)
        .map_err(to_tokio)?;
    let mut stderr = tokio::process::ChildStderr::from_std(child.stderr.take().ok_or("no stderr")?)
        .map_err(to_tokio)?;
    state.scope.spawn_until_cancelled("upload-pack stdin", async move {
        let _ = stdin.write_all(&body).await;
    });
    let mut first = vec![0u8; 64 << 10];
    let n = stdout.read(&mut first).await.map_err(|e| e.to_string())?;
    if n == 0 {
        let mut err = String::new();
        let _ = stderr.read_to_string(&mut err).await;
        let status = reap(child).await?;
        return Err(format!("{status}: {}", err.trim().lines().last().unwrap_or("no output")));
    }
    first.truncate(n);
    // Cancelled (the server closing), the child is dropped: cmux_process ends its group.
    state.scope.spawn_until_cancelled("upload-pack reap", async move {
        let mut err = String::new();
        let _ = stderr.read_to_string(&mut err).await;
        if let Ok(status) = reap(child).await
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
    let (stats, stats_state) = (state.stats.clone(), StatsWriter(state.cfg.stats_file.clone()));
    let stream = with_trailer(Box::pin(stream), move || {
        let secs = served.started.elapsed().as_secs_f64();
        eprintln!(
            "git-cache: {} caller={} served by cache, {secs:.1} s ({} bytes local in total)",
            served.key,
            served.caller,
            stats.local_bytes.load(Ordering::Relaxed)
        );
        stats_state.write(&stats);
        sideband.then(|| {
            pkt::progress(&format!(
                "cmux git cache: served by cache, {secs:.1} s ({}=0 skips it)\n",
                crate::switch::ENV
            ))
        })
    });
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/x-git-upload-pack-result")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from_stream(stream))
        .map_err(|e| e.to_string())
}
