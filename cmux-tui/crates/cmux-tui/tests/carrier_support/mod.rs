//! What the carrier end-to-end tests share: a local stand-in for
//! cmux-platform's carrier route, a real cmux-relay, and a real cmux-remote
//! daemon whose grant verifier trusts a keyset made for the test, with a
//! fake mux socket behind it. Every key is generated here.
#![allow(dead_code)]

pub mod host;

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
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, watch};

pub const MACHINE: &str = "vm_0123456789abcdefghij";
pub const ISSUER: &str = "cmux:cloud:test";
pub const SLOT: &str = "carrier-dial-slot";
pub const TOKEN: &str = "person-test-credential";
/// Two people's JWT credentials (`sub` person-a, person-b), both of whom
/// the platform answers for.
pub const JWT_A: &str = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJwZXJzb24tYSJ9.sig";
pub const JWT_B: &str = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJwZXJzb24tYiJ9.sig";
/// Two opaque dotted credentials, not JWTs, whose middle segments are the
/// same `sub` person-a claim; the platform answers for both.
pub const OPAQUE_1: &str = "opaque.eyJzdWIiOiJwZXJzb24tYSJ9.one";
pub const OPAQUE_2: &str = "other.eyJzdWIiOiJwZXJzb24tYSJ9.two";
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

/// The `status` at which the platform answers nothing for a minute (past
/// the dial's 20 s fetch timeout): a dial that stays in its ticket step.
pub const HANG: u16 = 599;
/// The `status` at which the platform answers as for 200, two seconds late.
pub const SLOW: u16 = 598;

/// The platform's carrier route: checks the bearer, answers a Connect
/// ticket for the open relay, a grant for the asked key, and the daemon key.
/// `status` other than 200 (read at each request) refuses it; [`HANG`]
/// answers nothing for a minute.
// A stand-in's wiring: one argument per thing a test reads back.
#[allow(clippy::too_many_arguments)]
pub async fn platform(
    signer: Arc<Signer>,
    relay: SocketAddr,
    daemon_key: Option<String>,
    status: Arc<AtomicU16>,
    asked: Arc<AtomicUsize>,
    teams: Teams,
    keys: Keys,
    bearers: Bearers,
    ssh: Option<Arc<SshStub>>,
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
            let keys = keys.clone();
            let bearers = bearers.clone();
            let ssh = ssh.clone();
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
                    if let Some(bearer) =
                        [TOKEN, JWT_A, JWT_B, OPAQUE_1, OPAQUE_2].into_iter().find(|token| {
                            header
                                == format!("authorization: bearer {}", token.to_ascii_lowercase())
                        })
                    {
                        authorized = true;
                        bearers.lock().unwrap().push(bearer);
                    }
                }
                let mut body = vec![0; length];
                reader.read_exact(&mut body).await.unwrap();
                let request: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                if let Some(ssh) = ssh.as_ref().filter(|_| path.ends_with("/ssh-endpoint")) {
                    assert_eq!(path, format!("/v1/cloud/machines/{MACHINE}/ssh-endpoint"));
                    assert!(authorized, "ssh-endpoint takes the person's credential");
                    let body = ssh.endpoint(&request).to_string();
                    let reply = format!(
                        "HTTP/1.1 200 X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(reply.as_bytes()).await;
                    return;
                }
                teams.lock().unwrap().push(team);
                keys.lock().unwrap().push(request["noise_key"].as_str().map(str::to_owned));
                let n = asked.fetch_add(1, Ordering::SeqCst);
                if status == HANG {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                }
                if status == SLOW {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
                let status = if status == SLOW { 200 } else { status };
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
                    if let Some(ssh) = &ssh {
                        value["ssh"] = ssh.candidate();
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

/// Answers `line` when it is the role stamp the session host writes first on a
/// grant's `mux-control` stream (`cmux-remote` `mux_carrier_role.rs`), the way
/// the session daemon takes it (`cmux-tui-core` `server/carrier_role.rs`), and
/// says whether it was. A stand-in that echoed the stamp instead did not take
/// it, so the host refused every stream of a grant that is not the owner's.
/// Like the daemon, it takes only a well-formed stamp (the stamp's request id
/// and exactly a valid `vmk`) and refuses any other `carrier-role` line.
pub async fn took_role_stamp(line: &str, writer: &mut tokio::net::unix::OwnedWriteHalf) -> bool {
    use cmux_link::carrier_role::{COMMAND, REQUEST_ID, parse};
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(line) else { return false };
    if fields.get("cmd").and_then(Value::as_str) != Some(COMMAND) {
        return false;
    }
    fields.remove("cmd");
    let id = fields.remove("id").unwrap_or(Value::Null);
    let taken = if id == REQUEST_ID && parse(&fields).is_some() {
        json!({"id": id, "ok": true, "data": {}})
    } else {
        let code = "carrier_role.malformed";
        json!({"id": id, "ok": false, "error": code, "error_code": code})
    };
    let _ = writer.write_all(format!("{taken}\n").as_bytes()).await;
    true
}

/// The session's mux socket: takes the role stamp ([`took_role_stamp`]),
/// echoes each line, then pushes one line of its own naming the mux
/// connection (`conn`, 0 for the first), so two sessions tell apart.
pub async fn fake_mux(path: &Path) {
    let listener = tokio::net::UnixListener::bind(path).unwrap();
    tokio::spawn(async move {
        for conn in 0_usize.. {
            let Ok((stream, _)) = listener.accept().await else { return };
            tokio::spawn(async move {
                let (reader, mut writer) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if took_role_stamp(&line, &mut writer).await {
                        continue;
                    }
                    writer.write_all(format!("{line}\n").as_bytes()).await.unwrap();
                    let pushed = format!("{{\"event\":\"pushed\",\"conn\":{conn}}}\n");
                    writer.write_all(pushed.as_bytes()).await.unwrap();
                }
            });
        }
    });
}

/// The platform's ssh backup carrier: the carrier answer's `ssh` candidate
/// and `ssh-endpoint`'s answer, a carrier key's route to it. Every
/// ssh-endpoint request body is kept.
#[derive(Default)]
pub struct SshStub {
    pub asked: Mutex<Vec<Value>>,
}

/// The candidate's mesh address (never dialed: the fake ssh runs the forced
/// command itself).
pub const SSH_HOST: &str = "10.20.0.7";

/// A well-formed host key for the candidate.
pub fn ssh_host_key() -> String {
    let mut blob = Vec::new();
    blob.extend_from_slice(&11_u32.to_be_bytes());
    blob.extend_from_slice(b"ssh-ed25519");
    blob.extend_from_slice(&32_u32.to_be_bytes());
    blob.extend_from_slice(&[7_u8; 32]);
    format!("ssh-ed25519 {}", base64::engine::general_purpose::STANDARD.encode(blob))
}

impl SshStub {
    fn candidate(&self) -> Value {
        json!({"host": SSH_HOST, "port": 22, "user": "cmux", "hostKey": null})
    }

    fn endpoint(&self, request: &Value) -> Value {
        self.asked.lock().unwrap().push(request.clone());
        json!({
            "host": SSH_HOST,
            "port": 22,
            "username": "cmux",
            "hostPublicKey": ssh_host_key(),
            "expiresAtUnix": now() + 900,
            "purpose": "carrier",
        })
    }
}

/// The `x-cmux-team` header of each platform request (`None` when absent).
pub type Teams = Arc<Mutex<Vec<Option<String>>>>;
/// The `noise_key` of each platform request (`None` for a ticket-only ask).
pub type Keys = Arc<Mutex<Vec<Option<String>>>>;
/// The accepted credential of each platform request that had one, in order.
pub type Bearers = Arc<Mutex<Vec<&'static str>>>;

pub struct World {
    pub platform: SocketAddr,
    pub teams: Teams,
    pub keys: Keys,
    pub bearers: Bearers,
    /// The relay the platform's answers name.
    pub relay: SocketAddr,
    /// The daemon key the platform answers (as `world_full`'s `key` says).
    pub daemon_key: Option<String>,
    signer: Arc<Signer>,
    /// What the platform answers next (200 grants, anything else refuses).
    pub status: Arc<AtomicU16>,
    pub dir: tempfile::TempDir,
    /// The daemon's registration (set late in [`world_parked`]).
    _registration: Registration,
    _runtime: tokio::runtime::Runtime,
}

type Registration = Arc<Mutex<Option<cmux_remote::provider::RelayDaemonRegistration>>>;

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
    world_with(status, asked, service, key, vmk, None)
}

/// A world whose relay parks a dial's Connect until the daemon registers,
/// and whose daemon registers `register_after` the first Connect arrives.
/// The relay here answers a Connect at once, so a proxy in front of it
/// holds each client's control bytes after its WebSocket upgrade (the
/// Connect) until the daemon has registered, as a parking relay does.
pub fn world_parked(register_after: Duration) -> World {
    world_with(
        200,
        Arc::new(AtomicUsize::new(0)),
        "mux-control",
        DaemonKey::Real,
        None,
        Some(register_after),
    )
}

fn world_with(
    status: u16,
    asked: Arc<AtomicUsize>,
    service: &'static str,
    key: DaemonKey,
    vmk: Option<&'static str>,
    park: Option<Duration>,
) -> World {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mux = dir.path().join("mux.sock");
    let state = dir.path().join("daemon");
    let teams = Teams::default();
    let keys = Keys::default();
    let bearers = Bearers::default();
    let shared_status = Arc::new(AtomicU16::new(status));
    let answered = shared_status.clone();
    let (platform, registration, relay, signer, daemon_key) = runtime.block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        // A parked Connect is the client control socket's first message:
        // the relay must not end it as a slow handshake while it waits.
        let relay = Relay::new(RelayConfig {
            allow_open: true,
            handshake_timeout: Duration::from_secs(120),
            ..RelayConfig::default()
        })
        .unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        let signer = Arc::new(Signer::generate(service, vmk));
        let answered_signer = signer.clone();
        std::fs::create_dir_all(&state).unwrap();
        let auth = AuthDatabase::load_or_create(&state, "carrier-dial-test", false).unwrap();
        let verifier =
            CarrierGrantVerifier::new(ISSUER, MACHINE, TEAM, signer.keyset(), || Some(now()), 64)
                .unwrap();
        auth.set_grant_verifier(Arc::new(verifier)).unwrap();
        let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let register = move || {
            register_relay_daemon(
                daemon,
                RelayDaemonConfig {
                    endpoint: url::Url::parse(&format!("relay+ws://{relay_address}")).unwrap(),
                    slot: SLOT.into(),
                    ticket: "open-daemon-ticket".into(),
                    maximum_frame_bytes: 65_535,
                    control_timeout: Duration::from_secs(5),
                },
            )
        };
        let registration = Registration::default();
        // The address the platform names: the relay, or the parking proxy.
        let named_relay = match park {
            None => {
                let registered = register().await.unwrap();
                *registration.lock().unwrap() = Some(registered);
                relay_address
            }
            Some(after) => {
                let (registered, open) = watch::channel(false);
                let held = Arc::new(Notify::new());
                let proxy = parking_proxy(relay_address, open, held.clone()).await;
                let late = registration.clone();
                tokio::spawn(async move {
                    held.notified().await;
                    tokio::time::sleep(after).await;
                    let done = register().await.unwrap();
                    *late.lock().unwrap() = Some(done);
                    let _ = registered.send(true);
                });
                proxy
            }
        };
        fake_mux(&mux).await;
        let services = DaemonServices::new(WorkspaceService::new(), Some(mux.clone()));
        std::thread::spawn(move || {
            let local = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            local.block_on(services.run(accepted));
        });
        let daemon_key = match key {
            DaemonKey::Real => Some(URL_SAFE_NO_PAD.encode(auth.identity().public_key())),
            DaemonKey::Missing => None,
            DaemonKey::Malformed => Some("not-a-key".into()),
            DaemonKey::Other => Some(URL_SAFE_NO_PAD.encode([9_u8; 32])),
        };
        let platform = platform(
            signer,
            named_relay,
            daemon_key.clone(),
            answered,
            asked,
            teams.clone(),
            keys.clone(),
            bearers.clone(),
            None,
        )
        .await;
        (platform, registration, named_relay, answered_signer, daemon_key)
    });
    World {
        platform,
        teams,
        keys,
        bearers,
        relay,
        daemon_key,
        signer,
        status: shared_status,
        dir,
        _registration: registration,
        _runtime: runtime,
    }
}

/// A proxy to `relay` that holds each connection's client bytes after its
/// WebSocket upgrade until `open` is true, and notifies `held` when it
/// holds one. The relay's bytes to the client always flow.
async fn parking_proxy(
    relay: SocketAddr,
    open: watch::Receiver<bool>,
    held: Arc<Notify>,
) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((client, _)) = listener.accept().await else { return };
            let (mut open, held) = (open.clone(), held.clone());
            tokio::spawn(async move {
                let Ok(upstream) = TcpStream::connect(relay).await else { return };
                let (mut client_read, mut client_write) = client.into_split();
                let (mut upstream_read, mut upstream_write) = upstream.into_split();
                tokio::spawn(async move {
                    let _ = tokio::io::copy(&mut upstream_read, &mut client_write).await;
                });
                // The upgrade request goes through; what follows it waits.
                let mut request = Vec::new();
                let mut chunk = [0_u8; 4096];
                let end = loop {
                    let Ok(read) = client_read.read(&mut chunk).await else { return };
                    if read == 0 {
                        return;
                    }
                    request.extend_from_slice(&chunk[..read]);
                    if let Some(at) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                        break at + 4;
                    }
                };
                if upstream_write.write_all(&request[..end]).await.is_err() {
                    return;
                }
                if !*open.borrow() {
                    held.notify_one();
                    if open.wait_for(|open| *open).await.is_err() {
                        return;
                    }
                }
                if upstream_write.write_all(&request[end..]).await.is_err() {
                    return;
                }
                let _ = tokio::io::copy(&mut client_read, &mut upstream_write).await;
            });
        }
    });
    address
}

/// The jti of handed-over grants: apart from the platform's, each its own.
static HANDED_OVER: AtomicUsize = AtomicUsize::new(1_000_000);

impl World {
    /// A create's `carrier` for the device whose Noise key is `noise_key`
    /// (base64url), as the dial or serve takes it on a line:
    /// `{"carrier_answer":{…}}`, with the platform's `daemon_key` when
    /// `with_daemon_key`.
    pub fn answer_line(&self, noise_key: &str, with_daemon_key: bool) -> String {
        let key: [u8; 32] = URL_SAFE_NO_PAD.decode(noise_key).unwrap().try_into().unwrap();
        let mut value = json!({
            "relay": format!("relay+ws://{}", self.relay),
            "slot": SLOT,
            "ticket": "open-client-ticket",
            "expires_at": now() + 300,
            "grant": self.signer.grant(&key, HANDED_OVER.fetch_add(1, Ordering::SeqCst)),
        });
        if with_daemon_key && let Some(daemon_key) = &self.daemon_key {
            value["daemon_key"] = json!(daemon_key);
        }
        format!("{}\n", json!({ "carrier_answer": value }))
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

/// A machine reachable over both carriers: the relay (behind a proxy a test
/// can cut, or a dead address) and a fake ssh whose "forced command" runs
/// the real `cmux-tui remote-link` into the same daemon's link socket.
pub struct SshWorld {
    pub platform: SocketAddr,
    pub dir: tempfile::TempDir,
    pub ssh: Arc<SshStub>,
    /// The tunnel hub's socket (a listener that only accepts).
    pub hub: std::path::PathBuf,
    /// The fake ssh client, and the file it writes its arguments to.
    pub fake_ssh: std::path::PathBuf,
    pub ssh_args: std::path::PathBuf,
    /// Cuts every relay connection, and refuses new ones.
    pub cut: watch::Sender<bool>,
    _hub: std::os::unix::net::UnixListener,
    _link: cmux_remote::daemon::UnixServer,
    _registration: Option<cmux_remote::provider::RelayDaemonRegistration>,
    _runtime: tokio::runtime::Runtime,
}

impl SshWorld {
    /// The dial's own connect log.
    pub fn connect_log(&self) -> String {
        let log = self.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
        std::fs::read_to_string(log).unwrap_or_default()
    }

    /// The private state the ssh carrier keeps.
    pub fn ssh_state(&self) -> std::path::PathBuf {
        self.dir.path().join(".local/state/cmux-tui/sessions/carrier/ssh")
    }
}

/// `relay_up`: the platform names a relay proxy the test can cut; else an
/// address nothing listens on, so every relay connect is refused.
pub fn world_ssh(relay_up: bool) -> SshWorld {
    use std::os::unix::fs::PermissionsExt as _;
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mux = dir.path().join("mux.sock");
    let link = dir.path().join("link.sock");
    let state = dir.path().join("daemon");
    let hub = dir.path().join("hub.sock");
    let hub_listener = std::os::unix::net::UnixListener::bind(&hub).unwrap();
    let ssh_args = dir.path().join("ssh-args");
    let fake_ssh = dir.path().join("fake-ssh");
    // sshd runs the key's forced command whatever the client asks; this
    // stand-in does the same, without the network or the ProxyCommand.
    std::fs::write(
        &fake_ssh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '{}'\nexec '{BIN}' remote-link --stdio --session carrier-ssh --link-socket '{}'\n",
            ssh_args.display(),
            link.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&fake_ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    let ssh = Arc::new(SshStub::default());
    let (cut, cut_seen) = watch::channel(false);
    let (platform, registration, link_server) = runtime.block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
        let (listener, router) = relay.server_parts(listener);
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let signer = Arc::new(Signer::generate("mux-control", None));
        std::fs::create_dir_all(&state).unwrap();
        let auth = AuthDatabase::load_or_create(&state, "carrier-ssh-test", false).unwrap();
        let verifier =
            CarrierGrantVerifier::new(ISSUER, MACHINE, TEAM, signer.keyset(), || Some(now()), 64)
                .unwrap();
        auth.set_grant_verifier(Arc::new(verifier)).unwrap();
        let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let link_server =
            cmux_remote::daemon::serve_unix(daemon.clone(), link.clone(), 65_535).await.unwrap();
        let (named, registration) = if relay_up {
            let registered = register_relay_daemon(
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
            (cuttable_proxy(relay_address, cut_seen).await, Some(registered))
        } else {
            let dead = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap();
            (dead, None)
        };
        fake_mux(&mux).await;
        let services = DaemonServices::new(WorkspaceService::new(), Some(mux.clone()));
        std::thread::spawn(move || {
            let local = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            local.block_on(services.run(accepted));
        });
        let daemon_key = Some(URL_SAFE_NO_PAD.encode(auth.identity().public_key()));
        let platform = platform(
            signer,
            named,
            daemon_key,
            Arc::new(AtomicU16::new(200)),
            Arc::new(AtomicUsize::new(0)),
            Teams::default(),
            Keys::default(),
            Bearers::default(),
            Some(ssh.clone()),
        )
        .await;
        (platform, registration, link_server)
    });
    SshWorld {
        platform,
        dir,
        ssh,
        hub,
        fake_ssh,
        ssh_args,
        cut,
        _hub: hub_listener,
        _link: link_server,
        _registration: registration,
        _runtime: runtime,
    }
}

/// A TCP proxy to `relay` whose connections all end, and whose new ones
/// are refused, once `cut` is true.
async fn cuttable_proxy(relay: SocketAddr, cut: watch::Receiver<bool>) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut client, _)) = listener.accept().await else { return };
            if *cut.borrow() {
                continue;
            }
            let mut cut = cut.clone();
            tokio::spawn(async move {
                let Ok(mut upstream) = TcpStream::connect(relay).await else { return };
                tokio::select! {
                    _ = tokio::io::copy_bidirectional(&mut client, &mut upstream) => {}
                    _ = cut.wait_for(|cut| *cut) => {}
                }
            });
        }
    });
    address
}
