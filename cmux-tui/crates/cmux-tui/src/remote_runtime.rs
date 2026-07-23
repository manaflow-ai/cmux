//! Lifecycle glue between the synchronous TUI/core and the asynchronous
//! transport-neutral remote daemon.

use std::collections::BTreeMap;
use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
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
    register_relay_daemon_with_credentials,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
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

#[derive(Debug, Clone)]
pub struct ClientRuntimeOptions {
    pub endpoints: Vec<Url>,
    pub routing: BTreeMap<String, String>,
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
    if options.endpoints.is_empty() {
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
    let mut failures = Vec::new();
    for (index, endpoint) in options.endpoints.iter().enumerate() {
        let endpoint = normalize_carrier_endpoint(endpoint.clone())?;
        let request = ConnectRequest {
            endpoint: endpoint.clone(),
            session: options.session,
            lane_policy: options.lane_policy,
            routing: options.routing.clone(),
        };
        let group = match connect_provider(options, request).await {
            Ok(group) => group,
            Err(error) => {
                failures.push(format!("{endpoint}: {error}"));
                continue;
            }
        };
        let route = group.description().to_string();
        let reconnect_groups: Arc<dyn ReconnectGroupSource> = Arc::new(RuntimeReconnectGroups {
            options: options.clone(),
            next: AtomicUsize::new(index.saturating_add(1)),
        });
        let connection = ClientConnection::connect_with_reconnect_groups(
            group.clone(),
            ClientConnectionConfig {
                identity: options.identity.clone(),
                expected_daemon: options.expected_daemon,
                auth: options.auth.clone(),
                device_name: options.device_name.clone(),
                session: options.session,
                lane_policy: options.lane_policy,
                limits: SessionLimits::default(),
                reconnect: options.reconnect,
            },
            Some(reconnect_groups),
        )
        .await;
        match connection {
            Ok(connection) => return Ok((connection, route)),
            Err(error) if route_failure_allows_fallback(&error) => {
                let _ = group.close().await;
                failures.push(format!("{endpoint}: {error}"));
            }
            Err(error) => return Err(error.into()),
        }
    }
    Err(anyhow!("all remote route candidates failed: {}", failures.join("; ")))
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

struct RuntimeReconnectGroups {
    options: ClientRuntimeOptions,
    next: AtomicUsize,
}

#[async_trait]
impl ReconnectGroupSource for RuntimeReconnectGroups {
    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let count = self.options.endpoints.len();
        if count == 0 {
            return Err(ProviderError::Configuration("no reconnect routes configured".into()));
        }
        let start = self.next.fetch_add(1, Ordering::Relaxed) % count;
        let mut failures = Vec::new();
        for offset in 0..count {
            let index = (start + offset) % count;
            let endpoint = normalize_carrier_endpoint(self.options.endpoints[index].clone())
                .map_err(|error| ProviderError::Configuration(error.to_string()))?;
            let request = ConnectRequest {
                endpoint: endpoint.clone(),
                session: self.options.session,
                lane_policy: self.options.lane_policy,
                routing: self.options.routing.clone(),
            };
            match connect_provider(&self.options, request).await {
                Ok(group) => {
                    self.next.store(index.saturating_add(1), Ordering::Relaxed);
                    return Ok(group);
                }
                Err(error) => failures.push(format!("{endpoint}: {error}")),
            }
        }
        Err(ProviderError::Transport(format!(
            "all reconnect route providers failed: {}",
            failures.join("; ")
        )))
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
            endpoints: vec![
                Url::parse("ws://first.invalid").unwrap(),
                Url::parse("ws://second.invalid").unwrap(),
            ],
            routing: BTreeMap::new(),
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
        };
        let source = RuntimeReconnectGroups { options, next: AtomicUsize::new(1) };
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
