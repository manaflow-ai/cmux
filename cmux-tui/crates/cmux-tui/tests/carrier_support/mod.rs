//! What the carrier end-to-end tests share: a local stand-in for
//! cmux-platform's carrier route, a real cmux-relay, and a real cmux-remote
//! daemon whose grant verifier trusts a keyset made for the test, with a
//! fake mux socket behind it. Every key is generated here.
#![allow(dead_code)]

use std::io::BufRead;
use std::net::SocketAddr;
use std::path::Path;
use std::process::Child;
use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_link::carrier_grant::{CarrierGrantVerifier, GRANT_TYP, noise_key_digest};
use cmux_link::keyset::Keyset;
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::daemon::RemoteDaemon;
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{RelayDaemonConfig, register_relay_daemon};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub const MACHINE: &str = "vm_0123456789abcdefghij";
pub const ISSUER: &str = "cmux:cloud:test";
pub const SLOT: &str = "carrier-dial-slot";
pub const TOKEN: &str = "person-test-credential";
pub const TEAM: &str = "team_00000000000000000001";
pub const BIN: &str = env!("CARGO_BIN_EXE_cmux-tui");

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

/// The platform's grant key, the service the grants it signs name, and
/// their `vmk` claim (none when `None`).
pub struct Signer(Ed25519KeyPair, &'static str, Option<&'static str>);

impl Signer {
    fn generate(service: &'static str, vmk: Option<&'static str>) -> Self {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Self(Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap(), service, vmk)
    }

    fn keyset(&self) -> Keyset {
        let public: [u8; 32] = self.0.public_key().as_ref().try_into().unwrap();
        Keyset { version: "0123456789abcdef".into(), keys: [("k1".to_string(), public)].into() }
    }

    /// A grant for `noise_key`, as the platform signs it.
    fn grant(&self, noise_key: &[u8; 32], jti: usize) -> String {
        let header = json!({"alg": "EdDSA", "kid": "k1", "typ": GRANT_TYP});
        let mut claims = json!({
            "iss": ISSUER,
            "aud": MACHINE,
            "team": TEAM,
            "sub": "user_00000000000000000001",
            "svc": [self.1],
            "nk": noise_key_digest(noise_key),
            "jti": URL_SAFE_NO_PAD.encode((jti as u128).to_be_bytes()),
            "iat": now() - 5,
            "exp": now() + 60,
        });
        if let Some(vmk) = self.2 {
            claims["vmk"] = json!(vmk);
        }
        let message = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap()),
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap())
        );
        let signature = self.0.sign(message.as_bytes());
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }
}

/// The platform's carrier route: checks the bearer, answers a Connect
/// ticket for the open relay, a grant for the asked key, and the daemon key.
/// `status` other than 200 (read at each request) refuses it.
pub async fn platform(
    signer: Arc<Signer>,
    relay: SocketAddr,
    daemon_key: Option<String>,
    status: Arc<AtomicU16>,
    asked: Arc<AtomicUsize>,
    teams: Teams,
) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let signer = signer.clone();
            let daemon_key = daemon_key.clone();
            let asked = asked.clone();
            let teams = teams.clone();
            let status = status.load(Ordering::SeqCst);
            tokio::spawn(async move {
                let mut reader = tokio::io::BufReader::new(&mut stream);
                let (mut length, mut authorized, mut path, mut team) =
                    (0, false, String::new(), None);
                let mut line = String::new();
                reader.read_line(&mut line).await.unwrap();
                path.push_str(line.split_whitespace().nth(1).unwrap_or(""));
                loop {
                    line.clear();
                    reader.read_line(&mut line).await.unwrap();
                    let header = line.trim().to_ascii_lowercase();
                    if header.is_empty() {
                        break;
                    }
                    if let Some(value) = header.strip_prefix("x-cmux-team:") {
                        team = Some(value.trim().to_owned());
                    }
                    if let Some(value) = header.strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap();
                    }
                    authorized |=
                        header == format!("authorization: bearer {}", TOKEN.to_ascii_lowercase());
                }
                let mut body = vec![0; length];
                reader.read_exact(&mut body).await.unwrap();
                let request: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                teams.lock().unwrap().push(team);
                let n = asked.fetch_add(1, Ordering::SeqCst);
                assert_eq!(path, format!("/v1/cloud/machines/{MACHINE}/carrier"));
                let (code, answer) = if status != 200 || !authorized {
                    (
                        403,
                        json!({"ok": false, "error": {"code": "auth.forbidden", "message": "no"}}),
                    )
                } else {
                    let mut value = json!({
                        "relay": format!("relay+ws://{relay}"),
                        "slot": SLOT,
                        "ticket": "open-client-ticket",
                        "expires_at": now() + 300,
                    });
                    if let Some(key) = &daemon_key {
                        value["daemon_key"] = json!(key);
                    }
                    if let Some(key) = request["noise_key"].as_str() {
                        let key: [u8; 32] =
                            URL_SAFE_NO_PAD.decode(key).unwrap().try_into().unwrap();
                        value["grant"] = json!(signer.grant(&key, n));
                    }
                    (200, json!({"ok": true, "value": value}))
                };
                let body = answer.to_string();
                let reply = format!(
                    "HTTP/1.1 {code} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(reply.as_bytes()).await;
            });
        }
    });
    address
}

/// The session's mux socket: echoes each line, then pushes one line of its
/// own naming the mux connection (`conn`, 0 for the first), so two sessions
/// tell apart.
pub async fn fake_mux(path: &Path) {
    let listener = tokio::net::UnixListener::bind(path).unwrap();
    tokio::spawn(async move {
        for conn in 0_usize.. {
            let Ok((stream, _)) = listener.accept().await else { return };
            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
                    let pushed = format!("{{\"event\":\"pushed\",\"conn\":{conn}}}\n");
                    writer.write_all(pushed.as_bytes()).await.unwrap();
                }
            });
        }
    });
}

/// The `x-cmux-team` header of each platform request (`None` when absent).
pub type Teams = Arc<Mutex<Vec<Option<String>>>>;

pub struct World {
    pub platform: SocketAddr,
    pub teams: Teams,
    /// What the platform answers next (200 grants, anything else refuses).
    pub status: Arc<AtomicU16>,
    pub dir: tempfile::TempDir,
    _registration: cmux_remote::provider::RelayDaemonRegistration,
    _runtime: tokio::runtime::Runtime,
}

/// A relay, a registered daemon with a grant verifier and a mux socket, and
/// the platform route answering `status` with grants for `service`.
pub fn world(status: u16, asked: Arc<AtomicUsize>) -> World {
    world_granting(status, asked, "mux-control")
}

/// What the platform answers as `daemon_key`.
#[derive(Clone, Copy)]
pub enum DaemonKey {
    /// The daemon's own key.
    Real,
    /// No `daemon_key` at all.
    Missing,
    /// Not 32 canonical base64url bytes.
    Malformed,
    /// A well-formed key that is not the daemon's.
    Other,
}

pub fn world_granting(status: u16, asked: Arc<AtomicUsize>, service: &'static str) -> World {
    world_full(status, asked, service, DaemonKey::Real)
}

pub fn world_full(
    status: u16,
    asked: Arc<AtomicUsize>,
    service: &'static str,
    key: DaemonKey,
) -> World {
    world_signed(status, asked, service, key, None)
}

/// [`world_full`] whose grants carry `vmk` as their `vmk` claim.
pub fn world_signed(
    status: u16,
    asked: Arc<AtomicUsize>,
    service: &'static str,
    key: DaemonKey,
    vmk: Option<&'static str>,
) -> World {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mux = dir.path().join("mux.sock");
    let state = dir.path().join("daemon");
    let teams = Teams::default();
    let shared_status = Arc::new(AtomicU16::new(status));
    let answered = shared_status.clone();
    let (platform, registration) = runtime.block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        let signer = Arc::new(Signer::generate(service, vmk));
        std::fs::create_dir_all(&state).unwrap();
        let auth = AuthDatabase::load_or_create(&state, "carrier-dial-test", false).unwrap();
        let verifier =
            CarrierGrantVerifier::new(ISSUER, MACHINE, TEAM, signer.keyset(), || Some(now()), 64)
                .unwrap();
        auth.set_grant_verifier(Arc::new(verifier)).unwrap();
        let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let registration = register_relay_daemon(
            daemon,
            RelayDaemonConfig {
                endpoint: url::Url::parse(&format!("relay+ws://{relay_address}")).unwrap(),
                slot: SLOT.into(),
                ticket: "open-daemon-ticket".into(),
                maximum_frame_bytes: 65_535,
                control_timeout: Duration::from_secs(5),
            },
        )
        .await
        .unwrap();
        fake_mux(&mux).await;
        let services = DaemonServices::new(WorkspaceService::new(), Some(mux.clone()));
        std::thread::spawn(move || {
            let local = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            local.block_on(services.run(accepted));
        });
        let platform = platform(
            signer,
            relay_address,
            match key {
                DaemonKey::Real => Some(URL_SAFE_NO_PAD.encode(auth.identity().public_key())),
                DaemonKey::Missing => None,
                DaemonKey::Malformed => Some("not-a-key".into()),
                DaemonKey::Other => Some(URL_SAFE_NO_PAD.encode([9_u8; 32])),
            },
            answered,
            asked,
            teams.clone(),
        )
        .await;
        (platform, registration)
    });
    World {
        platform,
        teams,
        status: shared_status,
        dir,
        _registration: registration,
        _runtime: runtime,
    }
}

pub fn line(reader: &mut impl BufRead) -> String {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    line
}

/// The child's exit code, or None (and the child ended) past `limit`.
pub fn wait(child: &mut Child, limit: Duration) -> Option<i32> {
    let started = std::time::Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status.code();
        }
        if started.elapsed() > limit {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
