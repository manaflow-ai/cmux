//! The local CodeRouter security boundary and phase-one listeners.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use axum::{
    Router,
    body::Body,
    extract::State,
    http::{HeaderMap, HeaderValue, Method, Request, StatusCode},
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
use tokio::net::UnixListener;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    net::TcpListener,
};
use tower_http::limit::RequestBodyLimitLayer;

mod admin_socket;
pub use admin_socket::{MAX_SOCKET_PATH_BYTES, admin_socket_path};
pub mod free_tier;
use free_tier::FreeTier;
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

/// Loads the install identity and its secret without exposing the storage
/// mechanism to the router.
pub trait InstallSecretStore: Send + Sync {
    /// Stable installation identifier used in scoped key strings.
    fn install_id(&self) -> &str;
    /// Read the install secret for one HMAC operation.
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>>;
}

/// A deterministic store for tests and local fixtures.
pub struct StaticInstallSecretStore {
    install_id: String,
    secret: Vec<u8>,
}

/// The router's store: one OS-CSPRNG secret per router run, in memory only
/// (keys never outlive the run). Each instance creates one secret and reuses it.
pub struct RandomInstallSecretStore {
    install_id: String,
    secret: Secret<Vec<u8>>,
}
impl RandomInstallSecretStore {
    /// Create one install identity with a fresh 32-byte secret.
    pub fn new(install_id: impl Into<String>) -> anyhow::Result<Self> {
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret)?;
        let kept = Secret::new(secret.to_vec());
        secret.zeroize();
        Ok(Self { install_id: install_id.into(), secret: kept })
    }
}
impl InstallSecretStore for RandomInstallSecretStore {
    fn install_id(&self) -> &str {
        &self.install_id
    }
    fn load(&self) -> anyhow::Result<Secret<Vec<u8>>> {
        Ok(Secret::new(self.secret.expose().clone()))
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
    free: Arc<FreeTier>,
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
    // SAFETY: setrlimit only reads the rlimit, a temporary that lives across the call.
    #[cfg(unix)]
    unsafe {
        let _ = libc::setrlimit(libc::RLIMIT_CORE, &libc::rlimit { rlim_cur: 0, rlim_max: 0 });
    }
}

/// One admin connection: its read and write halves, and its peer as read
/// from the whole socket at accept, before the split
/// ([`free_tier::ProviderPeer`]: the attestation provider check needs it).
pub type AdminConnection = (
    Box<dyn AsyncRead + Send + Unpin>,
    Box<dyn AsyncWrite + Send + Unpin>,
    free_tier::ProviderPeer,
);
/// Accepted admin connections; an error ends the router as a failed accept
/// does.
pub type AdminConnections = tokio::sync::mpsc::Receiver<std::io::Result<AdminConnection>>;

/// Start the admin UDS and loopback data-plane listener. Returns when the
/// router is told to stop (`shutdown`) or when its last owner is gone: with
/// `CMUX_ROUTER_OWNER_FIFO` set, the router reads that FIFO and stops once
/// no process holds its write end (the acpmux daemon and every agent host
/// do), also while it still waits on router.lock.
#[cfg(unix)]
pub async fn serve(home: impl AsRef<Path>) -> anyhow::Result<()> {
    serve_with_admin(home, bind_unix_admin).await
}

/// [`serve`]'s admin socket: a unix socket only this user may connect to,
/// each accepted connection handed to the router with its peer.
#[cfg(unix)]
fn bind_unix_admin(socket_path: &Path) -> anyhow::Result<AdminConnections> {
    let admin = UnixListener::bind(socket_path)?;
    {
        use std::os::unix::fs::PermissionsExt;
        // `bind_admin` is sync: the chmod is a counted ScopedBlockingCall.
        cmux_blocking::scoped_blocking_call(
            "fs::set_permissions",
            cmux_blocking::BlockingKind::Fs,
            || {
                cmux_threads::checked::fs::set_permissions(
                    socket_path,
                    std::fs::Permissions::from_mode(0o600),
                )
            },
        )?;
    }
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    // supervise-allow: its end, a panic included, drops `tx`; admin_loop then sees the channel close and stops the router with an error (fatal by construction).
    tokio::spawn(async move {
        loop {
            let accepted = admin.accept().await.map(|(stream, _)| {
                let peer = free_tier::ProviderPeer::of_unix(&stream);
                let (read, write) = stream.into_split();
                (Box::new(read) as _, Box::new(write) as _, peer)
            });
            let failed = accepted.is_err();
            if tx.send(accepted).await.is_err() || failed {
                break;
            }
        }
    });
    Ok(rx)
}

/// The router with its admin socket bound by `bind_admin` (given the socket
/// path, after the router lock is held and a stale socket file removed):
/// Unix binds a unix socket ([`serve`]); the Windows host binds its local
/// socket (AF_UNIX with same-user checks) and hands each connection over.
pub async fn serve_with_admin(
    home: impl AsRef<Path>,
    bind_admin: impl FnOnce(&Path) -> anyhow::Result<AdminConnections>,
) -> anyhow::Result<()> {
    install_panic_hook();
    disable_core_dumps();
    // Windows has no owner FIFO: the daemon's kill-on-close job object ends
    // the router with the daemon (acpmux daemon/router_owner.rs).
    #[cfg(unix)]
    let owners =
        std::env::var_os("CMUX_ROUTER_OWNER_FIFO").map(std::path::PathBuf::from).map(watch_owners);
    #[cfg(not(unix))]
    let owners = None;
    tokio::select! {
        result = serve_owned(home.as_ref(), bind_admin) => result,
        () = owners_gone(owners) => {
            tracing::info!("the local router has no owner left; it stops");
            Ok(())
        }
    }
}

/// True once the owner watch saw no writer left: `adopt` is refused from
/// then on, so a daemon never adopts a router that is stopping.
static OWNERS_GONE: std::sync::Mutex<bool> = std::sync::Mutex::new(false);

/// Where this run's install secret lives, for `status` (`install_secret`):
/// always `ephemeral` (random, in memory, this run only). The router never
/// uses the Keychain: a macOS access prompt appeared for every differently
/// signed build ("acpmux wants to use ... com.cmuxterm.coderouter").
static INSTALL_SECRET_KIND: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();
const INSTALL_SECRET_EPHEMERAL: &str = "ephemeral";

/// Reads the owner FIFO on its own thread (a blocking read: no polling, no
/// timer). A read returns 0 when no process holds a write end. Under
/// `OWNERS_GONE`'s lock the watch then checks again with a non-blocking read:
/// a daemon that opened the FIFO to adopt this router makes it `EAGAIN`
/// (a writer, no data), and the watch goes on.
#[cfg(unix)]
fn watch_owners(fifo: std::path::PathBuf) -> tokio::sync::oneshot::Receiver<()> {
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let (gone, receiver) = tokio::sync::oneshot::channel();
    let watch = move || {
        // Opened non-blocking, so a daemon that died before this open makes
        // the first check below find no writer (a blocking open would wait
        // for one forever). Any failure: no owner can be watched, so the
        // router stops as it would without one.
        let Ok(mut owners) = cmux_threads::checked::fs::open_with(
            std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK),
            &fifo,
        ) else {
            return;
        };
        let fd = owners.as_raw_fd();
        let set_nonblocking = |on: bool| {
            // SAFETY: fcntl on a descriptor this thread owns.
            unsafe {
                let flags = libc::fcntl(fd, libc::F_GETFL);
                let flags = if on { flags | libc::O_NONBLOCK } else { flags & !libc::O_NONBLOCK };
                libc::fcntl(fd, libc::F_SETFL, flags);
            }
        };
        // Blocking from here: a read waits for data or for the last writer.
        set_nonblocking(false);
        let mut byte = [0u8; 64];
        loop {
            match owners.read(&mut byte) {
                Ok(0) => {}
                Ok(_) => continue,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return,
            }
            let mut stopped = OWNERS_GONE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            set_nonblocking(true);
            let again = owners.read(&mut byte);
            set_nonblocking(false);
            match again {
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Ok(n) if n > 0 => continue,
                _ => {
                    *stopped = true;
                    return;
                }
            }
        }
    };
    // supervise-allow: its end, a panic included, drops `gone`; owners_gone then resolves and the router stops (fatal by construction).
    let spawned =
        cmux_threads::spawn("router-owners", cmux_threads::ThreadQos::Utility, move || {
            watch();
            let _ = gone.send(());
        });
    if let Err(e) = spawned {
        tracing::warn!("the router cannot watch its owners: {e}");
    }
    receiver
}

/// Resolves when the owners are gone; never without an owner FIFO.
async fn owners_gone(owners: Option<tokio::sync::oneshot::Receiver<()>>) {
    match owners {
        Some(receiver) => {
            let _ = receiver.await;
        }
        None => std::future::pending().await,
    }
}

async fn serve_owned(
    home: &Path,
    bind_admin: impl FnOnce(&Path) -> anyhow::Result<AdminConnections>,
) -> anyhow::Result<()> {
    // reqwest is built without a default TLS provider; the relay's upstream calls need one.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let router_dir = home.join("router");
    tokio::fs::create_dir_all(&router_dir).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&router_dir, std::fs::Permissions::from_mode(0o700)).await?;
    }
    // One router per home: a second one waits here until the first exits
    // (`shutdown`, or its last owner gone), so it never takes the
    // socket from a router that still holds a bearer.
    let lock = tokio::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(router_dir.join("router.lock"))
        .await?
        .into_std()
        .await;
    // Bounded: a router that never lets go (hung) must not collect waiters.
    // The wait runs on a plain thread, not the blocking pool: a router that
    // stops during it (no owner left) returns from main without waiting
    // for that thread.
    let (locked, lock_rx) = tokio::sync::oneshot::channel();
    // supervise-allow: one flock; a panic drops `locked`, so the await below fails and the router does not start.
    cmux_threads::spawn("router-lock", cmux_threads::ThreadQos::Utility, move || {
        let _ = locked.send(fs4::FileExt::lock(&lock).map(|()| lock));
    })?;
    let lock = tokio::time::timeout(std::time::Duration::from_secs(30), lock_rx)
        .await
        .map_err(|_| anyhow::anyhow!("another local router holds router.lock"))???;
    // Keys live in memory for one router run, so a fresh random install secret
    // per run is as strong as a stored one, on every platform. No Keychain:
    // its access prompt asked again for every differently signed build.
    // Chosen before the admin socket exists: a client that reaches the socket
    // gets an answer.
    let store: Arc<dyn InstallSecretStore> = Arc::new(RandomInstallSecretStore::new("default")?);
    let _ = INSTALL_SECRET_KIND.set(INSTALL_SECRET_EPHEMERAL);
    // `<home>/router/router.sock`, or a short path for a long home
    // (admin_socket.rs), whose private folder is made and checked on disk.
    let socket_path = admin_socket::admin_socket_path_async(home).await?;
    let _ = tokio::fs::remove_file(&socket_path).await;
    let admin = bind_admin(&socket_path)?;
    let bind_address: SocketAddr = "127.0.0.1:0".parse()?;
    let listener = TcpListener::bind(LoopbackAddr::try_from(bind_address)?.address()).await?;
    let keys = Arc::new(tokio::sync::RwLock::new(KeyRing::new(store)?));
    let port = listener.local_addr()?.port();
    let upstream: SharedUpstream = Arc::new(tokio::sync::RwLock::new(None));
    let free = FreeTier::new(http_client());
    let data = data_server(listener, keys.clone(), upstream.clone(), free.clone());
    let stop = Arc::new(tokio::sync::Notify::new());
    tokio::select! {
        _ = data => (),
        result = admin_loop(admin, keys, upstream, free, port, stop.clone()) => result?,
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
    let free = FreeTier::new(http_client());
    let task = tokio::spawn(data_server(listener, keys, upstream, free));
    Ok((address, task))
}

/// The relay's HTTP client toward the hosted router: no redirects (a bearer
/// never follows one to another host).
fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        // Per read, not per request: a long stream keeps going while bytes
        // arrive; an upstream that stops sending ends the request.
        .read_timeout(std::time::Duration::from_secs(300))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default()
}

async fn data_server(
    listener: TcpListener,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    free: Arc<FreeTier>,
) {
    let state = AppState {
        port: listener.local_addr().map(|address| address.port()).unwrap_or(0),
        keys,
        upstream,
        free,
        http: http_client(),
    };
    let app = Router::new()
        .fallback(any(data_request))
        .layer(RequestBodyLimitLayer::new(BODY_LIMIT))
        .with_state(state);
    let _ = axum::serve(listener, app.into_make_service()).await;
}
async fn admin_loop(
    mut admin: AdminConnections,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    free: Arc<FreeTier>,
    port: u16,
    stop: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    // The loop owns its connections; a panic ends that connection only.
    let mut connections = tokio::task::JoinSet::new();
    while let Some(accepted) = admin.recv().await {
        while connections.try_join_next().is_some() {}
        let connection = accepted?;
        let keys = keys.clone();
        let upstream = upstream.clone();
        let free = free.clone();
        let stop = stop.clone();
        connections.spawn(async move {
            let _ = admin_connection(connection, keys, upstream, free, port, stop).await;
        });
    }
    anyhow::bail!("the router admin listener ended")
}

/// The build of the acpmux that started this router (`CMUX_ROUTER_BUILD`):
/// a daemon of another build replaces it once no agent uses it.
fn router_build() -> String {
    std::env::var("CMUX_ROUTER_BUILD").unwrap_or_default()
}
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
    /// Exit after the reply (the daemon ended every agent, or it replaces
    /// a router of another build that no agent uses).
    Shutdown,
    /// A daemon that holds the owner FIFO takes this running router over
    /// (`{adopted, stopping, pid}`); refused once the router is stopping, or
    /// when it has no owner FIFO (started by hand).
    Adopt,
    /// The cmux app offers App Attest proofs for the free tier
    /// (`free_tier`): the connection then carries relay requests and the
    /// app's replies until it ends.
    AttestProvider(free_tier::Register),
}
async fn admin_connection(
    connection: AdminConnection,
    keys: Arc<tokio::sync::RwLock<KeyRing>>,
    upstream: SharedUpstream,
    free: Arc<FreeTier>,
    port: u16,
    stop: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    let (read, mut write, peer) = connection;
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
            // A mint error (no install secret) is answered, not a closed socket.
            AdminRequest::Mint { key_id, scope } => match keys.write().await.mint(key_id, scope) {
                Ok(key) => serde_json::json!({"key": key.expose()}),
                Err(error) => serde_json::json!({"error": error.to_string()}),
            },
            AdminRequest::List => serde_json::json!({"keys": keys.read().await.list()}),
            AdminRequest::Revoke { key_id } => {
                serde_json::json!({"revoked": keys.write().await.revoke(&key_id)})
            }
            AdminRequest::Status => {
                let up = upstream.read().await;
                serde_json::json!({"port": port, "build": router_build(), "pid": std::process::id(), "upstream": up.as_ref().map(Upstream::view), "free": free.view(), "install_secret": INSTALL_SECRET_KIND.get().copied()})
            }
            AdminRequest::Adopt => {
                // The daemon opened the owner FIFO before it asked; a router
                // whose owner watch already ended refuses.
                let stopping =
                    *OWNERS_GONE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let owned = std::env::var_os("CMUX_ROUTER_OWNER_FIFO").is_some();
                serde_json::json!({
                    "adopted": owned && !stopping,
                    "stopping": stopping,
                    "pid": std::process::id(),
                })
            }
            AdminRequest::MintKey { scope } => {
                let id = format!("s{}", uuid::Uuid::new_v4().simple());
                match keys.write().await.mint(id.clone(), scope) {
                    Ok(key) => serde_json::json!({"id": id, "key": key.expose()}),
                    Err(error) => serde_json::json!({"error": error.to_string()}),
                }
            }
            AdminRequest::RevokeKey { id } => {
                serde_json::json!({"revoked": keys.write().await.revoke(&id)})
            }
            AdminRequest::SetUpstream { origin, bearer, expires_at } => {
                match Upstream::new(&origin, bearer, expires_at) {
                    Ok(next) => {
                        let view = next.view();
                        *upstream.write().await = Some(next);
                        serde_json::json!({"upstream": view, "pid": std::process::id()})
                    }
                    Err(error) => serde_json::json!({"error": error.to_string()}),
                }
            }
            AdminRequest::ClearUpstream => {
                *upstream.write().await = None;
                serde_json::json!({"upstream": null})
            }
            AdminRequest::AttestProvider(register) => {
                // The peer check runs on this connection's peer (read at
                // accept), before anything is written to it.
                if !free_tier::provider_peer_allowed(&peer) {
                    write.write_all(b"{\"error\":\"provider refused\"}\n").await?;
                    return Ok(());
                }
                return free.serve_provider(register, lines, write).await;
            }
            AdminRequest::Shutdown => {
                *upstream.write().await = None;
                free.drop_token();
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

pub(crate) fn json_error(status: StatusCode, code: &str, message: &str) -> Response<Body> {
    let body = serde_json::json!({"error": {"code": code, "message": message}}).to_string();
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

/// The relay's own refusal that retrying cannot fix within a turn (no upstream, an
/// expired sign-in): `x-should-retry: false`, the Anthropic API's header that Claude
/// Code and the provider SDKs read, so the harness ends the turn with this message
/// at once instead of retrying a 503 for minutes while a phone shows "Working".
fn final_json_error(status: StatusCode, code: &str, message: &str) -> Response<Body> {
    let mut response = json_error(status, code, message);
    response.headers_mut().insert("x-should-retry", HeaderValue::from_static("false"));
    response
}

/// Request headers passed upstream; everything else (the client's auth, cookies,
/// host) stays here.
const FORWARD_REQUEST_HEADERS: &[&str] = &["content-type", "accept", "anthropic-version"];
const FORWARD_RESPONSE_HEADERS: &[&str] =
    &["content-type", "cache-control", "retry-after", "x-should-retry", "x-cmux-request-id"];

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
    // The account bearer wins while one is set; with none (signed out) the
    // free-tier device token, leased at this first request (free_tier).
    let account = {
        let up = state.upstream.read().await;
        match up.as_ref() {
            Some(up) if up.live() => {
                Some(Ok((format!("{}{path}", up.origin), up.bearer.expose().clone())))
            }
            Some(_) => Some(Err(final_json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "router.upstream_expired",
                "the cmux model router sign-in expired; open cmux to renew it",
            ))),
            None => None,
        }
    };
    let (url, bearer, free) = match account {
        Some(Ok((url, bearer))) => (url, bearer, false),
        Some(Err(refused)) => return refused,
        None => match state.free.bearer().await {
            Ok((origin, bearer)) => (format!("{origin}{path}"), bearer, true),
            Err(refused) => return *refused,
        },
    };
    let mut forward = state.http.request(method, &url).bearer_auth(&bearer);
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
    // A refused free token (its grant ended, or the device is unknown): lease again next time.
    if free && answer.status() == StatusCode::UNAUTHORIZED {
        state.free.drop_token_if(&bearer);
    }
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

#[cfg(test)]
mod relay_error_tests {
    use super::*;

    #[test]
    fn relay_refusals_that_retrying_cannot_fix_say_so() {
        let response = final_json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "router.no_upstream",
            "the cmux model router is not connected; open cmux",
        );
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers().get("x-should-retry").unwrap(), "false");
        assert_eq!(response.headers().get("content-type").unwrap(), "application/json");
        // A plain relay error (the router did not answer) stays retryable.
        let transient = json_error(
            StatusCode::BAD_GATEWAY,
            "router.unreachable",
            "the cmux model router did not answer",
        );
        assert!(transient.headers().get("x-should-retry").is_none());
        // The hosted router's own retry advice reaches the harness.
        assert!(FORWARD_RESPONSE_HEADERS.contains(&"x-should-retry"));
    }
}

#[cfg(all(test, unix))]
mod serve_tests;
