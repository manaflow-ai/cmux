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
use cmux_remote::admin::{MuxBinding, serve_admin_with_mux_binding};
use cmux_remote::bridge::serve_mux_bridge;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectGroupSource,
    ReconnectPolicy,
};
use cmux_remote::crypto::{AuthKind, ClientAuthMode, CryptoError, StaticIdentity};
#[cfg(test)]
use cmux_remote::daemon::serve_unix;
use cmux_remote::daemon::{
    DaemonSessionPolicy, DirectWebSocketOptions, serve_direct_websocket_with_options,
    serve_unix_with_shutdown,
};
use cmux_remote::first_dial::{DialOutcome, DialStop, LinkCell};
use cmux_remote::http::serve_workspace_http;
use cmux_remote::identity::{
    AuthDatabase, IdentityError, PersistedAuthStateSchema, credential_free_route_hint,
    default_state_dir, persisted_auth_state_schema,
};
use cmux_remote::observability::ClientConnectionSnapshot;
use cmux_remote::provider::{
    ConnectRequest, Dialer, DirectWebSocketProvider, IrohPathMode, LinkGroup, ProviderError,
    RelayClientConfig, RelayCredentialSource, RelayDaemonConfig, RelayDaemonRegistration,
    RelayProvider, SshProvider, SshProviderConfig, SupportedClientAuthModes, TransportProvider,
    UnixProvider, sanitized_route, sanitized_route_text, spawn_relay_daemon_registration,
};
#[cfg(feature = "iroh-transport")]
use cmux_remote::provider::{
    IrohListener, IrohProvider, IrohProviderConfig, load_or_create_iroh_secret,
};
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::ssh_bootstrap::{BootstrapError, SshBootstrapConfig, SshBootstrapper};
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;
use url::Url;

use crate::localization::catalog;

mod link_sidecars;
pub(crate) use link_sidecars::tunnel_route_record;

mod client_socket;
pub(crate) use client_socket::unix_socket_path_fits;
#[cfg(test)]
use client_socket::{
    BEFORE_SOCKET_DIRECTORY_RECORD_REPLACE, client_socket_lock_path, client_socket_path_in,
    prepare_client_socket, validate_client_socket_directory,
};
use client_socket::{
    SOCKET_DIRECTORY_RECORD, default_client_socket, prepare_client_socket_with_shutdown,
    private_socket_directory,
};

mod daemon_state;
pub use daemon_state::load_runtime_info;
use daemon_state::{
    CommittedRuntimeInfoError, finalize_daemon_lifecycle, persist_runtime_info,
    read_daemon_lifecycle_fence, recover_inactive_predecessor_state,
    verify_previous_shutdown_outcome,
};
pub(crate) use daemon_state::{
    acknowledge_failed_shutdown_outcome, acknowledge_legacy_shutdown_state,
    complete_verified_daemon_stop, inactive_daemon_needs_legacy_acknowledgement,
    load_shutdown_outcome, persist_daemon_lifecycle_fence,
};
#[cfg(test)]
use daemon_state::{
    bounded_unix_socket_connect, fail_state_directory_sync_after, persist_shutdown_outcome,
    read_optional_file, read_runtime_info, remove_shutdown_recovery_evidence,
};

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
/// How often a client's startup wait looks at the shutdown flag, so SIGTERM or
/// SIGINT ends a dial that is still connecting instead of waiting out its
/// startup timeout (an ssh `ProxyCommand` must exit when ssh does).
const STARTUP_SIGNAL_POLL: Duration = Duration::from_millis(100);
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
    /// The direct WebSocket listener grants carrier authentication to every link
    /// (`--remote-ws-trusted-carrier`): only for a listener reachable solely
    /// from a network whose members are all authorized.
    pub trusted_carrier_websocket: bool,
    pub workspace_http: Option<SocketAddr>,
    pub relays: Vec<RelayDaemonOptions>,
    /// The carrier grant config (`--carrier-grant-config`,
    /// `cmux_remote::grant::GrantConfig`); without it the daemon refuses
    /// every grant.
    pub carrier_grant_config: Option<PathBuf>,
    pub iroh: bool,
    pub advertised_routes: Vec<String>,
    pub resume_lease: Duration,
    pub replaceable_sidecar: bool,
    /// The Unix sockets an owner's carrier session may reach
    /// (`--remote-local-socket`, cmux-remote's `local-socket` service).
    pub local_sockets: Vec<PathBuf>,
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
            .field("trusted_carrier_websocket", &self.trusted_carrier_websocket)
            .field("workspace_http", &self.workspace_http)
            .field("relays", &self.relays)
            .field("iroh", &self.iroh)
            .field("advertised_routes", &advertised_routes)
            .field("resume_lease", &self.resume_lease)
            .field("replaceable_sidecar", &self.replaceable_sidecar)
            .field("local_sockets", &self.local_sockets)
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
    finished: Arc<AtomicBool>,
}

/// Marks the daemon runtime finished and wakes the headless owner loop when
/// the runtime thread's work ends.
struct FinishedSignal(Arc<AtomicBool>);

impl Drop for FinishedSignal {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
        crate::wake_headless();
    }
}

impl DaemonRuntimeHandle {
    pub fn info(&self) -> &DaemonRuntimeInfo {
        &self.info
    }

    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
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

/// The client-side transport registry.
///
/// `direct_dialer` replaces the operating-system TCP dial for `ws`/`wss`
/// routes: an in-process WireGuard tunnel (`WireGuardDialer`) or a shared hub
/// (`SocksDialer`). Every other scheme is unaffected.
/// `direct_carrier_auth` lets `ws`/`wss` routes dial with carrier authentication
/// (`remote connect --carrier`): the daemon is expected to serve a trusted-network
/// listener, as cmux Cloud machines do behind the owner's private network.
pub fn client_provider_registry(
    ssh: SshProviderConfig,
    relay_routes: BTreeMap<String, RelayClientOptions>,
    iroh_path: IrohPathMode,
    direct_dialer: Option<Arc<dyn Dialer>>,
    direct_carrier_auth: bool,
) -> Result<cmux_remote::provider::ProviderRegistry, ProviderError> {
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    let direct = match direct_dialer {
        Some(dialer) => DirectWebSocketProvider::with_dialer(MAX_CARRIER_FRAME_BYTES, dialer),
        None => DirectWebSocketProvider::new(MAX_CARRIER_FRAME_BYTES),
    }
    .with_carrier_auth(direct_carrier_auth);
    providers.register(Arc::new(direct))?;
    #[cfg(unix)]
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES)))?;
    providers.register(Arc::new(SshProvider::new(ssh)?))?;
    providers.register(Arc::new(RoutedRelayProvider { routes: relay_routes }))?;
    #[cfg(feature = "iroh-transport")]
    providers.register(Arc::new(IrohProvider::new(
        IrohProviderConfig::default().with_path_mode(iroh_path),
    )?))?;
    #[cfg(not(feature = "iroh-transport"))]
    let _ = iroh_path;
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

    /// A route that `provider` dials, outside any registry (the Cloud
    /// carrier builds its relay provider per attempt, around that attempt's
    /// tickets).
    pub(crate) fn for_provider(endpoint: Url, provider: &dyn TransportProvider) -> Self {
        Self {
            endpoint,
            routing: BTreeMap::new(),
            supported_client_auth: provider.supported_client_auth(),
        }
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
    /// Every SSH route's key carries a forced command that already runs
    /// `remote-link` (the Cloud carrier key, `command="cmux-tui remote-link
    /// --stdio ..."`). Then nothing else can run over it: the client skips
    /// `remote-probe` and any install, and dials the link at once.
    pub forced_command: bool,
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

    /// Whether the daemon no longer has this client's session (it outlived
    /// the daemon's resume lease, or was closed there). Permanent: the
    /// connection stops redialing, and only a new session can continue.
    pub fn session_unavailable(&self) -> bool {
        self.connection.session_unavailable() || self.multiplexer.session_unavailable()
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
    start_client_runtime_with(options, None)
}

/// [`start_client_runtime`] for a link that outlives a failed first connect (`remote connect
/// --headless`, the app's machine link): the first connect is a recovery like any later drop. Its
/// link socket answers from the start, it redials within its budget, at once on a network change
/// or an `await-ready`, and the startup timeout no longer ends it. It returns once connected, on a
/// permanent error (a refused identity, a changed daemon key, a bound `--reconnect-attempts` run
/// out), on a shutdown signal, or when `keep_waiting` (read every 100 ms) says the owner is gone.
pub fn start_recovering_client_runtime(
    options: ClientRuntimeOptions,
    keep_waiting: impl Fn() -> bool,
) -> anyhow::Result<ClientRuntimeHandle> {
    start_client_runtime_with(options, Some(&keep_waiting))
}

fn start_client_runtime_with(
    options: ClientRuntimeOptions,
    keep_waiting: Option<&dyn Fn() -> bool>,
) -> anyhow::Result<ClientRuntimeHandle> {
    if options.routes.is_empty() {
        return Err(anyhow!("remote connection has no route candidates"));
    }
    if options.startup_timeout.is_zero() {
        return Err(anyhow!("remote startup timeout must be positive"));
    }
    options.reconnect.validate()?;
    let startup_timeout = options.startup_timeout;
    let recovering = keep_waiting.is_some();
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (finished_tx, finished_rx) = watch::channel(false);
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name("cmux-remote-client".into())
        .spawn(move || {
            let runtime = build_remote_runtime("cmux-remote-client-worker")
                .context("could not start remote client Tokio runtime")?;
            let result = runtime.block_on(run_client(options, shutdown_rx, ready_tx, recovering));
            runtime.shutdown_timeout(REMOTE_RUNTIME_SHUTDOWN_TIMEOUT);
            finished_tx.send_replace(true);
            result
        })
        .context("could not start remote client thread")?;
    let deadline = keep_waiting.is_none().then(|| std::time::Instant::now() + startup_timeout);
    let ready = loop {
        let left = deadline.map_or(STARTUP_SIGNAL_POLL, |deadline| {
            deadline.saturating_duration_since(std::time::Instant::now())
        });
        match ready_rx.recv_timeout(left.min(STARTUP_SIGNAL_POLL)) {
            Ok(Ok(ready)) => break ready,
            Ok(Err(error)) => {
                let _ = shutdown_tx.send(true);
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(anyhow!(error));
            }
            Err(mpsc::RecvTimeoutError::Timeout) if crate::shutdown_requested() => {
                let _ = shutdown_tx.send(true);
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(anyhow!("remote connection startup interrupted by a signal"));
            }
            Err(mpsc::RecvTimeoutError::Timeout)
                if keep_waiting.is_some_and(|keep_waiting| !keep_waiting()) =>
            {
                let _ = shutdown_tx.send(true);
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(anyhow!("remote connection owner went away before the first connect"));
            }
            Err(mpsc::RecvTimeoutError::Timeout) if !left.is_zero() => {}
            Err(mpsc::RecvTimeoutError::Disconnected) if keep_waiting.is_some() => {
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(anyhow!("remote client runtime stopped before the first connect"));
            }
            Err(error) => {
                let _ = shutdown_tx.send(true);
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(anyhow!(
                    "remote connection did not become ready within {}s: {error}",
                    startup_timeout.as_secs()
                ));
            }
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

/// `recovering`: the link outlives a failed first connect, and says on stderr why each first
/// dial failed (an owner that still reads only stderr learns the reason without waiting for an
/// exit that no longer comes).
/// The stderr line a recovering link writes once its `PATH.admin` socket is bound. The app
/// matches it as `SSHMachineLink.socketReadyLine` (CmuxNextRemote/SSH/SSHMachineLink.swift);
/// `tests/remote_connect_link_socket_ready.rs` checks the binary prints it before any dial reports.
pub(crate) const LINK_SOCKET_READY_LINE: &str = "remote connect: link socket ready";

async fn run_client(
    options: ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    ready: mpsc::SyncSender<Result<ClientReady, String>>,
    recovering: bool,
) -> anyhow::Result<()> {
    let setup = async {
        let local_socket = match options.local_socket.clone() {
            Some(path) => path,
            None => default_client_socket(&options.state_dir, options.session)?,
        };
        let sidecars = link_sidecars::PendingSidecars::start(&local_socket).await;
        if recovering && sidecars.answers() {
            // The owner forwards a person's wait as soon as the link's socket answers, before
            // any dial reports (a stalled first dial says nothing on stderr).
            eprintln!("{LINK_SOCKET_READY_LINE}");
        }
        let (connection, route) = dial_first_connection(
            &options,
            shutdown.clone(),
            sidecars.cell(),
            sidecars.network(),
            recovering,
        )
        .await?;
        if *shutdown.borrow() {
            let _ = connection.close().await;
            return Err(anyhow!("remote client startup was cancelled"));
        }
        let socket_preparation =
            prepare_client_socket_with_shutdown(&local_socket, Some(shutdown.clone())).await?;
        if *shutdown.borrow() {
            let _ = connection.close().await;
            return Err(anyhow!("remote client startup was cancelled"));
        }
        let daemon_public_key = connection.daemon_public_key();
        let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
        let socket = socket_preparation.bind()?;
        // The SSH route behind this socket, so a CLI at a version-skew dead
        // end can name the exact upgrade command (cli/skew.rs, cx-ytw1).
        let route_record = link_sidecars::write_tunnel_route(&local_socket, &route);
        let _sidecars = sidecars.attach(&connection);
        let (bridge_shutdown_tx, bridge_shutdown_rx) = tokio::sync::oneshot::channel();
        let bridge_multiplexer = multiplexer.clone();
        let mut bridge = tokio::spawn(async move {
            let mut socket = socket;
            serve_mux_bridge(bridge_multiplexer, socket.listener(), bridge_shutdown_rx).await;
            let _ = socket.unlink();
            if let Some(record) = route_record {
                let _ = fs::remove_file(record);
            }
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

/// The first connect on a link of its own: a fresh state and no network watch.
#[cfg(test)]
async fn connect_first_available(
    options: &ClientRuntimeOptions,
    shutdown: watch::Receiver<bool>,
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    let watch = cmux_remote::network_watch::NetworkWatch::manual();
    connect_first_available_watching(options, shutdown, watch.subscribe()).await
}

/// The first connect on a link of its own, told of network changes by `network`.
#[cfg(test)]
async fn connect_first_available_watching(
    options: &ClientRuntimeOptions,
    shutdown: watch::Receiver<bool>,
    network: watch::Receiver<u64>,
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    dial_first_connection(options, shutdown, &LinkCell::new(), network, false).await
}

/// The first connect, run like a recovery of a later drop (`LinkCell::dial`): budgeted bursts
/// that park between them, a network change on `network` or a caller's wait dials at once, and
/// `cell` says where it is. A retryable route failure never ends it unless the policy bounds the
/// attempts; a permanent one (a refused identity, a changed daemon key) does.
async fn dial_first_connection(
    options: &ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    cell: &LinkCell,
    network: watch::Receiver<u64>,
    report_retries: bool,
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    let attempt_shutdown = shutdown.clone();
    let dial = cell.dial(options.reconnect, network, || {
        let mut attempt =
            RuntimeInitialRouteAttempt { options, shutdown: attempt_shutdown.clone() };
        async move {
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
                Ok(connection) => DialOutcome::Ready(connection),
                Err(error) if error.retryable => {
                    if report_retries {
                        eprintln!("remote connect: {:#}; redialing", error.error);
                    }
                    DialOutcome::Retry(error)
                }
                Err(error) => DialOutcome::Fatal(error),
            }
        }
    });
    tokio::select! {
        result = dial => result.map_err(|error| error.error),
        _ = wait_for_shutdown(&mut shutdown) => {
            Err(anyhow!("remote client startup was cancelled"))
        }
    }
}

/// A route attempt's error type, as the route runner needs it.
pub(crate) trait RouteFailure: Sized + Send {
    /// A failure that ends the round before or outside any one route.
    fn terminal(message: String) -> Self;
    /// This failure as one entry of a failed round's list.
    fn summary(&self) -> String;
    /// Every candidate failed: `failures` lists each as
    /// `<route>: <summary>`, and `last` is the last dialed route's own
    /// failure, when one was dialed.
    fn all_failed(failures: Vec<String>, last: Option<Self>) -> Self;
}

impl RouteFailure for anyhow::Error {
    fn terminal(message: String) -> Self {
        anyhow!(message)
    }

    fn summary(&self) -> String {
        format!("{self:#}")
    }

    fn all_failed(failures: Vec<String>, _last: Option<Self>) -> Self {
        anyhow!("all remote route candidates failed: {}", failures.join("; "))
    }
}

pub(crate) enum InitialRouteAttemptError<E = anyhow::Error> {
    Route { error: E, retryable: bool },
    Fatal(E),
}

#[derive(Debug)]
pub(crate) struct InitialRouteSelectionError<E = anyhow::Error> {
    pub(crate) error: E,
    pub(crate) retryable: bool,
}

impl<E> InitialRouteSelectionError<E> {
    fn terminal(error: E) -> Self {
        Self { error, retryable: false }
    }
}

impl From<DialStop> for InitialRouteSelectionError {
    fn from(stop: DialStop) -> Self {
        Self { error: anyhow!("{stop}"), retryable: matches!(stop, DialStop::NetworkChanged) }
    }
}

impl<E: fmt::Display> fmt::Display for InitialRouteSelectionError<E> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.error.fmt(formatter)
    }
}

#[async_trait]
pub(crate) trait InitialRouteAttempt<T: Send, E: Send = anyhow::Error> {
    async fn bootstrap_ssh(
        &mut self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError<E>>;
    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<T, InitialRouteAttemptError<E>>;
}

pub(crate) async fn select_initial_route<T: Send, E: RouteFailure>(
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    upgrade: bool,
    attempt: &mut impl InitialRouteAttempt<T, E>,
) -> Result<T, InitialRouteSelectionError<E>> {
    if routes.is_empty() {
        return Err(InitialRouteSelectionError::terminal(E::terminal(
            "remote connection has no route candidates".into(),
        )));
    }
    if upgrade && routes[0].endpoint.scheme() != "ssh" {
        return Err(InitialRouteSelectionError::terminal(E::terminal(
            "--upgrade requires SSH to be the initial route".into(),
        )));
    }
    let mut failures = Vec::new();
    let mut last = None;
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
        let request = connect_request(candidate, session, lane_policy).map_err(|error| {
            InitialRouteSelectionError::terminal(E::terminal(format!("{error:#}")))
        })?;
        let endpoint = request.endpoint.clone();
        let upgrade_candidate = upgrade && index == 0;
        if endpoint.scheme() == "ssh" {
            match attempt.bootstrap_ssh(&endpoint, upgrade_candidate).await {
                Ok(()) => {}
                Err(InitialRouteAttemptError::Route { error, retryable: route_retryable }) => {
                    if upgrade_candidate {
                        return Err(InitialRouteSelectionError::terminal(E::terminal(format!(
                            "SSH bootstrap failed for {display_endpoint}: {}",
                            error.summary()
                        ))));
                    }
                    retryable |= route_retryable;
                    failures.push(format!(
                        "{display_endpoint}: SSH bootstrap failed: {}",
                        error.summary()
                    ));
                    last = Some(error);
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
                    return Err(InitialRouteSelectionError::terminal(E::terminal(format!(
                        "upgraded SSH route failed for {display_endpoint}: {}",
                        error.summary()
                    ))));
                }
                retryable |= route_retryable;
                failures.push(format!("{display_endpoint}: {}", error.summary()));
                last = Some(error);
            }
            Err(InitialRouteAttemptError::Fatal(error)) => {
                return Err(InitialRouteSelectionError::terminal(error));
            }
        }
    }
    Err(InitialRouteSelectionError { error: E::all_failed(failures, last), retryable })
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
                        // `--reconnect-attempts` bounds the first connect
                        // only. The established link redials in budgeted
                        // bursts and parks between them instead of ending
                        // the process, which made every layer above redial.
                        reconnect: ReconnectPolicy {
                            maximum_attempts: None,
                            ..self.options.reconnect
                        },
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
    if options.forced_command {
        // The key's forced command runs `remote-link` whatever the client
        // asks, so a `remote-probe` here would open a link and fail to parse.
        return Ok(());
    }
    let (destination, port) = ssh_bootstrap_destination(endpoint)?;
    let mut config = SshBootstrapConfig::defaults(
        destination,
        cmux_build_identity::BUILD_IDENTITY,
        crate::distribution::DISTRIBUTION_VERSION,
        crate::distribution::NPM_BOOTSTRAP_VERSION,
    );
    config.ssh_binary = ssh.ssh_binary.clone();
    config.port = port;
    config.remote_binary = ssh.remote_binary.clone();
    config.extra_args = ssh.extra_args.clone();
    config.auto_install = options.auto_install;
    config.timeout = options.attempt_timeout;
    config.required_capabilities = ssh.required_remote_capabilities();
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
    error.downcast_ref::<BootstrapError>().is_some_and(|error| {
        error.is_retryable_carrier_failure() && !ssh_refused_permanently(error)
    })
}

/// What ssh prints when it reached the host and was refused: a failed authentication or a host
/// key it will not accept. ssh exits 255 for these as for an unreachable host, but no redial can
/// fix them, so a link that outlives a failed first connect must not redial them. Matched without
/// regard to case. The app names the same lines as an authentication or host key failure
/// (`SSHFailure.hostKeyNeedles` and `authNeedles`), so every one of those is here too.
const SSH_PERMANENT_REFUSALS: &[&str] = &[
    // Authentication: ssh's own last word once every method failed. Per-key lines
    // (`sign_and_send_pubkey: ...`, `no mutual signature algorithm`) are left out: ssh goes on to
    // the next key, so a later transport failure after one is still worth redialing.
    "Permission denied",
    "Too many authentication failures",
    "No more authentication methods",
    "Authentication failed",
    // Host keys: only the lines that end the connection. Warnings (`Permanently added the ...
    // host key for IP address ...`, the `REMOTE HOST IDENTIFICATION HAS CHANGED` banner, `host
    // key is known for ...`) can precede a connection that goes on, so no bare prefix matches.
    "Host key verification failed",
    "has changed and you have requested strict checking",
    "No matching host key type",
];

fn ssh_refused_permanently(error: &BootstrapError) -> bool {
    let (BootstrapError::Remote { stderr, .. } | BootstrapError::Install { stderr, .. }) = error
    else {
        return false;
    };
    let stderr = stderr.to_lowercase();
    SSH_PERMANENT_REFUSALS.iter().any(|refusal| stderr.contains(&refusal.to_lowercase()))
}

/// Returns when the owner asks the runtime to stop or a termination signal
/// arrives. Both are events; this used to re-check them every 50 ms.
async fn wait_for_shutdown_request(mut shutdown: Option<watch::Receiver<bool>>) {
    let mut signal_available = true;
    loop {
        if crate::shutdown_requested()
            || shutdown.as_ref().is_some_and(|receiver| *receiver.borrow())
        {
            return;
        }
        let owner = async {
            match &mut shutdown {
                Some(receiver) => receiver.changed().await.is_err(),
                None => std::future::pending().await,
            }
        };
        let signal = async {
            if signal_available {
                crate::wait_for_shutdown_signal_peek_async().await.is_err()
            } else {
                std::future::pending().await
            }
        };
        let (owner_closed, signal_unavailable) = tokio::select! {
            owner_closed = owner => (owner_closed, false),
            signal_unavailable = signal => (false, signal_unavailable),
        };
        if owner_closed {
            shutdown = None;
        }
        if signal_unavailable {
            signal_available = false;
        }
        if shutdown.is_none() && !signal_available {
            // Nothing left that can request a stop.
            std::future::pending::<()>().await;
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
pub(crate) trait ReconnectRouteAttempt<T: Send>: Send + Sync {
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
            .map(|(index, _)| {
                // A forced-command route has nothing to prepare (see
                // `SshBootstrapOptions::forced_command`).
                AtomicBool::new(
                    options.ssh_bootstrap.forced_command
                        || (selected_ssh && index == selected_index),
                )
            })
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
        let attempt = RuntimeReconnectRouteAttempt {
            options: &self.options,
            prepared_ssh: &self.prepared_ssh,
            shutdown: self.shutdown.clone(),
        };
        next_reconnect_route(
            &self.next,
            &self.options.routes,
            self.options.session,
            self.options.lane_policy,
            followup_auth_kind(&self.options.auth),
            &attempt,
        )
        .await
    }
}

/// The next route of an established link after its current one failed:
/// from `next` (one past the route that last connected) round the list,
/// and `next` moves past the route that connects. `remote connect` and the
/// Cloud carrier (`carrier::source`) both rotate this way.
pub(crate) async fn next_reconnect_route<T: Send>(
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<T, ProviderError> {
    let Some(start) = next.fetch_add(1, Ordering::Relaxed).checked_rem(routes.len()) else {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    };
    let (index, group) =
        select_reconnect_route(routes, start, session, lane_policy, auth, attempt).await?;
    next.store(index.saturating_add(1), Ordering::Relaxed);
    Ok(group)
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
        ClientAuthMode::Grant { .. } => AuthKind::Grant,
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
            | ConnectionError::SessionUnavailable
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
pub(crate) fn daemon_runtime_socket_paths(state: &Path) -> anyhow::Result<(PathBuf, PathBuf)> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    daemon_runtime_socket_paths_in(state, runtime.as_deref(), Path::new("/tmp"))
}

/// Resolves the daemon's link and admin sockets for a state path that is too
/// long for a Unix socket. `runtime` is `XDG_RUNTIME_DIR` and `shared_tmp` is
/// the world-writable directory used when no runtime directory is usable.
#[cfg(unix)]
fn daemon_runtime_socket_paths_in(
    state: &Path,
    runtime: Option<&Path>,
    shared_tmp: &Path,
) -> anyhow::Result<(PathBuf, PathBuf)> {
    use std::os::unix::ffi::OsStrExt;

    // The name from before NEXT's folder move, so a daemon from before it keeps its sockets' names.
    let identity = cmux_agent_pane_policy::build_identity::path_identity(state);
    let digest = format!("{:x}", Sha256::digest(identity.as_os_str().as_bytes()));
    let socket_names = |runtime: &Path| {
        (runtime.join(format!("{digest}-l.sock")), runtime.join(format!("{digest}-a.sock")))
    };
    if let Some(runtime) =
        runtime.filter(|path| path.is_absolute()).map(|path| path.join("cmux-rd"))
    {
        let (link, admin) = socket_names(&runtime);
        if unix_socket_path_fits(&link)
            && unix_socket_path_fits(&admin)
            && ensure_secure_directory(&runtime, DirectoryAccess::ManagedOwnerOnly).is_ok()
        {
            return Ok((link, admin));
        }
    }

    // Every client of this session computes the same paths from `state`, so
    // a fallback directory is recorded there for them to find.
    let prefix = format!("cmux-rd-{}", unsafe { libc::geteuid() });
    let runtime = private_socket_directory(
        shared_tmp,
        &prefix,
        &state.join(SOCKET_DIRECTORY_RECORD),
        |path| Ok(ensure_secure_directory(path, DirectoryAccess::ManagedOwnerOnly)?),
    )
    .context("could not create private remote daemon runtime directory")?;
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
    let finished = Arc::new(AtomicBool::new(false));
    let thread_finished = finished.clone();
    let thread = thread::Builder::new()
        .name(format!("cmux-remote-{}", options.session))
        .spawn(move || {
            // The headless owner loop blocks until this runtime ends, on
            // every return path including a failed runtime build.
            let _finished = FinishedSignal(thread_finished);
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
    Ok(DaemonRuntimeHandle { info, shutdown: shutdown_tx, thread: Some(thread), finished })
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
        #[cfg(unix)]
        if lifecycle_fenced {
            recover_inactive_predecessor_state(&state_dir, &link_socket, &admin_socket).await?;
        }
        verify_previous_shutdown_outcome(&state_dir, lifecycle_fenced)?;
        if !lifecycle_fenced {
            persist_daemon_lifecycle_fence(&state_dir)?;
        }
        if *startup_shutdown.borrow() {
            return Err(anyhow!("remote daemon startup was cancelled"));
        }
        if let Some(path) = &options.carrier_grant_config {
            install_grant_verifier(&auth, path);
        }
        let (daemon, clients) = cmux_remote::daemon::RemoteDaemon::with_policy(
            auth.clone(),
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: options.resume_lease },
        )?;
        #[cfg(unix)]
        let workspace = crate::machine_secrets::daemon_workspace_service(
            &auth,
            &state_dir,
            options.carrier_grant_config.as_deref(),
        );
        #[cfg(not(unix))]
        let workspace = cmux_remote::workspace::WorkspaceService::new();
        // The admin proof and service forwarding must use the same resolved
        // destination, including when the configured path is a symlink.
        let mux_binding = MuxBinding::new(&mux_socket, &link_socket)?;
        let mux_socket = mux_binding.mux_socket.clone();

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
                    serve_direct_websocket_with_options(
                        daemon.clone(),
                        address,
                        MAX_CARRIER_FRAME_BYTES,
                        DirectWebSocketOptions::new(
                            options.allow_insecure_non_loopback,
                            options.trusted_carrier_websocket,
                        ),
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
                        "{BIN}: authenticated workspace HTTP at http://{}; bearer token file {}",
                        server.local_addr(),
                        server.token_file().display()
                    );
                    Some(server)
                }
                None => None,
            };

            // The relay registers in the background: a ticket command that
            // fails or hangs, or a relay that is down, is retried and logged
            // while the local sockets serve. Only an invalid relay
            // configuration fails startup.
            let mut relays = Vec::with_capacity(options.relays.len());
            for relay in options.relays.iter().cloned() {
                relays.push(spawn_relay_daemon_registration(
                    daemon.clone(),
                    RelayDaemonConfig {
                        endpoint: relay.endpoint,
                        slot: relay.slot,
                        ticket: String::new(),
                        maximum_frame_bytes: MAX_CARRIER_FRAME_BYTES,
                        control_timeout: Duration::from_secs(15),
                    },
                    relay.credentials,
                    &crate::cli::BIN.to_string(),
                )?);
            }

            #[cfg(not(feature = "iroh-transport"))]
            if options.iroh {
                return Err(anyhow!("Iroh transport is not included in this cmux-tui build"));
            }
            #[cfg(feature = "iroh-transport")]
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
            #[cfg(not(feature = "iroh-transport"))]
            let iroh = None::<()>;

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
            #[cfg(feature = "iroh-transport")]
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
            #[cfg(not(feature = "iroh-transport"))]
            let iroh_node_id = None;
            if let Some(route) = websocket_route {
                push_unique_route(&mut routes, route);
            }
            // Unix is fastest on the same host, and clients promote it when its
            // socket exists locally. Keeping it last avoids exporting a remote
            // host's filesystem path as the default route for mobile clients.
            push_unique_route(&mut routes, unix_route);

            let admin = serve_admin_with_mux_binding(
                daemon,
                &admin_socket,
                routes.clone(),
                Some(lifecycle_id.clone()),
                Some(owner_shutdown),
                Some(mux_binding.clone()),
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
        let (unix, websocket, workspace_http, relays, _iroh, admin, info) = match transport_setup {
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
            // A Cloud machine's carrier (a grant config) also bridges the
            // acpmux service to this user's acpmux carrier socket, in the
            // home `cmux acp` resolves.
            #[cfg(unix)]
            let acpmux_socket = options
                .carrier_grant_config
                .as_ref()
                .and_then(|_| crate::acp::daemon_acpmux_home())
                .map(|home| cmux_remote::acpmux_bridge::socket_path(&home));
            #[cfg(not(unix))]
            let acpmux_socket = None;
            let services = DaemonServices::with_carrier_sockets(
                workspace,
                Some(mux_socket),
                options.local_sockets.clone(),
                acpmux_socket,
            );
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
        #[cfg(feature = "iroh-transport")]
        if let Some(listener) = _iroh
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

/// Installs the carrier grant verifier from `path`. A config that cannot be
/// read leaves grants refused (the daemon's default) and says why; the
/// daemon still serves every other route.
fn install_grant_verifier(auth: &AuthDatabase, path: &Path) {
    let installed = cmux_remote::grant::FileGrantVerifier::load(path).and_then(|verifier| {
        let verifier = verifier.with_unknown_kid_hook(Box::new(report_unknown_kid));
        let machine = verifier.config().machine.clone();
        auth.set_grant_verifier(Arc::new(verifier))
            .map(|()| machine)
            .map_err(|error| error.to_string())
    });
    match installed {
        Ok(machine) => {
            crate::client_log::stderr_log!(
                "remote",
                "{BIN}: carrier grants admitted for {machine}"
            );
        }
        Err(error) => {
            crate::client_log::stderr_log!("remote", "{BIN}: carrier grants refused ({error})");
        }
    }
}

/// Tells the Cloud agent a carrier grant named a kid this daemon's keyset
/// lacks, so it fetches the keyset and rewrites the grant config
/// (cmux-host `cloud/carrier_keyset.rs`). One line on the agent socket, on
/// its own thread so a handshake never waits; every step is bounded by
/// [`UNKNOWN_KID_REPORT_TIMEOUT`], and the verifier reports at most once a
/// minute.
fn report_unknown_kid(kid: &str) {
    let key = cmux_host::cloud::carrier_keyset::REQUEST_KEY;
    let line = format!("{}\n", serde_json::json!({ key: { "kid": kid } }));
    let spawned = thread::Builder::new().name("carrier-keyset-report".into()).spawn(move || {
        use std::io::{Read as _, Write as _};
        let socket = cmux_host::cloud::wire::AGENT_SOCKET;
        let Ok(mut stream) = std::os::unix::net::UnixStream::connect(socket) else { return };
        let _ = stream.set_write_timeout(Some(UNKNOWN_KID_REPORT_TIMEOUT));
        let _ = stream.set_read_timeout(Some(UNKNOWN_KID_REPORT_TIMEOUT));
        if stream.write_all(line.as_bytes()).is_ok() {
            let mut reply = [0_u8; 256];
            let _ = stream.read(&mut reply);
        }
    });
    if let Err(error) = spawned {
        crate::client_log::stderr_log!("remote", "{BIN}: carrier keyset report: {error}");
    }
}

/// Each step of an unknown-kid report (connect is local and immediate).
const UNKNOWN_KID_REPORT_TIMEOUT: Duration = Duration::from_secs(2);

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

#[cfg(test)]
mod tests;
