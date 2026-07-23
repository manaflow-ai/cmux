//! Lifecycle glue between the synchronous TUI/core and the asynchronous
//! transport-neutral remote daemon.

use std::collections::BTreeMap;
use std::fs;
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
use cmux_remote::crypto::{ClientAuthMode, CryptoError, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, serve_direct_websocket, serve_unix};
use cmux_remote::identity::{AuthDatabase, default_state_dir};
use cmux_remote::observability::ClientConnectionSnapshot;
use cmux_remote::provider::{
    ConnectRequest, DirectWebSocketProvider, IrohListener, IrohPathMode, IrohProvider,
    IrohProviderConfig, LinkGroup, ProviderError, RelayClientConfig, RelayCredentialSource,
    RelayDaemonConfig, RelayDaemonRegistration, RelayProvider, SshProvider, SshProviderConfig,
    TransportProvider, UnixProvider, load_or_create_iroh_secret,
    register_relay_daemon_with_credentials, sanitized_route,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::ssh_bootstrap::{SshBootstrapConfig, SshBootstrapper};
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use url::Url;

pub const MAX_CARRIER_FRAME_BYTES: usize = 65_535;
const MIN_REMOTE_RUNTIME_WORKERS: usize = 2;
const MAX_REMOTE_RUNTIME_WORKERS: usize = 4;

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

#[derive(Debug, Clone)]
pub struct RelayDaemonOptions {
    pub endpoint: Url,
    pub slot: String,
    pub credentials: RelayCredentialSource,
}

#[derive(Debug, Clone)]
pub struct DaemonRuntimeOptions {
    pub session: String,
    pub state_dir: Option<PathBuf>,
    pub link_socket: Option<PathBuf>,
    pub admin_socket: Option<PathBuf>,
    pub direct_websocket: Option<SocketAddr>,
    pub allow_insecure_non_loopback: bool,
    pub relays: Vec<RelayDaemonOptions>,
    pub iroh: bool,
    pub advertised_routes: Vec<String>,
    pub resume_lease: Duration,
    pub replaceable_sidecar: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonRuntimeInfo {
    pub session: String,
    pub state_dir: PathBuf,
    pub link_socket: PathBuf,
    pub admin_socket: PathBuf,
    pub daemon_fingerprint: String,
    pub routes: Vec<String>,
    pub direct_websocket: Option<SocketAddr>,
    pub iroh_node_id: Option<String>,
    #[serde(default)]
    pub replaceable_sidecar: bool,
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

#[derive(Debug, Clone)]
pub struct RelayClientOptions {
    pub slot: String,
    pub credentials: RelayCredentialSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRouteCandidate {
    pub endpoint: Url,
    pub routing: BTreeMap<String, String>,
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
    /// Explicit fallback credential applied to any relay route.
    pub relay: Option<RelayClientOptions>,
    /// Invitation-scoped credentials keyed by normalized relay route URL.
    pub relay_routes: BTreeMap<String, RelayClientOptions>,
    pub iroh_path: IrohPathMode,
    pub ssh: SshProviderConfig,
    pub ssh_bootstrap: SshBootstrapOptions,
}

#[derive(Debug, Clone)]
pub struct ClientRuntimeInfo {
    pub local_socket: PathBuf,
    pub daemon_public_key: [u8; 32],
    pub route: String,
}

pub struct ClientRuntimeHandle {
    info: ClientRuntimeInfo,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    shutdown: watch::Sender<bool>,
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
    let startup_timeout = options.startup_timeout;
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name("cmux-remote-client".into())
        .spawn(move || {
            let runtime = build_remote_runtime("cmux-remote-client-worker")
                .context("could not start remote client Tokio runtime")?;
            runtime.block_on(run_client(options, shutdown_rx, ready_tx))
        })
        .context("could not start remote client thread")?;
    let ready = match ready_rx.recv_timeout(startup_timeout) {
        Ok(Ok(ready)) => ready,
        Ok(Err(error)) => {
            let _ = shutdown_tx.send(true);
            let _ = thread.join();
            return Err(anyhow!(error));
        }
        Err(error) => {
            let _ = shutdown_tx.send(true);
            let _ = thread.join();
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
        thread: Some(thread),
    })
}

struct ClientReady {
    info: ClientRuntimeInfo,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
}

async fn run_client(
    options: ClientRuntimeOptions,
    mut shutdown: watch::Receiver<bool>,
    ready: mpsc::SyncSender<Result<ClientReady, String>>,
) -> anyhow::Result<()> {
    let setup = async {
        let (connection, route) = tokio::select! {
            result = connect_first_available(&options) => result?,
            _ = wait_for_shutdown(&mut shutdown) => return Ok(()),
        };
        let local_socket = options
            .local_socket
            .clone()
            .unwrap_or_else(|| default_client_socket(&options.state_dir, options.session));
        prepare_client_socket(&local_socket).await?;
        let daemon_public_key = connection.daemon_public_key();
        let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
        let listener = tokio::net::UnixListener::bind(&local_socket)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&local_socket, fs::Permissions::from_mode(0o600))?;
        }
        let (bridge_shutdown_tx, bridge_shutdown_rx) = tokio::sync::oneshot::channel();
        let mut bridge =
            tokio::spawn(serve_mux_bridge(multiplexer.clone(), listener, bridge_shutdown_rx));
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
        let _ = fs::remove_file(&local_socket);
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
) -> anyhow::Result<(Arc<ClientConnection>, String)> {
    let mut attempt = RuntimeInitialRouteAttempt { options };
    select_initial_route(
        &options.routes,
        options.session,
        options.lane_policy,
        options.ssh_bootstrap.upgrade,
        &mut attempt,
    )
    .await
}

enum InitialRouteAttemptError {
    Route(anyhow::Error),
    Fatal(anyhow::Error),
}

#[async_trait]
trait InitialRouteAttempt<T: Send> {
    async fn bootstrap_ssh(&mut self, endpoint: &Url, upgrade: bool) -> anyhow::Result<()>;
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
    upgrade: bool,
    attempt: &mut impl InitialRouteAttempt<T>,
) -> anyhow::Result<T> {
    if routes.is_empty() {
        return Err(anyhow!("remote connection has no route candidates"));
    }
    if upgrade && routes[0].endpoint.scheme() != "ssh" {
        return Err(anyhow!("--upgrade requires SSH to be the initial route"));
    }
    let mut failures = Vec::new();
    for (index, candidate) in routes.iter().enumerate() {
        let request = connect_request(candidate, session, lane_policy)?;
        let endpoint = request.endpoint.clone();
        let display_endpoint = sanitized_route(&endpoint);
        let upgrade_candidate = upgrade && index == 0;
        if endpoint.scheme() == "ssh"
            && let Err(error) = attempt.bootstrap_ssh(&endpoint, upgrade_candidate).await
        {
            if upgrade_candidate {
                return Err(anyhow!("SSH bootstrap failed for {display_endpoint}: {error:#}"));
            }
            failures.push(format!("{display_endpoint}: SSH bootstrap failed: {error:#}"));
            continue;
        }
        match attempt.connect(index, request).await {
            Ok(result) => return Ok(result),
            Err(InitialRouteAttemptError::Route(error)) => {
                if upgrade_candidate {
                    return Err(anyhow!(
                        "upgraded SSH route failed for {display_endpoint}: {error:#}"
                    ));
                }
                failures.push(format!("{display_endpoint}: {error:#}"));
            }
            Err(InitialRouteAttemptError::Fatal(error)) => return Err(error),
        }
    }
    Err(anyhow!("all remote route candidates failed: {}", failures.join("; ")))
}

struct RuntimeInitialRouteAttempt<'a> {
    options: &'a ClientRuntimeOptions,
}

#[async_trait]
impl InitialRouteAttempt<(Arc<ClientConnection>, String)> for RuntimeInitialRouteAttempt<'_> {
    async fn bootstrap_ssh(&mut self, endpoint: &Url, upgrade: bool) -> anyhow::Result<()> {
        bootstrap_initial_ssh_route(
            endpoint,
            &self.options.ssh,
            self.options.ssh_bootstrap,
            upgrade,
        )
        .await
    }

    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<(Arc<ClientConnection>, String), InitialRouteAttemptError> {
        let group = connect_provider(self.options, request)
            .await
            .map_err(|error| InitialRouteAttemptError::Route(error.into()))?;
        let route = group.description().to_string();
        let reconnect_groups: Arc<dyn ReconnectGroupSource> =
            Arc::new(RuntimeReconnectGroups::new(self.options.clone(), index));
        let connection = ClientConnection::connect_with_reconnect_groups(
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
        )
        .await;
        match connection {
            Ok(connection) => Ok((connection, route)),
            Err(error) if route_failure_allows_fallback(&error) => {
                let _ = group.close().await;
                Err(InitialRouteAttemptError::Route(error.into()))
            }
            Err(error) => Err(InitialRouteAttemptError::Fatal(error.into())),
        }
    }
}

async fn bootstrap_initial_ssh_route(
    endpoint: &Url,
    ssh: &SshProviderConfig,
    options: SshBootstrapOptions,
    upgrade: bool,
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
            Ok::<(), cmux_remote::ssh_bootstrap::BootstrapError>(())
        }) => {
            result.map_err(|_| anyhow!(
                "SSH bootstrap timed out after {}s",
                options.attempt_timeout.as_secs()
            ))??;
            Ok(())
        }
        () = wait_for_shutdown_request() => Err(anyhow!("SSH bootstrap interrupted")),
    }
}

async fn wait_for_shutdown_request() {
    while !crate::shutdown_requested() {
        tokio::time::sleep(Duration::from_millis(50)).await;
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
    Ok((destination, endpoint.port()))
}

async fn connect_provider(
    options: &ClientRuntimeOptions,
    request: ConnectRequest,
) -> Result<Arc<dyn LinkGroup>, ProviderError> {
    match request.endpoint.scheme() {
        "ws" | "wss" => {
            Ok(DirectWebSocketProvider::new(MAX_CARRIER_FRAME_BYTES).connect(request).await?)
        }
        "unix" => Ok(UnixProvider::new(MAX_CARRIER_FRAME_BYTES).connect(request).await?),
        "ssh" => Ok(SshProvider::new(options.ssh.clone())?.connect(request).await?),
        "relay+ws" | "relay+wss" | "relay+https" | "relay+do" => {
            let relay = options
                .relay_routes
                .get(request.endpoint.as_str())
                .or(options.relay.as_ref())
                .ok_or_else(|| {
                    ProviderError::Configuration(
                        "relay routes require relay slot and credentials".into(),
                    )
                })?;
            Ok(RelayProvider::with_credentials(
                RelayClientConfig {
                    slot: relay.slot.clone(),
                    ticket: String::new(),
                    maximum_frame_bytes: MAX_CARRIER_FRAME_BYTES,
                    control_timeout: Duration::from_secs(15),
                },
                relay.credentials.clone(),
            )?
            .connect(request)
            .await?)
        }
        "iroh" => {
            Ok(IrohProvider::new(IrohProviderConfig::default().with_path_mode(options.iroh_path))?
                .connect(request)
                .await?)
        }
        scheme => {
            Err(ProviderError::Configuration(format!("unsupported remote route scheme {scheme:?}")))
        }
    }
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
    async fn connect(&self, index: usize, request: ConnectRequest) -> Result<T, ProviderError>;
}

async fn select_reconnect_route<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    session: SessionId,
    lane_policy: LanePolicy,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<(usize, T), ProviderError> {
    if routes.is_empty() {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    }
    let mut failures = Vec::new();
    for offset in 0..routes.len() {
        let index = (start + offset) % routes.len();
        let request = connect_request(&routes[index], session, lane_policy)
            .map_err(|error| ProviderError::Configuration(error.to_string()))?;
        let endpoint = request.endpoint.clone();
        let display_endpoint = sanitized_route(&endpoint);
        match attempt.connect(index, request).await {
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
}

impl RuntimeReconnectGroups {
    fn new(options: ClientRuntimeOptions, selected_index: usize) -> Self {
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
        Self { options, next: AtomicUsize::new(selected_index.saturating_add(1)), prepared_ssh }
    }

    fn unprepared_installable_ssh_count(&self) -> usize {
        if !self.options.ssh_bootstrap.auto_install {
            return 0;
        }
        self.options
            .routes
            .iter()
            .enumerate()
            .filter(|(index, candidate)| {
                candidate.endpoint.scheme() == "ssh"
                    && !self.prepared_ssh[*index].load(Ordering::Acquire)
            })
            .count()
    }
}

#[async_trait]
impl ReconnectGroupSource for RuntimeReconnectGroups {
    fn resolution_timeout(&self, reconnect_attempt_timeout: Duration) -> Duration {
        let provider_attempts = u32::try_from(self.options.routes.len().max(1)).unwrap_or(u32::MAX);
        let ssh_bootstraps =
            u32::try_from(self.unprepared_installable_ssh_count()).unwrap_or(u32::MAX);
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
        };
        let start = self.next.fetch_add(1, Ordering::Relaxed) % count;
        let (index, group) = select_reconnect_route(
            &self.options.routes,
            start,
            self.options.session,
            self.options.lane_policy,
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
}

#[async_trait]
impl ReconnectRouteAttempt<Arc<dyn LinkGroup>> for RuntimeReconnectRouteAttempt<'_> {
    async fn connect(
        &self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let endpoint = request.endpoint.clone();
        let display_endpoint = sanitized_route(&endpoint);
        if endpoint.scheme() == "ssh" && !self.prepared_ssh[index].load(Ordering::Acquire) {
            bootstrap_initial_ssh_route(
                &endpoint,
                &self.options.ssh,
                self.options.ssh_bootstrap,
                false,
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
            connect_provider(self.options, request),
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

async fn prepare_client_socket(path: &Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    if !unix_socket_path_fits(path) {
        return Err(anyhow!(
            "client socket path is too long for this platform: {}",
            path.display()
        ));
    }
    let parent = path.parent().ok_or_else(|| anyhow!("client socket path has no parent"))?;
    let parent_existed = parent.exists();
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{FileTypeExt, PermissionsExt};
        if !parent_existed {
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        } else {
            let mode = fs::metadata(parent)?.permissions().mode();
            if mode & 0o022 != 0 && mode & 0o1000 == 0 {
                return Err(anyhow!(
                    "client socket directory {} is writable by other users and is not sticky",
                    parent.display()
                ));
            }
        }
        if let Ok(metadata) = fs::symlink_metadata(path) {
            if !metadata.file_type().is_socket() {
                return Err(anyhow!(
                    "refusing to replace non-socket client path {}",
                    path.display()
                ));
            }
            if tokio::net::UnixStream::connect(path).await.is_ok() {
                return Err(anyhow!("another client owns {}", path.display()));
            }
            fs::remove_file(path)?;
        }
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
    let session = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(session.as_bytes());
    let state = root.join("sessions").join(session);
    Ok((state.clone(), state.join("link.sock"), state.join("admin.sock")))
}

pub fn start_daemon_runtime(
    mux_socket: PathBuf,
    options: DaemonRuntimeOptions,
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
            runtime.block_on(run_daemon(
                mux_socket,
                options,
                state_dir,
                link_socket,
                admin_socket,
                shutdown_rx,
                owner_shutdown,
                ready_tx,
            ))
        })
        .context("could not start remote daemon thread")?;

    let info = match ready_rx.recv_timeout(Duration::from_secs(30)) {
        Ok(Ok(info)) => info,
        Ok(Err(error)) => {
            let _ = shutdown_tx.send(true);
            let _ = thread.join();
            return Err(anyhow!(error));
        }
        Err(error) => {
            let _ = shutdown_tx.send(true);
            let _ = thread.join();
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
        fs::create_dir_all(&state_dir)
            .with_context(|| format!("could not create {}", state_dir.display()))?;
        let auth =
            AuthDatabase::load_or_create(state_dir.join("auth"), options.session.clone(), true)?;
        let (daemon, clients) = cmux_remote::daemon::RemoteDaemon::with_policy(
            auth.clone(),
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: options.resume_lease },
        )?;

        let unix = serve_unix(daemon.clone(), &link_socket, MAX_CARRIER_FRAME_BYTES).await?;
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
        let mut startup_shutdown = shutdown.clone();
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
                Some(IrohListener::bind(daemon.clone(), config).await?)
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
                if let Some(addresses) = hints.get(cmux_remote::provider::ROUTING_DIRECT_ADDRS) {
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

        let admin =
            serve_admin_with_shutdown(daemon, &admin_socket, routes.clone(), Some(owner_shutdown))
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
            replaceable_sidecar: options.replaceable_sidecar,
        };
        persist_runtime_info(&state_dir, &info)?;
        ready.send(Ok(info)).map_err(|_| anyhow!("daemon owner stopped during startup"))?;

        let services = DaemonServices::new(WorkspaceService::new(), Some(mux_socket));
        services.run_with_shutdown(clients, shutdown).await;

        admin.shutdown().await;
        if let Some(listener) = iroh {
            listener.shutdown().await?;
        }
        for registration in relays {
            shutdown_relay(registration).await;
        }
        if let Some(server) = websocket {
            server.shutdown().await?;
        }
        unix.shutdown().await;
        let _ = fs::remove_file(state_dir.join("runtime.json"));
        Ok::<_, anyhow::Error>(())
    }
    .await;

    if let Err(error) = &setup {
        let _ = ready.send(Err(format!("{error:#}")));
    }
    setup
}

fn push_unique_route(routes: &mut Vec<String>, route: String) {
    if !routes.iter().any(|existing| existing == &route) {
        routes.push(route);
    }
}

async fn shutdown_relay(registration: RelayDaemonRegistration) {
    registration.shutdown().await;
}

fn persist_runtime_info(state_dir: &Path, info: &DaemonRuntimeInfo) -> anyhow::Result<()> {
    let path = state_dir.join("runtime.json");
    let temporary = state_dir.join(format!(".runtime-{}.json", std::process::id()));
    fs::write(&temporary, serde_json::to_vec_pretty(info)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(temporary, path)?;
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn resolved_test_route(
        route: &str,
        supported_auth: cmux_remote::provider::SupportedClientAuthModes,
    ) -> ResolvedRouteCandidate {
        ResolvedRouteCandidate::with_supported_client_auth_for_test(
            Url::parse(route).unwrap(),
            BTreeMap::new(),
            supported_auth,
        )
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
        async fn bootstrap_ssh(&mut self, endpoint: &Url, upgrade: bool) -> anyhow::Result<()> {
            self.events
                .push(FakeInitialRouteEvent::Bootstrap { endpoint: endpoint.to_string(), upgrade });
            if self.fail_ssh_bootstrap { Err(anyhow!("fake SSH is unreachable")) } else { Ok(()) }
        }

        async fn connect(
            &mut self,
            index: usize,
            request: ConnectRequest,
        ) -> Result<String, InitialRouteAttemptError> {
            let endpoint = request.endpoint.to_string();
            self.events.push(FakeInitialRouteEvent::Provider(request));
            if self.fail_provider_index == Some(index) {
                Err(InitialRouteAttemptError::Route(anyhow!("fake provider is unreachable")))
            } else {
                Ok(endpoint)
            }
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
        ) -> Result<String, ProviderError> {
            Err(ProviderError::Transport("fake provider is unreachable".into()))
        }
    }

    #[test]
    fn route_auth_capability_is_derived_from_the_local_provider_registry() {
        let mut providers = cmux_remote::provider::ProviderRegistry::default();
        providers
            .register(Arc::new(DirectWebSocketProvider::new(MAX_CARRIER_FRAME_BYTES)))
            .unwrap();
        let candidate = ResolvedRouteCandidate::resolve(
            Url::parse(
                "wss://daemon.example/v1/link?client_auth=device-or-carrier#untrusted-claim",
            )
            .unwrap(),
            BTreeMap::new(),
            &providers,
        )
        .unwrap();

        assert_eq!(
            candidate.supported_client_auth(),
            cmux_remote::provider::SupportedClientAuthModes::DeviceOnly
        );
    }

    #[tokio::test]
    async fn carrier_initial_fallback_skips_network_route_before_any_dial() {
        let routes = vec![
            resolved_test_route(
                "wss://network.example/v1/link",
                cmux_remote::provider::SupportedClientAuthModes::DeviceOnly,
            ),
            resolved_test_route(
                "ssh://carrier.example",
                cmux_remote::provider::SupportedClientAuthModes::DeviceOrCarrier,
            ),
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
            cmux_remote::crypto::AuthKind::Carrier,
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
                cmux_remote::provider::SupportedClientAuthModes::DeviceOnly,
            ),
            resolved_test_route(
                "ssh://carrier.example",
                cmux_remote::provider::SupportedClientAuthModes::DeviceOrCarrier,
            ),
        ];
        let attempt = FakeReconnectRouteAttempt::default();

        let (index, selected) = select_reconnect_route(
            &routes,
            0,
            SessionId([14; 16]),
            LanePolicy::Single,
            cmux_remote::crypto::AuthKind::Carrier,
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
            cmux_remote::provider::SupportedClientAuthModes::DeviceOnly,
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
            cmux_remote::crypto::AuthKind::Carrier,
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
        ClientRuntimeOptions {
            routes,
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
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
            relay: None,
            relay_routes: BTreeMap::new(),
            iroh_path: IrohPathMode::Auto,
            ssh: SshProviderConfig::default(),
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_millis(500),
            },
        }
    }

    #[test]
    fn reconnect_resolution_budget_covers_the_whole_candidate_cycle() {
        let candidate = |route: &str| ResolvedRouteCandidate {
            endpoint: Url::parse(route).unwrap(),
            routing: BTreeMap::new(),
        };
        let source = RuntimeReconnectGroups::new(
            reconnect_test_options(vec![
                candidate("wss://first.example/v1/link"),
                candidate("ssh://first-ssh.example"),
                candidate("iroh://fallback"),
                candidate("ssh://second-ssh.example"),
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
            reconnect_test_options(vec![candidate("wss://only.example/v1/link")]),
            0,
        );
        assert_eq!(
            ordinary.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(20),
            "an ordinary single-route reconnect must retain its configured deadline"
        );
    }

    #[tokio::test]
    async fn failed_ssh_bootstrap_falls_back_to_next_initial_provider() {
        let routes = vec![
            ResolvedRouteCandidate {
                endpoint: Url::parse("ssh://unreachable.example").unwrap(),
                routing: BTreeMap::new(),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse("iroh://next").unwrap(),
                routing: BTreeMap::from([(
                    cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                    "127.0.0.1:4242".into(),
                )]),
            },
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

    #[tokio::test]
    async fn initial_route_failures_redact_ssh_and_relay_endpoint_secrets() {
        let routes = vec![
            ResolvedRouteCandidate {
                endpoint: Url::parse("ssh://ssh-user:ssh-password-marker@ssh.example:2222")
                    .unwrap(),
                routing: BTreeMap::new(),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse(
                    "relay+wss://relay-user:relay-password-marker@relay.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
                )
                .unwrap(),
                routing: BTreeMap::new(),
            },
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
            ResolvedRouteCandidate {
                endpoint: Url::parse("ssh://upgrade-user@upgrade.example").unwrap(),
                routing: BTreeMap::new(),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse("wss://fallback.example/v1/link").unwrap(),
                routing: BTreeMap::new(),
            },
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
            ResolvedRouteCandidate {
                endpoint: Url::parse("ssh://upgrade-user@upgrade.example").unwrap(),
                routing: BTreeMap::new(),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse("wss://fallback.example/v1/link").unwrap(),
                routing: BTreeMap::new(),
            },
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
        let options = ClientRuntimeOptions {
            routes: vec![
                ResolvedRouteCandidate {
                    endpoint: Url::parse("wss://initial.example/v1/link").unwrap(),
                    routing: BTreeMap::new(),
                },
                ResolvedRouteCandidate {
                    endpoint: Url::parse("ssh://fallback.example").unwrap(),
                    routing: BTreeMap::new(),
                },
            ],
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
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
            relay: None,
            relay_routes: BTreeMap::new(),
            iroh_path: IrohPathMode::Auto,
            ssh: SshProviderConfig {
                ssh_binary: script.to_string_lossy().into_owned(),
                ..SshProviderConfig::default()
            },
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_millis(500),
            },
        };
        let source = RuntimeReconnectGroups::new(options, 0);

        assert_eq!(
            source.resolution_timeout(Duration::from_millis(20)),
            Duration::from_millis(540)
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
            ResolvedRouteCandidate {
                endpoint: Url::parse("iroh://first").unwrap(),
                routing: BTreeMap::from([(
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://first-relay.example".into(),
                )]),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse("iroh://second").unwrap(),
                routing: BTreeMap::from([(
                    cmux_remote::provider::ROUTING_RELAY_URL.into(),
                    "https://second-relay.example".into(),
                )]),
            },
        ];
        let attempt = FakeReconnectRouteAttempt::default();

        let (index, selected) =
            select_reconnect_route(&routes, 1, SessionId([7; 16]), LanePolicy::Single, &attempt)
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
            ResolvedRouteCandidate {
                endpoint: Url::parse(
                    "wss://ws-user:ws-password-marker@ws.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
                )
                .unwrap(),
                routing: BTreeMap::new(),
            },
            ResolvedRouteCandidate {
                endpoint: Url::parse(
                    "relay+wss://relay-user:relay-password-marker@relay.example/\
                     relay-capability?ticket=relay-query#relay-fragment",
                )
                .unwrap(),
                routing: BTreeMap::new(),
            },
        ];

        let error = select_reconnect_route(
            &routes,
            0,
            SessionId([12; 16]),
            LanePolicy::Single,
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
    async fn reconnect_ssh_bootstrap_failure_redacts_dial_userinfo() {
        let routes = vec![ResolvedRouteCandidate {
            endpoint: Url::parse("ssh://ssh-user:ssh-password-marker@ssh.example:2222").unwrap(),
            routing: BTreeMap::new(),
        }];
        let options = reconnect_test_options(routes.clone());
        let prepared_ssh = [AtomicBool::new(false)];
        let attempt =
            RuntimeReconnectRouteAttempt { options: &options, prepared_ssh: &prepared_ssh };
        let request = connect_request(&routes[0], options.session, options.lane_policy).unwrap();

        let error = match attempt.connect(0, request).await {
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
    async fn reconnect_source_cycles_normalized_route_candidates() {
        let options = ClientRuntimeOptions {
            routes: vec![
                ResolvedRouteCandidate {
                    endpoint: Url::parse("ws://first.invalid").unwrap(),
                    routing: BTreeMap::new(),
                },
                ResolvedRouteCandidate {
                    endpoint: Url::parse("ws://second.invalid").unwrap(),
                    routing: BTreeMap::new(),
                },
            ],
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
            device_name: "test".into(),
            session: SessionId([3; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy::default(),
            startup_timeout: Duration::from_secs(1),
            state_dir: PathBuf::from("/tmp/cmux-remote-route-test"),
            local_socket: None,
            relay: None,
            relay_routes: BTreeMap::new(),
            iroh_path: IrohPathMode::Auto,
            ssh: SshProviderConfig::default(),
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: true,
                upgrade: false,
                attempt_timeout: Duration::from_secs(1),
            },
        };
        let source = RuntimeReconnectGroups::new(options, 0);
        assert_eq!(source.next_group().await.unwrap().description(), "ws://second.invalid/v1/link");
        assert_eq!(source.next_group().await.unwrap().description(), "ws://first.invalid/v1/link");
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
