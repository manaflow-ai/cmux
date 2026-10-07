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
use std::{collections::BTreeMap, fmt, net::SocketAddr, path::Path, sync::Arc};
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
        let (password, _item) = security_framework::passwords::find_generic_password(
            None,
            "com.cmuxterm.coderouter",
            &self.install_id,
        )?;
        Ok(Secret::new(password.to_owned()))
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
    pub expires_at: u64,
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
        let digest = self.digest(&secret);
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
    fn digest(&self, secret: &[u8]) -> [u8; 32] {
        let Ok(install_secret) = self.store.load() else {
            return [0; 32];
        };
        let Ok(mut mac) = HmacSha256::new_from_slice(install_secret.expose()) else {
            return [0; 32];
        };
        mac.update(secret);
        mac.finalize().into_bytes().into()
    }
    fn validate(&self, value: &str) -> bool {
        let mut parts = value.split('_');
        if parts.next() != Some("crl") || parts.next() != Some(self.store.install_id()) {
            return false;
        }
        let Some(key_id) = parts.next() else { return false };
        let Some(secret) = parts.next() else { return false };
        if parts.next().is_some() {
            return false;
        }
        let Some(record) = self.keys.get(key_id) else { return false };
        let Ok(bytes) = hex::decode(secret) else { return false };
        if bytes.len() != 32 {
            return false;
        }
        tokens_match(&hex::encode(self.digest(&bytes)), &hex::encode(record.digest))
    }
}

#[derive(Clone)]
struct AppState {
    port: u16,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
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
    let router_dir = home.as_ref().join("router");
    tokio::fs::create_dir_all(&router_dir).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&router_dir, std::fs::Permissions::from_mode(0o700)).await?;
    }
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
    let port = listener.local_addr()?.port();
    let store = Arc::new(KeychainInstallSecretStore::new("default"));
    let keys = Arc::new(tokio::sync::RwLock::new(KeyRing::new(store)?));
    let state = AppState { port, keys: keys.clone() };
    let app = Router::new()
        .fallback(any(data_request))
        .layer(RequestBodyLimitLayer::new(BODY_LIMIT))
        .with_state(state);
    let data = axum::serve(listener, app.into_make_service());
    tokio::select! { result = data => result?, result = admin_loop(admin, keys) => result? }
    Ok(())
}
#[cfg(not(unix))]
pub async fn serve(_home: impl AsRef<Path>) -> anyhow::Result<()> {
    anyhow::bail!("the local router admin socket requires Unix")
}
#[cfg(unix)]
async fn admin_loop(
    listener: UnixListener,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
) -> anyhow::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let keys = keys.clone();
        tokio::spawn(async move {
            let _ = admin_connection(stream, keys).await;
        });
    }
}
#[cfg(unix)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum AdminRequest {
    Mint { key_id: String, scope: KeyScope },
    List,
    Revoke { key_id: String },
}
#[cfg(unix)]
async fn admin_connection(
    stream: UnixStream,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
) -> anyhow::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        let request: AdminRequest = serde_json::from_str(&line)?;
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
        };
        write.write_all(serde_json::to_string(&response)?.as_bytes()).await?;
        write.write_all(b"\n").await?;
    }
    Ok(())
}

/// Apply the data-plane gate to an in-memory request. This is also the stable
/// test seam for callers that embed the router instead of opening a socket.
pub async fn handle_request(
    request: Request<http_body_util::Full<bytes::Bytes>>,
    port: u16,
    keys: &KeyRing,
) -> StatusCode {
    let header_bytes: usize = request
        .headers()
        .iter()
        .map(|(name, value)| name.as_str().len() + value.as_bytes().len())
        .sum();
    if header_bytes > HEADER_LIMIT {
        return StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE;
    }
    if request.method() == Method::OPTIONS || request.headers().contains_key("origin") {
        return StatusCode::FORBIDDEN;
    }
    let hosts = request
        .headers()
        .get_all("host")
        .iter()
        .filter_map(|value| value.to_str().ok())
        .collect::<Vec<_>>();
    if hosts.len() != 1
        || !hosts.iter().any(|host| {
            *host == format!("127.0.0.1:{port}") || *host == format!("localhost:{port}")
        })
    {
        return StatusCode::MISDIRECTED_REQUEST;
    }
    let Some(auth) = request.headers().get("authorization").and_then(|value| value.to_str().ok())
    else {
        return StatusCode::UNAUTHORIZED;
    };
    let Some(token) = auth.strip_prefix("Bearer ").or_else(|| auth.strip_prefix("bearer ")) else {
        return StatusCode::UNAUTHORIZED;
    };
    if !keys.validate(token.trim()) {
        return StatusCode::UNAUTHORIZED;
    }
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let body = request.into_body().into_inner();
    if body.map_or(0, |bytes| bytes.len()) > BODY_LIMIT {
        return StatusCode::PAYLOAD_TOO_LARGE;
    }
    match (method, path.as_str()) {
        (Method::GET, "/v1/models") => StatusCode::OK,
        (Method::POST, "/v1/messages" | "/v1/responses") => StatusCode::NOT_IMPLEMENTED,
        _ => StatusCode::NOT_FOUND,
    }
}
#[axum::debug_handler]
async fn data_request(State(state): State<AppState>, request: Request<Body>) -> Response<Body> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let _ = request_id;
    let method = request.method().clone();
    let uri = request.uri().path().to_owned();
    let headers = request.headers().clone();
    let status = authorize(method.clone(), headers, state.port, &state.keys).await;
    if let Err(status) = status {
        return Response::builder()
            .status(status)
            .body(Body::empty())
            .unwrap_or_else(|_| Response::new(Body::empty()));
    }
    let status = match (method, uri.as_str()) {
        (Method::GET, "/v1/models") => StatusCode::OK,
        (Method::POST, "/v1/messages" | "/v1/responses") => StatusCode::NOT_IMPLEMENTED,
        _ => StatusCode::NOT_FOUND,
    };
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap_or_else(|_| Response::new(Body::empty()))
}
async fn authorize(
    method: Method,
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
    let Some(auth) = headers.get("authorization").and_then(|value| value.to_str().ok()) else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let Some(token) = auth.strip_prefix("Bearer ").or_else(|| auth.strip_prefix("bearer ")) else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    if !keys.read().await.validate(token.trim()) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn loopback_rejects_unspecified() {
        for value in ["0.0.0.0:0", "[::]:0", "192.168.1.1:1"] {
            assert!(LoopbackAddr::try_from(value.parse::<SocketAddr>().unwrap()).is_err());
        }
    }
}
