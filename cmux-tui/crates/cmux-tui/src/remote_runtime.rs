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
    RelayProvider, SshProvider, SshProviderConfig, SupportedClientAuthModes, TailnetCarrierMode,
    TailnetDialer, TailnetHints, TransportProvider, UnixProvider, sanitized_route,
    sanitized_route_text, spawn_relay_daemon_registration,
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
use cmux_remote::ssh_control::SSH_MASTER_AUTH_TIMEOUT;
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

mod daemon_run;
mod daemon_state;
mod route_last_good;
mod route_race;
mod startup_progress;
mod warm_standby;
use cmux_remote::connection::StandbyGroup;
#[cfg(test)]
use daemon_run::{finish_daemon_shutdown, load_daemon_auth_during_handoff};
use daemon_run::{push_unique_route, run_daemon};
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
use route_last_good::LastGoodRoute;
pub(crate) use route_race::{RouteOrder, RouteRace};
use startup_progress::StartupProgress;
pub use startup_progress::startup_refusal;
use warm_standby::{Armed, WarmStandby, arm_standby, next_warm_route, warm_standby_enabled};

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
/// Tailscale candidates stay off here; the connect path uses
/// [`client_provider_registry_with_tailnet`].
#[cfg(test)]
pub fn client_provider_registry(
    ssh: SshProviderConfig,
    relay_routes: BTreeMap<String, RelayClientOptions>,
    iroh_path: IrohPathMode,
    direct_dialer: Option<Arc<dyn Dialer>>,
    direct_carrier_auth: bool,
) -> Result<cmux_remote::provider::ProviderRegistry, ProviderError> {
    client_provider_registry_with_tailnet(
        ssh,
        relay_routes,
        iroh_path,
        direct_dialer,
        direct_carrier_auth,
        TailnetCarrierMode::Off,
        Arc::new(cmux_remote::provider::NoTailnetHints),
    )
}

/// Build the client registry with an optional, cached Tailscale path hint
/// source. The default registry above stays unchanged for callers that do not
/// opt into the setting. `cmux_remote::provider::hints_for_mode` supplies the
/// LocalAPI adapter without changing route races or wire messages.
pub fn client_provider_registry_with_tailnet(
    ssh: SshProviderConfig,
    relay_routes: BTreeMap<String, RelayClientOptions>,
    iroh_path: IrohPathMode,
    direct_dialer: Option<Arc<dyn Dialer>>,
    direct_carrier_auth: bool,
    tailnet_mode: TailnetCarrierMode,
    tailnet_hints: Arc<dyn TailnetHints>,
) -> Result<cmux_remote::provider::ProviderRegistry, ProviderError> {
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    let direct = match direct_dialer {
        Some(dialer) => DirectWebSocketProvider::with_dialer(MAX_CARRIER_FRAME_BYTES, dialer),
        None if tailnet_mode == TailnetCarrierMode::Off => {
            DirectWebSocketProvider::new(MAX_CARRIER_FRAME_BYTES)
        }
        None => DirectWebSocketProvider::with_dialer(
            MAX_CARRIER_FRAME_BYTES,
            Arc::new(TailnetDialer::new(tailnet_mode, tailnet_hints)),
        ),
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
    // SSH authentication (a password typed at the prompt) does not count
    // against the startup budget (issue 38157).
    let auth_clock = options.ssh.connection_share.auth_clock();
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
    let started = std::time::Instant::now();
    let deadline = keep_waiting.is_none().then(|| started + startup_timeout);
    let ready = loop {
        let now = std::time::Instant::now();
        let excluded = auth_clock.as_ref().map_or(Duration::ZERO, |clock| clock.excluded(now));
        let left = deadline.map_or(STARTUP_SIGNAL_POLL, |deadline| {
            (deadline + excluded).saturating_duration_since(now)
        });
        match ready_rx.recv_timeout(left.min(STARTUP_SIGNAL_POLL)) {
            Ok(Ok(ready)) => break ready,
            Ok(Err(failure)) => {
                let _ = shutdown_tx.send(true);
                reap_failed_startup(thread, "cmux-remote-client");
                return Err(failure.into_error());
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
                    "remote connection did not become ready within {}s ({}): the host may be down or the route wrong; `cmux remote known-daemons` lists the routes paired here, and a longer `--connect-timeout-seconds N` waits more",
                    whole_seconds_up(startup_timeout),
                    match error {
                        mpsc::RecvTimeoutError::Timeout => "no answer",
                        mpsc::RecvTimeoutError::Disconnected => "the client stopped",
                    }
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

/// A budget in whole seconds, rounded up. The CLI hands the runtime what is left of
/// `--connect-timeout-seconds N` after loading the identity and routes (N minus some
/// milliseconds), and `Duration::as_secs` truncated that, so a 3 s timeout reported "within 2s".
fn whole_seconds_up(budget: Duration) -> u64 {
    let whole = budget.as_secs();
    if budget.subsec_nanos() == 0 { whole } else { whole.saturating_add(1) }
}

struct ClientReady {
    info: ClientRuntimeInfo,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
}

/// The stderr line a recovering link writes once its `PATH.admin` socket is bound. The app
/// matches it as `SSHMachineLink.socketReadyLine` (CmuxNextRemote/SSH/SSHMachineLink.swift);
/// `tests/remote_connect_link_socket_ready.rs` checks the binary prints it before any dial reports.
pub(crate) const LINK_SOCKET_READY_LINE: &str = "remote connect: link socket ready";

/// `recovering`: the link outlives a failed first connect, and writes
/// [`LINK_SOCKET_READY_LINE`] once its socket answers.
async fn run_client(
    options: ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    ready: mpsc::SyncSender<Result<ClientReady, StartupFailure>>,
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
            // any dial reports (a stalled first dial says only that it is still connecting).
            eprintln!("{LINK_SOCKET_READY_LINE}");
        }
        let (connection, route) =
            dial_first_connection(&options, shutdown.clone(), sidecars.cell(), sidecars.network())
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
        let _sidecars = sidecars.attach(&connection, &multiplexer);
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
        // The owner reads the text; a far refusal also stays typed, so the CLI can say what to
        // do about it (`startup_refusal`).
        let _ = ready.send(Err(StartupFailure {
            message: format!("{error:#}"),
            refusal: startup_refusal(error).cloned(),
        }));
    }
    setup
}

/// Why a client's startup ended, as its owner thread reads it.
struct StartupFailure {
    message: String,
    refusal: Option<cmux_remote::link::Refusal>,
}

impl StartupFailure {
    fn into_error(self) -> anyhow::Error {
        match self.refusal {
            Some(refusal) => anyhow::Error::new(cmux_remote::link::LinkError::Refused(refusal))
                .context(self.message),
            None => anyhow!(self.message),
        }
    }
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
    dial_first_connection(options, shutdown, &LinkCell::new(), network).await
}

/// The first connect, run like a recovery of a later drop (`LinkCell::dial`): budgeted bursts
/// that park between them, a network change on `network` or a caller's wait dials at once, and
/// `cell` says where it is. A retryable route failure never ends it unless the policy bounds the
/// attempts; a permanent one (a refused identity, a changed daemon key, a far refusal no redial
/// cures) does. It says on stderr why it redials and that it is still connecting, at most once
/// per [`startup_progress::PROGRESS_EVERY`] and never silent for longer (`StartupProgress`).
async fn dial_first_connection(
    options: &ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    cell: &LinkCell,
    network: watch::Receiver<u64>,
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    let attempt_shutdown = shutdown.clone();
    let progress = StartupProgress::new(match &options.auth {
        ClientAuthMode::Invitation { id, .. } => Some(id.clone()),
        _ => None,
    });
    let progress = &progress;
    let last_good = LastGoodRoute::open(Some(&options.state_dir), options.expected_daemon);
    let last_good = last_good.as_ref();
    let dial = cell.dial(options.reconnect, network, || {
        let attempt =
            RuntimeInitialRouteAttempt { options, shutdown: attempt_shutdown.clone(), last_good };
        // Read each round: a remembered route that failed last round is forgotten by now.
        let first = last_good
            .and_then(|memory| memory.first(&options.routes, options.ssh_bootstrap.upgrade));
        let order = initial_route_order(options, first, last_good);
        async move {
            match select_initial_route_from(
                &options.routes,
                order,
                options.session,
                options.lane_policy,
                client_auth_kind(&options.auth),
                options.ssh_bootstrap.upgrade,
                &attempt,
            )
            .await
            {
                Ok(connection) => DialOutcome::Ready(connection),
                Err(error) if error.retryable => {
                    progress.redialing(&error.error);
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
        never = progress.tick() => match never {},
    }
}

/// How a first connect's round orders its routes: the remembered route first, and the routes
/// raced ([`route_race`]) when the connect is enrolled. An invitation is never raced (each
/// racer would ask the person to approve it), nor a grant (it may be single-use), nor
/// `--upgrade` (its SSH route installs the daemon first, alone).
fn initial_route_order(
    options: &ClientRuntimeOptions,
    first: Option<usize>,
    last_good: Option<&LastGoodRoute>,
) -> RouteOrder {
    let raceable = matches!(options.auth, ClientAuthMode::Enrolled)
        && !options.ssh_bootstrap.upgrade
        && options.routes.len() > 1
        && route_race_enabled();
    // A route broken on this network is dialed after the others, not skipped.
    let late = last_good.map_or(0, |memory| memory.late(&options.routes));
    if !raceable {
        return RouteOrder::serial(first).with_late(late);
    }
    // The stagger follows the leading route's last connect time when it is the remembered one.
    let lead = first.and(last_good.and_then(LastGoodRoute::connect_time));
    RouteOrder::raced(first, RouteRace::after(lead)).with_late(late)
}

/// `CMUX_REMOTE_ROUTE_RACE=0` dials the routes one at a time again (the A/B for the race's
/// numbers).
fn route_race_enabled() -> bool {
    std::env::var_os("CMUX_REMOTE_ROUTE_RACE").is_none_or(|value| value != "0")
}

/// The reconnect pass races when the first connect would: a follow-up dial is Enrolled unless
/// the link is a carrier's, and a reconnect is never an upgrade. No remembered connect time
/// reaches it, so the stagger is the floor.
fn reconnect_race(options: &ClientRuntimeOptions) -> Option<RouteRace> {
    (followup_auth_kind(&options.auth) == AuthKind::Enrolled
        && options.routes.len() > 1
        && route_race_enabled())
    .then(|| RouteRace::after(None))
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

/// One pass's route dials. The pass may run several at once ([`route_race`]), so both take
/// `&self`.
#[async_trait]
pub(crate) trait InitialRouteAttempt<T: Send, E: Send = anyhow::Error>: Sync {
    async fn bootstrap_ssh(
        &self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError<E>>;
    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<T, InitialRouteAttemptError<E>>;
}

/// One pass over `routes` in their own order, one at a time.
pub(crate) async fn select_initial_route<T: Send, E: RouteFailure>(
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    upgrade: bool,
    attempt: &impl InitialRouteAttempt<T, E>,
) -> Result<T, InitialRouteSelectionError<E>> {
    select_initial_route_from(
        routes,
        RouteOrder::default(),
        session,
        lane_policy,
        auth,
        upgrade,
        attempt,
    )
    .await
}

/// [`select_initial_route`] in `order`: `routes[order.first]` (the last-known-good route,
/// [`LastGoodRoute`]) before the others, the rest in their own order, raced when `order.race`
/// is set ([`route_race`]). Each attempt still gets the route's index in `routes`. The order
/// is ignored when `upgrade` is set: SSH at 0 must go first, alone.
pub(crate) async fn select_initial_route_from<T: Send, E: RouteFailure>(
    routes: &[ResolvedRouteCandidate],
    order: RouteOrder,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    upgrade: bool,
    attempt: &impl InitialRouteAttempt<T, E>,
) -> Result<T, InitialRouteSelectionError<E>> {
    route_race::select_routes(routes, order, session, lane_policy, auth, upgrade, attempt).await
}

struct RuntimeInitialRouteAttempt<'a> {
    options: &'a ClientRuntimeOptions,
    shutdown: watch::Receiver<bool>,
    /// The daemon's last-known-good route: told which route connected, and which failed.
    last_good: Option<&'a LastGoodRoute>,
}

#[async_trait]
impl InitialRouteAttempt<(Arc<ClientConnection>, String)> for RuntimeInitialRouteAttempt<'_> {
    async fn bootstrap_ssh(
        &self,
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
        .map_err(|error| {
            if let Some(memory) = self.last_good {
                memory.failed(endpoint);
                memory.leg(endpoint, cmux_braid_path::Outcome::of_text(&format!("{error:#}")));
            }
            InitialRouteAttemptError::Route {
                retryable: !upgrade && ssh_bootstrap_failure_is_retryable(&error),
                error,
            }
        })
    }

    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<(Arc<ClientConnection>, String), InitialRouteAttemptError> {
        let endpoint = request.endpoint.clone();
        let started = tokio::time::Instant::now();
        // A dial the race drops (another route won first) counts as outrun.
        let mut leg = LegOutcome { memory: self.last_good, endpoint: &endpoint, outcome: None };
        let result = self.connect_route(index, request).await;
        if let Some(memory) = self.last_good {
            match &result {
                Ok(_) => {
                    memory.connected_in(&endpoint, started.elapsed());
                    leg.outcome = Some(cmux_braid_path::Outcome::Won);
                }
                Err(InitialRouteAttemptError::Route { error, .. }) => {
                    memory.failed(&endpoint);
                    leg.outcome = Some(cmux_braid_path::Outcome::of_text(&format!("{error:#}")));
                }
                // A refusal or a cancel says nothing about the route.
                Err(InitialRouteAttemptError::Fatal(_)) => leg.memory = None,
            }
        }
        result
    }
}

/// How one route's dial ended, counted when the dial ends or is dropped
/// ([`LastGoodRoute::leg`]).
struct LegOutcome<'a> {
    memory: Option<&'a LastGoodRoute>,
    endpoint: &'a Url,
    outcome: Option<cmux_braid_path::Outcome>,
}

impl Drop for LegOutcome<'_> {
    fn drop(&mut self) {
        if let Some(memory) = self.memory {
            memory.leg(self.endpoint, self.outcome.unwrap_or(cmux_braid_path::Outcome::Outrun));
        }
    }
}

impl RuntimeInitialRouteAttempt<'_> {
    async fn connect_route(
        &self,
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
                // A far refusal no redial cures ends the startup, other routes included: they
                // reach the same machine, which refuses them the same way.
                Ok(Err(error)) if error.refusal().is_some() => {
                    return Err(InitialRouteAttemptError::Fatal(error.into()));
                }
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
        let standby_groups = Arc::new(RuntimeReconnectGroups::with_shutdown(
            self.options.clone(),
            index,
            self.shutdown.clone(),
        ));
        let reconnect_groups: Arc<dyn ReconnectGroupSource> = standby_groups.clone();
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
            Ok(connection) => {
                // The link is up: the best other route goes warm beside it.
                standby_groups.start_standby();
                Ok((connection, route))
            }
            Err(error) if error.refusal().is_some() => {
                close_failed_initial_group(&group).await;
                Err(InitialRouteAttemptError::Fatal(error.into()))
            }
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
    config.connection_share = ssh.connection_share.clone();
    let bootstrap = SshBootstrapper::new(config)?;
    // Authenticate once, before the attempt budget starts: a person may be
    // typing a password, and every later step reuses this connection.
    tokio::select! {
        result = bootstrap.connect() => result?,
        () = wait_for_shutdown_request(shutdown.clone()) => {
            return Err(anyhow!("SSH bootstrap interrupted"));
        }
    }
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

/// Opens (or reuses) the route's shared SSH connection: the same target the
/// bootstrap and the carrier links use, so they all ride on it.
async fn open_shared_ssh_connection(endpoint: &Url, ssh: &SshProviderConfig) -> anyhow::Result<()> {
    let (destination, port) = ssh_bootstrap_destination(endpoint)?;
    ssh.connection_share
        .client_arguments(&cmux_remote::ssh_control::SshTarget {
            ssh_binary: ssh.ssh_binary.clone(),
            destination,
            port,
            extra_args: ssh.extra_args.clone(),
        })
        .await?;
    Ok(())
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

pub(crate) fn ssh_bootstrap_destination(endpoint: &Url) -> anyhow::Result<(String, Option<u16>)> {
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

/// [`route_race::select_reconnect_routes`] one route at a time.
#[cfg(test)]
async fn select_reconnect_route<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<(usize, T), ProviderError> {
    route_race::select_reconnect_routes(routes, start, None, session, lane_policy, auth, attempt)
        .await
}

struct RuntimeReconnectGroups {
    inner: Arc<ReconnectGroupsInner>,
}

struct ReconnectGroupsInner {
    options: ClientRuntimeOptions,
    next: AtomicUsize,
    /// The reconnect pass's race (`None`: one route at a time), as the first connect's.
    race: Option<RouteRace>,
    prepared_ssh: Vec<AtomicBool>,
    shutdown: Option<watch::Receiver<bool>>,
    /// The warm standby route (`warm_standby.rs`); empty until [`Self::start_standby`].
    standby: WarmStandby<Arc<dyn LinkGroup>>,
}

impl std::ops::Deref for RuntimeReconnectGroups {
    type Target = ReconnectGroupsInner;

    fn deref(&self) -> &ReconnectGroupsInner {
        &self.inner
    }
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
        let race = reconnect_race(&options);
        Self {
            inner: Arc::new(ReconnectGroupsInner {
                options,
                next: AtomicUsize::new(selected_index.saturating_add(1)),
                race,
                prepared_ssh,
                shutdown,
                standby: WarmStandby::new(selected_index),
            }),
        }
    }

    /// Starts keeping one warm standby route, once the active link is up. One keeper task per
    /// peer; it ends when this source is dropped. A no-op for a single route, for any follow-up
    /// auth but Enrolled, and with `CMUX_REMOTE_WARM_STANDBY=0`.
    fn start_standby(&self) {
        if !self.standby_enabled() {
            return;
        }
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        runtime.spawn(keep_standby(Arc::downgrade(&self.inner), self.standby.wake()));
    }

    fn standby_enabled(&self) -> bool {
        followup_auth_kind(&self.options.auth) == AuthKind::Enrolled
            && self.options.routes.len() > 1
            && warm_standby_enabled()
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
        // Each SSH route may open its shared connection, which may prompt.
        let ssh_authentications = if self.options.ssh.connection_share.auth_clock().is_some() {
            u32::try_from(
                self.options
                    .routes
                    .iter()
                    .filter(|candidate| {
                        candidate.endpoint.scheme() == "ssh" && candidate.supports_client_auth(auth)
                    })
                    .count(),
            )
            .unwrap_or(u32::MAX)
        } else {
            0
        };
        reconnect_attempt_timeout
            .saturating_mul(provider_attempts)
            .saturating_add(
                self.options.ssh_bootstrap.attempt_timeout.saturating_mul(ssh_bootstraps),
            )
            .saturating_add(SSH_MASTER_AUTH_TIMEOUT.saturating_mul(ssh_authentications))
    }

    /// Every route this client can authenticate on but the link's own. Without the route race
    /// (`CMUX_REMOTE_ROUTE_RACE=0`, or a grant that is single-use) a redial is not raced either.
    fn alternates(&self) -> Option<usize> {
        self.race?;
        let auth = followup_auth_kind(&self.options.auth);
        let routes = self
            .options
            .routes
            .iter()
            .filter(|candidate| candidate.supports_client_auth(auth))
            .count();
        Some(routes.saturating_sub(1))
    }

    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let attempt = RuntimeReconnectRouteAttempt {
            options: &self.options,
            prepared_ssh: &self.prepared_ssh,
            shutdown: self.shutdown.clone(),
        };
        let (group, stale) = next_warm_route(
            &self.standby,
            &self.next,
            &self.options.routes,
            self.race,
            self.options.session,
            self.options.lane_policy,
            followup_auth_kind(&self.options.auth),
            &attempt,
            group_alive,
        )
        .await?;
        if let Some(stale) = stale {
            close_failed_initial_group(&stale).await;
        }
        Ok(group)
    }

    async fn take_standby(&self) -> Option<StandbyGroup> {
        let (_, group) = match warm_standby::take_standby(&self.standby, &self.next, group_alive)? {
            Ok(taken) => taken,
            Err(stale) => {
                close_failed_initial_group(&stale).await;
                return None;
            }
        };
        let rtt = group
            .transport_snapshot()
            .await
            .selected_path
            .and_then(|path| path.rtt_micros)
            .map(Duration::from_micros);
        Some(StandbyGroup {
            group,
            attempt_timeout: warm_standby::attempt_timeout(rtt),
            race_after: self.race.map(|race| race.stagger),
        })
    }
}

/// A held group is live until it says it closed (no round trip).
fn group_alive(group: &Arc<dyn LinkGroup>) -> bool {
    !group.is_closed()
}

/// The keeper of one peer's warm standby: dials it when the slot is empty, closed or due its
/// replacement, and looks again when the reconnect took it, when the held group closes, at its
/// refresh, or after a backoff when the dial failed (or the group closed within
/// [`warm_standby::MIN_LIFE`]). Holds the source only weakly, so it ends with it.
async fn keep_standby(weak: std::sync::Weak<ReconnectGroupsInner>, wake: Arc<tokio::sync::Notify>) {
    let mut backoff = warm_standby::INITIAL_BACKOFF;
    loop {
        let Some(inner) = weak.upgrade() else { return };
        if inner.shutdown.as_ref().is_some_and(|shutdown| *shutdown.borrow()) {
            return;
        }
        let attempt = RuntimeReconnectRouteAttempt {
            options: &inner.options,
            prepared_ssh: &inner.prepared_ssh,
            shutdown: inner.shutdown.clone(),
        };
        let armed = arm_standby(
            &inner.standby,
            &inner.next,
            &inner.options.routes,
            inner.options.session,
            inner.options.lane_policy,
            followup_auth_kind(&inner.options.auth),
            &attempt,
            group_alive,
            |group: Arc<dyn LinkGroup>| async move { group.hold().await },
        )
        .await;
        let mut wait = match armed {
            Ok(Armed::Held(left)) => left,
            Ok(Armed::Dialed { retired, .. }) => {
                if let Some(retired) = retired {
                    close_failed_initial_group(&retired).await;
                }
                // Look again at once: the slot answers `Held` with its refresh, which a hold
                // the far end granted puts minutes out instead of seconds.
                Duration::ZERO
            }
            Ok(Armed::NoRoute) => return,
            Ok(Armed::Cooling(left)) => left,
            Err(_) => {
                let wait = backoff;
                backoff = (backoff * 2).min(warm_standby::MAX_BACKOFF);
                wait
            }
        };
        let held = inner.standby.held();
        drop(inner);
        let closed = async {
            match &held {
                Some((group, _)) => group.wait_closed().await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = tokio::time::sleep(wait) => {}
            () = wake.notified() => {}
            () = closed => {
                // Closed while held: re-arm now, unless it died young (back off then).
                let lived = held.as_ref().map(|(_, armed_at)| armed_at.elapsed());
                if lived.is_some_and(|lived| lived < warm_standby::MIN_LIFE) {
                    wait = backoff;
                    backoff = (backoff * 2).min(warm_standby::MAX_BACKOFF);
                    tokio::select! {
                        () = tokio::time::sleep(wait) => {}
                        () = wake.notified() => {}
                    }
                }
                continue;
            }
        }
        if held.as_ref().is_some_and(|(_, armed_at)| armed_at.elapsed() >= warm_standby::MIN_LIFE) {
            backoff = warm_standby::INITIAL_BACKOFF;
        }
    }
}

/// The next route of an established link after its current one failed:
/// from `next` (one past the route that last connected) round the list,
/// and `next` moves past the route that connects. `remote connect` and the
/// Cloud carrier (`carrier::source`) both rotate this way; `remote connect` races the routes
/// (`race`), the carrier, whose grants are single-use, does not.
pub(crate) async fn next_reconnect_route<T: Send>(
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<T, ProviderError> {
    next_reconnect_route_skipping(next, routes, None, race, session, lane_policy, auth, attempt)
        .await
}

/// [`next_reconnect_route`] with one route left out of the pass (the route a warm standby
/// was just taken from), unless it is the only one.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn next_reconnect_route_skipping<T: Send>(
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    skip: Option<usize>,
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<T, ProviderError> {
    // A raced pass moves `next` only when it ends: a redial that asks for the next route and
    // is dropped by a network change a moment later (`ClientConnection::race_redial`) asks
    // again and must get the same route, not the one after it. A pass that tries its routes
    // one at a time still moves on before it starts, so one dropped on a hung route does not
    // start on that route again.
    let from = if race.is_some() {
        next.load(Ordering::Relaxed)
    } else {
        next.fetch_add(1, Ordering::Relaxed)
    };
    let Some(start) = from.checked_rem(routes.len()) else {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    };
    let selected = route_race::select_reconnect_routes_skipping(
        routes,
        start,
        skip,
        race,
        session,
        lane_policy,
        auth,
        attempt,
    )
    .await;
    match selected {
        Ok((index, group)) => {
            next.store(index.saturating_add(1), Ordering::Relaxed);
            Ok(group)
        }
        Err(error) => {
            if race.is_some() {
                next.store(start.saturating_add(1), Ordering::Relaxed);
            }
            Err(error)
        }
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
        if endpoint.scheme() == "ssh" {
            // A master lost with the network authenticates again here, out of
            // the attempt budget: a person may be typing a password, and a
            // 15 s cut would kill ssh and prompt again each attempt.
            tokio::select! {
                result = open_shared_ssh_connection(&endpoint, &self.options.ssh) => {
                    result.map_err(|error| ProviderError::Transport(format!(
                        "SSH connection failed for reconnect route {display_endpoint}: {error:#}"
                    )))?;
                }
                () = wait_for_shutdown_request(self.shutdown.clone()) => {
                    return Err(ProviderError::Transport("SSH reconnect interrupted".into()));
                }
            }
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

#[cfg(test)]
mod tests;
