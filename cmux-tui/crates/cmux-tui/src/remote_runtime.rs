//! Lifecycle glue between the synchronous TUI/core and the asynchronous
//! transport-neutral remote daemon.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::future::Future;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, anyhow};
use async_trait::async_trait;
use base64::Engine;
use cmux_remote::admin::serve_admin_with_shutdown;
use cmux_remote::bridge::serve_mux_bridge;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectGroupSource,
    ReconnectPolicy,
};
use cmux_remote::crypto::{AuthKind, ClientAuthMode, CryptoError, StaticIdentity};
#[cfg(test)]
use cmux_remote::daemon::serve_unix;
use cmux_remote::daemon::{DaemonSessionPolicy, serve_direct_websocket, serve_unix_with_shutdown};
use cmux_remote::http::serve_workspace_http;
use cmux_remote::identity::{
    AuthDatabase, IdentityError, PersistedAuthStateSchema, credential_free_route_hint,
    default_state_dir, persisted_auth_state_schema,
};
use cmux_remote::observability::ClientConnectionSnapshot;
use cmux_remote::provider::{
    ConnectRequest, DirectWebSocketProvider, IrohListener, IrohPathMode, IrohProvider,
    IrohProviderConfig, LinkGroup, ProviderError, RelayClientConfig, RelayCredentialSource,
    RelayDaemonConfig, RelayDaemonRegistration, RelayProvider, SshProvider, SshProviderConfig,
    SupportedClientAuthModes, TransportProvider, UnixProvider, load_or_create_iroh_secret,
    register_relay_daemon_with_credentials, sanitized_route, sanitized_route_text,
};
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::ssh_bootstrap::{BootstrapError, SshBootstrapConfig, SshBootstrapper};
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;
use url::Url;

use crate::localization::catalog;

pub const MAX_CARRIER_FRAME_BYTES: usize = 65_535;
const MIN_REMOTE_RUNTIME_WORKERS: usize = 2;
const MAX_REMOTE_RUNTIME_WORKERS: usize = 4;
const INITIAL_GROUP_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
const UNIX_SOCKET_PROBE_TIMEOUT: Duration = Duration::from_millis(250);
const CLIENT_SOCKET_LOCK_RETRY: Duration = Duration::from_millis(10);
const DAEMON_STARTUP_TIMEOUT: Duration = Duration::from_secs(30);
const DAEMON_AUTH_LEASE_RETRY_TIMEOUT: Duration = Duration::from_secs(5);
const DAEMON_AUTH_LEASE_RETRY_INTERVAL: Duration = Duration::from_millis(10);
const STARTUP_THREAD_REAP_TIMEOUT: Duration = Duration::from_millis(250);
const REMOTE_RUNTIME_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(250);
const MAX_DAEMON_SESSION_COMPONENT_BYTES: usize = 120;
const DAEMON_SHUTDOWN_OUTCOME_VERSION: u32 = 1;
const DAEMON_LIFECYCLE_FENCE_VERSION: u32 = 1;

#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum DaemonCleanupPausePhase {
    BeforeLifecycleFence,
    BeforeListenerStartup,
    BeforeReadySend,
    BeforeAuthRelease,
    AfterAuthShutdown,
}

#[cfg(test)]
struct DaemonCleanupPause {
    expected_state_dir: PathBuf,
    expected_phase: DaemonCleanupPausePhase,
    reached: mpsc::SyncSender<()>,
    resume: std::sync::Mutex<mpsc::Receiver<()>>,
}

#[cfg(test)]
static DAEMON_CLEANUP_PAUSES: std::sync::Mutex<Vec<Arc<DaemonCleanupPause>>> =
    std::sync::Mutex::new(Vec::new());

#[cfg(test)]
static STATE_DIRECTORY_SYNC_FAILURES: std::sync::Mutex<Vec<(PathBuf, usize)>> =
    std::sync::Mutex::new(Vec::new());

#[cfg(test)]
struct DaemonCleanupPauseHandle {
    pause: Arc<DaemonCleanupPause>,
    reached: mpsc::Receiver<()>,
    resume: Option<mpsc::SyncSender<()>>,
}

#[cfg(test)]
impl DaemonCleanupPauseHandle {
    fn install(expected_state_dir: PathBuf, expected_phase: DaemonCleanupPausePhase) -> Self {
        let (reached_tx, reached) = mpsc::sync_channel(1);
        let (resume, resume_rx) = mpsc::sync_channel(1);
        let pause = Arc::new(DaemonCleanupPause {
            expected_state_dir,
            expected_phase,
            reached: reached_tx,
            resume: std::sync::Mutex::new(resume_rx),
        });
        let mut installed =
            DAEMON_CLEANUP_PAUSES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        assert!(
            !installed.iter().any(|existing| {
                existing.expected_state_dir == pause.expected_state_dir
                    && existing.expected_phase == pause.expected_phase
            }),
            "a matching daemon cleanup pause is already installed"
        );
        installed.push(pause.clone());
        Self { pause, reached, resume: Some(resume) }
    }

    fn wait_until_reached(&self) {
        self.reached
            // The daemon performs real filesystem and socket setup before it
            // reaches this deterministic test hook. Keep the observation
            // bounded without coupling it to parallel CI runner load.
            .recv_timeout(Duration::from_secs(10))
            .expect("daemon shutdown did not reach the lifecycle cleanup pause");
    }

    fn assert_not_reached_before(&self, other_shutdown: &thread::JoinHandle<anyhow::Result<()>>) {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        loop {
            match self.reached.try_recv() {
                Ok(()) => panic!("an unrelated daemon entered the lifecycle cleanup pause"),
                Err(mpsc::TryRecvError::Disconnected) => {
                    panic!("daemon lifecycle cleanup pause disconnected")
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
            if other_shutdown.is_finished() {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "unrelated daemon shutdown did not finish"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    fn resume(&mut self) {
        if let Some(resume) = self.resume.take() {
            let _ = resume.send(());
        }
        DAEMON_CLEANUP_PAUSES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|pause| !Arc::ptr_eq(pause, &self.pause));
    }
}

#[cfg(test)]
impl Drop for DaemonCleanupPauseHandle {
    fn drop(&mut self) {
        self.resume();
    }
}

#[cfg(test)]
fn pause_daemon_cleanup(state_dir: &Path, phase: DaemonCleanupPausePhase) {
    let pause = DAEMON_CLEANUP_PAUSES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .find(|pause| pause.expected_state_dir == state_dir && pause.expected_phase == phase)
        .cloned();
    if let Some(pause) = pause {
        let _ = pause.reached.send(());
        let _ = pause.resume.lock().unwrap_or_else(std::sync::PoisonError::into_inner).recv();
    }
}

#[cfg(test)]
fn fail_state_directory_sync_after(state_dir: &Path, successful_syncs: usize) {
    STATE_DIRECTORY_SYNC_FAILURES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .push((state_dir.to_path_buf(), successful_syncs));
}

fn remote_runtime_worker_count() -> usize {
    thread::available_parallelism()
        .map(std::num::NonZeroUsize::get)
        .unwrap_or(MIN_REMOTE_RUNTIME_WORKERS)
        .clamp(MIN_REMOTE_RUNTIME_WORKERS, MAX_REMOTE_RUNTIME_WORKERS)
}

fn build_remote_runtime(thread_name: &str) -> anyhow::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(remote_runtime_worker_count())
        .thread_name(thread_name)
        .enable_all()
        .build()
        .context("could not start remote Tokio runtime")
}

fn reap_failed_startup(runtime_thread: thread::JoinHandle<anyhow::Result<()>>, runtime_name: &str) {
    let (finished_tx, finished_rx) = mpsc::sync_channel(1);
    let reaper_name = format!("{runtime_name}-startup-reaper");
    let reaper = thread::Builder::new().name(reaper_name).spawn(move || {
        let _ = finished_tx.send(runtime_thread.join());
    });
    if reaper.is_ok() {
        let _ = finished_rx.recv_timeout(STARTUP_THREAD_REAP_TIMEOUT);
    }
}

#[derive(Clone)]
pub struct RelayDaemonOptions {
    pub endpoint: Url,
    pub slot: String,
    pub credentials: RelayCredentialSource,
}

impl fmt::Debug for RelayDaemonOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayDaemonOptions")
            .field("endpoint", &sanitized_route(&self.endpoint))
            .field("slot", &"[REDACTED]")
            .field("credentials", &self.credentials)
            .finish()
    }
}

#[derive(Clone)]
pub struct DaemonRuntimeOptions {
    pub session: String,
    pub state_dir: Option<PathBuf>,
    pub link_socket: Option<PathBuf>,
    pub admin_socket: Option<PathBuf>,
    pub direct_websocket: Option<SocketAddr>,
    pub allow_insecure_non_loopback: bool,
    pub workspace_http: Option<SocketAddr>,
    pub relays: Vec<RelayDaemonOptions>,
    pub iroh: bool,
    pub advertised_routes: Vec<String>,
    pub resume_lease: Duration,
    pub replaceable_sidecar: bool,
}

impl fmt::Debug for DaemonRuntimeOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let advertised_routes = self
            .advertised_routes
            .iter()
            .map(|route| sanitized_route_text(route))
            .collect::<Vec<_>>();
        formatter
            .debug_struct("DaemonRuntimeOptions")
            .field("session", &self.session)
            .field("state_dir", &self.state_dir)
            .field("link_socket", &self.link_socket)
            .field("admin_socket", &self.admin_socket)
            .field("direct_websocket", &self.direct_websocket)
            .field("allow_insecure_non_loopback", &self.allow_insecure_non_loopback)
            .field("workspace_http", &self.workspace_http)
            .field("relays", &self.relays)
            .field("iroh", &self.iroh)
            .field("advertised_routes", &advertised_routes)
            .field("resume_lease", &self.resume_lease)
            .field("replaceable_sidecar", &self.replaceable_sidecar)
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct DaemonRuntimeInfo {
    pub session: String,
    pub state_dir: PathBuf,
    pub link_socket: PathBuf,
    pub admin_socket: PathBuf,
    pub daemon_fingerprint: String,
    pub routes: Vec<String>,
    pub direct_websocket: Option<SocketAddr>,
    pub iroh_node_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_id: Option<String>,
    #[serde(default)]
    pub replaceable_sidecar: bool,
}

impl fmt::Debug for DaemonRuntimeInfo {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let routes =
            self.routes.iter().map(|route| sanitized_route_text(route)).collect::<Vec<_>>();
        formatter
            .debug_struct("DaemonRuntimeInfo")
            .field("session", &self.session)
            .field("state_dir", &self.state_dir)
            .field("link_socket", &self.link_socket)
            .field("admin_socket", &self.admin_socket)
            .field("daemon_fingerprint", &self.daemon_fingerprint)
            .field("routes", &routes)
            .field("direct_websocket", &self.direct_websocket)
            .field("iroh_node_id", &self.iroh_node_id)
            .field("lifecycle_id", &self.lifecycle_id)
            .field("replaceable_sidecar", &self.replaceable_sidecar)
            .finish()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct DaemonShutdownOutcome {
    pub(crate) version: u32,
    pub(crate) lifecycle_id: String,
    pub(crate) status: DaemonShutdownStatus,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum DaemonShutdownStatus {
    Succeeded,
    Failed,
}

#[derive(Serialize, Deserialize)]
struct DaemonLifecycleFence {
    version: u32,
}

pub struct DaemonRuntimeHandle {
    info: DaemonRuntimeInfo,
    shutdown: watch::Sender<bool>,
    thread: Option<thread::JoinHandle<anyhow::Result<()>>>,
}

impl DaemonRuntimeHandle {
    pub fn info(&self) -> &DaemonRuntimeInfo {
        &self.info
    }

    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_some_and(thread::JoinHandle::is_finished)
    }

    pub fn shutdown(mut self) -> anyhow::Result<()> {
        let _ = self.shutdown.send(true);
        match self.thread.take().expect("daemon runtime thread is present").join() {
            Ok(result) => result,
            Err(_) => Err(anyhow!("remote daemon runtime thread panicked")),
        }
    }
}

impl Drop for DaemonRuntimeHandle {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
    }
}

#[derive(Clone)]
pub struct RelayClientOptions {
    pub slot: String,
    pub credentials: RelayCredentialSource,
}

impl fmt::Debug for RelayClientOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RelayClientOptions")
            .field("slot", &"[REDACTED]")
            .field("credentials", &self.credentials)
            .finish()
    }
}

#[derive(Clone)]
struct RoutedRelayProvider {
    routes: BTreeMap<String, RelayClientOptions>,
}

impl fmt::Debug for RoutedRelayProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let routes = self
            .routes
            .iter()
            .map(|(route, options)| (sanitized_route_text(route), options))
            .collect::<Vec<_>>();
        formatter.debug_struct("RoutedRelayProvider").field("routes", &routes).finish()
    }
}

#[async_trait]
impl TransportProvider for RoutedRelayProvider {
    fn name(&self) -> &'static str {
        "configured-websocket-relay"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["relay+ws", "relay+wss", "relay+https", "relay+do"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOnly
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let relay = self.routes.get(request.endpoint.as_str()).ok_or_else(|| {
            ProviderError::Configuration(
                "relay route requires credentials bound to its exact endpoint".into(),
            )
        })?;
        RelayProvider::with_credentials(
            RelayClientConfig {
                slot: relay.slot.clone(),
                ticket: String::new(),
                maximum_frame_bytes: MAX_CARRIER_FRAME_BYTES,
                control_timeout: Duration::from_secs(15),
            },
            relay.credentials.clone(),
        )?
        .connect(request)
        .await
    }
}

pub fn client_provider_registry(
    ssh: SshProviderConfig,
    relay_routes: BTreeMap<String, RelayClientOptions>,
    iroh_path: IrohPathMode,
) -> Result<cmux_remote::provider::ProviderRegistry, ProviderError> {
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers.register(Arc::new(DirectWebSocketProvider::new(MAX_CARRIER_FRAME_BYTES)))?;
    #[cfg(unix)]
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES)))?;
    providers.register(Arc::new(SshProvider::new(ssh)?))?;
    providers.register(Arc::new(RoutedRelayProvider { routes: relay_routes }))?;
    providers.register(Arc::new(IrohProvider::new(
        IrohProviderConfig::default().with_path_mode(iroh_path),
    )?))?;
    Ok(providers)
}

#[derive(Clone, PartialEq, Eq)]
pub struct ResolvedRouteCandidate {
    pub endpoint: Url,
    pub routing: BTreeMap<String, String>,
    supported_client_auth: SupportedClientAuthModes,
}

impl fmt::Debug for ResolvedRouteCandidate {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let routing_keys = self.routing.keys().map(String::as_str).collect::<Vec<_>>();
        formatter
            .debug_struct("ResolvedRouteCandidate")
            .field("endpoint", &sanitized_route(&self.endpoint))
            .field("routing_keys", &routing_keys)
            .field("supported_client_auth", &self.supported_client_auth)
            .finish()
    }
}

impl ResolvedRouteCandidate {
    pub fn resolve(
        endpoint: Url,
        routing: BTreeMap<String, String>,
        providers: &cmux_remote::provider::ProviderRegistry,
    ) -> Result<Self, ProviderError> {
        if endpoint.scheme() == "ssh" {
            ssh_bootstrap_destination(&endpoint).map_err(|_| {
                ProviderError::Configuration("SSH route is not a safe OpenSSH destination".into())
            })?;
        }
        let supported_client_auth = providers.supported_client_auth(endpoint.scheme())?;
        Ok(Self { endpoint, routing, supported_client_auth })
    }

    #[cfg(test)]
    pub fn supported_client_auth(&self) -> SupportedClientAuthModes {
        self.supported_client_auth
    }

    fn supports_client_auth(&self, auth: AuthKind) -> bool {
        self.supported_client_auth.supports(auth)
    }

    #[cfg(test)]
    fn with_supported_client_auth_for_test(
        endpoint: Url,
        routing: BTreeMap<String, String>,
        supported_client_auth: SupportedClientAuthModes,
    ) -> Self {
        Self { endpoint, routing, supported_client_auth }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SshBootstrapOptions {
    pub auto_install: bool,
    pub upgrade: bool,
    pub attempt_timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct ClientRuntimeOptions {
    pub routes: Vec<ResolvedRouteCandidate>,
    pub providers: Arc<cmux_remote::provider::ProviderRegistry>,
    pub identity: StaticIdentity,
    pub expected_daemon: Option<[u8; 32]>,
    pub auth: ClientAuthMode,
    pub device_name: String,
    pub session: SessionId,
    pub lane_policy: LanePolicy,
    pub reconnect: ReconnectPolicy,
    pub startup_timeout: Duration,
    pub state_dir: PathBuf,
    pub local_socket: Option<PathBuf>,
    pub ssh: SshProviderConfig,
    pub ssh_bootstrap: SshBootstrapOptions,
}

#[derive(Clone)]
pub struct ClientRuntimeInfo {
    pub local_socket: PathBuf,
    pub daemon_public_key: [u8; 32],
    pub route: String,
}

impl fmt::Debug for ClientRuntimeInfo {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ClientRuntimeInfo")
            .field("local_socket", &self.local_socket)
            .field("daemon_public_key", &self.daemon_public_key)
            .field("route", &sanitized_route_text(&self.route))
            .finish()
    }
}

pub struct ClientRuntimeHandle {
    info: ClientRuntimeInfo,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    shutdown: watch::Sender<bool>,
    finished: watch::Receiver<bool>,
    thread: Option<thread::JoinHandle<anyhow::Result<()>>>,
}

impl ClientRuntimeHandle {
    pub fn info(&self) -> &ClientRuntimeInfo {
        &self.info
    }

    pub fn multiplexer(&self) -> &Arc<ServiceMultiplexer> {
        &self.multiplexer
    }

    pub async fn connection_snapshot(&self) -> ClientConnectionSnapshot {
        self.connection.snapshot().await
    }

    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_some_and(thread::JoinHandle::is_finished)
    }

    pub fn subscribe_finished(&self) -> watch::Receiver<bool> {
        self.finished.clone()
    }

    pub fn shutdown(mut self) -> anyhow::Result<()> {
        let _ = self.shutdown.send(true);
        match self.thread.take().expect("client runtime thread is present").join() {
            Ok(result) => result,
            Err(_) => Err(anyhow!("remote client runtime thread panicked")),
        }
    }
}

impl Drop for ClientRuntimeHandle {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
    }
}

pub fn start_client_runtime(options: ClientRuntimeOptions) -> anyhow::Result<ClientRuntimeHandle> {
    if options.routes.is_empty() {
        return Err(anyhow!("remote connection has no route candidates"));
    }
    if options.startup_timeout.is_zero() {
        return Err(anyhow!("remote startup timeout must be positive"));
    }
    options.reconnect.validate()?;
    let startup_timeout = options.startup_timeout;
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (finished_tx, finished_rx) = watch::channel(false);
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name("cmux-remote-client".into())
        .spawn(move || {
            let runtime = build_remote_runtime("cmux-remote-client-worker")
                .context("could not start remote client Tokio runtime")?;
            let result = runtime.block_on(run_client(options, shutdown_rx, ready_tx));
            runtime.shutdown_timeout(REMOTE_RUNTIME_SHUTDOWN_TIMEOUT);
            finished_tx.send_replace(true);
            result
        })
        .context("could not start remote client thread")?;
    let ready = match ready_rx.recv_timeout(startup_timeout) {
        Ok(Ok(ready)) => ready,
        Ok(Err(error)) => {
            let _ = shutdown_tx.send(true);
            reap_failed_startup(thread, "cmux-remote-client");
            return Err(anyhow!(error));
        }
        Err(error) => {
            let _ = shutdown_tx.send(true);
            reap_failed_startup(thread, "cmux-remote-client");
            return Err(anyhow!(
                "remote connection did not become ready within {}s: {error}",
                startup_timeout.as_secs()
            ));
        }
    };
    Ok(ClientRuntimeHandle {
        info: ready.info,
        connection: ready.connection,
        multiplexer: ready.multiplexer,
        shutdown: shutdown_tx,
        finished: finished_rx,
        thread: Some(thread),
    })
}

struct ClientReady {
    info: ClientRuntimeInfo,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
}

#[cfg(unix)]
#[derive(Debug)]
struct ClientSocketPathLock {
    file: fs::File,
}

#[cfg(unix)]
impl Drop for ClientSocketPathLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;

        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(unix)]
#[derive(Debug)]
struct ClientSocketPreparation {
    path: PathBuf,
    _lock: ClientSocketPathLock,
}

#[cfg(unix)]
impl ClientSocketPreparation {
    fn bind(self) -> anyhow::Result<ClientSocketLease> {
        use std::os::unix::fs::PermissionsExt;

        let lease = ClientSocketLease::bind_locked(self.path.clone())?;
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))?;
        Ok(lease)
    }
}

#[cfg(unix)]
struct ClientSocketLease {
    listener: tokio::net::UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
    linked: bool,
}

#[cfg(unix)]
impl ClientSocketLease {
    fn bind_locked(path: PathBuf) -> std::io::Result<Self> {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};

        let listener = tokio::net::UnixListener::bind(&path)?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                let _ = fs::remove_file(&path);
                return Err(error);
            }
        };
        if !metadata.file_type().is_socket() {
            let _ = fs::remove_file(&path);
            return Err(std::io::Error::other("bound client path is not a Unix socket"));
        }
        Ok(Self { listener, path, device: metadata.dev(), inode: metadata.ino(), linked: true })
    }

    fn listener(&self) -> &tokio::net::UnixListener {
        &self.listener
    }

    fn unlink(&mut self) -> std::io::Result<()> {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};

        if !self.linked {
            return Ok(());
        }
        let metadata = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.linked = false;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if !metadata.file_type().is_socket()
            || metadata.dev() != self.device
            || metadata.ino() != self.inode
        {
            self.linked = false;
            return Ok(());
        }
        fs::remove_file(&self.path)?;
        self.linked = false;
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for ClientSocketLease {
    fn drop(&mut self) {
        let _ = self.unlink();
    }
}

async fn run_client(
    options: ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    ready: mpsc::SyncSender<Result<ClientReady, String>>,
) -> anyhow::Result<()> {
    let setup = async {
        let (connection, route) = connect_first_available(&options, shutdown.clone()).await?;
        if *shutdown.borrow() {
            let _ = connection.close().await;
            return Err(anyhow!("remote client startup was cancelled"));
        }
        let local_socket = options
            .local_socket
            .clone()
            .unwrap_or_else(|| default_client_socket(&options.state_dir, options.session));
        let socket_preparation =
            prepare_client_socket_with_shutdown(&local_socket, Some(shutdown.clone())).await?;
        if *shutdown.borrow() {
            let _ = connection.close().await;
            return Err(anyhow!("remote client startup was cancelled"));
        }
        let daemon_public_key = connection.daemon_public_key();
        let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
        let socket = socket_preparation.bind()?;
        let (bridge_shutdown_tx, bridge_shutdown_rx) = tokio::sync::oneshot::channel();
        let bridge_multiplexer = multiplexer.clone();
        let mut bridge = tokio::spawn(async move {
            let mut socket = socket;
            serve_mux_bridge(bridge_multiplexer, socket.listener(), bridge_shutdown_rx).await;
            let _ = socket.unlink();
        });
        let mut fatal = multiplexer.subscribe_fatal();
        ready
            .send(Ok(ClientReady {
                info: ClientRuntimeInfo {
                    local_socket: local_socket.clone(),
                    daemon_public_key,
                    route,
                },
                connection: connection.clone(),
                multiplexer,
            }))
            .map_err(|_| anyhow!("remote client owner stopped during startup"))?;

        let outcome = tokio::select! {
            _ = wait_for_shutdown(&mut shutdown) => Ok(()),
            message = wait_for_fatal(&mut fatal) => Err(anyhow!(
                "remote connection terminated: {message}"
            )),
            result = &mut bridge => Err(match result {
                Ok(()) => anyhow!("local remote-control bridge stopped unexpectedly"),
                Err(error) => anyhow!("local remote-control bridge failed: {error}"),
            }),
        };
        let _ = bridge_shutdown_tx.send(());
        if !bridge.is_finished() {
            let _ = bridge.await;
        }
        let _ = connection.close().await;
        outcome
    }
    .await;
    if let Err(error) = &setup {
        let _ = ready.send(Err(format!("{error:#}")));
    }
    setup
}

async fn connect_first_available(
    options: &ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    let mut attempts = 0_u32;
    let mut delay = options.reconnect.initial_delay;
    loop {
        attempts = attempts.saturating_add(1);
        let mut attempt = RuntimeInitialRouteAttempt { options, shutdown: shutdown.clone() };
        match select_initial_route(
            &options.routes,
            options.session,
            options.lane_policy,
            client_auth_kind(&options.auth),
            options.ssh_bootstrap.upgrade,
            &mut attempt,
        )
        .await
        {
            Ok(connection) => return Ok(connection),
            Err(error)
                if error.retryable
                    && options
                        .reconnect
                        .maximum_attempts
                        .is_none_or(|maximum| attempts < maximum) =>
            {
                tokio::select! {
                    _ = tokio::time::sleep(options.reconnect.retry_delay(delay)) => {}
                    _ = wait_for_shutdown(&mut shutdown) => {
                        return Err(anyhow!("remote client startup was cancelled"));
                    }
                }
                delay = (delay * 2).min(options.reconnect.maximum_delay);
            }
            Err(error) => return Err(error.error),
        }
    }
}

enum InitialRouteAttemptError {
    Route { error: anyhow::Error, retryable: bool },
    Fatal(anyhow::Error),
}

#[derive(Debug)]
struct InitialRouteSelectionError {
    error: anyhow::Error,
    retryable: bool,
}

impl InitialRouteSelectionError {
    fn terminal(error: anyhow::Error) -> Self {
        Self { error, retryable: false }
    }
}

impl fmt::Display for InitialRouteSelectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.error.fmt(formatter)
    }
}

#[async_trait]
trait InitialRouteAttempt<T: Send> {
    async fn bootstrap_ssh(
        &mut self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError>;
    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<T, InitialRouteAttemptError>;
}

async fn select_initial_route<T: Send>(
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    upgrade: bool,
    attempt: &mut impl InitialRouteAttempt<T>,
) -> Result<T, InitialRouteSelectionError> {
    if routes.is_empty() {
        return Err(InitialRouteSelectionError::terminal(anyhow!(
            "remote connection has no route candidates"
        )));
    }
    if upgrade && routes[0].endpoint.scheme() != "ssh" {
        return Err(InitialRouteSelectionError::terminal(anyhow!(
            "--upgrade requires SSH to be the initial route"
        )));
    }
    let mut failures = Vec::new();
    let mut retryable = false;
    for (index, candidate) in routes.iter().enumerate() {
        let display_endpoint = sanitized_route(&candidate.endpoint);
        if !candidate.supports_client_auth(auth) {
            failures.push(format!(
                "{display_endpoint}: {}",
                ProviderError::UnsupportedClientAuth {
                    scheme: candidate.endpoint.scheme().into(),
                    auth,
                }
            ));
            continue;
        }
        let request = connect_request(candidate, session, lane_policy)
            .map_err(InitialRouteSelectionError::terminal)?;
        let endpoint = request.endpoint.clone();
        let upgrade_candidate = upgrade && index == 0;
        if endpoint.scheme() == "ssh" {
            match attempt.bootstrap_ssh(&endpoint, upgrade_candidate).await {
                Ok(()) => {}
                Err(InitialRouteAttemptError::Route { error, retryable: route_retryable }) => {
                    if upgrade_candidate {
                        return Err(InitialRouteSelectionError::terminal(anyhow!(
                            "SSH bootstrap failed for {display_endpoint}: {error:#}"
                        )));
                    }
                    retryable |= route_retryable;
                    failures.push(format!("{display_endpoint}: SSH bootstrap failed: {error:#}"));
                    continue;
                }
                Err(InitialRouteAttemptError::Fatal(error)) => {
                    return Err(InitialRouteSelectionError::terminal(error));
                }
            }
        }
        match attempt.connect(index, request).await {
            Ok(result) => return Ok(result),
            Err(InitialRouteAttemptError::Route { error, retryable: route_retryable }) => {
                if upgrade_candidate {
                    return Err(InitialRouteSelectionError::terminal(anyhow!(
                        "upgraded SSH route failed for {display_endpoint}: {error:#}"
                    )));
                }
                retryable |= route_retryable;
                failures.push(format!("{display_endpoint}: {error:#}"));
            }
            Err(InitialRouteAttemptError::Fatal(error)) => {
                return Err(InitialRouteSelectionError::terminal(error));
            }
        }
    }
    Err(InitialRouteSelectionError {
        error: anyhow!("all remote route candidates failed: {}", failures.join("; ")),
        retryable,
    })
}

struct RuntimeInitialRouteAttempt<'a> {
    options: &'a ClientRuntimeOptions,
    shutdown: watch::Receiver<bool>,
}

#[async_trait]
impl InitialRouteAttempt<(Arc<ClientConnection>, String)> for RuntimeInitialRouteAttempt<'_> {
    async fn bootstrap_ssh(
        &mut self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError> {
        bootstrap_initial_ssh_route(
            endpoint,
            &self.options.ssh,
            self.options.ssh_bootstrap,
            upgrade,
            Some(self.shutdown.clone()),
        )
        .await
        .map_err(|error| InitialRouteAttemptError::Route {
            retryable: !upgrade && ssh_bootstrap_failure_is_retryable(&error),
            error,
        })
    }

    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<(Arc<ClientConnection>, String), InitialRouteAttemptError> {
        let display_endpoint = sanitized_route(&request.endpoint);
        let timeout = self.options.reconnect.attempt_timeout;
        let deadline = tokio::time::Instant::now() + timeout;
        let mut shutdown = self.shutdown.clone();
        let group = tokio::select! {
            result = tokio::time::timeout_at(
                deadline,
                self.options
                    .providers
                    .connect(request, client_auth_kind(&self.options.auth)),
            ) => match result {
                Ok(Ok(group)) => group,
                Ok(Err(error)) => {
                    return Err(InitialRouteAttemptError::Route {
                        retryable: error.is_retryable_carrier_failure(),
                        error: error.into(),
                    });
                }
                Err(_) => {
                    return Err(initial_route_timeout(&display_endpoint, timeout));
                }
            },
            _ = wait_for_shutdown(&mut shutdown) => {
                return Err(InitialRouteAttemptError::Fatal(anyhow!(
                    "remote client startup was cancelled"
                )));
            }
        };
        let route = group.description().to_string();
        let invitation = matches!(&self.options.auth, ClientAuthMode::Invitation { .. });
        let connection_timeout = if invitation { self.options.startup_timeout } else { timeout };
        let connection_deadline =
            if invitation { tokio::time::Instant::now() + connection_timeout } else { deadline };
        let reconnect_groups: Arc<dyn ReconnectGroupSource> =
            Arc::new(RuntimeReconnectGroups::with_shutdown(
                self.options.clone(),
                index,
                self.shutdown.clone(),
            ));
        let mut shutdown = self.shutdown.clone();
        let connection = tokio::select! {
            result = tokio::time::timeout_at(
                connection_deadline,
                ClientConnection::connect_with_reconnect_groups(
                    group.clone(),
                    ClientConnectionConfig {
                        identity: self.options.identity.clone(),
                        expected_daemon: self.options.expected_daemon,
                        auth: self.options.auth.clone(),
                        device_name: self.options.device_name.clone(),
                        session: self.options.session,
                        lane_policy: self.options.lane_policy,
                        limits: SessionLimits::default(),
                        reconnect: self.options.reconnect,
                    },
                    Some(reconnect_groups),
                ),
            ) => match result {
                Ok(connection) => connection,
                Err(_) => {
                    close_failed_initial_group(&group).await;
                    return Err(initial_route_timeout(&display_endpoint, connection_timeout));
                }
            },
            _ = wait_for_shutdown(&mut shutdown) => {
                close_failed_initial_group(&group).await;
                return Err(InitialRouteAttemptError::Fatal(anyhow!(
                    "remote client startup was cancelled"
                )));
            }
        };
        match connection {
            Ok(connection) => Ok((connection, route)),
            Err(error) if route_failure_allows_fallback(&error) => {
                close_failed_initial_group(&group).await;
                Err(InitialRouteAttemptError::Route {
                    retryable: error.is_retryable_carrier_failure(),
                    error: error.into(),
                })
            }
            Err(error) => {
                close_failed_initial_group(&group).await;
                Err(InitialRouteAttemptError::Fatal(error.into()))
            }
        }
    }
}

fn initial_route_timeout(endpoint: &str, timeout: Duration) -> InitialRouteAttemptError {
    InitialRouteAttemptError::Route {
        error: anyhow!("initial route {endpoint} timed out after {}ms", timeout.as_millis()),
        retryable: true,
    }
}

async fn close_failed_initial_group(group: &Arc<dyn LinkGroup>) {
    let _ = tokio::time::timeout(INITIAL_GROUP_CLOSE_TIMEOUT, group.close()).await;
}

async fn bootstrap_initial_ssh_route(
    endpoint: &Url,
    ssh: &SshProviderConfig,
    options: SshBootstrapOptions,
    upgrade: bool,
    shutdown: Option<watch::Receiver<bool>>,
) -> anyhow::Result<()> {
    let (destination, port) = ssh_bootstrap_destination(endpoint)?;
    let mut config = SshBootstrapConfig::defaults(destination);
    config.ssh_binary = ssh.ssh_binary.clone();
    config.port = port;
    config.remote_binary = ssh.remote_binary.clone();
    config.extra_args = ssh.extra_args.clone();
    config.auto_install = options.auto_install;
    config.timeout = options.attempt_timeout;
    let bootstrap = SshBootstrapper::new(config)?;
    tokio::select! {
        result = tokio::time::timeout(options.attempt_timeout, async {
            if upgrade {
                bootstrap.install_verified().await?;
                bootstrap
                    .stop_daemon(&ssh.remote_session, ssh.remote_state_dir.as_deref())
                    .await?;
            } else {
                bootstrap.ensure_installed().await?;
            }
            Ok::<(), BootstrapError>(())
        }) => {
            result.map_err(|_| BootstrapError::Timeout)??;
            Ok(())
        }
        () = wait_for_shutdown_request(shutdown) => Err(anyhow!("SSH bootstrap interrupted")),
    }
}

fn ssh_bootstrap_failure_is_retryable(error: &anyhow::Error) -> bool {
    error.downcast_ref::<BootstrapError>().is_some_and(BootstrapError::is_retryable_carrier_failure)
}

async fn wait_for_shutdown_request(mut shutdown: Option<watch::Receiver<bool>>) {
    loop {
        if crate::shutdown_requested()
            || shutdown.as_ref().is_some_and(|receiver| *receiver.borrow())
        {
            return;
        }
        if let Some(receiver) = &mut shutdown {
            tokio::select! {
                result = receiver.changed() => {
                    if result.is_err() {
                        shutdown = None;
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        } else {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

fn ssh_bootstrap_destination(endpoint: &Url) -> anyhow::Result<(String, Option<u16>)> {
    if endpoint.password().is_some() {
        return Err(anyhow!("passwords are not allowed in SSH URLs; use SSH authentication"));
    }
    if !matches!(endpoint.path(), "" | "/")
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
    {
        return Err(anyhow!("SSH routes cannot contain a path, query, or fragment"));
    }
    let host = match endpoint.host().ok_or_else(|| anyhow!("SSH endpoint is missing a host"))? {
        url::Host::Domain(host) => host.to_string(),
        url::Host::Ipv4(host) => host.to_string(),
        url::Host::Ipv6(host) => host.to_string(),
    };
    let username = endpoint.username();
    let destination = if username.is_empty() { host } else { format!("{username}@{host}") };
    if destination.starts_with('-') {
        return Err(anyhow!("SSH destination cannot begin with an option prefix"));
    }
    Ok((destination, endpoint.port()))
}

fn connect_request(
    candidate: &ResolvedRouteCandidate,
    session: SessionId,
    lane_policy: LanePolicy,
) -> anyhow::Result<ConnectRequest> {
    Ok(ConnectRequest {
        endpoint: normalize_carrier_endpoint(candidate.endpoint.clone())?,
        session,
        lane_policy,
        routing: candidate.routing.clone(),
    })
}

#[async_trait]
trait ReconnectRouteAttempt<T: Send>: Send + Sync {
    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
        auth: AuthKind,
    ) -> Result<T, ProviderError>;
}

async fn select_reconnect_route<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<(usize, T), ProviderError> {
    if routes.is_empty() {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    }
    let mut failures = Vec::new();
    for offset in 0..routes.len() {
        let index = (start + offset) % routes.len();
        if !routes[index].supports_client_auth(auth) {
            failures.push(format!(
                "{}: {}",
                sanitized_route(&routes[index].endpoint),
                ProviderError::UnsupportedClientAuth {
                    scheme: routes[index].endpoint.scheme().into(),
                    auth,
                }
            ));
            continue;
        }
        let request = connect_request(&routes[index], session, lane_policy)
            .map_err(|error| ProviderError::Configuration(error.to_string()))?;
        let endpoint = request.endpoint.clone();
        let display_endpoint = sanitized_route(&endpoint);
        match attempt.connect(index, request, auth).await {
            Ok(group) => return Ok((index, group)),
            Err(error) => {
                failures.push(format!("{display_endpoint}: {error}"));
                continue;
            }
        }
    }
    Err(ProviderError::Transport(format!(
        "all reconnect route providers failed: {}",
        failures.join("; ")
    )))
}

struct RuntimeReconnectGroups {
    options: ClientRuntimeOptions,
    next: AtomicUsize,
    prepared_ssh: Vec<AtomicBool>,
    shutdown: Option<watch::Receiver<bool>>,
}

impl RuntimeReconnectGroups {
    #[cfg(test)]
    fn new(options: ClientRuntimeOptions, selected_index: usize) -> Self {
        Self::new_inner(options, selected_index, None)
    }

    fn with_shutdown(
        options: ClientRuntimeOptions,
        selected_index: usize,
        shutdown: watch::Receiver<bool>,
    ) -> Self {
        Self::new_inner(options, selected_index, Some(shutdown))
    }

    fn new_inner(
        options: ClientRuntimeOptions,
        selected_index: usize,
        shutdown: Option<watch::Receiver<bool>>,
    ) -> Self {
        let selected_ssh = options
            .routes
            .get(selected_index)
            .is_some_and(|candidate| candidate.endpoint.scheme() == "ssh");
        let prepared_ssh = options
            .routes
            .iter()
            .enumerate()
            .map(|(index, _)| AtomicBool::new(selected_ssh && index == selected_index))
            .collect();
        Self {
            options,
            next: AtomicUsize::new(selected_index.saturating_add(1)),
            prepared_ssh,
            shutdown,
        }
    }

    fn unprepared_ssh_probe_count(&self) -> usize {
        let auth = followup_auth_kind(&self.options.auth);
        self.options
            .routes
            .iter()
            .enumerate()
            .filter(|(index, candidate)| {
                candidate.endpoint.scheme() == "ssh"
                    && candidate.supports_client_auth(auth)
                    && !self.prepared_ssh[*index].load(Ordering::Acquire)
            })
            .count()
    }
}

#[async_trait]
impl ReconnectGroupSource for RuntimeReconnectGroups {
    fn resolution_timeout(&self, reconnect_attempt_timeout: Duration) -> Duration {
        let auth = followup_auth_kind(&self.options.auth);
        let provider_attempts = u32::try_from(
            self.options
                .routes
                .iter()
                .filter(|candidate| candidate.supports_client_auth(auth))
                .count()
                .max(1),
        )
        .unwrap_or(u32::MAX);
        let ssh_bootstraps = u32::try_from(self.unprepared_ssh_probe_count()).unwrap_or(u32::MAX);
        reconnect_attempt_timeout.saturating_mul(provider_attempts).saturating_add(
            self.options.ssh_bootstrap.attempt_timeout.saturating_mul(ssh_bootstraps),
        )
    }

    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let count = self.options.routes.len();
        if count == 0 {
            return Err(ProviderError::Configuration("no reconnect routes configured".into()));
        }
        let attempt = RuntimeReconnectRouteAttempt {
            options: &self.options,
            prepared_ssh: &self.prepared_ssh,
            shutdown: self.shutdown.clone(),
        };
        let start = self.next.fetch_add(1, Ordering::Relaxed) % count;
        let (index, group) = select_reconnect_route(
            &self.options.routes,
            start,
            self.options.session,
            self.options.lane_policy,
            followup_auth_kind(&self.options.auth),
            &attempt,
        )
        .await?;
        self.next.store(index.saturating_add(1), Ordering::Relaxed);
        Ok(group)
    }
}

struct RuntimeReconnectRouteAttempt<'a> {
    options: &'a ClientRuntimeOptions,
    prepared_ssh: &'a [AtomicBool],
    shutdown: Option<watch::Receiver<bool>>,
}

#[async_trait]
impl ReconnectRouteAttempt<Arc<dyn LinkGroup>> for RuntimeReconnectRouteAttempt<'_> {
    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
        auth: AuthKind,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let endpoint = request.endpoint.clone();
        let display_endpoint = sanitized_route(&endpoint);
        if endpoint.scheme() == "ssh" && !self.prepared_ssh[index].load(Ordering::Acquire) {
            bootstrap_initial_ssh_route(
                &endpoint,
                &self.options.ssh,
                self.options.ssh_bootstrap,
                false,
                self.shutdown.clone(),
            )
            .await
            .map_err(|error| {
                ProviderError::Transport(format!(
                    "SSH bootstrap failed for reconnect route {display_endpoint}: {error:#}"
                ))
            })?;
            self.prepared_ssh[index].store(true, Ordering::Release);
        }
        tokio::time::timeout(
            self.options.reconnect.attempt_timeout,
            self.options.providers.connect(request, auth),
        )
        .await
        .map_err(|_| {
            ProviderError::Transport(format!(
                "reconnect route provider {display_endpoint} timed out after {}ms",
                self.options.reconnect.attempt_timeout.as_millis()
            ))
        })?
    }
}

fn client_auth_kind(auth: &ClientAuthMode) -> AuthKind {
    match auth {
        ClientAuthMode::Enrolled => AuthKind::Enrolled,
        ClientAuthMode::Invitation { .. } => AuthKind::Invitation,
        ClientAuthMode::Carrier => AuthKind::Carrier,
    }
}

fn followup_auth_kind(auth: &ClientAuthMode) -> AuthKind {
    match auth {
        ClientAuthMode::Invitation { .. } => AuthKind::Enrolled,
        other => client_auth_kind(other),
    }
}

fn route_failure_allows_fallback(error: &ConnectionError) -> bool {
    !matches!(
        error,
        ConnectionError::Crypto(
            CryptoError::Unauthorized(_) | CryptoError::DaemonKeyMismatch { .. }
        ) | ConnectionError::Protocol(_)
            | ConnectionError::GenerationExhausted
            | ConnectionError::Closed
    )
}

async fn wait_for_shutdown(shutdown: &mut watch::Receiver<bool>) {
    while !*shutdown.borrow() && shutdown.changed().await.is_ok() {}
}

async fn wait_for_fatal(fatal: &mut watch::Receiver<Option<String>>) -> String {
    loop {
        if let Some(message) = fatal.borrow().clone() {
            return message;
        }
        if fatal.changed().await.is_err() {
            return "service multiplexer stopped".into();
        }
    }
}

fn normalize_carrier_endpoint(mut endpoint: Url) -> anyhow::Result<Url> {
    if matches!(endpoint.scheme(), "ws" | "wss") && matches!(endpoint.path(), "" | "/") {
        endpoint.set_path("/v1/link");
    }
    Ok(endpoint)
}

#[cfg(test)]
async fn prepare_client_socket(path: &Path) -> anyhow::Result<ClientSocketPreparation> {
    prepare_client_socket_with_shutdown(path, None).await
}

async fn prepare_client_socket_with_shutdown(
    path: &Path,
    mut shutdown: Option<watch::Receiver<bool>>,
) -> anyhow::Result<ClientSocketPreparation> {
    if !unix_socket_path_fits(path) {
        return Err(anyhow!(
            "client socket path is too long for this platform: {}",
            path.display()
        ));
    }
    let parent = path.parent().ok_or_else(|| anyhow!("client socket path has no parent"))?;
    prepare_client_socket_directory(parent)?;
    let lock_path = client_socket_lock_path(path)?;
    let path_lock = acquire_client_socket_lock(&lock_path, shutdown.as_mut()).await?;

    use std::os::unix::fs::FileTypeExt;

    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error)
                .with_context(|| format!("could not inspect client socket {}", path.display()));
        }
        Ok(metadata) => {
            if !metadata.file_type().is_socket() {
                return Err(anyhow!(
                    "refusing to replace non-socket client path {}",
                    path.display()
                ));
            }
            match tokio::time::timeout(
                UNIX_SOCKET_PROBE_TIMEOUT,
                tokio::net::UnixStream::connect(path),
            )
            .await
            {
                Ok(Ok(_)) => return Err(anyhow!("another client owns {}", path.display())),
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                    remove_stale_client_socket(path, &metadata)?;
                }
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
                Ok(Err(error)) => {
                    return Err(error).with_context(|| {
                        format!("could not verify ownership of client socket {}", path.display())
                    });
                }
                Err(_) => {
                    return Err(anyhow!(
                        "timed out checking whether another client owns {}",
                        path.display()
                    ));
                }
            }
        }
    }
    Ok(ClientSocketPreparation { path: path.to_path_buf(), _lock: path_lock })
}

#[cfg(unix)]
fn remove_stale_client_socket(path: &Path, expected: &fs::Metadata) -> anyhow::Result<()> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};

    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error)
            .with_context(|| format!("could not recheck stale client socket {}", path.display())),
        Ok(current)
            if current.file_type().is_socket()
                && current.dev() == expected.dev()
                && current.ino() == expected.ino() =>
        {
            fs::remove_file(path)?;
            Ok(())
        }
        Ok(_) => {
            Err(anyhow!("client socket {} changed during stale-owner detection", path.display()))
        }
    }
}

#[cfg(unix)]
fn client_socket_lock_path(path: &Path) -> anyhow::Result<PathBuf> {
    let file_name =
        path.file_name().ok_or_else(|| anyhow!("client socket path has no file name"))?;
    let mut lock_name = file_name.to_os_string();
    lock_name.push(".lock");
    Ok(path.with_file_name(lock_name))
}

#[cfg(unix)]
async fn acquire_client_socket_lock(
    path: &Path,
    mut shutdown: Option<&mut watch::Receiver<bool>>,
) -> anyhow::Result<ClientSocketPathLock> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("could not open client socket lock {}", path.display()))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(anyhow!("client socket lock {} is not a regular file", path.display()));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(anyhow!(
            "client socket lock {} is not owned by the effective user",
            path.display()
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(anyhow!("client socket lock {} is accessible by another user", path.display()));
    }
    if metadata.nlink() != 1 {
        return Err(anyhow!("client socket lock {} has unexpected hard links", path.display()));
    }

    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(ClientSocketPathLock { file });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(error)
                .with_context(|| format!("could not lock client socket path {}", path.display()));
        }
        match shutdown.as_deref_mut() {
            Some(shutdown) => {
                tokio::select! {
                    _ = tokio::time::sleep(CLIENT_SOCKET_LOCK_RETRY) => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote client startup was cancelled"));
                    }
                }
            }
            None => tokio::time::sleep(CLIENT_SOCKET_LOCK_RETRY).await,
        }
    }
}

#[cfg(unix)]
fn prepare_client_socket_directory(path: &Path) -> anyhow::Result<()> {
    ensure_secure_directory(path, DirectoryAccess::OwnerControlled)?;
    let metadata = fs::symlink_metadata(path)?;
    validate_client_socket_directory(path, &metadata, unsafe { libc::geteuid() })
}

#[cfg(unix)]
fn validate_client_socket_directory(
    path: &Path,
    metadata: &fs::Metadata,
    effective_uid: u32,
) -> anyhow::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if metadata.file_type().is_symlink() {
        return Err(anyhow!("client socket directory {} must not be a symlink", path.display()));
    }
    if !metadata.is_dir() {
        return Err(anyhow!("client socket directory {} is not a directory", path.display()));
    }
    if metadata.uid() != effective_uid {
        return Err(anyhow!(
            "client socket directory {} is not owned by the effective user",
            path.display()
        ));
    }
    if metadata.permissions().mode() & 0o022 != 0 {
        return Err(anyhow!(
            "client socket directory {} is writable by another user",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn unix_socket_path_fits(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;

    let capacity = unsafe { std::mem::zeroed::<libc::sockaddr_un>() }.sun_path.len();
    path.as_os_str().as_bytes().len() < capacity
}

fn default_client_socket(state_dir: &Path, session: SessionId) -> PathBuf {
    let candidate = state_dir.join("connections").join(format!("{session:?}")).join("mux.sock");
    #[cfg(unix)]
    if !unix_socket_path_fits(&candidate) {
        let uid = unsafe { libc::geteuid() };
        let name =
            format!("{}.sock", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(session.0));
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        let fallback = runtime.join(format!("cmux-r-{uid}")).join(&name);
        if unix_socket_path_fits(&fallback) {
            return fallback;
        }
        return PathBuf::from(format!("/tmp/cmux-r-{uid}/{name}"));
    }
    candidate
}

pub fn daemon_paths(
    session: &str,
    state_override: Option<&Path>,
) -> anyhow::Result<(PathBuf, PathBuf, PathBuf)> {
    let root = match state_override {
        Some(path) => path.to_path_buf(),
        None => default_state_dir().ok_or_else(|| {
            anyhow!("cannot determine remote state directory; set CMUX_REMOTE_STATE_DIR")
        })?,
    };
    let encoded_session =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(session.as_bytes());
    let session_component = if encoded_session.len() <= MAX_DAEMON_SESSION_COMPONENT_BYTES {
        encoded_session
    } else {
        format!("sha256-{:x}", Sha256::digest(session.as_bytes()))
    };
    let state = root.join("sessions").join(session_component);
    let state_link = state.join("link.sock");
    let state_admin = state.join("admin.sock");
    if unix_socket_path_fits(&state_link) && unix_socket_path_fits(&state_admin) {
        return Ok((state, state_link, state_admin));
    }
    let (link, admin) = daemon_runtime_socket_paths(&state)?;
    Ok((state, link, admin))
}

#[cfg(unix)]
fn daemon_runtime_socket_paths(state: &Path) -> anyhow::Result<(PathBuf, PathBuf)> {
    use std::os::unix::ffi::OsStrExt;

    let digest = format!("{:x}", Sha256::digest(state.as_os_str().as_bytes()));
    let socket_names = |runtime: &Path| {
        (runtime.join(format!("{digest}-l.sock")), runtime.join(format!("{digest}-a.sock")))
    };
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("cmux-rd"))
    {
        let (link, admin) = socket_names(&runtime);
        if unix_socket_path_fits(&link)
            && unix_socket_path_fits(&admin)
            && ensure_secure_directory(&runtime, DirectoryAccess::ManagedOwnerOnly).is_ok()
        {
            return Ok((link, admin));
        }
    }

    let runtime = PathBuf::from(format!("/tmp/cmux-rd-{}", unsafe { libc::geteuid() }));
    ensure_secure_directory(&runtime, DirectoryAccess::ManagedOwnerOnly).with_context(|| {
        format!("could not create private remote daemon runtime directory {}", runtime.display())
    })?;
    let (link, admin) = socket_names(&runtime);
    if !unix_socket_path_fits(&link) || !unix_socket_path_fits(&admin) {
        return Err(anyhow!("remote daemon runtime socket path is too long for this platform"));
    }
    Ok((link, admin))
}

pub fn start_daemon_runtime(
    mux_socket: PathBuf,
    options: DaemonRuntimeOptions,
) -> anyhow::Result<DaemonRuntimeHandle> {
    start_daemon_runtime_with_timeout(mux_socket, options, DAEMON_STARTUP_TIMEOUT)
}

fn start_daemon_runtime_with_timeout(
    mux_socket: PathBuf,
    options: DaemonRuntimeOptions,
    startup_timeout: Duration,
) -> anyhow::Result<DaemonRuntimeHandle> {
    let (state_dir, default_link, default_admin) =
        daemon_paths(&options.session, options.state_dir.as_deref())?;
    let link_socket = options.link_socket.clone().unwrap_or(default_link);
    let admin_socket = options.admin_socket.clone().unwrap_or(default_admin);
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let owner_shutdown = shutdown_tx.clone();
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name(format!("cmux-remote-{}", options.session))
        .spawn(move || {
            let runtime = build_remote_runtime("cmux-remote-daemon-worker")?;
            let result = runtime.block_on(run_daemon(
                mux_socket,
                options,
                state_dir,
                link_socket,
                admin_socket,
                shutdown_rx,
                owner_shutdown,
                ready_tx,
            ));
            runtime.shutdown_timeout(REMOTE_RUNTIME_SHUTDOWN_TIMEOUT);
            result
        })
        .context("could not start remote daemon thread")?;

    let info = match ready_rx.recv_timeout(startup_timeout) {
        Ok(Ok(info)) => info,
        Ok(Err(error)) => {
            let _ = shutdown_tx.send(true);
            reap_failed_startup(thread, "cmux-remote-daemon");
            return Err(anyhow!(error));
        }
        Err(error) => {
            let _ = shutdown_tx.send(true);
            reap_failed_startup(thread, "cmux-remote-daemon");
            return Err(anyhow!("remote daemon did not become ready: {error}"));
        }
    };
    Ok(DaemonRuntimeHandle { info, shutdown: shutdown_tx, thread: Some(thread) })
}

#[allow(clippy::too_many_arguments)]
async fn run_daemon(
    mux_socket: PathBuf,
    options: DaemonRuntimeOptions,
    state_dir: PathBuf,
    link_socket: PathBuf,
    admin_socket: PathBuf,
    shutdown: watch::Receiver<bool>,
    owner_shutdown: watch::Sender<bool>,
    ready: mpsc::SyncSender<Result<DaemonRuntimeInfo, String>>,
) -> anyhow::Result<()> {
    let setup = async {
        let mut startup_shutdown = shutdown.clone();
        let auth_state_dir = state_dir.join("auth");
        let mut lifecycle_fenced = read_daemon_lifecycle_fence(&state_dir)
            .context(catalog().remote.verify_lifecycle_fence)?;
        if lifecycle_fenced {
            persist_daemon_lifecycle_fence(&state_dir)
                .context(catalog().remote.confirm_lifecycle_fence_durability)?;
        }
        let auth_state_preexisting =
            auth_state_dir.try_exists().context(catalog().remote.inspect_authorization_state)?;
        let auth_state_schema = auth_state_preexisting
            .then(|| persisted_auth_state_schema(&auth_state_dir))
            .transpose()
            .context(catalog().remote.inspect_authorization_schema)?;
        if matches!(auth_state_schema, Some(PersistedAuthStateSchema::Legacy))
            || matches!(auth_state_schema, Some(PersistedAuthStateSchema::Missing))
            || (lifecycle_fenced && !auth_state_preexisting)
        {
            return Err(anyhow!(catalog().remote.legacy_authorization_requires_migration));
        }
        let auth = load_daemon_auth_during_handoff(
            &auth_state_dir,
            &options.session,
            &mut startup_shutdown,
            DAEMON_AUTH_LEASE_RETRY_TIMEOUT,
        )
        .await?;
        // Version 2 authorization state is the rollback fence understood by
        // older binaries. Publish the lifecycle marker only after that state
        // is durable and while its exclusive lease is still held.
        if !auth_state_preexisting && !lifecycle_fenced {
            ensure_secure_directory(&state_dir, DirectoryAccess::OwnerControlled)
                .context(catalog().remote.prepare_lifecycle_state)?;
            #[cfg(test)]
            pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeLifecycleFence);
            persist_daemon_lifecycle_fence(&state_dir)?;
            lifecycle_fenced = true;
        }
        verify_previous_shutdown_outcome(&state_dir, lifecycle_fenced)?;
        if !lifecycle_fenced {
            persist_daemon_lifecycle_fence(&state_dir)?;
        }
        if *startup_shutdown.borrow() {
            return Err(anyhow!("remote daemon startup was cancelled"));
        }
        let (daemon, clients) = cmux_remote::daemon::RemoteDaemon::with_policy(
            auth.clone(),
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: options.resume_lease },
        )?;
        let workspace = WorkspaceService::new();

        let lifecycle_id = uuid::Uuid::new_v4().to_string();
        let preliminary_runtime = persist_runtime_info(
            &state_dir,
            &DaemonRuntimeInfo {
                session: options.session.clone(),
                state_dir: state_dir.clone(),
                link_socket: link_socket.clone(),
                admin_socket: admin_socket.clone(),
                daemon_fingerprint: auth.identity().fingerprint(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some(lifecycle_id.clone()),
                replaceable_sidecar: options.replaceable_sidecar,
            },
        );
        if let Err(error) = preliminary_runtime {
            if error.downcast_ref::<CommittedRuntimeInfoError>().is_some() {
                return finalize_daemon_authorization(auth, state_dir, lifecycle_id, vec![error])
                    .await;
            }
            return Err(error);
        }
        let transport_setup: anyhow::Result<_> = async {
            #[cfg(test)]
            pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeListenerStartup);
            let unix = serve_unix_with_shutdown(
                daemon.clone(),
                &link_socket,
                MAX_CARRIER_FRAME_BYTES,
                Some(owner_shutdown.clone()),
            )
            .await?;
            let websocket = match options.direct_websocket {
                Some(address) => Some(
                    serve_direct_websocket(
                        daemon.clone(),
                        address,
                        MAX_CARRIER_FRAME_BYTES,
                        options.allow_insecure_non_loopback,
                    )
                    .await?,
                ),
                None => None,
            };
            let workspace_http = match options.workspace_http {
                Some(address) => {
                    let server = serve_workspace_http(
                        workspace.clone(),
                        address,
                        state_dir.join("workspace-http.token"),
                    )
                    .await?;
                    crate::client_log::stderr_log!(
                        "remote",
                        "cmux-tui: authenticated workspace HTTP at http://{}; bearer token file {}",
                        server.local_addr(),
                        server.token_file().display()
                    );
                    Some(server)
                }
                None => None,
            };

            let mut relay_tasks = tokio::task::JoinSet::new();
            for relay in options.relays.iter().cloned() {
                let daemon = daemon.clone();
                relay_tasks.spawn(async move {
                    register_relay_daemon_with_credentials(
                        daemon,
                        RelayDaemonConfig {
                            endpoint: relay.endpoint,
                            slot: relay.slot,
                            ticket: String::new(),
                            maximum_frame_bytes: MAX_CARRIER_FRAME_BYTES,
                            control_timeout: Duration::from_secs(15),
                        },
                        relay.credentials,
                    )
                    .await
                });
            }
            let mut relays = Vec::with_capacity(options.relays.len());
            while !relay_tasks.is_empty() {
                let result = tokio::select! {
                    result = relay_tasks.join_next() => result,
                    _ = wait_for_shutdown(&mut startup_shutdown) => {
                        return Err(anyhow!("remote daemon startup was cancelled"));
                    }
                };
                let result = result.expect("a non-empty relay task set has a result");
                relays.push(result.context("relay registration task failed")??);
            }

            let iroh = match options.iroh {
                true => {
                    let config = IrohProviderConfig {
                        secret_key: Some(load_or_create_iroh_secret(&state_dir.join("iroh.key"))?),
                        ..IrohProviderConfig::default()
                    };
                    Some(tokio::select! {
                        result = IrohListener::bind(daemon.clone(), config) => result?,
                        _ = wait_for_shutdown(&mut startup_shutdown) => {
                            return Err(anyhow!("remote daemon startup was cancelled"));
                        }
                    })
                }
                false => None,
            };

            let mut routes = Vec::new();
            for route in &options.advertised_routes {
                push_unique_route(&mut routes, route.clone());
            }
            for relay in &options.relays {
                push_unique_route(&mut routes, relay.endpoint.to_string());
            }
            let mut unix_route = Url::parse("unix:///")?;
            unix_route.set_path(
                link_socket
                    .to_str()
                    .ok_or_else(|| anyhow!("remote link socket path is not valid UTF-8"))?,
            );
            let unix_route = unix_route.to_string();
            let websocket_route = if let Some(server) = &websocket {
                let address = server.local_addr();
                if !address.ip().is_unspecified() {
                    Some(format!("ws://{address}/v1/link"))
                } else {
                    None
                }
            } else {
                None
            };
            let iroh_node_id = if let Some(listener) = &iroh {
                let route = listener.route().await?;
                let hints = route.routing_hints();
                let mut route_url = Url::parse(&format!("iroh://{}", route.node_id()))?;
                {
                    let mut query = route_url.query_pairs_mut();
                    if let Some(relay) = hints.get(cmux_remote::provider::ROUTING_RELAY_URL) {
                        query.append_pair("relay_url", relay);
                    }
                    if let Some(addresses) = hints.get(cmux_remote::provider::ROUTING_DIRECT_ADDRS)
                    {
                        query.append_pair("direct_addrs", addresses);
                    }
                }
                push_unique_route(&mut routes, route_url.to_string());
                Some(route.node_id().to_string())
            } else {
                None
            };
            if let Some(route) = websocket_route {
                push_unique_route(&mut routes, route);
            }
            // Unix is fastest on the same host, and clients promote it when its
            // socket exists locally. Keeping it last avoids exporting a remote
            // host's filesystem path as the default route for mobile clients.
            push_unique_route(&mut routes, unix_route);

            let admin = serve_admin_with_shutdown(
                daemon,
                &admin_socket,
                routes.clone(),
                Some(lifecycle_id.clone()),
                Some(owner_shutdown),
            )
            .await?;
            let info = DaemonRuntimeInfo {
                session: options.session,
                state_dir: state_dir.clone(),
                link_socket: link_socket.clone(),
                admin_socket: admin_socket.clone(),
                daemon_fingerprint: auth.identity().fingerprint(),
                routes,
                direct_websocket: websocket.as_ref().map(|server| server.local_addr()),
                iroh_node_id,
                lifecycle_id: Some(lifecycle_id.clone()),
                replaceable_sidecar: options.replaceable_sidecar,
            };
            persist_runtime_info(&state_dir, &info)?;
            Ok((unix, websocket, workspace_http, relays, iroh, admin, info))
        }
        .await;
        let (unix, websocket, workspace_http, relays, iroh, admin, info) = match transport_setup {
            Ok(transports) => transports,
            Err(error) => {
                return finalize_daemon_authorization(auth, state_dir, lifecycle_id, vec![error])
                    .await;
            }
        };
        #[cfg(test)]
        pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeReadySend);
        let mut shutdown_failures = Vec::new();
        if ready.send(Ok(info)).is_ok() {
            let services = DaemonServices::new(workspace, Some(mux_socket));
            services.run_with_shutdown(clients, shutdown).await;
        } else {
            shutdown_failures.push(anyhow!("daemon owner stopped during startup"));
        }

        if let Err(error) = admin.shutdown().await {
            shutdown_failures
                .push(anyhow::Error::new(error).context("admin listener shutdown failed"));
        }
        if let Some(server) = workspace_http
            && let Err(error) = server.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("workspace HTTP shutdown failed"));
        }
        if let Some(listener) = iroh
            && let Err(error) = listener.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("Iroh listener shutdown failed"));
        }
        for registration in relays {
            shutdown_relay(registration).await;
        }
        if let Some(server) = websocket
            && let Err(error) = server.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("WebSocket server shutdown failed"));
        }
        if let Err(error) = unix.shutdown().await {
            shutdown_failures
                .push(anyhow::Error::new(error).context("Unix listener shutdown failed"));
        }
        finalize_daemon_authorization(auth, state_dir, lifecycle_id, shutdown_failures).await
    }
    .await;

    if let Err(error) = &setup {
        let _ = ready.send(Err(format!("{error:#}")));
    }
    setup
}

async fn load_daemon_auth_during_handoff(
    state_dir: &Path,
    daemon_name: &str,
    shutdown: &mut watch::Receiver<bool>,
    retry_timeout: Duration,
) -> anyhow::Result<Arc<AuthDatabase>> {
    let deadline = tokio::time::Instant::now() + retry_timeout;
    loop {
        match AuthDatabase::load_or_create(state_dir, daemon_name.to_owned(), true) {
            Ok(auth) => return Ok(auth),
            Err(IdentityError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if *shutdown.borrow() {
                    return Err(anyhow!("remote daemon startup was cancelled"));
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err(anyhow::Error::new(IdentityError::Io(error)).context(
                        "remote daemon authorization state is still owned by another process",
                    ));
                }
                tokio::select! {
                    _ = tokio::time::sleep(
                        DAEMON_AUTH_LEASE_RETRY_INTERVAL.min(remaining)
                    ) => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote daemon startup was cancelled"));
                    }
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn verify_previous_shutdown_outcome(
    state_dir: &Path,
    lifecycle_fenced: bool,
) -> anyhow::Result<()> {
    let previous_runtime = read_runtime_info(state_dir)
        .context(catalog().remote.verify_previous_lifecycle_metadata)?;
    let outcome =
        read_shutdown_outcome(state_dir).context(catalog().remote.verify_previous_finalization)?;

    if let Some(previous_runtime) = &previous_runtime {
        match previous_runtime.lifecycle_id.as_deref() {
            Some(expected_lifecycle_id) if !expected_lifecycle_id.is_empty() => {
                let outcome = outcome
                    .as_ref()
                    .ok_or_else(|| anyhow!(catalog().remote.modern_predecessor_missing_outcome))?;
                if outcome.lifecycle_id != expected_lifecycle_id {
                    return Err(anyhow!(catalog().remote.finalization_wrong_lifecycle));
                }
            }
            Some(_) => {
                return Err(anyhow!(catalog().remote.runtime_empty_lifecycle));
            }
            None => {
                return Err(anyhow!(catalog().remote.state_predates_lifecycle_fence));
            }
        }
    }

    if !lifecycle_fenced && previous_runtime.is_none() {
        // A stale successful outcome is insufficient: an older daemon can run
        // after that lifecycle and remove its own runtime metadata before its
        // final authorization write completes.
        return Err(anyhow!(catalog().remote.state_missing_lifecycle_fence));
    }

    match outcome.map(|outcome| outcome.status) {
        None | Some(DaemonShutdownStatus::Succeeded) => Ok(()),
        Some(DaemonShutdownStatus::Failed) => {
            Err(anyhow!(catalog().remote.previous_finalization_failed_ack))
        }
    }
}

fn combine_shutdown_failures(mut failures: Vec<anyhow::Error>) -> anyhow::Result<()> {
    match failures.len() {
        0 => Ok(()),
        1 => Err(failures.pop().expect("one shutdown failure is present")),
        _ => Err(anyhow!(
            "remote daemon shutdown encountered multiple failures: {}",
            failures.into_iter().map(|error| format!("{error:#}")).collect::<Vec<_>>().join("; ")
        )),
    }
}

async fn finish_daemon_shutdown(
    mut transport_failures: Vec<anyhow::Error>,
    authorization_finalization: impl Future<Output = Result<(), IdentityError>>,
) -> anyhow::Result<()> {
    if let Err(error) = authorization_finalization.await {
        transport_failures.push(
            anyhow::Error::new(error).context(catalog().remote.authorization_finalization_failed),
        );
    }
    combine_shutdown_failures(transport_failures)
}

async fn finalize_daemon_authorization(
    auth: Arc<AuthDatabase>,
    state_dir: PathBuf,
    lifecycle_id: String,
    transport_failures: Vec<anyhow::Error>,
) -> anyhow::Result<()> {
    let cleanup_state_dir = state_dir.clone();
    let authorization_finalization = auth.shutdown_with_cleanup(move |finalization| {
        #[cfg(test)]
        pause_daemon_cleanup(&cleanup_state_dir, DaemonCleanupPausePhase::BeforeAuthRelease);
        let status = if finalization.is_ok() {
            DaemonShutdownStatus::Succeeded
        } else {
            DaemonShutdownStatus::Failed
        };
        finalize_daemon_lifecycle(&cleanup_state_dir, &lifecycle_id, status)
    });
    let result = finish_daemon_shutdown(transport_failures, authorization_finalization).await;
    #[cfg(test)]
    pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::AfterAuthShutdown);
    result
}

fn push_unique_route(routes: &mut Vec<String>, route: String) {
    if !routes.iter().any(|existing| existing == &route) {
        routes.push(route);
    }
}

async fn shutdown_relay(registration: RelayDaemonRegistration) {
    registration.shutdown().await;
}

#[derive(Debug)]
struct CommittedRuntimeInfoError(IdentityError);

impl fmt::Display for CommittedRuntimeInfoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "remote runtime metadata was committed but durability confirmation failed: {}",
            self.0
        )
    }
}

impl std::error::Error for CommittedRuntimeInfoError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

fn persist_runtime_info(state_dir: &Path, info: &DaemonRuntimeInfo) -> anyhow::Result<()> {
    use std::io::Write as _;

    let mut persisted = info.clone();
    persisted.routes.clear();
    for route in &info.routes {
        let route = credential_free_route_hint(route)
            .map_err(|_| anyhow!("remote runtime route metadata is invalid"))?;
        push_unique_route(&mut persisted.routes, route);
    }

    let path = state_dir.join("runtime.json");
    let temporary =
        state_dir.join(format!(".runtime-{}-{}.json", std::process::id(), uuid::Uuid::new_v4()));
    let result: anyhow::Result<()> = (|| {
        let encoded = serde_json::to_vec_pretty(&persisted)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        fs::rename(&temporary, &path)?;
        if let Err(error) = sync_state_directory(state_dir) {
            return Err(anyhow::Error::new(CommittedRuntimeInfoError(error)));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn finalize_daemon_lifecycle(
    state_dir: &Path,
    lifecycle_id: &str,
    status: DaemonShutdownStatus,
) -> Result<(), IdentityError> {
    persist_shutdown_outcome(
        state_dir,
        &DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id: lifecycle_id.to_owned(),
            status,
        },
    )?;
    remove_owned_runtime_info(state_dir, lifecycle_id)
}

fn persist_shutdown_outcome(
    state_dir: &Path,
    outcome: &DaemonShutdownOutcome,
) -> Result<(), IdentityError> {
    use std::io::Write as _;

    let path = state_dir.join("shutdown.json");
    let temporary =
        state_dir.join(format!(".shutdown-{}-{}.json", std::process::id(), uuid::Uuid::new_v4()));
    let result = (|| {
        let encoded = serde_json::to_vec_pretty(outcome).map_err(IdentityError::Json)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(IdentityError::Io)?;
        file.write_all(&encoded).map_err(IdentityError::Io)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, &path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub(crate) fn persist_daemon_lifecycle_fence(state_dir: &Path) -> Result<(), IdentityError> {
    use std::io::Write as _;

    if read_daemon_lifecycle_fence(state_dir)? {
        // A prior attempt may have renamed the fence before its directory sync
        // failed, so visibility alone does not confirm durability.
        return sync_state_directory(state_dir);
    }
    let path = state_dir.join("lifecycle-fence.json");
    let temporary = state_dir.join(format!(
        ".lifecycle-fence-{}-{}.json",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let result = (|| {
        let encoded = serde_json::to_vec_pretty(&DaemonLifecycleFence {
            version: DAEMON_LIFECYCLE_FENCE_VERSION,
        })
        .map_err(IdentityError::Json)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(IdentityError::Io)?;
        file.write_all(&encoded).map_err(IdentityError::Io)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn remove_owned_runtime_info(state_dir: &Path, lifecycle_id: &str) -> Result<(), IdentityError> {
    let path = state_dir.join("runtime.json");
    let current = match fs::read(&path) {
        Ok(current) => current,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    let current: DaemonRuntimeInfo =
        serde_json::from_slice(&current).map_err(IdentityError::Json)?;
    if current.lifecycle_id.as_deref() != Some(lifecycle_id) {
        return Err(IdentityError::Invalid(
            "remote runtime lifecycle ownership changed during shutdown".into(),
        ));
    }
    match fs::remove_file(path) {
        Ok(()) => sync_state_directory(state_dir),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(IdentityError::Io(error)),
    }
}

fn sync_state_directory(path: &Path) -> Result<(), IdentityError> {
    #[cfg(unix)]
    {
        #[cfg(test)]
        {
            let mut failures = STATE_DIRECTORY_SYNC_FAILURES
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(index) = failures.iter().position(|(expected, _)| expected == path) {
                if failures[index].1 == 0 {
                    failures.swap_remove(index);
                    return Err(IdentityError::Io(std::io::Error::other(
                        "injected state-directory sync failure",
                    )));
                }
                failures[index].1 -= 1;
            }
        }
        fs::File::open(path).and_then(|directory| directory.sync_all()).map_err(IdentityError::Io)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

pub fn load_runtime_info(
    session: &str,
    state_override: Option<&Path>,
) -> anyhow::Result<DaemonRuntimeInfo> {
    let (state, _, _) = daemon_paths(session, state_override)?;
    let path = state.join("runtime.json");
    serde_json::from_slice(&fs::read(&path).with_context(|| {
        format!("remote daemon is not running for session {session:?} ({})", path.display())
    })?)
    .context("remote daemon runtime metadata is invalid")
}

fn read_runtime_info(state_dir: &Path) -> Result<Option<DaemonRuntimeInfo>, IdentityError> {
    let encoded = match fs::read(state_dir.join("runtime.json")) {
        Ok(encoded) => encoded,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    serde_json::from_slice(&encoded).map(Some).map_err(IdentityError::Json)
}

fn read_optional_file(path: &Path) -> Result<Option<Vec<u8>>, IdentityError> {
    match fs::read(path) {
        Ok(encoded) => Ok(Some(encoded)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(IdentityError::Io(error)),
    }
}

fn decode_shutdown_outcome(encoded: &[u8]) -> Result<DaemonShutdownOutcome, IdentityError> {
    let outcome: DaemonShutdownOutcome =
        serde_json::from_slice(encoded).map_err(IdentityError::Json)?;
    if outcome.version != DAEMON_SHUTDOWN_OUTCOME_VERSION {
        return Err(IdentityError::Invalid(format!(
            "remote daemon shutdown outcome version {} is unsupported",
            outcome.version
        )));
    }
    if outcome.lifecycle_id.is_empty() {
        return Err(IdentityError::Invalid(
            "remote daemon shutdown outcome has an empty lifecycle id".into(),
        ));
    }
    Ok(outcome)
}

fn read_daemon_lifecycle_fence(state_dir: &Path) -> Result<bool, IdentityError> {
    let Some(encoded) = read_optional_file(&state_dir.join("lifecycle-fence.json"))? else {
        return Ok(false);
    };
    let fence: DaemonLifecycleFence =
        serde_json::from_slice(&encoded).map_err(IdentityError::Json)?;
    if fence.version != DAEMON_LIFECYCLE_FENCE_VERSION {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_fence_version_unsupported(fence.version),
        ));
    }
    Ok(true)
}

pub(crate) fn inactive_daemon_needs_legacy_acknowledgement(
    state_dir: &Path,
) -> anyhow::Result<bool> {
    let auth_state_dir = state_dir.join("auth");
    let lifecycle_fenced =
        read_daemon_lifecycle_fence(state_dir).context(catalog().remote.verify_lifecycle_fence)?;
    if !auth_state_dir.try_exists().context(catalog().remote.inspect_authorization_state)? {
        return Ok(lifecycle_fenced);
    }
    let auth_schema = persisted_auth_state_schema(&auth_state_dir)
        .context(catalog().remote.inspect_authorization_schema)?;
    Ok(auth_schema != PersistedAuthStateSchema::Current || !lifecycle_fenced)
}

fn read_shutdown_outcome(state_dir: &Path) -> Result<Option<DaemonShutdownOutcome>, IdentityError> {
    let path = state_dir.join("shutdown.json");
    read_optional_file(&path)?.map(|encoded| decode_shutdown_outcome(&encoded)).transpose()
}

pub(crate) fn load_shutdown_outcome(state_dir: &Path) -> anyhow::Result<DaemonShutdownOutcome> {
    read_shutdown_outcome(state_dir)?
        .ok_or_else(|| {
            anyhow!(
                "remote daemon shutdown outcome is unavailable ({})",
                state_dir.join("shutdown.json").display()
            )
        })
        .context("remote daemon shutdown outcome is invalid")
}

#[cfg(unix)]
pub(crate) async fn complete_verified_daemon_stop(
    state_dir: &Path,
    daemon_name: &str,
) -> anyhow::Result<()> {
    let auth_state_dir = state_dir.join("auth");
    auth_state_dir.try_exists().context(catalog().remote.inspect_stopped_authorization_state)?;

    let auth = AuthDatabase::load_or_migrate_legacy(&auth_state_dir, daemon_name, true)
        .context(catalog().remote.acquire_stopped_authorization_lease)?;
    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        persist_daemon_lifecycle_fence(&cleanup_state_dir)
    })
    .await
    .context(catalog().remote.finalize_stopped_authorization_migration)
}

#[cfg(unix)]
pub(crate) async fn acknowledge_failed_shutdown_outcome(
    state_dir: &Path,
    daemon_name: &str,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let initial_runtime = read_optional_file(&runtime_path)
        .context(catalog().remote.snapshot_runtime_for_recovery)?;
    let initial_outcome = read_optional_file(&outcome_path)
        .context(catalog().remote.snapshot_finalization_for_recovery)?;
    let runtime = validate_failed_shutdown_recovery_evidence(&initial_runtime, &initial_outcome)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;

    let auth = AuthDatabase::load_or_migrate_legacy(state_dir.join("auth"), daemon_name, true)
        .context(catalog().remote.acquire_recovery_authorization_lease)?;

    let runtime_snapshot = read_optional_file(&runtime_path)
        .context(catalog().remote.resnapshot_runtime_for_recovery)?;
    let outcome_snapshot = read_optional_file(&outcome_path)
        .context(catalog().remote.resnapshot_finalization_for_recovery)?;
    if runtime_snapshot != initial_runtime || outcome_snapshot != initial_outcome {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_recovery));
    }
    let runtime = validate_failed_shutdown_recovery_evidence(&runtime_snapshot, &outcome_snapshot)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;

    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        remove_shutdown_recovery_evidence(&cleanup_state_dir, runtime_snapshot, outcome_snapshot)
    })
    .await
    .context(catalog().remote.complete_authorization_recovery)
}

fn validate_failed_shutdown_recovery_evidence(
    runtime_snapshot: &Option<Vec<u8>>,
    outcome_snapshot: &Option<Vec<u8>>,
) -> anyhow::Result<Option<DaemonRuntimeInfo>> {
    let runtime = runtime_snapshot
        .as_deref()
        .map(serde_json::from_slice::<DaemonRuntimeInfo>)
        .transpose()
        .context(catalog().remote.verify_runtime_for_recovery)?;

    if let Some(runtime) = &runtime {
        match runtime.lifecycle_id.as_deref() {
            Some(lifecycle_id) if !lifecycle_id.is_empty() => {}
            _ => {
                return Err(anyhow!(catalog().remote.refuse_failed_ack_with_legacy_runtime));
            }
        }
    } else {
        let encoded = outcome_snapshot
            .as_deref()
            .ok_or_else(|| anyhow!(catalog().remote.no_failed_finalization_recorded))?;
        if matches!(
            decode_shutdown_outcome(encoded),
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Succeeded, .. })
        ) {
            return Err(anyhow!(catalog().remote.finalization_succeeded_no_ack));
        }
    }
    Ok(runtime)
}

#[cfg(unix)]
pub(crate) async fn acknowledge_legacy_shutdown_state(
    state_dir: &Path,
    daemon_name: &str,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    let auth_state_dir = state_dir.join("auth");
    let auth_state_preexisting =
        auth_state_dir.try_exists().context(catalog().remote.inspect_legacy_authorization_state)?;
    let lifecycle_fenced =
        read_daemon_lifecycle_fence(state_dir).context(catalog().remote.verify_lifecycle_fence)?;
    if !auth_state_preexisting && !lifecycle_fenced {
        return Err(anyhow!(catalog().remote.no_legacy_authorization_state));
    }

    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let initial_runtime =
        read_optional_file(&runtime_path).context(catalog().remote.snapshot_legacy_runtime)?;
    let initial_outcome =
        read_optional_file(&outcome_path).context(catalog().remote.snapshot_legacy_shutdown)?;
    let runtime = validate_legacy_shutdown_evidence(&initial_runtime, &initial_outcome)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.legacy_finalization_label,
    )
    .await?;

    let auth = AuthDatabase::load_or_migrate_legacy(&auth_state_dir, daemon_name, true)
        .context(catalog().remote.acquire_legacy_recovery_authorization_lease)?;
    let runtime_snapshot =
        read_optional_file(&runtime_path).context(catalog().remote.resnapshot_legacy_runtime)?;
    let outcome_snapshot =
        read_optional_file(&outcome_path).context(catalog().remote.resnapshot_legacy_shutdown)?;
    if runtime_snapshot != initial_runtime || outcome_snapshot != initial_outcome {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_legacy_recovery));
    }
    let runtime = validate_legacy_shutdown_evidence(&runtime_snapshot, &outcome_snapshot)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.legacy_finalization_label,
    )
    .await?;

    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        finish_legacy_shutdown_recovery(&cleanup_state_dir, runtime_snapshot, outcome_snapshot)
    })
    .await
    .context(catalog().remote.complete_legacy_authorization_recovery)
}

#[cfg(unix)]
async fn verify_recovery_sockets_inactive(
    runtime: Option<&DaemonRuntimeInfo>,
    link_socket: &Path,
    admin_socket: &Path,
    finalization: &str,
) -> anyhow::Result<()> {
    let mut sockets = Vec::with_capacity(4);
    if let Some(runtime) = runtime {
        sockets.push(runtime.link_socket.as_path());
        sockets.push(runtime.admin_socket.as_path());
    }
    for socket in [link_socket, admin_socket] {
        if !sockets.contains(&socket) {
            sockets.push(socket);
        }
    }
    for socket in sockets {
        match bounded_unix_socket_connect(tokio::net::UnixStream::connect(socket)).await {
            Ok(_) => {
                return Err(anyhow!(
                    catalog()
                        .remote
                        .refuse_active_socket(finalization, &socket.display().to_string())
                ));
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    catalog().remote.verify_socket_inactive(&socket.display().to_string())
                });
            }
        }
    }
    Ok(())
}

#[cfg(unix)]
async fn bounded_unix_socket_connect<F, T>(connect: F) -> std::io::Result<T>
where
    F: Future<Output = std::io::Result<T>>,
{
    tokio::time::timeout(UNIX_SOCKET_PROBE_TIMEOUT, connect).await.map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "daemon Unix socket probe exceeded its deadline",
        )
    })?
}

fn validate_legacy_shutdown_evidence(
    runtime_snapshot: &Option<Vec<u8>>,
    outcome_snapshot: &Option<Vec<u8>>,
) -> anyhow::Result<Option<DaemonRuntimeInfo>> {
    // Explicit operator acknowledgement is the only recovery path for raw
    // metadata that cannot reveal its recorded sockets. The caller still
    // holds the authorization lease and probes the session's default sockets
    // before removing the unchanged byte snapshot.
    let runtime = runtime_snapshot
        .as_deref()
        .and_then(|encoded| serde_json::from_slice::<DaemonRuntimeInfo>(encoded).ok());
    let runtime_is_malformed = runtime_snapshot.is_some() && runtime.is_none();
    if runtime.as_ref().is_some_and(|runtime| runtime.lifecycle_id.is_some()) {
        return Err(anyhow!(catalog().remote.lifecycle_runtime_requires_failed_ack));
    }
    if !runtime_is_malformed && let Some(encoded) = outcome_snapshot {
        match decode_shutdown_outcome(encoded) {
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Succeeded, .. }) => {}
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Failed, .. }) | Err(_) => {
                return Err(anyhow!(catalog().remote.shutdown_evidence_requires_failed_ack));
            }
        }
    }
    Ok(runtime)
}

fn finish_legacy_shutdown_recovery(
    state_dir: &Path,
    expected_runtime: Option<Vec<u8>>,
    expected_outcome: Option<Vec<u8>>,
) -> Result<(), IdentityError> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    if read_optional_file(&runtime_path)? != expected_runtime
        || read_optional_file(&outcome_path)? != expected_outcome
    {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_evidence_changed_during_legacy_recovery.into(),
        ));
    }
    persist_daemon_lifecycle_fence(state_dir)?;
    if expected_runtime.is_some() {
        fs::remove_file(runtime_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    Ok(())
}

fn remove_shutdown_recovery_evidence(
    state_dir: &Path,
    expected_runtime: Option<Vec<u8>>,
    expected_outcome: Option<Vec<u8>>,
) -> Result<(), IdentityError> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    if read_optional_file(&runtime_path)? != expected_runtime
        || read_optional_file(&outcome_path)? != expected_outcome
    {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_evidence_changed_during_recovery.into(),
        ));
    }

    persist_daemon_lifecycle_fence(state_dir)?;
    if expected_runtime.is_some() {
        fs::remove_file(runtime_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    if expected_outcome.is_some() {
        fs::remove_file(outcome_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use cmux_remote::daemon::RemoteDaemon;

    use super::*;

    fn instrumented_test_timeout(timeout: Duration) -> Duration {
        let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|scale| *scale > 0)
            .unwrap_or(1);
        timeout.saturating_mul(scale)
    }

    fn resolved_test_route(
        route: &str,
        supported_auth: SupportedClientAuthModes,
    ) -> ResolvedRouteCandidate {
        resolved_test_route_with_routing(route, BTreeMap::new(), supported_auth)
    }

    fn resolved_test_route_with_routing(
        route: &str,
        routing: BTreeMap<String, String>,
        supported_auth: SupportedClientAuthModes,
    ) -> ResolvedRouteCandidate {
        ResolvedRouteCandidate::with_supported_client_auth_for_test(
            Url::parse(route).unwrap(),
            routing,
            supported_auth,
        )
    }

    fn test_route(route: &str) -> ResolvedRouteCandidate {
        let endpoint = Url::parse(route).unwrap();
        let supported_auth = if matches!(endpoint.scheme(), "ssh" | "unix") {
            SupportedClientAuthModes::DeviceOrCarrier
        } else {
            SupportedClientAuthModes::DeviceOnly
        };
        ResolvedRouteCandidate::with_supported_client_auth_for_test(
            endpoint,
            BTreeMap::new(),
            supported_auth,
        )
    }

    fn unix_test_route(path: &Path) -> Url {
        let mut endpoint = Url::parse("unix:///").unwrap();
        endpoint.set_path(path.to_str().unwrap());
        endpoint
    }

    #[tokio::test]
    async fn unmatched_relay_route_never_fetches_fallback_credentials() {
        let fetches = Arc::new(AtomicUsize::new(0));
        let credentials = RelayCredentialSource::callback({
            let fetches = Arc::clone(&fetches);
            move || {
                fetches.fetch_add(1, Ordering::SeqCst);
                async { Ok::<_, ()>("ticket".to_string()) }
            }
        });
        let provider = RoutedRelayProvider {
            routes: BTreeMap::from([(
                Url::parse("relay+ws://configured.example").unwrap().to_string(),
                RelayClientOptions { slot: "slot".into(), credentials },
            )]),
        };

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            provider.connect(ConnectRequest {
                endpoint: Url::parse("relay+ws://127.0.0.1:9").unwrap(),
                session: SessionId([88; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            }),
        )
        .await
        .expect("unmatched relay lookup reached a network timeout");

        assert!(matches!(result, Err(ProviderError::Configuration(_))));
        assert_eq!(fetches.load(Ordering::SeqCst), 0);
    }

    fn test_providers(ssh: SshProviderConfig) -> Arc<cmux_remote::provider::ProviderRegistry> {
        Arc::new(client_provider_registry(ssh, BTreeMap::new(), IrohPathMode::Auto).unwrap())
    }

    #[derive(Debug, PartialEq, Eq)]
    enum FakeInitialRouteEvent {
        Bootstrap { endpoint: String, upgrade: bool },
        Provider(ConnectRequest),
    }

    struct FakeInitialRouteAttempt {
        fail_ssh_bootstrap: bool,
        fail_provider_index: Option<usize>,
        events: Vec<FakeInitialRouteEvent>,
    }

    #[async_trait]
    impl InitialRouteAttempt<String> for FakeInitialRouteAttempt {
        async fn bootstrap_ssh(
            &mut self,
            endpoint: &Url,
            upgrade: bool,
        ) -> Result<(), InitialRouteAttemptError> {
            self.events
                .push(FakeInitialRouteEvent::Bootstrap { endpoint: endpoint.to_string(), upgrade });
            if self.fail_ssh_bootstrap {
                Err(InitialRouteAttemptError::Route {
                    error: anyhow!("fake SSH is unreachable"),
                    retryable: true,
                })
            } else {
                Ok(())
            }
        }

        async fn connect(
            &mut self,
            index: usize,
            request: ConnectRequest,
        ) -> Result<String, InitialRouteAttemptError> {
            let endpoint = request.endpoint.to_string();
            self.events.push(FakeInitialRouteEvent::Provider(request));
            if self.fail_provider_index == Some(index) {
                Err(InitialRouteAttemptError::Route {
                    error: anyhow!("fake provider is unreachable"),
                    retryable: true,
                })
            } else {
                Ok(endpoint)
            }
        }
    }

    struct TransientStartupProvider {
        calls: Arc<AtomicUsize>,
        transient_failures: usize,
        unix_path: PathBuf,
        unix: UnixProvider,
    }

    #[async_trait]
    impl TransportProvider for TransientStartupProvider {
        fn name(&self) -> &'static str {
            "transient-startup"
        }

        fn schemes(&self) -> &'static [&'static str] {
            &["transient-startup"]
        }

        fn supported_client_auth(&self) -> SupportedClientAuthModes {
            SupportedClientAuthModes::DeviceOrCarrier
        }

        async fn connect(
            &self,
            mut request: ConnectRequest,
        ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
            if self.calls.fetch_add(1, Ordering::AcqRel) < self.transient_failures {
                return Err(ProviderError::Link(cmux_remote::link::LinkError::Transport(
                    "transient startup carrier failure".into(),
                )));
            }
            let mut endpoint = Url::parse("unix:///").unwrap();
            endpoint.set_path(self.unix_path.to_str().unwrap());
            request.endpoint = endpoint;
            self.unix.connect(request).await
        }
    }

    struct HangingStartupProvider {
        calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl TransportProvider for HangingStartupProvider {
        fn name(&self) -> &'static str {
            "hanging-startup"
        }

        fn schemes(&self) -> &'static [&'static str] {
            &["hanging-startup"]
        }

        fn supported_client_auth(&self) -> SupportedClientAuthModes {
            SupportedClientAuthModes::DeviceOrCarrier
        }

        async fn connect(
            &self,
            _request: ConnectRequest,
        ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
            self.calls.fetch_add(1, Ordering::AcqRel);
            std::future::pending().await
        }
    }

    struct HangingOpenProvider {
        close_calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl TransportProvider for HangingOpenProvider {
        fn name(&self) -> &'static str {
            "hanging-open"
        }

        fn schemes(&self) -> &'static [&'static str] {
            &["hanging-open"]
        }

        fn supported_client_auth(&self) -> SupportedClientAuthModes {
            SupportedClientAuthModes::DeviceOrCarrier
        }

        async fn connect(
            &self,
            _request: ConnectRequest,
        ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
            Ok(Arc::new(HangingOpenGroup { close_calls: self.close_calls.clone() }))
        }
    }

    struct HangingOpenGroup {
        close_calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl LinkGroup for HangingOpenGroup {
        fn description(&self) -> &str {
            "hanging-open://daemon"
        }

        fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
            cmux_remote::provider::ProviderCapabilities::STREAM
        }

        fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
            &cmux_remote::provider::CarrierEvidence::None
        }

        async fn open(
            &self,
            _request: cmux_remote::provider::LinkRequest,
        ) -> Result<Box<dyn cmux_remote::link::FrameLink>, ProviderError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), ProviderError> {
            self.close_calls.fetch_add(1, Ordering::AcqRel);
            Ok(())
        }
    }

    #[derive(Default)]
    struct FakeReconnectRouteAttempt {
        requests: std::sync::Mutex<Vec<ConnectRequest>>,
    }

    #[async_trait]
    impl ReconnectRouteAttempt<String> for FakeReconnectRouteAttempt {
        async fn connect(
            &self,
            _index: usize,
            request: ConnectRequest,
            _auth: AuthKind,
        ) -> Result<String, ProviderError> {
            let endpoint = request.endpoint.to_string();
            self.requests.lock().unwrap().push(request);
            Ok(endpoint)
        }
    }

    struct RejectingReconnectRouteAttempt;

    #[async_trait]
    impl ReconnectRouteAttempt<String> for RejectingReconnectRouteAttempt {
        async fn connect(
            &self,
            _index: usize,
            _request: ConnectRequest,
            _auth: AuthKind,
        ) -> Result<String, ProviderError> {
            Err(ProviderError::Transport("fake provider is unreachable".into()))
        }
    }

    struct DebugEchoingReconnectRouteAttempt;

    #[async_trait]
    impl ReconnectRouteAttempt<String> for DebugEchoingReconnectRouteAttempt {
        async fn connect(
            &self,
            _index: usize,
            request: ConnectRequest,
            _auth: AuthKind,
        ) -> Result<String, ProviderError> {
            Err(ProviderError::Transport(format!("provider rejected {request:?}")))
        }
    }

    #[derive(Default)]
    struct AuthRecordingReconnectRouteAttempt {
        auth: std::sync::Mutex<Vec<AuthKind>>,
    }

    #[async_trait]
    impl ReconnectRouteAttempt<String> for AuthRecordingReconnectRouteAttempt {
        async fn connect(
            &self,
            _index: usize,
            request: ConnectRequest,
            auth: AuthKind,
        ) -> Result<String, ProviderError> {
            self.auth.lock().unwrap().push(auth);
            Ok(request.endpoint.to_string())
        }
    }

    #[tokio::test]
    async fn invitation_reconnect_dials_with_enrolled_auth() {
        let routes = vec![resolved_test_route(
            "wss://network.example/v1/link",
            SupportedClientAuthModes::DeviceOnly,
        )];
        let invitation = ClientAuthMode::Invitation {
            id: "invitation".into(),
            secret: zeroize::Zeroizing::new([17; 32]),
        };
        let attempt = AuthRecordingReconnectRouteAttempt::default();

        select_reconnect_route(
            &routes,
            0,
            SessionId([16; 16]),
            LanePolicy::Single,
            followup_auth_kind(&invitation),
            &attempt,
        )
        .await
        .unwrap();

        assert_eq!(attempt.auth.into_inner().unwrap(), [AuthKind::Enrolled]);
    }

    #[test]
    fn route_auth_capability_is_derived_from_the_local_provider_registry() {
        let providers = test_providers(SshProviderConfig::default());
        let candidate = ResolvedRouteCandidate::resolve(
            Url::parse(
                "wss://daemon.example/v1/link?client_auth=device-or-carrier#untrusted-claim",
            )
            .unwrap(),
            BTreeMap::new(),
            &providers,
        )
        .unwrap();

        assert_eq!(candidate.supported_client_auth(), SupportedClientAuthModes::DeviceOnly);
        for scheme in ["ws", "wss", "relay+ws", "relay+wss", "relay+https", "relay+do", "iroh"] {
            assert_eq!(
                providers.supported_client_auth(scheme).unwrap(),
                SupportedClientAuthModes::DeviceOnly,
                "{scheme}"
            );
        }
        assert_eq!(
            providers.supported_client_auth("ssh").unwrap(),
            SupportedClientAuthModes::DeviceOrCarrier
        );
        #[cfg(unix)]
        assert_eq!(
            providers.supported_client_auth("unix").unwrap(),
            SupportedClientAuthModes::DeviceOrCarrier
        );
    }

    #[tokio::test]
    async fn daemon_shutdown_finalizes_authorization_after_transport_failure() {
        let finalized = Arc::new(AtomicBool::new(false));
        let observed = finalized.clone();
        let result = finish_daemon_shutdown(
            vec![anyhow!("injected transport shutdown failure")],
            async move {
                observed.store(true, Ordering::SeqCst);
                Err(IdentityError::Invalid("injected authorization failure".into()))
            },
        )
        .await;

        assert!(finalized.load(Ordering::SeqCst));
        let error = result.expect_err("shutdown failures were discarded").to_string();
        assert!(error.contains("transport shutdown failure"), "{error}");
        assert!(error.contains("authorization finalization failed"), "{error}");
    }

    #[test]
    fn shutdown_recovery_preserves_lifecycle_evidence_when_its_snapshot_changes() {
        let directory = tempfile::tempdir().unwrap();
        let runtime_path = directory.path().join("runtime.json");
        let outcome_path = directory.path().join("shutdown.json");
        fs::write(&runtime_path, b"runtime-before").unwrap();
        fs::write(&outcome_path, b"outcome-before").unwrap();
        let runtime_snapshot = read_optional_file(&runtime_path).unwrap();
        let outcome_snapshot = read_optional_file(&outcome_path).unwrap();
        fs::write(&runtime_path, b"runtime-after").unwrap();

        let error =
            remove_shutdown_recovery_evidence(directory.path(), runtime_snapshot, outcome_snapshot)
                .expect_err("changed lifecycle evidence was removed");

        assert!(error.to_string().contains("changed"), "{error}");
        assert_eq!(fs::read(&runtime_path).unwrap(), b"runtime-after");
        assert_eq!(fs::read(&outcome_path).unwrap(), b"outcome-before");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_runtime_shutdown_removes_only_its_owned_lifecycle_paths() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "owned-shutdown".into(),
                state_dir: Some(directory.path().join("state")),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        let info = runtime.info().clone();
        let lifecycle_id =
            info.lifecycle_id.clone().expect("new daemon omitted its lifecycle identity");
        let metadata = info.state_dir.join("runtime.json");
        assert!(info.link_socket.exists());
        assert!(info.admin_socket.exists());
        assert!(metadata.exists());

        runtime.shutdown().unwrap();

        assert!(!info.link_socket.exists());
        assert!(!info.admin_socket.exists());
        assert!(!metadata.exists());
        assert_eq!(
            load_shutdown_outcome(&info.state_dir).unwrap(),
            DaemonShutdownOutcome {
                version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                lifecycle_id,
                status: DaemonShutdownStatus::Succeeded,
            }
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_refuses_failed_authorization_finalization() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "failed-predecessor";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        persist_shutdown_outcome(
            &state_dir,
            &DaemonShutdownOutcome {
                version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                lifecycle_id: "failed-predecessor".into(),
                status: DaemonShutdownStatus::Failed,
            },
        )
        .unwrap();

        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        );
        let error = match result {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("daemon started after failed authorization finalization");
            }
        };
        assert!(error.to_string().contains("authorization finalization"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_refuses_malformed_authorization_finalization() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "malformed-predecessor";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(state_dir.join("shutdown.json"), b"{not-json").unwrap();

        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        );
        let error = match result {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("daemon started after malformed authorization finalization");
            }
        };
        assert!(error.to_string().contains("authorization finalization"), "{error:#}");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_refuses_unfenced_legacy_state_after_runtime_cleanup() {
        for case in ["missing-outcome", "stale-success"] {
            let directory = tempfile::tempdir_in("/tmp").unwrap();
            let state_root = directory.path().join("state");
            let session = format!("unfenced-legacy-cleanup-{case}");
            let (state_dir, _, _) = daemon_paths(&session, Some(&state_root)).unwrap();
            drop(
                AuthDatabase::load_or_create(state_dir.join("auth"), &session, true)
                    .expect("could not seed legacy authorization state"),
            );
            if case == "stale-success" {
                persist_shutdown_outcome(
                    &state_dir,
                    &DaemonShutdownOutcome {
                        version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                        lifecycle_id: "earlier-modern-lifecycle".into(),
                        status: DaemonShutdownStatus::Succeeded,
                    },
                )
                .unwrap();
            }

            let result = start_daemon_runtime(
                directory.path().join("missing-mux.sock"),
                DaemonRuntimeOptions {
                    session,
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
            );
            let error = match result {
                Err(error) => error,
                Ok(runtime) => {
                    runtime.shutdown().unwrap();
                    panic!("{case}: daemon started without a lifecycle fence");
                }
            };
            assert!(error.to_string().contains("lifecycle fence"), "{case}: {error:#}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_does_not_treat_lifecycle_marker_as_an_auth_rollback_fence() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "marker-with-legacy-auth";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        let auth_state_dir = state_dir.join("auth");
        fs::create_dir_all(&auth_state_dir).unwrap();
        fs::write(
            auth_state_dir.join("devices.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "version": 1,
                "revision": 0,
                "revocation_generation": 0,
                "devices": [],
                "invitations": [],
            }))
            .unwrap(),
        )
        .unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        let error = match start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        ) {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("lifecycle marker bypassed authorization-state migration");
            }
        };

        assert!(error.to_string().contains("explicit migration"), "{error:#}");
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap(),
            Some(1),
            "rejected startup rewrote legacy authorization state"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_refuses_lifecycle_marker_without_authorization_state() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "marker-without-auth";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        let error = match start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        ) {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("lifecycle marker created missing authorization state");
            }
        };

        assert!(error.to_string().contains("explicit migration"), "{error:#}");
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            None,
            "rejected marker-only state created authorization state"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_refuses_lifecycle_fenced_lock_only_auth_initialization() {
        use std::os::unix::fs::OpenOptionsExt as _;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "reject-lock-only-auth";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        let auth_state_dir = state_dir.join("auth");
        fs::create_dir_all(&auth_state_dir).unwrap();
        OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(auth_state_dir.join("devices.json.lock"))
            .unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        let error = match start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        ) {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("lifecycle marker was trusted as an authorization rollback fence");
            }
        };

        assert!(error.to_string().contains("explicit migration"), "{error:#}");
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap(),
            None,
            "rejected startup created rollback-fenced authorization state"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_persists_auth_rollback_fence_before_lifecycle_marker() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "auth-fence-before-lifecycle-marker";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        let auth_state_dir = state_dir.join("auth");
        let mut pause = DaemonCleanupPauseHandle::install(
            state_dir,
            DaemonCleanupPausePhase::BeforeLifecycleFence,
        );

        let mux_socket = directory.path().join("missing-mux.sock");
        let startup = thread::spawn(move || {
            start_daemon_runtime(
                mux_socket,
                DaemonRuntimeOptions {
                    session: session.into(),
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
            )
        });

        pause.wait_until_reached();
        let auth_version =
            cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap();
        pause.resume();
        let runtime = startup.join().unwrap().unwrap();
        runtime.shutdown().unwrap();

        assert_eq!(
            auth_version,
            Some(cmux_remote::identity::AUTH_STATE_VERSION),
            "lifecycle marker publication preceded the versioned authorization rollback fence"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_resyncs_visible_fence_before_initializing_auth() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "resync-visible-fence";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o300)).unwrap();
        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        );
        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700)).unwrap();

        let error = match result {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("startup trusted a visible lifecycle fence without re-syncing it");
            }
        };
        assert!(error.to_string().contains("lifecycle fence"), "{error:#}");
        assert!(
            !state_dir.join("auth").exists(),
            "startup initialized authorization state before confirming fence durability"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_does_not_publish_marker_without_auth_rollback_fence() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "fence-before-auth-failure";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        symlink("missing-auth-target", state_dir.join("auth")).unwrap();

        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        );

        assert!(result.is_err(), "daemon accepted a dangling authorization-state symlink");
        assert!(
            !read_daemon_lifecycle_fence(&state_dir).unwrap(),
            "auth initialization failure left a marker that older binaries ignore"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_migrates_verified_modern_state_to_a_lifecycle_fence() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "migrate-modern-lifecycle";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(&state_root)).unwrap();
        drop(
            AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
                .expect("could not seed authorization state"),
        );
        persist_runtime_info(
            &state_dir,
            &DaemonRuntimeInfo {
                session: session.into(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "completed-modern-daemon".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some("completed-modern-lifecycle".into()),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        persist_shutdown_outcome(
            &state_dir,
            &DaemonShutdownOutcome {
                version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                lifecycle_id: "completed-modern-lifecycle".into(),
                status: DaemonShutdownStatus::Succeeded,
            },
        )
        .unwrap();

        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .expect("verified modern state did not migrate");

        assert!(read_daemon_lifecycle_fence(&state_dir).unwrap());
        runtime.shutdown().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn existing_lifecycle_fence_retry_resyncs_parent_directory() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_dir = directory.path().join("state");
        fs::create_dir_all(&state_dir).unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o100)).unwrap();
        let result = persist_daemon_lifecycle_fence(&state_dir);
        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700)).unwrap();

        let error = result.expect_err("existing lifecycle fence skipped its directory sync");
        assert!(
            matches!(
                error,
                IdentityError::Io(ref error)
                    if error.kind() == std::io::ErrorKind::PermissionDenied
            ),
            "{error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn lifecycle_fence_allows_retry_before_runtime_metadata_is_published() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "fenced-startup-retry";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        drop(
            AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
                .expect("could not seed authorization state"),
        );
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .expect("lifecycle-fenced startup retry was rejected");

        runtime.shutdown().unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn legacy_recovery_makes_marker_only_state_safe_to_restart() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "recover-marker-only-state";
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        persist_daemon_lifecycle_fence(&state_dir).unwrap();

        assert!(inactive_daemon_needs_legacy_acknowledgement(&state_dir).unwrap());
        acknowledge_legacy_shutdown_state(&state_dir, session, &link_socket, &admin_socket)
            .await
            .unwrap();
        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            Some(cmux_remote::identity::AUTH_STATE_VERSION)
        );
        assert!(!inactive_daemon_needs_legacy_acknowledgement(&state_dir).unwrap());

        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .expect("explicit marker-only recovery did not make startup safe");
        runtime.shutdown().unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn verified_stop_creates_current_authorization_when_state_is_missing() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_dir = directory.path().join("missing-state");

        complete_verified_daemon_stop(&state_dir, "verified-missing-state")
            .await
            .expect("verified stop did not initialize rollback-fenced authorization state");

        assert_eq!(
            cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
            Some(cmux_remote::identity::AUTH_STATE_VERSION)
        );
        assert!(read_daemon_lifecycle_fence(&state_dir).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_requires_exact_modern_predecessor_authorization_finalization() {
        for (case, outcome_lifecycle) in [("missing", None), ("stale", Some("different-lifecycle"))]
        {
            let directory = tempfile::tempdir_in("/tmp").unwrap();
            let state_root = directory.path().join("state");
            let session = format!("modern-predecessor-{case}");
            let (state_dir, link_socket, admin_socket) =
                daemon_paths(&session, Some(&state_root)).unwrap();
            fs::create_dir_all(&state_dir).unwrap();
            persist_runtime_info(
                &state_dir,
                &DaemonRuntimeInfo {
                    session: session.clone(),
                    state_dir: state_dir.clone(),
                    link_socket,
                    admin_socket,
                    daemon_fingerprint: "predecessor".into(),
                    routes: Vec::new(),
                    direct_websocket: None,
                    iroh_node_id: None,
                    lifecycle_id: Some("expected-lifecycle".into()),
                    replaceable_sidecar: true,
                },
            )
            .unwrap();
            if let Some(lifecycle_id) = outcome_lifecycle {
                persist_shutdown_outcome(
                    &state_dir,
                    &DaemonShutdownOutcome {
                        version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                        lifecycle_id: lifecycle_id.into(),
                        status: DaemonShutdownStatus::Succeeded,
                    },
                )
                .unwrap();
            }

            let result = start_daemon_runtime(
                directory.path().join("missing-mux.sock"),
                DaemonRuntimeOptions {
                    session,
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
            );
            let error = match result {
                Err(error) => error,
                Ok(runtime) => {
                    runtime.shutdown().unwrap();
                    panic!("daemon started with {case} predecessor finalization evidence");
                }
            };
            assert!(error.to_string().contains("authorization finalization"), "{case}: {error:#}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn daemon_persists_active_lifecycle_before_opening_listener() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "active-before-listener";
        let (state_dir, link_socket, _) = daemon_paths(session, Some(&state_root)).unwrap();
        let mut pause = DaemonCleanupPauseHandle::install(
            state_dir.clone(),
            DaemonCleanupPausePhase::BeforeListenerStartup,
        );
        let mux_socket = directory.path().join("missing-mux.sock");
        let caller = thread::spawn(move || {
            start_daemon_runtime(
                mux_socket,
                DaemonRuntimeOptions {
                    session: session.into(),
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
            )
        });
        pause.wait_until_reached();

        let active = read_runtime_info(&state_dir).unwrap();
        let listener_opened = link_socket.exists();
        pause.resume();
        let runtime = caller.join().unwrap().unwrap();
        let final_lifecycle_id =
            runtime.info().lifecycle_id.clone().expect("ready daemon omitted its lifecycle id");
        runtime.shutdown().unwrap();

        assert!(!listener_opened, "link listener opened before the lifecycle checkpoint");
        let active = active.expect("active lifecycle was not persisted before listener startup");
        assert_eq!(active.lifecycle_id.as_deref(), Some(final_lifecycle_id.as_str()));
    }

    #[cfg(unix)]
    #[test]
    fn daemon_runtime_metadata_remains_until_auth_finalization() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "durable-cleanup".into(),
                state_dir: Some(directory.path().join("state")),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        let state_dir = runtime.info().state_dir.clone();
        let lifecycle_id =
            runtime.info().lifecycle_id.clone().expect("new daemon omitted its lifecycle identity");
        let metadata = state_dir.join("runtime.json");
        let outcome = state_dir.join("shutdown.json");
        let mut pause = DaemonCleanupPauseHandle::install(
            state_dir.clone(),
            DaemonCleanupPausePhase::BeforeAuthRelease,
        );
        let shutdown = thread::spawn(move || runtime.shutdown());
        pause.wait_until_reached();

        assert!(
            metadata.exists(),
            "daemon published lifecycle completion before auth finalization"
        );
        assert!(!outcome.exists(), "daemon published its outcome before auth finalization");
        pause.resume();
        shutdown.join().unwrap().unwrap();
        assert!(!metadata.exists());
        assert_eq!(load_shutdown_outcome(&state_dir).unwrap().lifecycle_id, lifecycle_id);
    }

    #[cfg(unix)]
    #[test]
    fn exiting_daemon_never_removes_successor_runtime_metadata() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "successor-metadata".into(),
                state_dir: Some(directory.path().join("state")),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        let info = runtime.info().clone();
        let mut pause = DaemonCleanupPauseHandle::install(
            info.state_dir.clone(),
            DaemonCleanupPausePhase::AfterAuthShutdown,
        );

        let unrelated_directory = tempfile::tempdir_in("/tmp").unwrap();
        let unrelated = start_daemon_runtime(
            unrelated_directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "unrelated-cleanup".into(),
                state_dir: Some(unrelated_directory.path().join("state")),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        let unrelated_shutdown = thread::spawn(move || unrelated.shutdown());
        pause.assert_not_reached_before(&unrelated_shutdown);
        unrelated_shutdown.join().unwrap().unwrap();

        let shutdown = thread::spawn(move || runtime.shutdown());
        pause.wait_until_reached();

        let successor =
            AuthDatabase::load_or_create(info.state_dir.join("auth"), "successor", true)
                .expect("predecessor retained its authorization state lease after shutdown");
        let metadata = info.state_dir.join("runtime.json");
        fs::write(&metadata, b"successor-runtime").unwrap();
        pause.resume();
        shutdown.join().unwrap().unwrap();

        assert_eq!(fs::read(&metadata).unwrap(), b"successor-runtime");
        drop(successor);
    }

    #[cfg(unix)]
    #[test]
    fn daemon_runtime_rejects_an_intermediate_state_symlink_before_creating_state() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "symlinked-state".into(),
                state_dir: Some(alias),
                link_socket: Some(directory.path().join("sockets/link.sock")),
                admin_socket: Some(directory.path().join("sockets/admin.sock")),
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        );
        if let Ok(runtime) = result {
            runtime.shutdown().unwrap();
            panic!("intermediate state symlink was accepted");
        }
        assert!(!target.join("sessions").exists());
    }

    #[cfg(unix)]
    #[test]
    fn client_startup_timeout_returns_while_the_socket_path_lock_is_held() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let daemon_root = directory.path().join("daemon");
        let daemon = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "client-startup-lock".into(),
                state_dir: Some(daemon_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        let providers = test_providers(SshProviderConfig::default());
        let route = ResolvedRouteCandidate::resolve(
            unix_test_route(&daemon.info().link_socket),
            BTreeMap::new(),
            &providers,
        )
        .unwrap();
        let local_socket = directory.path().join("client/mux.sock");
        fs::create_dir_all(local_socket.parent().unwrap()).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(client_socket_lock_path(&local_socket).unwrap())
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

        let ssh = SshProviderConfig::default();
        let client_state = directory.path().join("client-state");
        let (done_tx, done_rx) = mpsc::sync_channel(1);
        let caller = thread::spawn(move || {
            let result = start_client_runtime(ClientRuntimeOptions {
                routes: vec![route],
                providers,
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "client-startup-lock-test".into(),
                session: SessionId([31; 16]),
                lane_policy: LanePolicy::Single,
                reconnect: ReconnectPolicy {
                    maximum_attempts: Some(1),
                    heartbeat_interval: None,
                    ..ReconnectPolicy::default()
                },
                startup_timeout: Duration::from_millis(100),
                state_dir: client_state,
                local_socket: Some(local_socket),
                ssh,
                ssh_bootstrap: SshBootstrapOptions {
                    auto_install: false,
                    upgrade: false,
                    attempt_timeout: Duration::from_secs(1),
                },
            });
            let _ = done_tx.send(result.map(|runtime| runtime.shutdown()));
        });

        let completed_while_locked = done_rx.recv_timeout(Duration::from_millis(500)).is_ok();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        if !completed_while_locked {
            done_rx
                .recv_timeout(Duration::from_secs(3))
                .expect("client startup stayed blocked after releasing the socket lock")
                .unwrap_err();
        }
        caller.join().unwrap();
        daemon.shutdown().unwrap();

        assert!(
            completed_while_locked,
            "client startup timeout joined a worker blocked on the socket path lock"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_timeout_returns_while_the_identity_path_lock_is_held() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let (session_state, link_socket, _) =
            daemon_paths("daemon-startup-lock", Some(&state_root)).unwrap();
        let auth_state = session_state.join("auth");
        fs::create_dir_all(&auth_state).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(auth_state.join("identity.json.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

        let mux_socket = directory.path().join("missing-mux.sock");
        let (done_tx, done_rx) = mpsc::sync_channel(1);
        let caller = thread::spawn(move || {
            let result = start_daemon_runtime_with_timeout(
                mux_socket,
                DaemonRuntimeOptions {
                    session: "daemon-startup-lock".into(),
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
                Duration::from_millis(100),
            );
            let _ = done_tx.send(result.map(|runtime| runtime.shutdown()));
        });

        let completed_while_locked = done_rx.recv_timeout(Duration::from_millis(500)).is_ok();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        if !completed_while_locked {
            done_rx
                .recv_timeout(Duration::from_secs(3))
                .expect("daemon startup stayed blocked after releasing the identity lock")
                .unwrap_err();
        }
        caller.join().unwrap();
        let cleanup_deadline = std::time::Instant::now() + Duration::from_secs(3);
        while link_socket.exists() && std::time::Instant::now() < cleanup_deadline {
            thread::sleep(Duration::from_millis(10));
        }

        assert!(
            completed_while_locked,
            "daemon startup timeout joined a worker blocked on the identity path lock"
        );
        assert!(!link_socket.exists(), "timed-out daemon left its link socket behind");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_finalizes_lifecycle_when_ready_receiver_disappears() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "ready-receiver-disappears";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        let mut pause = DaemonCleanupPauseHandle::install(
            state_dir.clone(),
            DaemonCleanupPausePhase::BeforeReadySend,
        );
        let mux_socket = directory.path().join("missing-mux.sock");
        let caller = thread::spawn(move || {
            start_daemon_runtime_with_timeout(
                mux_socket,
                DaemonRuntimeOptions {
                    session: session.into(),
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
                Duration::from_millis(500),
            )
        });
        pause.wait_until_reached();

        let lifecycle_id = read_runtime_info(&state_dir)
            .unwrap()
            .expect("starting daemon did not persist runtime metadata")
            .lifecycle_id
            .expect("starting daemon omitted its lifecycle id");
        let startup = caller.join().unwrap();
        let error = match startup {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("paused daemon became ready after its owner timed out");
            }
        };
        assert!(error.to_string().contains("did not become ready"), "{error:#}");
        pause.resume();

        let runtime_path = state_dir.join("runtime.json");
        let outcome_path = state_dir.join("shutdown.json");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while (runtime_path.exists() || !outcome_path.exists())
            && std::time::Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }

        assert!(!runtime_path.exists(), "orphaned startup retained active runtime metadata");
        let outcome = load_shutdown_outcome(&state_dir)
            .expect("orphaned startup did not publish authorization finalization");
        assert_eq!(outcome.lifecycle_id, lifecycle_id);
        assert_eq!(outcome.status, DaemonShutdownStatus::Succeeded);
    }

    #[cfg(unix)]
    #[test]
    fn daemon_startup_retries_a_predecessors_auth_state_lease() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let (session_state, _, _) =
            daemon_paths("daemon-handoff-retry", Some(&state_root)).unwrap();
        let auth_state = session_state.join("auth");
        drop(
            AuthDatabase::load_or_create(&auth_state, "daemon-handoff-retry", true)
                .expect("could not seed current authorization state"),
        );
        persist_daemon_lifecycle_fence(&session_state).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(auth_state.join("devices.json.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

        let mux_socket = directory.path().join("missing-mux.sock");
        let (done_tx, done_rx) = mpsc::sync_channel(1);
        let caller = thread::spawn(move || {
            let result = start_daemon_runtime_with_timeout(
                mux_socket,
                DaemonRuntimeOptions {
                    session: "daemon-handoff-retry".into(),
                    state_dir: Some(state_root),
                    link_socket: None,
                    admin_socket: None,
                    direct_websocket: None,
                    allow_insecure_non_loopback: false,
                    workspace_http: None,
                    relays: Vec::new(),
                    iroh: false,
                    advertised_routes: Vec::new(),
                    resume_lease: Duration::from_secs(2),
                    replaceable_sidecar: true,
                },
                Duration::from_secs(3),
            );
            let _ = done_tx.send(result.map(DaemonRuntimeHandle::shutdown));
        });

        let early = done_rx.recv_timeout(Duration::from_millis(200));
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        let finished_while_locked = early.is_ok();
        let result = match early {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => done_rx
                .recv_timeout(Duration::from_secs(3))
                .expect("daemon startup did not finish after its predecessor released state"),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                panic!("daemon startup caller disconnected")
            }
        };
        caller.join().unwrap();

        assert!(
            !finished_while_locked,
            "daemon startup failed instead of waiting for its predecessor's state lease"
        );
        result
            .expect("daemon startup failed after its predecessor released state")
            .expect("daemon shutdown failed after a successful handoff");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn daemon_auth_handoff_retry_stops_at_its_deadline() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir().unwrap();
        let auth_state = directory.path().join("auth");
        fs::create_dir_all(&auth_state).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(auth_state.join("devices.json.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        let (_shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let started = tokio::time::Instant::now();

        let error = load_daemon_auth_during_handoff(
            &auth_state,
            "bounded-handoff",
            &mut shutdown_rx,
            Duration::from_millis(50),
        )
        .await
        .unwrap_err()
        .to_string();

        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        assert!(error.contains("still owned"), "{error}");
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "authorization state handoff retry exceeded its deadline"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn daemon_auth_handoff_retry_observes_startup_cancellation() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir().unwrap();
        let auth_state = directory.path().join("auth");
        fs::create_dir_all(&auth_state).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(auth_state.join("devices.json.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let retry = tokio::spawn(async move {
            load_daemon_auth_during_handoff(
                &auth_state,
                "cancelled-handoff",
                &mut shutdown_rx,
                Duration::from_secs(5),
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(!retry.is_finished(), "authorization state handoff did not retry");

        shutdown_tx.send_replace(true);
        let error = tokio::time::timeout(Duration::from_secs(1), retry)
            .await
            .expect("authorization state handoff ignored startup cancellation")
            .unwrap()
            .unwrap_err()
            .to_string();

        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        assert!(error.contains("cancelled"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_paths_bound_session_components_and_unix_socket_names() {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root =
            PathBuf::from("/tmp").join("long-root-a".repeat(6)).join("long-root-b".repeat(6));
        let session = "long-session".repeat(128);
        let first = daemon_paths(&session, Some(&root)).unwrap();
        let second = daemon_paths(&session, Some(&root)).unwrap();

        assert_eq!(first, second, "daemon path fallback was not deterministic");
        assert!(first.0.starts_with(root.join("sessions")));
        assert!(
            first.0.file_name().unwrap().as_bytes().len() <= 255,
            "encoded session exceeded NAME_MAX: {}",
            first.0.display()
        );
        assert!(
            unix_socket_path_fits(&first.1),
            "link socket path was too long: {}",
            first.1.display()
        );
        assert!(
            unix_socket_path_fits(&first.2),
            "admin socket path was too long: {}",
            first.2.display()
        );
        assert_ne!(first.1, first.2);
        for parent in [first.1.parent().unwrap(), first.2.parent().unwrap()] {
            let metadata = fs::symlink_metadata(parent).unwrap();
            assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
            assert_eq!(metadata.permissions().mode() & 0o077, 0);
        }
    }

    #[test]
    fn runtime_route_debug_redacts_raw_urls_slots_and_routing_hints() {
        let candidate = resolved_test_route_with_routing(
            "wss://candidate-user-marker:candidate-password-marker@candidate.example/\
             candidate-path-marker?ticket=candidate-query-marker#candidate-fragment-marker",
            BTreeMap::from([
                (
                    cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                    "direct-hint-marker:4242".into(),
                ),
                (
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://hint-user-marker:hint-password-marker@hint.example/\
                     hint-path-marker?ticket=hint-query-marker#hint-fragment-marker"
                        .into(),
                ),
            ]),
            SupportedClientAuthModes::DeviceOnly,
        );
        let relay_options = RelayDaemonOptions {
            endpoint: Url::parse(
                "relay+wss://daemon-user-marker:daemon-password-marker@daemon.example/\
                 daemon-path-marker?ticket=daemon-query-marker#daemon-fragment-marker",
            )
            .unwrap(),
            slot: "daemon-slot-marker".into(),
            credentials: RelayCredentialSource::static_ticket("daemon-ticket-marker").unwrap(),
        };
        let routed_provider = RoutedRelayProvider {
            routes: BTreeMap::from([(
                "relay+wss://map-user-marker:map-password-marker@map.example/\
                 map-path-marker?ticket=map-query-marker#map-fragment-marker"
                    .into(),
                RelayClientOptions {
                    slot: "route-slot-marker".into(),
                    credentials: RelayCredentialSource::static_ticket("route-ticket-marker")
                        .unwrap(),
                },
            )]),
        };
        let daemon_options = DaemonRuntimeOptions {
            session: "debug-control".into(),
            state_dir: None,
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            workspace_http: None,
            relays: vec![relay_options],
            iroh: false,
            advertised_routes: vec!["%%% malformed-route-marker %%%".into()],
            resume_lease: Duration::from_secs(1),
            replaceable_sidecar: false,
        };
        let daemon_info = DaemonRuntimeInfo {
            session: "debug-control".into(),
            state_dir: PathBuf::from("/tmp/state"),
            link_socket: PathBuf::from("/tmp/link"),
            admin_socket: PathBuf::from("/tmp/admin"),
            daemon_fingerprint: "public-fingerprint".into(),
            routes: vec!["%%% malformed-info-route-marker %%%".into()],
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: None,
            replaceable_sidecar: false,
        };
        let client_options = reconnect_test_options(vec![candidate.clone()]);
        let client_info = ClientRuntimeInfo {
            local_socket: PathBuf::from("/tmp/client"),
            daemon_public_key: [7; 32],
            route: "wss://client-info-user-marker:client-info-password-marker@client-info.example/\
                    client-info-path-marker?ticket=client-info-query-marker#\
                    client-info-fragment-marker"
                .into(),
        };

        let diagnostic = format!(
            "candidate={candidate:?} provider={routed_provider:?} \
             daemon_options={daemon_options:?} daemon_info={daemon_info:?} \
             client_options={client_options:?} client_info={client_info:?}"
        );

        for secret in [
            "candidate-user-marker",
            "candidate-password-marker",
            "candidate-path-marker",
            "candidate-query-marker",
            "candidate-fragment-marker",
            "direct-hint-marker",
            "hint-user-marker",
            "hint-password-marker",
            "hint-path-marker",
            "hint-query-marker",
            "hint-fragment-marker",
            "daemon-user-marker",
            "daemon-password-marker",
            "daemon-path-marker",
            "daemon-query-marker",
            "daemon-fragment-marker",
            "daemon-slot-marker",
            "daemon-ticket-marker",
            "map-user-marker",
            "map-password-marker",
            "map-path-marker",
            "map-query-marker",
            "map-fragment-marker",
            "route-slot-marker",
            "route-ticket-marker",
            "malformed-route-marker",
            "malformed-info-route-marker",
            "client-info-user-marker",
            "client-info-password-marker",
            "client-info-path-marker",
            "client-info-query-marker",
            "client-info-fragment-marker",
        ] {
            assert!(
                !diagnostic.contains(secret),
                "remote runtime Debug leaked {secret:?}: {diagnostic}"
            );
        }
        assert!(diagnostic.contains("wss://candidate.example"), "{diagnostic}");
        assert!(diagnostic.contains("relay+wss://daemon.example"), "{diagnostic}");
        assert!(diagnostic.contains("relay+wss://map.example"), "{diagnostic}");
        assert!(diagnostic.contains("wss://client-info.example"), "{diagnostic}");
        assert!(diagnostic.contains("invalid route"), "{diagnostic}");
        assert!(diagnostic.contains(cmux_remote::provider::ROUTING_DIRECT_ADDRS), "{diagnostic}");
        assert!(diagnostic.contains(cmux_remote::provider::ROUTING_RELAY_URL), "{diagnostic}");
    }

    #[tokio::test]
    async fn carrier_initial_fallback_skips_network_route_before_any_dial() {
        let routes = vec![
            resolved_test_route(
                "wss://network.example/v1/link",
                SupportedClientAuthModes::DeviceOnly,
            ),
            resolved_test_route("ssh://carrier.example", SupportedClientAuthModes::DeviceOrCarrier),
        ];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: false,
            fail_provider_index: None,
            events: Vec::new(),
        };

        let selected = select_initial_route(
            &routes,
            SessionId([13; 16]),
            LanePolicy::Single,
            AuthKind::Carrier,
            false,
            &mut attempt,
        )
        .await
        .unwrap();

        assert_eq!(selected, "ssh://carrier.example");
        assert_eq!(
            attempt.events,
            [
                FakeInitialRouteEvent::Bootstrap {
                    endpoint: "ssh://carrier.example".into(),
                    upgrade: false,
                },
                FakeInitialRouteEvent::Provider(ConnectRequest {
                    endpoint: Url::parse("ssh://carrier.example").unwrap(),
                    session: SessionId([13; 16]),
                    lane_policy: LanePolicy::Single,
                    routing: BTreeMap::new(),
                }),
            ],
            "the device-only WebSocket provider was invoked before carrier fallback"
        );
    }

    #[tokio::test]
    async fn carrier_reconnect_skips_network_route_before_any_dial() {
        let routes = vec![
            resolved_test_route(
                "wss://network.example/v1/link",
                SupportedClientAuthModes::DeviceOnly,
            ),
            resolved_test_route("ssh://carrier.example", SupportedClientAuthModes::DeviceOrCarrier),
        ];
        let attempt = FakeReconnectRouteAttempt::default();

        let (index, selected) = select_reconnect_route(
            &routes,
            0,
            SessionId([14; 16]),
            LanePolicy::Single,
            AuthKind::Carrier,
            &attempt,
        )
        .await
        .unwrap();

        assert_eq!(index, 1);
        assert_eq!(selected, "ssh://carrier.example");
        assert_eq!(
            attempt.requests.into_inner().unwrap(),
            [ConnectRequest {
                endpoint: Url::parse("ssh://carrier.example").unwrap(),
                session: SessionId([14; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            }],
            "the device-only WebSocket provider was invoked during reconnect"
        );
    }

    #[tokio::test]
    async fn carrier_route_selection_fails_without_dialing_when_every_route_is_device_only() {
        let routes = vec![resolved_test_route(
            "wss://network.example/v1/link",
            SupportedClientAuthModes::DeviceOnly,
        )];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: false,
            fail_provider_index: None,
            events: Vec::new(),
        };

        let error = select_initial_route(
            &routes,
            SessionId([15; 16]),
            LanePolicy::Single,
            AuthKind::Carrier,
            false,
            &mut attempt,
        )
        .await
        .unwrap_err()
        .to_string();

        assert!(error.contains("carrier"), "{error}");
        assert!(attempt.events.is_empty(), "an incompatible route was dialed");
    }

    fn reconnect_test_options(routes: Vec<ResolvedRouteCandidate>) -> ClientRuntimeOptions {
        let ssh = SshProviderConfig::default();
        ClientRuntimeOptions {
            routes,
            providers: test_providers(ssh.clone()),
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Enrolled,
            device_name: "test".into(),
            session: SessionId([10; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                attempt_timeout: Duration::from_millis(20),
                heartbeat_interval: None,
                ..ReconnectPolicy::default()
            },
            startup_timeout: Duration::from_millis(500),
            state_dir: PathBuf::from("/tmp/cmux-reconnect-budget-test"),
            local_socket: None,
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_millis(500),
            },
        }
    }

    #[test]
    fn reconnect_resolution_budget_covers_the_whole_candidate_cycle() {
        let source = RuntimeReconnectGroups::new(
            reconnect_test_options(vec![
                test_route("wss://first.example/v1/link"),
                test_route("ssh://first-ssh.example"),
                test_route("iroh://fallback"),
                test_route("ssh://second-ssh.example"),
            ]),
            0,
        );

        assert_eq!(
            source.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(1_080),
            "four provider attempts and two first-use SSH bootstraps need one aggregate deadline"
        );
        source.prepared_ssh[1].store(true, Ordering::Release);
        assert_eq!(
            source.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(580)
        );
        source.prepared_ssh[3].store(true, Ordering::Release);
        assert_eq!(source.resolution_timeout(Duration::from_millis(20)), Duration::from_millis(80));

        let ordinary = RuntimeReconnectGroups::new(
            reconnect_test_options(vec![test_route("wss://only.example/v1/link")]),
            0,
        );
        assert_eq!(
            ordinary.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(20),
            "an ordinary single-route reconnect must retain its configured deadline"
        );

        let mut no_install_options = reconnect_test_options(vec![
            test_route("wss://selected.example/v1/link"),
            test_route("ssh://no-install.example"),
        ]);
        no_install_options.ssh_bootstrap.auto_install = false;
        let probe_timeout = no_install_options.ssh_bootstrap.attempt_timeout;
        let no_install = RuntimeReconnectGroups::new(no_install_options, 0);
        assert_eq!(
            no_install.resolution_timeout(Duration::from_millis(20)),
            probe_timeout + Duration::from_millis(40),
            "an unprepared no-install SSH route still needs time for remote-probe"
        );
    }

    #[cfg(unix)]
    #[test]
    fn client_shutdown_cancels_reconnect_ssh_bootstrap_and_kills_child() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let daemon_root = directory.path().join("daemon");
        let daemon_link = daemon_root.join("link.sock");
        let proxy_link = directory.path().join("proxy-link.sock");
        let daemon = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: "shutdown-cancel".into(),
                state_dir: Some(daemon_root.clone()),
                link_socket: Some(daemon_link.clone()),
                admin_socket: Some(daemon_root.join("admin.sock")),
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: false,
            },
        )
        .unwrap();
        let proxy_listener = std::os::unix::net::UnixListener::bind(&proxy_link).unwrap();
        proxy_listener.set_nonblocking(true).unwrap();
        let (cut_tx, cut_rx) = tokio::sync::oneshot::channel();
        let proxy = thread::spawn(move || {
            let runtime = build_remote_runtime("cmux-remote-carrier-cut-test").unwrap();
            runtime.block_on(async move {
                let listener = tokio::net::UnixListener::from_std(proxy_listener).unwrap();
                let (mut client_stream, _) = listener.accept().await.unwrap();
                let mut daemon_stream = tokio::net::UnixStream::connect(daemon_link).await.unwrap();
                tokio::select! {
                    _ = cut_rx => {}
                    result = tokio::io::copy_bidirectional(
                        &mut client_stream,
                        &mut daemon_stream,
                    ) => {
                        result.unwrap();
                    }
                }
            });
        });

        let script = directory.path().join("ssh");
        let pid_file = directory.path().join("ssh.pid");
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s' \"$$\" > '{}'\nexec /bin/sleep 30\n",
                pid_file.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let ssh = SshProviderConfig {
            ssh_binary: script.to_string_lossy().into_owned(),
            ..SshProviderConfig::default()
        };
        let providers = Arc::new(
            client_provider_registry(ssh.clone(), BTreeMap::new(), IrohPathMode::Auto).unwrap(),
        );
        let mut unix_route = Url::parse("unix:///").unwrap();
        unix_route.set_path(proxy_link.to_str().unwrap());
        let routes = [unix_route, Url::parse("ssh://fallback.example").unwrap()]
            .into_iter()
            .map(|endpoint| {
                ResolvedRouteCandidate::resolve(endpoint, BTreeMap::new(), &providers).unwrap()
            })
            .collect();
        let client = start_client_runtime(ClientRuntimeOptions {
            routes,
            providers,
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
            device_name: "shutdown-cancel-test".into(),
            session: SessionId([21; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                initial_delay: Duration::from_millis(10),
                maximum_delay: Duration::from_millis(10),
                // This fixture injects carrier EOF directly and asserts prompt
                // shutdown during SSH bootstrap. Give setup handshakes their
                // own budget and keep heartbeat timing out of that invariant.
                attempt_timeout: instrumented_test_timeout(Duration::from_secs(1)),
                full_jitter: false,
                heartbeat_interval: None,
                heartbeat_timeout: Duration::from_secs(1),
                maximum_attempts: None,
            },
            startup_timeout: instrumented_test_timeout(Duration::from_secs(5)),
            state_dir: directory.path().join("client"),
            local_socket: Some(directory.path().join("client.sock")),
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_secs(10),
            },
        })
        .unwrap();

        cut_tx.send(()).unwrap();
        proxy.join().unwrap();
        let deadline =
            std::time::Instant::now() + instrumented_test_timeout(Duration::from_secs(3));
        let pid = loop {
            if let Ok(value) = fs::read_to_string(&pid_file)
                && let Ok(pid) = value.parse::<libc::pid_t>()
            {
                break pid;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "client did not enter reconnect SSH bootstrap"
            );
            thread::sleep(Duration::from_millis(10));
        };

        let (done_tx, done_rx) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let _ = done_tx.send(client.shutdown());
        });
        let completed_promptly =
            match done_rx.recv_timeout(instrumented_test_timeout(Duration::from_millis(500))) {
                Ok(result) => {
                    result.unwrap();
                    true
                }
                Err(_) => {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                    done_rx
                        .recv_timeout(instrumented_test_timeout(Duration::from_secs(3)))
                        .expect("client shutdown stayed blocked after SSH cleanup")
                        .unwrap();
                    false
                }
            };
        assert!(
            completed_promptly,
            "client shutdown waited for the reconnect SSH bootstrap timeout"
        );

        let deadline =
            std::time::Instant::now() + instrumented_test_timeout(Duration::from_secs(2));
        while unsafe { libc::kill(pid, 0) } == 0 && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "cancelled SSH child is still alive");
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
        daemon.shutdown().unwrap();
    }

    #[tokio::test]
    async fn failed_ssh_bootstrap_falls_back_to_next_initial_provider() {
        let routes = vec![
            test_route("ssh://unreachable.example"),
            resolved_test_route_with_routing(
                "iroh://next",
                BTreeMap::from([(
                    cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                    "127.0.0.1:4242".into(),
                )]),
                SupportedClientAuthModes::DeviceOnly,
            ),
        ];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: true,
            fail_provider_index: None,
            events: Vec::new(),
        };

        let selected = select_initial_route(
            &routes,
            SessionId([5; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            false,
            &mut attempt,
        )
        .await
        .unwrap();

        assert_eq!(selected, "iroh://next");
        assert_eq!(
            attempt.events,
            [
                FakeInitialRouteEvent::Bootstrap {
                    endpoint: "ssh://unreachable.example".into(),
                    upgrade: false,
                },
                FakeInitialRouteEvent::Provider(ConnectRequest {
                    endpoint: Url::parse("iroh://next").unwrap(),
                    session: SessionId([5; 16]),
                    lane_policy: LanePolicy::Single,
                    routing: BTreeMap::from([(
                        cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                        "127.0.0.1:4242".into(),
                    )]),
                }),
            ]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn initial_client_connection_retries_transient_carrier_failure() {
        let directory = tempfile::tempdir().unwrap();
        let daemon_auth =
            AuthDatabase::load_or_create(directory.path().join("daemon"), "startup-retry", true)
                .unwrap();
        let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
        let unix_path = directory.path().join("daemon.sock");
        let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

        let calls = Arc::new(AtomicUsize::new(0));
        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers
            .register(Arc::new(TransientStartupProvider {
                calls: calls.clone(),
                transient_failures: 1,
                unix_path,
                unix: UnixProvider::new(MAX_CARRIER_FRAME_BYTES),
            }))
            .unwrap();
        let providers = Arc::new(providers);
        let route = ResolvedRouteCandidate::resolve(
            Url::parse("transient-startup://daemon").unwrap(),
            BTreeMap::new(),
            &providers,
        )
        .unwrap();
        let ssh = SshProviderConfig::default();
        let options = ClientRuntimeOptions {
            routes: vec![route],
            providers,
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
            device_name: "startup-retry-test".into(),
            session: SessionId([22; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                initial_delay: Duration::from_millis(1),
                maximum_delay: Duration::from_millis(1),
                attempt_timeout: Duration::from_secs(1),
                full_jitter: false,
                heartbeat_interval: None,
                heartbeat_timeout: Duration::from_secs(1),
                maximum_attempts: Some(2),
            },
            startup_timeout: Duration::from_secs(2),
            state_dir: directory.path().join("client"),
            local_socket: None,
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: false,
                upgrade: false,
                attempt_timeout: Duration::from_secs(1),
            },
        };
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        let (connection, _) = tokio::time::timeout(
            Duration::from_secs(2),
            connect_first_available(&options, shutdown_rx),
        )
        .await
        .expect("initial client connection retry timed out")
        .expect("transient initial carrier failure stopped the client");

        assert_eq!(calls.load(Ordering::Acquire), 2);
        connection.close().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn invitation_approval_outlives_the_route_attempt_timeout() {
        let directory = tempfile::tempdir().unwrap();
        let daemon_auth = AuthDatabase::load_or_create(
            directory.path().join("daemon"),
            "delayed-invitation-approval",
            true,
        )
        .unwrap();
        let unix_path = directory.path().join("daemon.sock");
        let route = unix_test_route(&unix_path);
        let invitation = daemon_auth
            .create_invitation(Duration::from_secs(60), vec![route.to_string()])
            .await
            .unwrap();
        let daemon_key: [u8; 32] = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&invitation.daemon_public_key)
            .unwrap()
            .try_into()
            .unwrap();
        let (daemon, _clients) = RemoteDaemon::new(daemon_auth.clone(), SessionLimits::default());
        let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();
        let providers = Arc::new(providers);
        let route = ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap();
        let ssh = SshProviderConfig::default();
        let options = ClientRuntimeOptions {
            routes: vec![route],
            providers,
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(daemon_key),
            auth: ClientAuthMode::Invitation {
                id: invitation.id.clone(),
                secret: zeroize::Zeroizing::new(invitation.secret_bytes().unwrap()),
            },
            device_name: "delayed-approval-client".into(),
            session: SessionId([24; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                initial_delay: Duration::from_millis(1),
                maximum_delay: Duration::from_millis(1),
                attempt_timeout: Duration::from_millis(20),
                full_jitter: false,
                heartbeat_interval: None,
                heartbeat_timeout: Duration::from_secs(1),
                maximum_attempts: Some(2),
            },
            startup_timeout: Duration::from_secs(1),
            state_dir: directory.path().join("client"),
            local_socket: None,
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: false,
                upgrade: false,
                attempt_timeout: Duration::from_secs(1),
            },
        };
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let connection =
            tokio::spawn(async move { connect_first_available(&options, shutdown_rx).await });

        let pending = daemon_auth.wait_for_pending(Duration::from_millis(200)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(60)).await;
        daemon_auth.approve(&pending[0].invitation_id).await.unwrap();

        let (connection, _) = tokio::time::timeout(Duration::from_secs(1), connection)
            .await
            .expect("delayed invitation approval timed out")
            .unwrap()
            .expect("the route timer abandoned a pending invitation approval");
        connection.close().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn initial_provider_timeout_falls_back_to_next_route() {
        let directory = tempfile::tempdir().unwrap();
        let daemon_auth =
            AuthDatabase::load_or_create(directory.path().join("daemon"), "dial-timeout", true)
                .unwrap();
        let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
        let unix_path = directory.path().join("daemon.sock");
        let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

        let calls = Arc::new(AtomicUsize::new(0));
        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers.register(Arc::new(HangingStartupProvider { calls: calls.clone() })).unwrap();
        providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();
        let providers = Arc::new(providers);
        let routes = [Url::parse("hanging-startup://daemon").unwrap(), unix_test_route(&unix_path)]
            .into_iter()
            .map(|route| {
                ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap()
            })
            .collect();
        let mut options = reconnect_test_options(routes);
        options.providers = providers;
        options.auth = ClientAuthMode::Carrier;
        options.reconnect.maximum_attempts = Some(1);
        options.reconnect.attempt_timeout = instrumented_test_timeout(Duration::from_millis(20));
        options.reconnect.full_jitter = false;
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        let (connection, selected) = tokio::time::timeout(
            instrumented_test_timeout(Duration::from_millis(500)),
            connect_first_available(&options, shutdown_rx),
        )
        .await
        .expect("a stalled provider monopolized initial route selection")
        .expect("the next initial route did not connect");

        assert_eq!(calls.load(Ordering::Acquire), 1);
        assert_eq!(selected, format!("unix://{}", unix_path.display()));
        connection.close().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn initial_link_timeout_closes_group_and_falls_back_to_next_route() {
        let directory = tempfile::tempdir().unwrap();
        let daemon_auth =
            AuthDatabase::load_or_create(directory.path().join("daemon"), "link-timeout", true)
                .unwrap();
        let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
        let unix_path = directory.path().join("daemon.sock");
        let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

        let close_calls = Arc::new(AtomicUsize::new(0));
        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers
            .register(Arc::new(HangingOpenProvider { close_calls: close_calls.clone() }))
            .unwrap();
        providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();
        let providers = Arc::new(providers);
        let routes = [Url::parse("hanging-open://daemon").unwrap(), unix_test_route(&unix_path)]
            .into_iter()
            .map(|route| {
                ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap()
            })
            .collect();
        let mut options = reconnect_test_options(routes);
        options.providers = providers;
        options.auth = ClientAuthMode::Carrier;
        options.reconnect.maximum_attempts = Some(1);
        options.reconnect.attempt_timeout = instrumented_test_timeout(Duration::from_millis(20));
        options.reconnect.full_jitter = false;
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        let (connection, selected) = tokio::time::timeout(
            instrumented_test_timeout(Duration::from_millis(500)),
            connect_first_available(&options, shutdown_rx),
        )
        .await
        .expect("a stalled physical link monopolized initial route selection")
        .expect("the next initial route did not connect");

        assert_eq!(close_calls.load(Ordering::Acquire), 1);
        assert_eq!(selected, format!("unix://{}", unix_path.display()));
        connection.close().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn initial_client_connection_respects_one_attempt_policy() {
        let directory = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers
            .register(Arc::new(TransientStartupProvider {
                calls: calls.clone(),
                transient_failures: usize::MAX,
                unix_path: directory.path().join("unused.sock"),
                unix: UnixProvider::new(MAX_CARRIER_FRAME_BYTES),
            }))
            .unwrap();
        let providers = Arc::new(providers);
        let route = ResolvedRouteCandidate::resolve(
            Url::parse("transient-startup://daemon").unwrap(),
            BTreeMap::new(),
            &providers,
        )
        .unwrap();
        let mut options = reconnect_test_options(vec![route]);
        options.providers = providers;
        options.auth = ClientAuthMode::Carrier;
        options.reconnect.maximum_attempts = Some(1);
        options.reconnect.full_jitter = false;
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        let error = connect_first_available(&options, shutdown_rx).await.unwrap_err();

        assert!(error.to_string().contains("transient startup carrier failure"), "{error:#}");
        assert_eq!(calls.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn initial_route_failures_redact_ssh_and_relay_endpoint_secrets() {
        let routes = vec![
            test_route("ssh://ssh-user:ssh-password-marker@ssh.example:2222"),
            test_route(
                "relay+wss://relay-user:relay-password-marker@relay.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
            ),
        ];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: true,
            fail_provider_index: Some(1),
            events: Vec::new(),
        };

        let error = select_initial_route(
            &routes,
            SessionId([11; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            false,
            &mut attempt,
        )
        .await
        .unwrap_err()
        .to_string();

        for secret in [
            "ssh-user",
            "ssh-password-marker",
            "relay-user",
            "relay-password-marker",
            "capability-marker",
            "query-marker",
            "fragment-marker",
        ] {
            assert!(!error.contains(secret), "route failure leaked {secret:?}: {error}");
        }
        assert!(error.contains("ssh://ssh.example:2222"), "{error}");
        assert!(error.contains("relay+wss://relay.example"), "{error}");
    }

    #[tokio::test]
    async fn upgrade_bootstrap_failure_is_fatal_without_provider_fallback() {
        let routes = vec![
            test_route("ssh://upgrade-user@upgrade.example"),
            test_route("wss://fallback.example/v1/link"),
        ];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: true,
            fail_provider_index: None,
            events: Vec::new(),
        };

        let error = select_initial_route(
            &routes,
            SessionId([6; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            true,
            &mut attempt,
        )
        .await
        .unwrap_err();

        assert!(error.to_string().contains("fake SSH is unreachable"));
        assert!(!error.to_string().contains("upgrade-user"));
        assert!(error.to_string().contains("ssh://upgrade.example"));
        assert_eq!(
            attempt.events,
            [FakeInitialRouteEvent::Bootstrap {
                endpoint: "ssh://upgrade-user@upgrade.example".into(),
                upgrade: true,
            }]
        );
    }

    #[tokio::test]
    async fn upgrade_provider_failure_is_fatal_without_route_fallback() {
        let routes = vec![
            test_route("ssh://upgrade-user@upgrade.example"),
            test_route("wss://fallback.example/v1/link"),
        ];
        let mut attempt = FakeInitialRouteAttempt {
            fail_ssh_bootstrap: false,
            fail_provider_index: Some(0),
            events: Vec::new(),
        };

        let error = select_initial_route(
            &routes,
            SessionId([8; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            true,
            &mut attempt,
        )
        .await
        .unwrap_err();

        assert!(error.to_string().contains("fake provider is unreachable"));
        assert!(!error.to_string().contains("upgrade-user"));
        assert!(error.to_string().contains("ssh://upgrade.example"));
        assert_eq!(
            attempt.events,
            [
                FakeInitialRouteEvent::Bootstrap {
                    endpoint: "ssh://upgrade-user@upgrade.example".into(),
                    upgrade: true,
                },
                FakeInitialRouteEvent::Provider(ConnectRequest {
                    endpoint: Url::parse("ssh://upgrade-user@upgrade.example").unwrap(),
                    session: SessionId([8; 16]),
                    lane_policy: LanePolicy::Single,
                    routing: BTreeMap::new(),
                }),
            ]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reconnect_bootstraps_an_ssh_candidate_not_attempted_initially() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let log = directory.path().join("ssh.log");
        let probe = cmux_remote::ssh_bootstrap::RemoteProbe {
            app: "cmux-tui".into(),
            version: cmux_remote::ssh_bootstrap::DISTRIBUTION_VERSION.into(),
            distribution_version: Some(cmux_remote::ssh_bootstrap::DISTRIBUTION_VERSION.into()),
            npm_bootstrap_version: cmux_remote::ssh_bootstrap::NPM_BOOTSTRAP_VERSION
                .map(str::to_owned),
            build_identity: Some(cmux_remote::ssh_bootstrap::BUILD_IDENTITY.into()),
            remote_protocol: cmux_remote_protocol::REMOTE_PROTOCOL_VERSION,
            os: "test".into(),
            arch: "test".into(),
        };
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nprintf '%s\\n' '{}'\n",
                log.display(),
                serde_json::to_string(&probe).unwrap()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let ssh = SshProviderConfig {
            ssh_binary: script.to_string_lossy().into_owned(),
            ..SshProviderConfig::default()
        };
        let options = ClientRuntimeOptions {
            routes: vec![
                test_route("wss://initial.example/v1/link"),
                test_route("ssh://fallback.example"),
            ],
            providers: test_providers(ssh.clone()),
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Enrolled,
            device_name: "test".into(),
            session: SessionId([9; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                attempt_timeout: Duration::from_millis(20),
                heartbeat_interval: None,
                ..ReconnectPolicy::default()
            },
            startup_timeout: Duration::from_millis(500),
            state_dir: directory.path().join("state"),
            local_socket: None,
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                // This launches a real subprocess while hundreds of TUI tests
                // run concurrently. Keep the watchdog independent of host
                // scheduler latency; the reconnect budget remains 20 ms.
                attempt_timeout: Duration::from_secs(30),
            },
        };
        let source = RuntimeReconnectGroups::new(options, 0);

        assert_eq!(
            source.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(30_040)
        );
        assert_eq!(source.next_group().await.unwrap().description(), "ssh://fallback.example");
        assert_eq!(
            source.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(40),
            "prepared SSH routes must retain only the per-provider reconnect budgets"
        );
        source.next.store(1, Ordering::Relaxed);
        assert_eq!(source.next_group().await.unwrap().description(), "ssh://fallback.example");
        let probes = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter(|line| line.contains(" remote-probe --json"))
            .count();
        assert_eq!(probes, 1, "a prepared SSH reconnect route was probed again");
    }

    #[tokio::test]
    async fn reconnect_provider_receives_the_exact_route_candidate_hints() {
        let routes = vec![
            resolved_test_route_with_routing(
                "iroh://first",
                BTreeMap::from([(
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://first-relay.example".into(),
                )]),
                SupportedClientAuthModes::DeviceOnly,
            ),
            resolved_test_route_with_routing(
                "iroh://second",
                BTreeMap::from([(
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://second-relay.example".into(),
                )]),
                SupportedClientAuthModes::DeviceOnly,
            ),
        ];
        let attempt = FakeReconnectRouteAttempt::default();

        let (index, selected) = select_reconnect_route(
            &routes,
            1,
            SessionId([7; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            &attempt,
        )
        .await
        .unwrap();

        assert_eq!(index, 1);
        assert_eq!(selected, "iroh://second");
        assert_eq!(
            attempt.requests.into_inner().unwrap(),
            [ConnectRequest {
                endpoint: Url::parse("iroh://second").unwrap(),
                session: SessionId([7; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::from([(
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://second-relay.example".into(),
                )]),
            }]
        );
    }

    #[tokio::test]
    async fn reconnect_failures_redact_endpoint_secrets() {
        let routes = vec![
            test_route(
                "wss://ws-user:ws-password-marker@ws.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
            ),
            test_route(
                "relay+wss://relay-user:relay-password-marker@relay.example/\
                     relay-capability?ticket=relay-query#relay-fragment",
            ),
        ];

        let error = select_reconnect_route(
            &routes,
            0,
            SessionId([12; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            &RejectingReconnectRouteAttempt,
        )
        .await
        .unwrap_err()
        .to_string();

        for secret in [
            "ws-user",
            "ws-password-marker",
            "capability-marker",
            "query-marker",
            "fragment-marker",
            "relay-user",
            "relay-password-marker",
            "relay-capability",
            "relay-query",
            "relay-fragment",
        ] {
            assert!(!error.contains(secret), "reconnect failure leaked {secret:?}: {error}");
        }
        assert!(error.contains("wss://ws.example/"), "{error}");
        assert!(error.contains("relay+wss://relay.example"), "{error}");
    }

    #[tokio::test]
    async fn reconnect_provider_debug_error_redacts_request_route_and_hints() {
        let routes = vec![resolved_test_route_with_routing(
            "wss://reconnect-user-marker:reconnect-password-marker@reconnect.example/\
             reconnect-path-marker?ticket=reconnect-query-marker#reconnect-fragment-marker",
            BTreeMap::from([(
                cmux_remote::provider::ROUTING_RELAY_URL.into(),
                "https://routing-user-marker:routing-password-marker@routing.example/\
                 routing-path-marker?ticket=routing-query-marker#routing-fragment-marker"
                    .into(),
            )]),
            SupportedClientAuthModes::DeviceOnly,
        )];

        let error = select_reconnect_route(
            &routes,
            0,
            SessionId([18; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            &DebugEchoingReconnectRouteAttempt,
        )
        .await
        .unwrap_err()
        .to_string();

        for secret in [
            "reconnect-user-marker",
            "reconnect-password-marker",
            "reconnect-path-marker",
            "reconnect-query-marker",
            "reconnect-fragment-marker",
            "routing-user-marker",
            "routing-password-marker",
            "routing-path-marker",
            "routing-query-marker",
            "routing-fragment-marker",
        ] {
            assert!(!error.contains(secret), "reconnect diagnostic leaked {secret:?}: {error}");
        }
        assert!(error.contains("wss://reconnect.example"), "{error}");
        assert!(error.contains(cmux_remote::provider::ROUTING_RELAY_URL), "{error}");
    }

    #[tokio::test]
    async fn reconnect_ssh_bootstrap_failure_redacts_dial_userinfo() {
        let routes = vec![test_route("ssh://ssh-user:ssh-password-marker@ssh.example:2222")];
        let options = reconnect_test_options(routes.clone());
        let prepared_ssh = [AtomicBool::new(false)];
        let attempt = RuntimeReconnectRouteAttempt {
            options: &options,
            prepared_ssh: &prepared_ssh,
            shutdown: None,
        };
        let request = connect_request(&routes[0], options.session, options.lane_policy).unwrap();

        let error = match attempt.connect(0, request, AuthKind::Enrolled).await {
            Err(error) => error.to_string(),
            Ok(_) => panic!("SSH reconnect unexpectedly succeeded"),
        };

        assert!(!error.contains("ssh-user"), "{error}");
        assert!(!error.contains("ssh-password-marker"), "{error}");
        assert!(error.contains("ssh://ssh.example:2222"), "{error}");
    }

    #[test]
    fn ssh_bootstrap_normalizes_ipv6_and_preserves_port() {
        let endpoint = Url::parse("ssh://alice@[2001:db8::1]:2222").unwrap();
        assert_eq!(
            ssh_bootstrap_destination(&endpoint).unwrap(),
            ("alice@2001:db8::1".into(), Some(2222))
        );
    }

    #[test]
    fn ssh_bootstrap_rejects_option_like_destination() {
        let endpoint = Url::parse("ssh://-Fvalidation@localhost").unwrap();
        assert!(ssh_bootstrap_destination(&endpoint).is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn connection_timeout_bounds_initial_ssh_bootstrap() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        fs::write(&script, "#!/bin/sh\nexec /bin/sleep 30\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let ssh = SshProviderConfig {
            ssh_binary: script.to_string_lossy().into_owned(),
            ..SshProviderConfig::default()
        };
        let options = SshBootstrapOptions {
            auto_install: true,
            upgrade: false,
            attempt_timeout: Duration::from_millis(100),
        };

        let error = bootstrap_initial_ssh_route(
            &Url::parse("ssh://example.com").unwrap(),
            &ssh,
            options,
            false,
            None,
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("timed out"));
    }

    #[test]
    fn remote_runtime_worker_pool_is_bounded() {
        assert!(
            (MIN_REMOTE_RUNTIME_WORKERS..=MAX_REMOTE_RUNTIME_WORKERS)
                .contains(&remote_runtime_worker_count())
        );
        build_remote_runtime("cmux-remote-runtime-test").unwrap();
    }

    #[tokio::test]
    async fn reconnect_source_cycles_candidates_with_sanitized_descriptions() {
        let ssh = SshProviderConfig::default();
        let options = ClientRuntimeOptions {
            routes: vec![test_route("ws://first.invalid"), test_route("ws://second.invalid")],
            providers: test_providers(ssh.clone()),
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Enrolled,
            device_name: "test".into(),
            session: SessionId([3; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy::default(),
            startup_timeout: Duration::from_secs(1),
            state_dir: PathBuf::from("/tmp/cmux-remote-route-test"),
            local_socket: None,
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_secs(1),
            },
        };
        let source = RuntimeReconnectGroups::new(options, 0);
        assert_eq!(source.next_group().await.unwrap().description(), "ws://second.invalid/");
        assert_eq!(source.next_group().await.unwrap().description(), "ws://first.invalid/");
    }

    #[test]
    fn persisted_runtime_metadata_redacts_route_credentials() {
        let directory = tempfile::tempdir().unwrap();
        let info = DaemonRuntimeInfo {
            session: "persist-redaction".into(),
            state_dir: directory.path().into(),
            link_socket: directory.path().join("link.sock"),
            admin_socket: directory.path().join("admin.sock"),
            daemon_fingerprint: "public-fingerprint".into(),
            routes: vec![
                "wss://persist-user-marker:persist-password-marker@persist.example/\
                 persist-path-marker?ticket=persist-query-marker#persist-fragment-marker"
                    .into(),
            ],
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: None,
            replaceable_sidecar: false,
        };

        persist_runtime_info(directory.path(), &info).unwrap();

        let persisted = fs::read_to_string(directory.path().join("runtime.json")).unwrap();
        for secret in [
            "persist-user-marker",
            "persist-password-marker",
            "persist-path-marker",
            "persist-query-marker",
            "persist-fragment-marker",
        ] {
            assert!(!persisted.contains(secret), "runtime metadata leaked {secret:?}: {persisted}");
        }
        let persisted: DaemonRuntimeInfo = serde_json::from_str(&persisted).unwrap();
        assert_eq!(persisted.routes, ["wss://persist.example/"]);
        assert_eq!(persisted.session, info.session);
    }

    #[test]
    fn persisted_runtime_metadata_keeps_dialable_iroh_hints() {
        let directory = tempfile::tempdir().unwrap();
        let node_id = "a".repeat(64);
        let mut iroh_route = Url::parse(&format!("iroh://{node_id}")).unwrap();
        iroh_route
            .query_pairs_mut()
            .append_pair(
                "relay_url",
                "https://persist-user:persist-password@relay.example/private?token=persist-token",
            )
            .append_pair("direct_addrs", "127.0.0.1:7777")
            .append_pair("ticket", "drop-me");
        let info = DaemonRuntimeInfo {
            session: "persist-iroh-routing".into(),
            state_dir: directory.path().into(),
            link_socket: directory.path().join("link.sock"),
            admin_socket: directory.path().join("admin.sock"),
            daemon_fingerprint: "public-fingerprint".into(),
            routes: vec![iroh_route.to_string()],
            direct_websocket: None,
            iroh_node_id: Some(node_id.clone()),
            lifecycle_id: None,
            replaceable_sidecar: false,
        };

        persist_runtime_info(directory.path(), &info).unwrap();

        let persisted = fs::read_to_string(directory.path().join("runtime.json")).unwrap();
        for secret in ["persist-user", "persist-password", "persist-token", "drop-me"] {
            assert!(!persisted.contains(secret), "runtime metadata leaked {secret:?}: {persisted}");
        }
        let persisted: DaemonRuntimeInfo = serde_json::from_str(&persisted).unwrap();
        let route = Url::parse(&persisted.routes[0]).unwrap();
        let routing = route.query_pairs().into_owned().collect::<BTreeMap<_, _>>();
        assert_eq!(route.host_str(), Some(node_id.as_str()));
        assert_eq!(routing["relay_url"], "https://relay.example/");
        assert_eq!(routing["direct_addrs"], "127.0.0.1:7777");
        assert!(!routing.contains_key("ticket"));
    }

    #[cfg(unix)]
    #[test]
    fn persisted_runtime_metadata_propagates_parent_directory_sync_failure() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let info = DaemonRuntimeInfo {
            session: "persist-runtime-sync".into(),
            state_dir: directory.path().into(),
            link_socket: directory.path().join("link.sock"),
            admin_socket: directory.path().join("admin.sock"),
            daemon_fingerprint: "public-fingerprint".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some("durable-active-lifecycle".into()),
            replaceable_sidecar: false,
        };

        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o300)).unwrap();
        let result = persist_runtime_info(directory.path(), &info);
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();

        result.expect_err("runtime persistence skipped its parent-directory sync");
    }

    #[cfg(unix)]
    #[test]
    fn daemon_finalizes_preliminary_lifecycle_after_committed_runtime_sync_failure() {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = "committed-preliminary-runtime";
        let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
        fail_state_directory_sync_after(&state_dir, 1);

        let error = match start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root.clone()),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        ) {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("daemon ignored a preliminary runtime durability failure");
            }
        };
        assert!(error.to_string().contains("injected state-directory sync failure"), "{error:#}");
        assert!(
            !state_dir.join("runtime.json").exists(),
            "committed preliminary runtime was left without lifecycle finalization"
        );
        let outcome = load_shutdown_outcome(&state_dir)
            .expect("committed preliminary runtime did not publish a shutdown outcome");
        assert_eq!(outcome.status, DaemonShutdownStatus::Succeeded);

        let retry = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .expect("finalized preliminary lifecycle blocked the next startup");
        retry.shutdown().unwrap();
    }

    #[test]
    fn persisted_runtime_metadata_rejects_malformed_routes_without_echoing_them() {
        let directory = tempfile::tempdir().unwrap();
        let info = DaemonRuntimeInfo {
            session: "persist-malformed".into(),
            state_dir: directory.path().into(),
            link_socket: directory.path().join("link.sock"),
            admin_socket: directory.path().join("admin.sock"),
            daemon_fingerprint: "public-fingerprint".into(),
            routes: vec!["%%% malformed-persisted-route-marker %%%".into()],
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: None,
            replaceable_sidecar: false,
        };

        let error = persist_runtime_info(directory.path(), &info).unwrap_err().to_string();

        assert!(!error.contains("malformed-persisted-route-marker"), "{error}");
        assert!(!directory.path().join("runtime.json").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_socket_rejects_a_symlinked_parent_directory() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let real_parent = directory.path().join("real");
        let symlinked_parent = directory.path().join("alias");
        fs::create_dir(&real_parent).unwrap();
        symlink(&real_parent, &symlinked_parent).unwrap();

        let error = prepare_client_socket(&symlinked_parent.join("mux.sock"))
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains("symlink"), "{error}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_socket_rejects_an_intermediate_symlink_before_creating_the_parent() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let result = prepare_client_socket(&alias.join("missing/mux.sock")).await;

        assert!(result.is_err(), "intermediate symlink was accepted");
        assert!(!target.join("missing").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_socket_rejects_a_symlinked_path_lock() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"do not lock").unwrap();
        symlink(&target, directory.path().join("mux.sock.lock")).unwrap();

        let error = prepare_client_socket(&directory.path().join("mux.sock"))
            .await
            .unwrap_err()
            .to_string();

        assert!(
            error.contains("lock") || error.contains("symlink"),
            "unexpected lock-file rejection: {error}"
        );
        assert_eq!(fs::read(target).unwrap(), b"do not lock");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_socket_creates_a_private_owned_parent_directory() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let directory = tempfile::tempdir().unwrap();
        let parent = directory.path().join("private");
        prepare_client_socket(&parent.join("mux.sock")).await.unwrap();

        let metadata = fs::symlink_metadata(parent).unwrap();
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
        assert_eq!(metadata.permissions().mode() & 0o077, 0);

        let lock_metadata = fs::symlink_metadata(directory.path().join("private/mux.sock.lock"))
            .expect("client socket preparation did not persist its ownership lock");
        assert!(lock_metadata.is_file());
        assert_eq!(lock_metadata.uid(), unsafe { libc::geteuid() });
        assert_eq!(lock_metadata.permissions().mode() & 0o077, 0);
        assert_eq!(lock_metadata.nlink(), 1);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn recovery_socket_probe_bounds_a_stalled_connect() {
        let stalled = std::future::pending::<std::io::Result<()>>();

        let error =
            tokio::time::timeout(Duration::from_secs(1), bounded_unix_socket_connect(stalled))
                .await
                .expect("recovery socket probe ignored its internal deadline")
                .expect_err("a permanently pending socket probe unexpectedly connected");

        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    }

    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stale_client_socket_takeover_waits_for_the_path_lock() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let stale = tokio::net::UnixListener::bind(&path).unwrap();
        drop(stale);

        let lock_path = directory.path().join("mux.sock.lock");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(lock_path)
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

        let contender_path = path.clone();
        let mut contender = tokio::spawn(async move {
            prepare_client_socket(&contender_path).await.unwrap().bind().unwrap()
        });
        assert!(
            tokio::time::timeout(Duration::from_millis(100), &mut contender).await.is_err(),
            "stale-socket takeover ignored the per-path ownership lock"
        );

        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        let lease = tokio::time::timeout(Duration::from_secs(1), contender)
            .await
            .expect("client socket takeover stayed blocked after the path lock was released")
            .unwrap();
        assert!(path.exists());
        drop(lease);
    }

    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_stale_client_socket_takeover_has_one_owner() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let stale = tokio::net::UnixListener::bind(&path).unwrap();
        drop(stale);

        let start = Arc::new(tokio::sync::Barrier::new(2));
        let spawn_contender = |path: PathBuf, start: Arc<tokio::sync::Barrier>| {
            tokio::spawn(async move {
                start.wait().await;
                prepare_client_socket(&path).await?.bind()
            })
        };
        let first = spawn_contender(path.clone(), Arc::clone(&start));
        let second = spawn_contender(path.clone(), start);
        let (first, second) =
            tokio::time::timeout(Duration::from_secs(2), async { tokio::join!(first, second) })
                .await
                .expect("concurrent stale-socket takeover did not settle");
        let first = first.unwrap();
        let second = second.unwrap();

        let (lease, rejected) = match (first, second) {
            (Ok(lease), Err(error)) | (Err(error), Ok(lease)) => (lease, error),
            (Ok(_), Ok(_)) => panic!("two clients acquired the same local socket"),
            (Err(first), Err(second)) => {
                panic!("both clients failed stale-socket takeover: {first:#}; {second:#}")
            }
        };
        assert!(rejected.to_string().contains("another client owns"), "{rejected:#}");
        tokio::time::timeout(Duration::from_secs(1), tokio::net::UnixStream::connect(&path))
            .await
            .expect("winning client socket was unreachable")
            .unwrap();
        drop(lease);
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn client_socket_lease_never_unlinks_a_bound_successor() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let mut previous = prepare_client_socket(&path).await.unwrap().bind().unwrap();

        previous.unlink().unwrap();
        let successor = tokio::net::UnixListener::bind(&path).unwrap();
        drop(previous);

        assert!(path.exists(), "old client lease unlinked the successor socket");
        let connect = tokio::net::UnixStream::connect(&path);
        let accept = successor.accept();
        let (connected, accepted) =
            tokio::time::timeout(Duration::from_secs(1), async { tokio::join!(connect, accept) })
                .await
                .expect("successor socket was unreachable");
        connected.unwrap();
        accepted.unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn client_socket_rejects_a_parent_owned_by_another_user() {
        use std::os::unix::fs::MetadataExt;

        let directory = tempfile::tempdir().unwrap();
        let metadata = fs::symlink_metadata(directory.path()).unwrap();
        let other_uid = metadata.uid() ^ 1;

        let error =
            validate_client_socket_directory(directory.path(), &metadata, other_uid).unwrap_err();
        assert!(error.to_string().contains("not owned by the effective user"));
    }

    #[cfg(unix)]
    #[test]
    fn long_state_path_uses_a_short_runtime_socket() {
        let state = PathBuf::from("/tmp").join("x".repeat(256));
        let socket = default_client_socket(&state, SessionId([4; 16]));
        assert!(unix_socket_path_fits(&socket));
        assert!(!socket.starts_with(state));
    }
}
