//! The tunnel keeper against a fake platform and VM API (axum), a fake hub
//! that really listens on the socket (so the dial's own ssh check sees it),
//! a join that comes and goes and a sign-in that comes and goes.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;
use axum::body::Bytes;
use axum::http::{HeaderMap, StatusCode, Uri};
use cmux_server_core::install_key::SystemRandom;
use serde_json::{Value, json};

use super::*;
use crate::carrier::ssh::{self, Absent, SshSetup};
use crate::carrier::tunnel::RunningHub;

const MESH: &str = "mesh_0000000000000000000000000a";
const DEVICE: &str = "dev_0000000000000000000000000b";
const GATEWAY: &str = "mVS8z5lKoaFVnHkPXDVWTyIkp0ZB1Cj8DbpsGh+Ibhs=";

type Reply = (u16, Value);

/// One fake origin: requests (path, bearer) recorded, answers from per-path
/// queues whose last answer repeats.
#[derive(Default)]
struct Fake {
    requests: Mutex<Vec<(String, String)>>,
    answers: Mutex<Vec<(String, VecDeque<Reply>)>>,
}

impl Fake {
    fn answer(&self, path_part: &str, replies: Vec<Reply>) {
        let mut answers = self.answers.lock().unwrap();
        answers.retain(|(part, _)| part != path_part);
        answers.push((path_part.to_owned(), replies.into()));
    }

    fn reply(&self, path: &str, bearer: String) -> Reply {
        self.requests.lock().unwrap().push((path.to_owned(), bearer));
        let mut answers = self.answers.lock().unwrap();
        for (part, queue) in answers.iter_mut() {
            if path.contains(part.as_str()) {
                return if queue.len() > 1 { queue.pop_front().unwrap() } else { queue[0].clone() };
            }
        }
        (404, json!({"code": "not_found"}))
    }

    fn bearers(&self, path_part: &str) -> Vec<String> {
        let requests = self.requests.lock().unwrap();
        requests.iter().filter(|(p, _)| p.contains(path_part)).map(|(_, b)| b.clone()).collect()
    }
}

async fn serve(fake: Arc<Fake>) -> String {
    let app = axum::Router::new().fallback(move |uri: Uri, headers: HeaderMap, _body: Bytes| {
        let fake = Arc::clone(&fake);
        async move {
            let bearer = headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_owned();
            let (status, answer) = fake.reply(uri.path(), bearer);
            (StatusCode::from_u16(status).unwrap(), axum::Json(answer))
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    origin
}

fn mesh_only() -> Reply {
    (
        200,
        json!({"tunnel_id": "machine_1", "network_id": "team_1", "mesh_id": MESH,
        "device_id": null, "address_v4": null, "address_v6": null,
        "client_public_key": "x", "server_public_key": null, "client_config": null}),
    )
}

fn enrolled(wg: &str) -> Reply {
    (
        200,
        json!({"tunnel_id": "tun_1", "network_id": "team_1", "mesh_id": MESH,
        "device_id": DEVICE, "address_v4": "10.128.0.2", "address_v6": null,
        "client_public_key": wg, "server_public_key": GATEWAY,
        "client_config": {"endpoint": "gw.example:51820", "interface_address": "10.128.0.2/32",
            "allowed_ips": ["10.128.0.0/20"], "mtu": 1280, "persistent_keepalive_seconds": 25}}),
    )
}

fn tunnel_read() -> Reply {
    (
        200,
        json!({"id": "tun_1", "meshId": MESH, "deviceId": DEVICE, "endpointHost": "gw.example",
        "endpointPort": 51820, "serverPublicKey": GATEWAY, "interfaceAddress": "10.128.0.2/32",
        "meshAddress": "10.128.0.2", "allowedIps": ["10.128.0.0/20"], "mtu": 1280,
        "persistentKeepaliveSeconds": 25}),
    )
}

/// Hubs that listen on the socket, as `wg hub` does once ready.
#[derive(Default)]
struct Hubs {
    launched: AtomicUsize,
    crash: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}

struct ListeningHub {
    socket: PathBuf,
    _listener: std::os::unix::net::UnixListener,
    ended: tokio::sync::oneshot::Receiver<()>,
}

impl Drop for ListeningHub {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
    }
}

#[async_trait]
impl RunningHub for ListeningHub {
    async fn exited(&mut self) -> String {
        match (&mut self.ended).await {
            Ok(()) => "killed".into(),
            Err(_) => std::future::pending().await,
        }
    }
    async fn stop(self: Box<Self>) {}
}

struct ListeningLauncher(Arc<Hubs>);

#[async_trait]
impl HubLauncher for ListeningLauncher {
    async fn launch(
        &self,
        config: Zeroizing<String>,
        socket: &Path,
    ) -> Result<Box<dyn RunningHub>, String> {
        cmux_wg::WgConfig::parse_wg_quick(&config).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(socket);
        let listener = std::os::unix::net::UnixListener::bind(socket).map_err(|e| e.to_string())?;
        self.0.launched.fetch_add(1, Ordering::SeqCst);
        let (crash, ended) = tokio::sync::oneshot::channel();
        *self.0.crash.lock().unwrap() = Some(crash);
        Ok(Box::new(ListeningHub { socket: socket.to_path_buf(), _listener: listener, ended }))
    }
}

struct World {
    _dir: tempfile::TempDir,
    platform: Arc<Fake>,
    hubs: Arc<Hubs>,
    joined: Arc<AtomicBool>,
    signed_in: Arc<AtomicBool>,
    asks: Arc<AtomicUsize>,
    events: tokio::sync::mpsc::UnboundedReceiver<KeeperEvent>,
    seen: Vec<KeeperEvent>,
    setup: SshSetup,
    wg_public: String,
    _keeper: tokio::task::JoinHandle<()>,
}

fn timing() -> KeeperTiming {
    KeeperTiming {
        check_every: Duration::from_millis(20),
        sign_in_every: Duration::from_millis(40),
        restart_floor: Duration::from_millis(10),
        restart_ceiling: Duration::from_millis(40),
        unavailable_wait: Duration::from_secs(3600),
        tunnel: TunnelTiming {
            refresh_every: Duration::from_secs(3600),
            retry_floor: Duration::from_millis(5),
            retry_ceiling: Duration::from_millis(10),
            max_failures: 3,
        },
    }
}

async fn world(joined: bool, signed_in: bool) -> World {
    world_attaching(joined, signed_in, None).await
}

/// A world whose platform answers every attach with `attach` (else mesh, then the enrollment).
async fn world_attaching(joined: bool, signed_in: bool, attach: Option<Reply>) -> World {
    let dir = tempfile::tempdir().unwrap();
    let (platform, vm) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
    let platform_origin = serve(Arc::clone(&platform)).await;
    let vm_origin = serve(Arc::clone(&vm)).await;
    let wg_private = Zeroizing::new([9u8; 32]);
    let wg_public = {
        let secret = x25519_dalek::StaticSecret::from(*wg_private);
        base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            x25519_dalek::PublicKey::from(&secret).as_bytes(),
        )
    };
    match attach {
        Some(reply) => platform.answer("/attach", vec![reply]),
        None => platform.answer("/attach", vec![mesh_only(), enrolled(&wg_public)]),
    }
    vm.answer("/signed/tunnel", vec![tunnel_read()]);
    let install = Arc::new(InstallKey::generate(&SystemRandom::new()).unwrap());
    let (joined_flag, signed_flag, asks) = (
        Arc::new(AtomicBool::new(joined)),
        Arc::new(AtomicBool::new(signed_in)),
        Arc::new(AtomicUsize::new(0)),
    );
    let joined_source: JoinedSource = {
        let (flag, platform_origin) = (Arc::clone(&joined_flag), platform_origin.clone());
        Arc::new(move || {
            Ok(flag.load(Ordering::SeqCst).then(|| Joined {
                machine_id: "machine_1".into(),
                name: "leo-mac".into(),
                team: "team_1".into(),
                platform: platform_origin.clone(),
                wg_private: wg_private.clone(),
                install: Arc::clone(&install),
            }))
        })
    };
    let token: TokenSource = {
        let (flag, asks) = (Arc::clone(&signed_flag), Arc::clone(&asks));
        Arc::new(move |team: &str, _platform: &str| {
            assert_eq!(team, "team_1");
            let n = asks.fetch_add(1, Ordering::SeqCst);
            if flag.load(Ordering::SeqCst) {
                Ok(Zeroizing::new(format!("person-token-{n}")))
            } else {
                Err("not_signed_in".into())
            }
        })
    };
    let hubs = Arc::new(Hubs::default());
    let socket = dir.path().join("carrier").join("tunnel.sock");
    let (tx, events) = tokio::sync::mpsc::unbounded_channel();
    let keeper = Keeper {
        joined: joined_source,
        token,
        socket: socket.clone(),
        launcher: Arc::new(ListeningLauncher(Arc::clone(&hubs))),
        vm_api: Some(vm_origin),
        timing: timing(),
        jitter: |d| d,
        on_event: Arc::new(move |event: &KeeperEvent| {
            let _ = tx.send(event.clone());
        }),
    };
    let setup = SshSetup {
        hub: Some(socket),
        state: Some(dir.path().join("ssh-state")),
        ssh_binary: "ssh".into(),
        exe: Some(PathBuf::from("/opt/cmux/cmux")),
    };
    World {
        _dir: dir,
        platform,
        hubs,
        joined: joined_flag,
        signed_in: signed_flag,
        asks,
        events,
        seen: Vec::new(),
        setup,
        wg_public,
        _keeper: tokio::spawn(keeper.run()),
    }
}

impl World {
    /// The next event that `want` takes, within 10 s; every event is kept.
    async fn until(&mut self, want: impl Fn(&KeeperEvent) -> bool) -> KeeperEvent {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let event = tokio::time::timeout_at(deadline, self.events.recv())
                .await
                .unwrap_or_else(|_| panic!("no wanted event; seen {:?}", self.seen))
                .expect("keeper alive");
            self.seen.push(event.clone());
            if want(&event) {
                return event;
            }
        }
    }

    fn ssh(&self) -> Result<(), Absent> {
        ssh::ssh_ready(&self.setup)
    }
}

#[tokio::test]
async fn the_hub_runs_while_joined_and_signed_in_and_stops_when_the_device_leaves() {
    let mut world = world(true, true).await;
    assert_eq!(world.ssh(), Err(Absent::Tunnel), "no hub before the keeper starts one");
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.ssh(), Ok(()), "capabilities report ssh, not no_tunnel");
    // Both attaches (mesh, then the signed enrollment) carried an app token, each asked afresh.
    let bearers = world.platform.bearers("/attach");
    assert_eq!(bearers.len(), 2, "{bearers:?}");
    assert!(bearers.iter().all(|b| b.starts_with("Bearer person-token-")), "{bearers:?}");
    assert_ne!(bearers.first(), bearers.get(1), "each attach asks the app again");

    world.joined.store(false, Ordering::SeqCst);
    world.until(|e| *e == KeeperEvent::Stopped("left")).await;
    assert_eq!(world.ssh(), Err(Absent::Tunnel), "the hub is gone with the join");
    let launched = world.hubs.launched.load(Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(world.hubs.launched.load(Ordering::SeqCst), launched, "nothing starts unjoined");

    world.joined.store(true, Ordering::SeqCst);
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.ssh(), Ok(()), "a new join starts it again");
}

#[tokio::test]
async fn signing_out_stops_the_hub_and_signing_in_starts_it_again() {
    let mut world = world(true, true).await;
    world.until(|e| *e == KeeperEvent::Ready).await;
    world.signed_in.store(false, Ordering::SeqCst);
    world.until(|e| *e == KeeperEvent::Stopped("signed_out")).await;
    assert_eq!(world.ssh(), Err(Absent::Tunnel));
    let attaches = world.platform.bearers("/attach").len();
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(world.platform.bearers("/attach").len(), attaches, "no attach while signed out");

    world.signed_in.store(true, Ordering::SeqCst);
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.ssh(), Ok(()));
}

#[tokio::test]
async fn nothing_starts_until_the_device_is_joined_and_someone_is_signed_in() {
    let mut world = world(false, false).await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(world.asks.load(Ordering::SeqCst), 0, "an unjoined device asks no app");
    world.joined.store(true, Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(world.asks.load(Ordering::SeqCst) > 0, "a joined device asks whether anyone is in");
    assert!(world.platform.bearers("/attach").is_empty(), "no attach without a sign-in");
    assert_eq!(world.hubs.launched.load(Ordering::SeqCst), 0);
    assert_eq!(world.ssh(), Err(Absent::Tunnel));

    world.signed_in.store(true, Ordering::SeqCst);
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.ssh(), Ok(()));
    assert!(world.seen.iter().all(|e| !matches!(e, KeeperEvent::Ended(_))), "{:?}", world.seen);
}

#[tokio::test]
async fn a_killed_hub_is_started_again() {
    let mut world = world(true, true).await;
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.hubs.launched.load(Ordering::SeqCst), 1);
    let crash = world.hubs.crash.lock().unwrap().take().unwrap();
    crash.send(()).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while world.hubs.launched.load(Ordering::SeqCst) < 2 {
        assert!(tokio::time::Instant::now() < deadline, "the killed hub was not started again");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while world.ssh().is_err() {
        assert!(tokio::time::Instant::now() < deadline, "the new hub does not serve");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test]
async fn a_supervisor_that_gives_up_starts_again_after_a_doubling_wait() {
    let mut world = world_attaching(true, true, Some((503, json!({"code": "unavailable"})))).await;
    let mut waits = Vec::new();
    while waits.len() < 4 {
        let event = world.until(|e| matches!(e, KeeperEvent::Waiting(_))).await;
        if let KeeperEvent::Waiting(delay) = event {
            waits.push(delay);
        }
    }
    let ms: Vec<u128> = waits.iter().map(Duration::as_millis).collect();
    // Floor 10 ms doubling to the 40 ms ceiling.
    assert_eq!(ms, [10, 20, 40, 40]);
    let failed =
        world.seen.iter().filter(|e| matches!(e, KeeperEvent::Ended(TunnelStatus::Failed(_))));
    assert!(failed.count() >= 4, "{:?}", world.seen);

    // Once the platform answers again, the next start serves the socket.
    world.platform.answer("/attach", vec![mesh_only(), enrolled(&world.wg_public)]);
    world.until(|e| *e == KeeperEvent::Ready).await;
    assert_eq!(world.ssh(), Ok(()));
}

#[tokio::test]
async fn a_team_without_a_provider_mesh_waits_long_before_asking_again() {
    let mut world = world_attaching(true, true, Some((200, json!({"mesh_id": null})))).await;
    let event = world.until(|e| matches!(e, KeeperEvent::Waiting(_))).await;
    assert_eq!(event, KeeperEvent::Waiting(Duration::from_secs(3600)));
    assert!(
        world.seen.contains(&KeeperEvent::Ended(TunnelStatus::Unavailable(tunnel::NO_MESH.into())))
    );
    assert_eq!(world.ssh(), Err(Absent::Tunnel));
}

#[test]
fn a_device_name_is_one_the_vm_api_takes() {
    assert_eq!(device_name("Leo's MacBook Pro"), "Leos MacBook Pro");
    assert_eq!(device_name("  -mac"), "mac");
    assert_eq!(device_name("💻"), "cmux-mac");
    assert_eq!(device_name(&"a".repeat(80)).len(), 63);
}
