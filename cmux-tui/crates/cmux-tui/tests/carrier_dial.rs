//! `cmux carrier dial` end to end: the real binary fetches a ticket and a
//! grant from a local stand-in for cmux-platform, crosses a real cmux-relay,
//! and is admitted by a real cmux-remote daemon whose grant verifier trusts
//! a keyset made for this test. Bytes then flow both ways between the
//! dial's stdio and the daemon's mux socket. Every key is generated here.
#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
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

const MACHINE: &str = "vm_0123456789abcdefghij";
const ISSUER: &str = "cmux:cloud:test";
const SLOT: &str = "carrier-dial-slot";
const TOKEN: &str = "person-test-credential";
const TEAM: &str = "team_00000000000000000001";
const BIN: &str = env!("CARGO_BIN_EXE_cmux-tui");

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

/// The platform's grant key and the service the grants it signs name.
struct Signer(Ed25519KeyPair, &'static str);

impl Signer {
    fn generate(service: &'static str) -> Self {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Self(Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap(), service)
    }

    fn keyset(&self) -> Keyset {
        let public: [u8; 32] = self.0.public_key().as_ref().try_into().unwrap();
        Keyset { version: "0123456789abcdef".into(), keys: [("k1".to_string(), public)].into() }
    }

    /// A grant for `noise_key`, as the platform signs it.
    fn grant(&self, noise_key: &[u8; 32], jti: usize) -> String {
        let header = json!({"alg": "EdDSA", "kid": "k1", "typ": GRANT_TYP});
        let claims = json!({
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
/// `status` other than 200 refuses every request.
async fn platform(
    signer: Arc<Signer>,
    relay: SocketAddr,
    daemon_key: [u8; 32],
    status: u16,
    asked: Arc<AtomicUsize>,
    teams: Teams,
) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let signer = signer.clone();
            let asked = asked.clone();
            let teams = teams.clone();
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
                        "daemon_key": URL_SAFE_NO_PAD.encode(daemon_key),
                    });
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

/// The session's mux socket: echoes each line, then pushes one line of its own.
async fn fake_mux(path: &Path) {
    let listener = tokio::net::UnixListener::bind(path).unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
                    writer.write_all(b"{\"event\":\"pushed\"}\n").await.unwrap();
                }
            });
        }
    });
}

/// The `x-cmux-team` header of each platform request (`None` when absent).
type Teams = Arc<Mutex<Vec<Option<String>>>>;

struct World {
    platform: SocketAddr,
    teams: Teams,
    dir: tempfile::TempDir,
    _registration: cmux_remote::provider::RelayDaemonRegistration,
    _runtime: tokio::runtime::Runtime,
}

/// A relay, a registered daemon with a grant verifier and a mux socket, and
/// the platform route answering `status` with grants for `service`.
fn world(status: u16, asked: Arc<AtomicUsize>) -> World {
    world_granting(status, asked, "mux-control")
}

fn world_granting(status: u16, asked: Arc<AtomicUsize>, service: &'static str) -> World {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mux = dir.path().join("mux.sock");
    let state = dir.path().join("daemon");
    let teams = Teams::default();
    let (platform, registration) = runtime.block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        let signer = Arc::new(Signer::generate(service));
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
            auth.identity().public_key(),
            status,
            asked,
            teams.clone(),
        )
        .await;
        (platform, registration)
    });
    World { platform, teams, dir, _registration: registration, _runtime: runtime }
}

fn dial(world: &World) -> Child {
    dial_with(world, &[])
}

fn dial_with(world: &World, extra: &[&str]) -> Child {
    Command::new(BIN)
        .args(["carrier", "dial", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(extra)
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

fn line(reader: &mut impl BufRead) -> String {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    line
}

#[test]
fn a_carrier_dial_carries_the_daemon_stream_both_ways() {
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world(200, asked.clone());
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply, json!({"ok": true, "path_state": "relay", "route": "carrier"}));
    let route = line(&mut stderr);
    assert!(
        route.starts_with(&format!(
            "cloud.connect route=carrier machine={MACHINE} phase=connect outcome=ok ms="
        )),
        "{route}"
    );
    assert!(asked.load(Ordering::SeqCst) >= 1, "the ticket came from the platform");

    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    stdin.write_all(b"{\"cmd\":\"identify\",\"id\":1}\n").unwrap();
    stdin.flush().unwrap();
    assert_eq!(
        line(&mut stdout),
        "{\"cmd\":\"identify\",\"id\":1}\n",
        "the device's line reached the daemon"
    );
    assert_eq!(
        line(&mut stdout),
        "{\"event\":\"pushed\"}\n",
        "the daemon's own line reached the device"
    );

    drop(stdin);
    let status = wait(&mut child, Duration::from_secs(20));
    assert_eq!(status, Some(0), "the dial ends when its stream ends");
    let teams = world.teams.lock().unwrap().clone();
    assert!(
        !teams.is_empty() && teams.iter().all(Option::is_none),
        "no team, no header: {teams:?}"
    );
    // The route line also went to the dial's own connect log, exactly.
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    let text = std::fs::read_to_string(&log).unwrap();
    assert_eq!(text, route, "connect.log holds the route line and nothing else");
    let ms = route.trim_end().rsplit_once(" ms=").unwrap().1;
    assert!(!ms.is_empty() && ms.bytes().all(|b| b.is_ascii_digit()), "nothing after ms=: {route}");
}

#[test]
fn a_named_team_goes_to_the_platform_as_x_cmux_team() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let mut child = dial_with(&world, &["--team", TEAM]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
    let teams = world.teams.lock().unwrap().clone();
    assert!(
        !teams.is_empty() && teams.iter().all(|t| t.as_deref() == Some(TEAM)),
        "every request names the team: {teams:?}"
    );
}

#[test]
fn a_refused_ticket_names_the_ticket_step() {
    let world = world(403, Arc::new(AtomicUsize::new(0)));
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error_code"], "ticket");
    assert!(reply["error_detail"].as_str().unwrap().contains("auth.forbidden"), "{reply}");
    let route = line(&mut stderr);
    assert!(route.contains("phase=connect outcome=ticket"), "{route}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(2));
}

#[test]
fn a_grant_without_mux_control_fails_the_handshake_before_ok() {
    let world = world_granting(200, Arc::new(AtomicUsize::new(0)), "tcp-tunnel");
    let mut child = dial(&world);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "handshake", "{reply}");
    let route = line(&mut stderr);
    assert!(route.contains("phase=connect outcome=handshake"), "{route}");
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(5));
}

/// The desktop is the machine owner's alone: this test's grants carry no
/// `vmk`, so the daemon refuses the desktop stream and the dial says so.
#[test]
fn a_desktop_dial_without_the_owner_grant_is_refused_as_a_service() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let mut child = dial_with(&world, &["--service", "desktop"]);
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let reply: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "service_refused", "{reply}");
    assert!(
        reply["error_detail"].as_str().unwrap().contains("does not allow local-socket"),
        "{reply}"
    );
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(6));
}

/// The child's exit code, or None (and the child ended) past `limit`.
fn wait(child: &mut Child, limit: Duration) -> Option<i32> {
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
