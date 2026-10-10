//! The local CodeRouter security boundary and phase-one listeners.
use axum::{
    Router,
    body::Body,
    extract::State,
    http::{HeaderMap, Method, Request, StatusCode},
    response::Response,
    routing::any,
};
use cmux_local_auth::{ListenerPolicy, tokens_match};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    net::SocketAddr,
    path::Path,
    sync::Arc,
};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
};
use tower_http::limit::RequestBodyLimitLayer;
use zeroize::Zeroize;

pub const BODY_LIMIT: usize = 64 * 1024 * 1024;
const HEADER_LIMIT: usize = 64 * 1024;
type HmacSha256 = Hmac<Sha256>;

/// Router policy switches shared by current and future account routing phases.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RouterConfig {
    /// Permit pooling more than one consumer Claude or ChatGPT OAuth login.
    /// This remains disabled until the legal review is complete.
    #[serde(default, rename = "allowOAuthPooling")]
    pub allow_oauth_pooling: bool,
}

/// A secret that is erased on drop and never appears in diagnostics.
pub struct Secret<T: Zeroize>(T);
impl<T: Zeroize> Secret<T> {
    /// Wrap a value that must not be retained after use.
    pub fn new(value: T) -> Self {
        Self(value)
    }
    /// Borrow the secret for the one operation that needs it.
    pub fn expose(&self) -> &T {
        &self.0
    }
}
impl<T: Zeroize> fmt::Debug for Secret<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}
impl<T: Zeroize> Drop for Secret<T> {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Loads the install identity and Keychain-held secret without exposing the
/// storage mechanism to the router.
pub trait InstallSecretStore: Send + Sync {
    /// Stable installation identifier used in scoped key strings.
    fn install_id(&self) -> &str;
    /// Read the install secret for one HMAC operation.
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>>;
}

/// A deterministic store for tests and local fixtures. Production composition
/// supplies a Keychain implementation through the same trait.
pub struct StaticInstallSecretStore {
    install_id: String,
    secret: Vec<u8>,
}

/// A per-install random store used by tests to model first-launch Keychain
/// creation. Each instance creates one OS-CSPRNG secret and reuses it.
pub struct RandomInstallSecretStore {
    install_id: String,
    secret: Vec<u8>,
}
impl RandomInstallSecretStore {
    /// Create one install identity with a fresh 32-byte secret.
    pub fn new(install_id: impl Into<String>) -> anyhow::Result<Self> {
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret)?;
        Ok(Self { install_id: install_id.into(), secret: secret.to_vec() })
    }
}
impl InstallSecretStore for RandomInstallSecretStore {
    fn install_id(&self) -> &str {
        &self.install_id
    }
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>> {
        Ok(Secret::new(self.secret.clone()))
    }
}
impl StaticInstallSecretStore {
    /// Construct a test store; callers should use a temporary fixture secret.
    pub fn new(install_id: impl Into<String>, secret: Vec<u8>) -> Self {
        Self { install_id: install_id.into(), secret }
    }
}
impl InstallSecretStore for StaticInstallSecretStore {
    fn install_id(&self) -> &str {
        &self.install_id
    }
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>> {
        if self.secret.is_empty() {
            anyhow::bail!("install secret is empty");
        }
        Ok(Secret::new(self.secret.clone()))
    }
}

/// Production Keychain store. The item is addressed by service and install id;
/// the router never persists the returned bytes.
pub struct KeychainInstallSecretStore {
    install_id: String,
}
impl KeychainInstallSecretStore {
    /// Use the per-install CodeRouter generic-password account.
    pub fn new(install_id: impl Into<String>) -> Self {
        Self { install_id: install_id.into() }
    }
}
impl InstallSecretStore for KeychainInstallSecretStore {
    fn install_id(&self) -> &str {
        &self.install_id
    }
    #[cfg(target_os = "macos")]
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>> {
        let keychain = security_framework::os::macos::keychain::SecKeychain::default()?;
        match keychain.find_generic_password("com.cmuxterm.coderouter", &self.install_id) {
            Ok((password, _item)) => Ok(Secret::new(password.to_owned())),
            Err(_) => {
                let mut secret = [0u8; 32];
                getrandom::fill(&mut secret)?;
                keychain.set_generic_password(
                    "com.cmuxterm.coderouter",
                    &self.install_id,
                    &secret,
                )?;
                Ok(Secret::new(secret.to_vec()))
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>> {
        anyhow::bail!("Keychain install secrets require macOS")
    }
}

/// A TCP address that is guaranteed to be loopback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoopbackAddr(SocketAddr);
impl TryFrom<SocketAddr> for LoopbackAddr {
    type Error = std::io::Error;
    fn try_from(value: SocketAddr) -> Result<Self, Self::Error> {
        if !value.ip().is_loopback() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "address is not loopback",
            ));
        }
        Ok(Self(value))
    }
}
impl LoopbackAddr {
    pub fn address(self) -> SocketAddr {
        self.0
    }
}

/// The scope attached to a client key.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct KeyScope {
    pub harness: String,
    pub session: String,
    pub surfaces: Vec<String>,
    pub families: BTreeSet<ApiFamily>,
    pub expires_at: u64,
}
/// API family authorized by a scoped key.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum ApiFamily {
    AnthropicMessages,
    OpenAiResponses,
    /// OpenAI chat/completions (the hosted cmux model router's OpenAI shape).
    OpenAiChat,
}
impl ApiFamily {
    /// The families that may call `path`. Chat completions also takes an
    /// OpenAI Responses key: both are the OpenAI side of one harness.
    fn for_path(path: &str) -> &'static [Self] {
        match path {
            "/v1/messages" | "/v1/messages/count_tokens" => &[Self::AnthropicMessages],
            "/v1/responses" => &[Self::OpenAiResponses],
            "/v1/chat/completions" => &[Self::OpenAiChat, Self::OpenAiResponses],
            _ => &[],
        }
    }
}
#[derive(Clone)]
struct KeyRecord {
    digest: [u8; 32],
    scope: KeyScope,
}

/// In-memory key store. Only HMAC digests are retained.
pub struct KeyRing {
    store: Arc<dyn InstallSecretStore>,
    keys: BTreeMap<String, KeyRecord>,
}
impl KeyRing {
    /// Create a key store backed by the injected Keychain seam.
    pub fn new(store: Arc<dyn InstallSecretStore>) -> anyhow::Result<Self> {
        if store.install_id().is_empty() {
            anyhow::bail!("install id is empty");
        }
        Ok(Self { store, keys: BTreeMap::new() })
    }
    /// Mint one scoped key. The clear secret is returned once; only its HMAC is stored.
    pub fn mint(
        &mut self,
        key_id: impl Into<String>,
        scope: KeyScope,
    ) -> anyhow::Result<Secret<String>> {
        let key_id = key_id.into();
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret)?;
        // No install secret, no key: a digest is never computed without one.
        let digest =
            self.digest(&secret).ok_or_else(|| anyhow::anyhow!("install secret unavailable"))?;
        self.keys.insert(key_id.clone(), KeyRecord { digest, scope });
        let encoded = hex::encode(secret);
        Ok(Secret::new(format!("crl_{}_{}_{}", self.store.install_id(), key_id, encoded)))
    }
    /// Revoke a key by id.
    pub fn revoke(&mut self, key_id: &str) -> bool {
        self.keys.remove(key_id).is_some()
    }
    /// Return public key metadata without secrets.
    pub fn list(&self) -> Vec<(String, KeyScope)> {
        self.keys.iter().map(|(id, record)| (id.clone(), record.scope.clone())).collect()
    }
    /// HMAC of `secret` under the install secret; None (fail closed) when the
    /// install secret cannot be read, so no key ever matches a fixed digest.
    fn digest(&self, secret: &[u8]) -> Option<[u8; 32]> {
        let install_secret = self.store.load().ok()?;
        let mut mac = HmacSha256::new_from_slice(install_secret.expose()).ok()?;
        mac.update(secret);
        Some(mac.finalize().into_bytes().into())
    }
    fn validate(&self, value: &str) -> Option<&KeyScope> {
        let mut parts = value.split('_');
        if parts.next() != Some("crl") || parts.next() != Some(self.store.install_id()) {
            return None;
        }
        let key_id = parts.next()?;
        let secret = parts.next()?;
        if parts.next().is_some() {
            return None;
        }
        let record = self.keys.get(key_id)?;
        // expires_at: unix seconds; 0 = until revoked or the router stops.
        if record.scope.expires_at != 0 && record.scope.expires_at <= unix_now() {
            return None;
        }
        let Ok(bytes) = hex::decode(secret) else { return None };
        if bytes.len() != 32 {
            return None;
        }
        let digest = self.digest(&bytes)?;
        tokens_match(&hex::encode(digest), &hex::encode(record.digest)).then_some(&record.scope)
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The hosted cmux model router the relay forwards to, with the bearer the app
/// pushes (`set_upstream`). The bearer never leaves this process except toward
/// `origin`; harnesses hold only their crl_ key.
pub struct Upstream {
    origin: String,
    bearer: Secret<String>,
    /// Unix seconds; the relay refuses to forward after it (the app renews before).
    expires_at: u64,
}
impl Upstream {
    /// `origin` must be an https origin: the bearer is sent there.
    pub fn new(origin: &str, bearer: String, expires_at: u64) -> anyhow::Result<Self> {
        let url = url::Url::parse(origin)?;
        // https only: any local user can listen on a loopback port, so plain
        // http would hand the bearer to whoever holds that port.
        if url.scheme() != "https"
            || url.path() != "/"
            || url.query().is_some()
            || !url.username().is_empty()
        {
            anyhow::bail!("upstream origin must be an https origin");
        }
        if bearer.is_empty() || bearer.len() > 8192 || bearer.contains(['\r', '\n']) {
            anyhow::bail!("upstream bearer is invalid");
        }
        Ok(Self {
            origin: origin.trim_end_matches('/').to_owned(),
            bearer: Secret::new(bearer),
            expires_at,
        })
    }
    fn live(&self) -> bool {
        self.expires_at == 0 || self.expires_at > unix_now()
    }
    fn view(&self) -> serde_json::Value {
        serde_json::json!({"origin": self.origin, "expires_at": self.expires_at, "live": self.live()})
    }
}

pub type SharedUpstream = Arc<tokio::sync::RwLock<Option<Upstream>>>;

#[derive(Clone)]
struct AppState {
    port: u16,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    http: reqwest::Client,
}

/// Install a panic hook that reports only source location, never a payload.
pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        if let Some(location) = info.location() {
            eprintln!("panic at {}:{}", location.file(), location.line());
        } else {
            eprintln!("panic at <unknown>");
        }
    }));
}
fn disable_core_dumps() {
    #[cfg(unix)]
    unsafe {
        let _ = libc::setrlimit(libc::RLIMIT_CORE, &libc::rlimit { rlim_cur: 0, rlim_max: 0 });
    }
}

/// Start the admin UDS and loopback data-plane listener.
#[cfg(unix)]
pub async fn serve(home: impl AsRef<Path>) -> anyhow::Result<()> {
    install_panic_hook();
    disable_core_dumps();
    // reqwest is built without a default TLS provider; the relay's upstream calls need one.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let router_dir = home.as_ref().join("router");
    tokio::fs::create_dir_all(&router_dir).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&router_dir, std::fs::Permissions::from_mode(0o700)).await?;
    }
    // One router per home: a second one waits here until the first exits
    // (`shutdown`, from a daemon of a newer build), so it never takes the
    // socket from a router that still holds a bearer.
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(router_dir.join("router.lock"))?;
    // Bounded: a router that never lets go (hung) must not collect waiters.
    let lock = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        tokio::task::spawn_blocking(move || fs4::FileExt::lock(&lock).map(|()| lock)),
    )
    .await
    .map_err(|_| anyhow::anyhow!("another local router holds router.lock"))???;
    let socket_path = router_dir.join("router.sock");
    let _ = tokio::fs::remove_file(&socket_path).await;
    let admin = UnixListener::bind(&socket_path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600)).await?;
    }
    let bind_address: SocketAddr = "127.0.0.1:0".parse()?;
    let listener = TcpListener::bind(LoopbackAddr::try_from(bind_address)?.address()).await?;
    // Keys live in memory for one router run. macOS keeps the install secret in
    // the Keychain; elsewhere a fresh random secret per run is equivalent.
    #[cfg(target_os = "macos")]
    let store: Arc<dyn InstallSecretStore> = Arc::new(KeychainInstallSecretStore::new("default"));
    #[cfg(not(target_os = "macos"))]
    let store: Arc<dyn InstallSecretStore> = Arc::new(RandomInstallSecretStore::new("default")?);
    let keys = Arc::new(tokio::sync::RwLock::new(KeyRing::new(store)?));
    let port = listener.local_addr()?.port();
    let upstream: SharedUpstream = Arc::new(tokio::sync::RwLock::new(None));
    let data = data_server(listener, keys.clone(), upstream.clone());
    let stop = Arc::new(tokio::sync::Notify::new());
    tokio::select! {
        _ = data => (),
        result = admin_loop(admin, keys, upstream, port, stop.clone()) => result?,
        _ = stop.notified() => (),
    }
    drop(lock);
    Ok(())
}

/// Start the real loopback data plane for integration tests and composition.
pub async fn spawn_data_plane(
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
) -> anyhow::Result<(SocketAddr, tokio::task::JoinHandle<()>)> {
    let listener =
        TcpListener::bind(LoopbackAddr::try_from("127.0.0.1:0".parse::<SocketAddr>()?)?.address())
            .await?;
    let address = listener.local_addr()?;
    let task = tokio::spawn(data_server(listener, keys, upstream));
    Ok((address, task))
}

async fn data_server(
    listener: TcpListener,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
) {
    let http = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        // Per read, not per request: a long stream keeps going while bytes
        // arrive; an upstream that stops sending ends the request.
        .read_timeout(std::time::Duration::from_secs(300))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default();
    let state = AppState {
        port: listener.local_addr().map(|address| address.port()).unwrap_or(0),
        keys,
        upstream,
        http,
    };
    let app = Router::new()
        .fallback(any(data_request))
        .layer(RequestBodyLimitLayer::new(BODY_LIMIT))
        .with_state(state);
    let _ = axum::serve(listener, app.into_make_service()).await;
}
#[cfg(not(unix))]
pub async fn serve(_home: impl AsRef<Path>) -> anyhow::Result<()> {
    anyhow::bail!("the local router admin socket requires Unix")
}
#[cfg(unix)]
async fn admin_loop(
    listener: UnixListener,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    port: u16,
    stop: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let keys = keys.clone();
        let upstream = upstream.clone();
        let stop = stop.clone();
        tokio::spawn(async move {
            let _ = admin_connection(stream, keys, upstream, port, stop).await;
        });
    }
}

/// The build of the acpmux that started this router (`CMUX_ROUTER_BUILD`):
/// a daemon of another build replaces it (`shutdown`, then a new router).
fn router_build() -> String {
    std::env::var("CMUX_ROUTER_BUILD").unwrap_or_default()
}
#[cfg(unix)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum AdminRequest {
    Mint {
        key_id: String,
        scope: KeyScope,
    },
    List,
    Revoke {
        key_id: String,
    },
    /// The loopback data-plane port (acpmux `local-coderouter` routes read it),
    /// plus the upstream state (never the bearer).
    Status,
    /// A per-session key with a router-chosen id: `{id, key}` (the route store
    /// mints one at spawn and revokes it at session end).
    MintKey {
        scope: KeyScope,
    },
    RevokeKey {
        id: String,
    },
    /// The hosted model router and the bearer the app renews before `expires_at`.
    SetUpstream {
        origin: String,
        bearer: String,
        expires_at: u64,
    },
    ClearUpstream,
    /// Exit after the reply (a daemon of a newer build starts its own router).
    Shutdown,
}
#[cfg(unix)]
async fn admin_connection(
    stream: UnixStream,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    port: u16,
    stop: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        let request: AdminRequest = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                // A fixed message: a parse error can quote the request's values.
                let reply = serde_json::json!({"error": "bad request"});
                write.write_all(format!("{reply}\n").as_bytes()).await?;
                continue;
            }
        };
        let response = match request {
            AdminRequest::Mint { key_id, scope } => {
                let mut guard = keys.write().await;
                let key = guard.mint(key_id, scope)?;
                serde_json::json!({"key": key.expose()})
            }
            AdminRequest::List => serde_json::json!({"keys": keys.read().await.list()}),
            AdminRequest::Revoke { key_id } => {
                serde_json::json!({"revoked": keys.write().await.revoke(&key_id)})
            }
            AdminRequest::Status => {
                let up = upstream.read().await;
                serde_json::json!({"port": port, "build": router_build(), "pid": std::process::id(), "upstream": up.as_ref().map(Upstream::view)})
            }
            AdminRequest::MintKey { scope } => {
                let id = format!("s{}", uuid::Uuid::new_v4().simple());
                let key = keys.write().await.mint(id.clone(), scope)?;
                serde_json::json!({"id": id, "key": key.expose()})
            }
            AdminRequest::RevokeKey { id } => {
                serde_json::json!({"revoked": keys.write().await.revoke(&id)})
            }
            AdminRequest::SetUpstream { origin, bearer, expires_at } => {
                match Upstream::new(&origin, bearer, expires_at) {
                    Ok(next) => {
                        let view = next.view();
                        *upstream.write().await = Some(next);
                        serde_json::json!({"upstream": view})
                    }
                    Err(error) => serde_json::json!({"error": error.to_string()}),
                }
            }
            AdminRequest::ClearUpstream => {
                *upstream.write().await = None;
                serde_json::json!({"upstream": null})
            }
            AdminRequest::Shutdown => {
                *upstream.write().await = None;
                write.write_all(b"{\"stopping\":true}\n").await?;
                stop.notify_one();
                return Ok(());
            }
        };
        write.write_all(serde_json::to_string(&response)?.as_bytes()).await?;
        write.write_all(b"\n").await?;
    }
    Ok(())
}

/// Local paths the relay forwards, and their hosted router paths.
fn upstream_path(method: &Method, path: &str) -> Option<&'static str> {
    match (method, path) {
        (&Method::GET, "/v1/models") => Some("/v1/inference/models"),
        (&Method::POST, "/v1/chat/completions") => Some("/v1/inference/chat/completions"),
        (&Method::POST, "/v1/messages") => Some("/v1/inference/v1/messages"),
        (&Method::POST, "/v1/messages/count_tokens") => {
            Some("/v1/inference/v1/messages/count_tokens")
        }
        _ => None,
    }
}

fn json_error(status: StatusCode, code: &str, message: &str) -> Response<Body> {
    let body = serde_json::json!({"error": {"code": code, "message": message}}).to_string();
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

/// Request headers passed upstream; everything else (the client's auth, cookies,
/// host) stays here.
const FORWARD_REQUEST_HEADERS: &[&str] = &["content-type", "accept", "anthropic-version"];
const FORWARD_RESPONSE_HEADERS: &[&str] =
    &["content-type", "cache-control", "retry-after", "x-cmux-request-id"];

#[axum::debug_handler]
async fn data_request(State(state): State<AppState>, request: Request<Body>) -> Response<Body> {
    let method = request.method().clone();
    let uri = request.uri().path().to_owned();
    let headers = request.headers().clone();
    let status =
        authorize(method.clone(), uri.as_str(), headers.clone(), state.port, &state.keys).await;
    if let Err(status) = status {
        return Response::builder()
            .status(status)
            .body(Body::empty())
            .unwrap_or_else(|_| Response::new(Body::empty()));
    }
    let Some(path) = upstream_path(&method, uri.as_str()) else {
        let status = match (&method, uri.as_str()) {
            (&Method::POST, "/v1/responses") => StatusCode::NOT_IMPLEMENTED,
            _ => StatusCode::NOT_FOUND,
        };
        return Response::builder()
            .status(status)
            .body(Body::empty())
            .unwrap_or_else(|_| Response::new(Body::empty()));
    };
    let (url, bearer) = {
        let up = state.upstream.read().await;
        match up.as_ref() {
            Some(up) if up.live() => (format!("{}{path}", up.origin), up.bearer.expose().clone()),
            Some(_) => {
                return json_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "router.upstream_expired",
                    "the cmux model router sign-in expired; open cmux to renew it",
                );
            }
            None => {
                return json_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "router.no_upstream",
                    "the cmux model router is not connected; open cmux",
                );
            }
        }
    };
    let mut forward = state.http.request(method, &url).bearer_auth(bearer);
    for name in FORWARD_REQUEST_HEADERS {
        if let Some(value) = headers.get(*name) {
            forward = forward.header(*name, value);
        }
    }
    let body = reqwest::Body::wrap_stream(request.into_body().into_data_stream());
    let answer = match forward.body(body).send().await {
        Ok(answer) => answer,
        Err(_) => {
            return json_error(
                StatusCode::BAD_GATEWAY,
                "router.unreachable",
                "the cmux model router did not answer",
            );
        }
    };
    let mut out = Response::builder().status(answer.status().as_u16());
    for name in FORWARD_RESPONSE_HEADERS {
        if let Some(value) = answer.headers().get(*name) {
            out = out.header(*name, value.as_bytes());
        }
    }
    out.body(Body::from_stream(answer.bytes_stream()))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}
async fn authorize(
    method: Method,
    path: &str,
    headers: HeaderMap,
    port: u16,
    keys: &Arc<tokio::sync::RwLock<KeyRing>>,
) -> Result<(), StatusCode> {
    let header_bytes: usize =
        headers.iter().map(|(name, value)| name.as_str().len() + value.as_bytes().len()).sum();
    if header_bytes > HEADER_LIMIT {
        return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
    }
    if method == Method::OPTIONS || headers.contains_key("origin") {
        return Err(StatusCode::FORBIDDEN);
    }
    if headers.keys().any(|name| name.as_str().starts_with("sec-fetch-")) {
        return Err(StatusCode::FORBIDDEN);
    }
    let hosts =
        headers.get_all("host").iter().filter_map(|value| value.to_str().ok()).collect::<Vec<_>>();
    let policy = ListenerPolicy::loopback(port);
    if policy.check(&hosts, &[]).is_err()
        || !hosts.iter().any(|host| {
            *host == format!("127.0.0.1:{port}") || *host == format!("localhost:{port}")
        })
    {
        return Err(StatusCode::MISDIRECTED_REQUEST);
    }
    // Bearer, or x-api-key (Messages API clients send the key there).
    let bearer = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|auth| auth.strip_prefix("Bearer ").or_else(|| auth.strip_prefix("bearer ")));
    let api_key = headers.get("x-api-key").and_then(|value| value.to_str().ok());
    let Some(token) = bearer.or(api_key) else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let scope = {
        let guard = keys.read().await;
        guard.validate(token.trim()).cloned()
    };
    let Some(scope) = scope else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let allowed = ApiFamily::for_path(path);
    if !allowed.is_empty() && !allowed.iter().any(|family| scope.families.contains(family)) {
        return Err(StatusCode::FORBIDDEN);
    }
    Ok(())
}
