//! A machine whose session host can restart: the same stand-in platform and
//! real relay as [`super::world`], a daemon that keeps its identity across
//! restarts (as a restarted session host does: same key, no sessions), and
//! a proxy in front of the relay for the client side that a test can cut or
//! hold, so a session's link drops and its resume goes through again.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_link::carrier_grant::CarrierGrantVerifier;
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::daemon::RemoteDaemon;
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{RelayDaemonConfig, RelayDaemonRegistration, register_relay_daemon};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, watch};

use super::{Bearers, ISSUER, Keys, MACHINE, SLOT, Signer, TEAM, Teams, fake_mux, now, platform};

/// When the session host restarts by itself.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Restart {
    /// Only when the test calls [`HostWorld::restart`].
    OnRequest,
    /// Right after it admits its first session, before it serves any stream
    /// on it: the client's handshake finished, and its first request finds
    /// the link gone (the updater restarting the session host at boot).
    AfterFirstSession,
}

/// What the mux socket behind the daemon is.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mux {
    /// [`fake_mux`]: echoes each line and pushes one naming its connection.
    Echo,
    /// [`EventLog`]: an agent chat's event log, attached with `afterSeq`.
    Events,
}

pub struct HostWorld {
    pub platform: SocketAddr,
    pub dir: tempfile::TempDir,
    /// The chat's event log when the mux is [`Mux::Events`].
    pub events: Arc<EventLog>,
    /// How many times the session host started (1 before any restart).
    pub starts: Arc<AtomicUsize>,
    proxy: Arc<Proxy>,
    host: Arc<tokio::sync::Mutex<Host>>,
    runtime: tokio::runtime::Runtime,
}

struct Host {
    auth: Arc<AuthDatabase>,
    relay: SocketAddr,
    mux: PathBuf,
    proxy: Arc<Proxy>,
    registration: Option<RelayDaemonRegistration>,
    shutdown: Option<watch::Sender<bool>>,
    /// What a stopped host left behind (as a killed process leaves its
    /// sockets to time out): kept, never closed politely.
    stopped: Vec<Box<dyn std::any::Any + Send>>,
}

pub fn host_world(restart: Restart, mux: Mux) -> HostWorld {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mux_path = dir.path().join("mux.sock");
    let state = dir.path().join("daemon");
    let events = Arc::new(EventLog::default());
    let starts = Arc::new(AtomicUsize::new(0));
    let proxy = Arc::new(Proxy::default());
    let (platform_address, host) = runtime.block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let relay = Relay::new(RelayConfig {
            allow_open: true,
            handshake_timeout: Duration::from_secs(120),
            ..RelayConfig::default()
        })
        .unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        let signer = Arc::new(Signer::generate("mux-control", None));
        std::fs::create_dir_all(&state).unwrap();
        let auth = AuthDatabase::load_or_create(&state, "carrier-restart-test", false).unwrap();
        let verifier =
            CarrierGrantVerifier::new(ISSUER, MACHINE, TEAM, signer.keyset(), || Some(now()), 64)
                .unwrap();
        auth.set_grant_verifier(Arc::new(verifier)).unwrap();
        match mux {
            Mux::Echo => fake_mux(&mux_path).await,
            Mux::Events => events.clone().serve(&mux_path),
        }
        let host = Arc::new(tokio::sync::Mutex::new(Host {
            auth: auth.clone(),
            relay: relay_address,
            mux: mux_path.clone(),
            proxy: proxy.clone(),
            registration: None,
            shutdown: None,
            stopped: Vec::new(),
        }));
        start(host.clone(), starts.clone(), restart).await;
        let client_relay = proxy.clone().listen(relay_address).await;
        let daemon_key = Some(URL_SAFE_NO_PAD.encode(auth.identity().public_key()));
        let platform_address = platform(
            signer,
            client_relay,
            daemon_key,
            Arc::new(AtomicU16::new(200)),
            Arc::new(AtomicUsize::new(0)),
            Teams::default(),
            Keys::default(),
            Bearers::default(),
        )
        .await;
        (platform_address, host)
    });
    HostWorld { platform: platform_address, dir, events, starts, proxy, host, runtime }
}

type Started = (
    tokio::sync::mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    Arc<DaemonServices>,
    watch::Receiver<bool>,
);

/// Starts the session host: a new daemon (no sessions) on the machine's
/// identity, registered on the relay, serving the mux socket.
async fn start(host: Arc<tokio::sync::Mutex<Host>>, starts: Arc<AtomicUsize>, restart: Restart) {
    let (accepted, services, shutdown) = register(&host, &starts).await;
    if restart == Restart::AfterFirstSession {
        tokio::spawn(restart_after_first(host, starts, accepted, services));
        return;
    }
    run(accepted, services, shutdown);
}

/// The first session is admitted (its handshake is done), then the host
/// goes away under it before serving anything, and comes back empty.
async fn restart_after_first(
    host: Arc<tokio::sync::Mutex<Host>>,
    starts: Arc<AtomicUsize>,
    mut accepted: tokio::sync::mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    services: Arc<DaemonServices>,
) {
    let Some(first) = accepted.recv().await else { return };
    stop(&host).await;
    host.lock().await.stopped.extend([
        Box::new(first) as Box<dyn std::any::Any + Send>,
        Box::new(accepted),
        Box::new(services),
    ]);
    let (accepted, services, shutdown) = register(&host, &starts).await;
    run(accepted, services, shutdown);
}

async fn register(host: &Arc<tokio::sync::Mutex<Host>>, starts: &AtomicUsize) -> Started {
    let mut state = host.lock().await;
    let (daemon, accepted) = RemoteDaemon::new(state.auth.clone(), SessionLimits::default());
    let registration = register_relay_daemon(
        daemon,
        RelayDaemonConfig {
            endpoint: url::Url::parse(&format!("relay+ws://{}", state.relay)).unwrap(),
            slot: SLOT.into(),
            ticket: "open-daemon-ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
    )
    .await
    .unwrap();
    state.registration = Some(registration);
    starts.fetch_add(1, Ordering::SeqCst);
    let (shutdown_tx, shutdown) = watch::channel(false);
    state.shutdown = Some(shutdown_tx);
    let services = DaemonServices::new(WorkspaceService::new(), Some(state.mux.clone()));
    (accepted, services, shutdown)
}

fn run(
    accepted: tokio::sync::mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    services: Arc<DaemonServices>,
    shutdown: watch::Receiver<bool>,
) {
    std::thread::spawn(move || {
        let local = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        local.block_on(services.run_with_shutdown(accepted, shutdown));
    });
}

/// Stops the session host the way a restart does: it leaves the relay,
/// every client link through it drops at once (nothing says goodbye), and
/// its services stop. Its sessions are gone with it.
async fn stop(host: &Arc<tokio::sync::Mutex<Host>>) {
    let (registration, shutdown, proxy) = {
        let mut state = host.lock().await;
        (state.registration.take(), state.shutdown.take(), state.proxy.clone())
    };
    if let Some(registration) = registration {
        registration.shutdown().await;
    }
    proxy.cut();
    if let Some(shutdown) = shutdown {
        let _ = shutdown.send(true);
    }
}

impl HostWorld {
    /// Restarts the session host: the old one stops (its sessions are
    /// gone) and a new one on the same identity registers.
    pub fn restart(&self) {
        let (host, starts) = (self.host.clone(), self.starts.clone());
        self.runtime.block_on(async move {
            stop(&host).await;
            let (accepted, services, shutdown) = register(&host, &starts).await;
            run(accepted, services, shutdown);
        });
    }

    /// Drops every client link through the relay proxy; new ones go
    /// through as before.
    pub fn cut(&self) {
        self.proxy.cut();
    }

    /// Drops every client link and holds every new one (it connects but no
    /// byte crosses) until [`HostWorld::release`].
    pub fn hold(&self) {
        self.proxy.holding.send_replace(true);
        self.proxy.cut();
    }

    /// Client links the relay proxy accepted so far.
    pub fn links(&self) -> usize {
        self.proxy.links.load(Ordering::SeqCst)
    }

    pub fn release(&self) {
        self.proxy.holding.send_replace(false);
    }

    pub fn connect_log(&self) -> String {
        let log = self.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
        std::fs::read_to_string(log).unwrap_or_default()
    }

    pub fn socket_path(&self) -> PathBuf {
        self.dir.path().join("carrier.sock")
    }
}

/// The client side's way to the relay: forwards each TCP connection, and
/// can drop them all ([`Proxy::cut`]) or hold new ones.
#[derive(Default)]
struct Proxy {
    cuts: watch::Sender<u64>,
    holding: watch::Sender<bool>,
    /// Client links it accepted.
    links: AtomicUsize,
}

impl Proxy {
    fn cut(&self) {
        self.cuts.send_modify(|cuts| *cuts += 1);
    }

    async fn listen(self: Arc<Self>, relay: SocketAddr) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((client, _)) = listener.accept().await else { return };
                self.links.fetch_add(1, Ordering::SeqCst);
                let proxy = self.clone();
                tokio::spawn(async move {
                    let mut cuts = proxy.cuts.subscribe();
                    cuts.borrow_and_update();
                    let mut holding = proxy.holding.subscribe();
                    if *holding.borrow_and_update() {
                        tokio::select! {
                            _ = holding.wait_for(|holding| !*holding) => {}
                            _ = cuts.changed() => return,
                        }
                    }
                    let Ok(upstream) = TcpStream::connect(relay).await else { return };
                    let (mut client_read, mut client_write) = client.into_split();
                    let (mut upstream_read, mut upstream_write) = upstream.into_split();
                    tokio::select! {
                        _ = tokio::io::copy(&mut upstream_read, &mut client_write) => {}
                        _ = tokio::io::copy(&mut client_read, &mut upstream_write) => {}
                        _ = cuts.changed() => {}
                    }
                });
            }
        });
        address
    }
}

/// An agent chat's event log behind the mux socket, kept across session
/// host restarts (the chat's own process keeps it, as acpmux does). A line
/// `{"cmd":"attach","afterSeq":N}` answers every event after `N`, then each
/// new one as it is appended: `{"event":"chat","seq":S}`.
#[derive(Default)]
pub struct EventLog {
    events: Mutex<VecDeque<u64>>,
    appended: Notify,
}

impl EventLog {
    /// Appends the next event and returns its seq.
    pub fn append(&self) -> u64 {
        let seq = {
            let mut events = self.events.lock().unwrap();
            let seq = events.back().copied().unwrap_or(0) + 1;
            events.push_back(seq);
            seq
        };
        self.appended.notify_waiters();
        seq
    }

    fn after(&self, seq: u64) -> Vec<u64> {
        self.events.lock().unwrap().iter().copied().filter(|event| *event > seq).collect()
    }

    fn serve(self: Arc<Self>, path: &Path) {
        let listener = tokio::net::UnixListener::bind(path).unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { return };
                let log = self.clone();
                tokio::spawn(async move {
                    let (reader, mut writer) = stream.into_split();
                    let mut lines = tokio::io::BufReader::new(reader).lines();
                    let Ok(Some(line)) = lines.next_line().await else { return };
                    let request: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    let mut sent = request["afterSeq"].as_u64().unwrap_or(0);
                    loop {
                        let appended = log.appended.notified();
                        for seq in log.after(sent) {
                            let event = format!("{}\n", json!({"event": "chat", "seq": seq}));
                            if writer.write_all(event.as_bytes()).await.is_err() {
                                return;
                            }
                            sent = seq;
                        }
                        appended.await;
                    }
                });
            }
        });
    }
}
