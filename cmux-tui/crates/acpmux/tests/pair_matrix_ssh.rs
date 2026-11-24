//! The transport pair matrix's `ssh -W` direct path (DESIGN: mobile-speed pair matrix, rows
//! mac-linux and mac-mac): the path a Mac takes to an `ssh://` peer (a Linux fleet host, a
//! machine with nothing but sshd reachable), which `peer_carriers.rs` always keeps
//! ("ssh: `ssh -W` to the configured `ssh://` URL. Always kept"). `pair_matrix_desktop.rs` has the
//! peer's other direct path (ws) and the hub-carrier relay; this file is only the ssh variant.
//!
//! The rig, all on one runner:
//! - B: an in-process acpmux hub with the stand-in agent, serving its WebSocket with a peer
//!   token, as the remote daemon does.
//! - A throwaway OpenSSH server (the runner's `/usr/sbin/sshd`, not root, on a free loopback
//!   port, its own host key and one authorized key), as hq's connectivity harness
//!   `acpmux-peer-bench.sh` runs one.
//! - `cmux_fault::shaper::Shaper` in front of that sshd: the shaped link is the ssh TCP
//!   connection, so every wire byte counted is an encrypted ssh byte.
//! - A: an in-process acpmux hub (the Mac's daemon) whose peer `box` is
//!   `ssh://box.invalid:<B's port>` with both tokens configured (so ssh is only the tunnel), and
//!   whose `ssh` is a shim on PATH that runs the real `/usr/bin/ssh` with this rig's config
//!   (host 127.0.0.1, the shaper's port, the rig's key). A's peer code is the product's:
//!   `open_ssh` (`peer_carriers.rs:634`), `spawn_tunnel` (`peer_runtime.rs:352`), its liveness
//!   and redial.
//! - The client: an in-process connection to A (the Mac app's), attaching B's chat by its
//!   peer name `box/pm-chat` (`_acpmux/attach`, limit 400, 128 KiB) and watching its events.
//!
//! Metrics (DESIGN "Cell = 4 metrics"): `ttfc_ms` from adding the peer to the first attach
//! that returns rows; `resume_ms` from the condition's end to the arrival on A's client of a
//! marker prompted into the chat on B after the change (the steady conditions, loss and
//! latency, end with a 5 s blip in the link, as `pair_matrix_desktop.rs` does); `delta_bytes` both ways
//! through the shaper from the change to that arrival (`long`: bytes per minute over the hold);
//! `fail` 1 when a run reached no content or no marker within 90 s, or saw a marker event's seq
//! twice. Lines: `PAIRCELL {...}` with `"path":"direct-ssh"`, `PAIRCELL-NA {...}`.
//!
//! Not in any number: the client Mac's app (Swift), a real second host (both hubs run on this
//! runner: `host_os` is the runner's), a wall-clock jump during `sleep` (the hubs share this
//! process's clock), and failover (an `ssh://` peer has no second path without a hub
//! `daemonId`, `peer_carriers.rs:11`; the relay rows are `pair_matrix_desktop.rs`'s).
//!
//! `#[ignore]`: `cargo test --release -p acpmux --test pair_matrix_ssh -- --ignored --nocapture
//! --test-threads 1`, with `PAIRMATRIX_*` (DESIGN "Env every bench reads").
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/) and the runner's ssh and sshd.
// It starts from a cleared environment, so the bench's knobs are kept by name.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "PAIRMATRIX_PAIR",
    "PAIRMATRIX_N",
    "PAIRMATRIX_SEED_BASE",
    "PAIRMATRIX_CONDITIONS",
    "PAIRMATRIX_LOADS",
    "PAIRMATRIX_PATHS",
    "PAIRMATRIX_LONG_MINUTES",
]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message as RpcMessage, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    Origin, WsAuth, bind_ws, serve_connection, serve_connection_with, serve_ws_with,
};
use cmux_fault::Trace;
use cmux_fault::shaper::{LinkProfile, ProfileFile, Shaper};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::time::Instant;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const RIG: &str = "pair_matrix_ssh.rs::pair_matrix_ssh";
const PATH_NAME: &str = "direct-ssh";
/// A run that reaches no content (or no marker) within this is a failure (DESIGN).
const BOUND: Duration = Duration::from_secs(90);
const SSH: &str = "/usr/bin/ssh";
const SSH_KEYGEN: &str = "/usr/bin/ssh-keygen";
const SSHD: &str = "/usr/sbin/sshd";
/// The person key both hubs hold (`hub/person.rs`), as `peer_integration.rs`'s clients do.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CHAT: &str = "pm-chat";
const ALL_CONDITIONS: &[&str] = &["loss", "latency", "handoff", "sleep", "failover", "long"];

// ---------------------------------------------------------------------------------------------
// Env and lines

fn env_list(name: &str, default: &[&str]) -> Vec<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => {
            v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
        }
        _ => default.iter().map(|s| (*s).to_owned()).collect(),
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

fn pair() -> String {
    std::env::var("PAIRMATRIX_PAIR")
        .ok()
        .filter(|p| !p.trim().is_empty())
        .unwrap_or_else(|| "mac-linux".into())
}

fn host_os() -> &'static str {
    std::env::consts::OS
}

struct Key<'a> {
    condition: &'a str,
    load: &'a str,
    run: u64,
    seed: u64,
    profile: &'a str,
}

fn emit(k: &Key, metric: &str, value: Option<f64>, error: Option<&str>) {
    let mut line = json!({
        "pair": pair(), "path": PATH_NAME, "condition": k.condition, "load": k.load,
        "metric": metric, "value": value, "run": k.run, "seed": k.seed, "host_os": host_os(),
        "client_os": host_os(), "profile": k.profile, "rig": RIG,
    });
    if let Some(e) = error {
        line["error"] = json!(e);
    }
    println!("PAIRCELL {line}");
}

fn emit_na(condition: &str, load: &str, reason: &str) {
    let line = json!({
        "pair": pair(), "path": PATH_NAME, "condition": condition, "load": load, "metric": "*",
        "host_os": host_os(), "rig": RIG, "reason": reason,
    });
    println!("PAIRCELL-NA {line}");
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 10_000.0).round() / 10.0
}

// ---------------------------------------------------------------------------------------------
// The throwaway sshd and A's ssh shim

struct Sshd {
    child: std::process::Child,
    dir: PathBuf,
    port: u16,
}

impl Drop for Sshd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn run_ok(cmd: &mut std::process::Command) -> Result<String, String> {
    let out = cmd.output().map_err(|e| format!("{cmd:?}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{cmd:?}: {} {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn write_exe(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// sshd on a free loopback port in `dir`, and A's `ssh` shim at `dir/bin/ssh`, which dials the
/// port in `dir/port` (the run's shaper). Err names why it cannot run on this runner.
fn sshd_up(dir: &Path) -> Result<Sshd, String> {
    for tool in [SSH, SSH_KEYGEN, SSHD] {
        if !Path::new(tool).exists() {
            return Err(format!(
                "no {tool} on this runner (the ssh path needs OpenSSH's client and server)"
            ));
        }
    }
    std::fs::create_dir_all(dir.join("bin")).map_err(|e| e.to_string())?;
    let user = run_ok(std::process::Command::new("id").arg("-un"))?;
    for key in ["hostkey", "userkey"] {
        let path = dir.join(key);
        run_ok(
            std::process::Command::new(SSH_KEYGEN)
                .args(["-q", "-t", "ed25519", "-N", "", "-f"])
                .arg(&path),
        )?;
    }
    std::fs::copy(dir.join("userkey.pub"), dir.join("authorized_keys"))
        .map_err(|e| e.to_string())?;
    let port = free_port();
    let d = dir.display();
    std::fs::write(
        dir.join("sshd_config"),
        format!(
            "Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/hostkey\nAuthorizedKeysFile {d}/authorized_keys\n\
             PasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\n\
             PidFile {d}/sshd.pid\nMaxStartups 200\nMaxSessions 200\nAllowTcpForwarding yes\n\
             AllowUsers {user}\nLogLevel ERROR\n"
        ),
    )
    .map_err(|e| e.to_string())?;
    std::fs::write(
        dir.join("ssh_config"),
        format!(
            "Host *\n  HostName 127.0.0.1\n  User {user}\n  IdentityFile {d}/userkey\n  IdentitiesOnly yes\n\
             \x20 StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n"
        ),
    )
    .map_err(|e| e.to_string())?;
    // One line per ssh A spawns (W: a tunnel), then the real client on the run's shaper port.
    write_exe(
        &dir.join("bin/ssh"),
        &format!(
            "#!/bin/sh\ncase \" $* \" in *\" -W \"*) k=W;; *) k=read;; esac\necho \"$k\" >> {d}/ssh.log\n\
             exec {SSH} -F {d}/ssh_config -o Port=\"$(cat {d}/port)\" \"$@\"\n"
        ),
    );
    let log = std::fs::File::create(dir.join("sshd.log")).map_err(|e| e.to_string())?;
    let child = std::process::Command::new(SSHD)
        .args(["-D", "-e", "-f"])
        .arg(dir.join("sshd_config"))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(log)
        .spawn()
        .map_err(|e| format!("spawn {SSHD}: {e}"))?;
    let mut sshd = Sshd { child, dir: dir.to_owned(), port };
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        if let Ok(Some(status)) = sshd.child.try_wait() {
            let log = std::fs::read_to_string(dir.join("sshd.log")).unwrap_or_default();
            return Err(format!("sshd exited {status}: {}", log.trim()));
        }
        if std::time::Instant::now() > deadline {
            return Err("sshd did not listen within 10 s".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // One login through the shim, unshaped, so a refusal (a locked account, no forwarding)
    // shows here once instead of as 90 s failures in every cell.
    std::fs::write(dir.join("port"), port.to_string()).map_err(|e| e.to_string())?;
    let probe = run_ok(std::process::Command::new(dir.join("bin/ssh")).args([
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        "--",
        "box.invalid",
        "echo",
        "pm-ok",
    ]));
    match probe {
        Ok(out) if out.contains("pm-ok") => {}
        Ok(out) => return Err(format!("ssh login probe said {out:?}")),
        Err(e) => {
            let log = std::fs::read_to_string(dir.join("sshd.log")).unwrap_or_default();
            return Err(format!("ssh login probe failed: {e}; sshd: {}", log.trim()));
        }
    }
    let _ = std::fs::remove_file(dir.join("ssh.log"));
    sshd.port = port;
    Ok(sshd)
}

fn tunnels(dir: &Path) -> u64 {
    std::fs::read_to_string(dir.join("ssh.log"))
        .map(|s| s.lines().filter(|l| *l == "W").count() as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------------------------
// Hubs and connections

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// B's WebSocket with a peer token (`server/peer_auth.rs`): its port and the token.
async fn listen_with_peer_token(b: Arc<Hub>, home: &Path) -> (u16, String) {
    std::fs::create_dir_all(home).unwrap();
    let auth = PeerAuth::create(home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token.trim().to_owned())
}

/// B's own connection: seeds the chat and prompts markers and the stream into it.
struct Control {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Control {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(65536);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(RpcMessage::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn answer(&mut self, id: i64, within: Duration) -> Option<Value> {
        let deadline = Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            let v: Value = serde_json::from_str(&line).ok()?;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return Some(v);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.answer(id, BOUND).await.unwrap_or_else(|| panic!("{m}: no answer in {BOUND:?}"))
    }

    async fn new_session(&mut self, cwd: &Path, name: &str) -> String {
        let made = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) -> Option<Value> {
        let id = self
            .post(
                method::SESSION_PROMPT,
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
            )
            .await;
        self.answer(id, BOUND).await
    }

    /// Turns of ~1 KB answers (the stand-in agent echoes the prompt) until `turns`.
    async fn seed(&mut self, session: &str, turns: u64) {
        let pad = "lorem ipsum dolor sit amet ".repeat(37);
        let started = Instant::now();
        for n in 0..turns {
            if n > 0 && n % 500 == 0 {
                eprintln!(
                    "pairmatrix-ssh: seeding turn {n}/{turns}, {:?} so far",
                    started.elapsed()
                );
            }
            let v = self.prompt(session, &format!("turn {n}: {pad}")).await;
            let v = v.unwrap_or_else(|| panic!("seed turn {n} hung"));
            assert!(v.get("error").is_none(), "seed turn {n}: {v}");
        }
    }
}

/// What A's client saw of the marker it waits for.
#[derive(Default)]
struct Watch {
    marker: Option<String>,
    first: Option<Instant>,
    seqs: Vec<u64>,
    dup: bool,
}

/// The Mac app's connection to A: requests by id, every notification read at once (a stream
/// into the chat never backs up into A), marker events noted.
struct Client {
    tx: mpsc::Sender<String>,
    next: AtomicI64,
    pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
    watch: Arc<Mutex<Watch>>,
    hit: Arc<Notify>,
}

fn event_seq(v: &Value) -> Option<u64> {
    if v.get("method").and_then(Value::as_str) != Some(method::MUX_EVENT) {
        return None;
    }
    let p = &v["params"];
    ["seq", "/event/seq", "/record/seq"]
        .iter()
        .find_map(|k| if k.starts_with('/') { p.pointer(k) } else { p.get(*k) })
        .and_then(Value::as_u64)
}

impl Client {
    async fn open(hub: Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
        tokio::spawn(serve_connection(hub, in_rx, out_tx));
        let pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>> = Arc::default();
        let watch: Arc<Mutex<Watch>> = Arc::default();
        let hit = Arc::new(Notify::new());
        {
            let (pending, watch, hit) = (pending.clone(), watch.clone(), hit.clone());
            tokio::spawn(async move {
                while let Some(line) = out_rx.recv().await {
                    let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                    if v.get("method").is_none() {
                        if let Some(id) = v.get("id").and_then(Value::as_i64)
                            && let Some(tx) = pending.lock().unwrap().remove(&id)
                        {
                            let _ = tx.send(v);
                        }
                        continue;
                    }
                    let mut w = watch.lock().unwrap();
                    let Some(marker) = w.marker.clone() else { continue };
                    if !line.contains(&marker) {
                        continue;
                    }
                    if let Some(seq) = event_seq(&v) {
                        if w.seqs.contains(&seq) {
                            w.dup = true;
                        }
                        w.seqs.push(seq);
                    }
                    if w.first.is_none() {
                        w.first = Some(Instant::now());
                        hit.notify_waiters();
                        hit.notify_one();
                    }
                }
            });
        }
        let c = Self { tx, next: AtomicI64::new(0), pending, watch, hit };
        let init = c
            .call(
                method::INITIALIZE,
                json!({"protocolVersion": 1, "clientInfo": {"name": "pair-matrix-ssh"}}),
                BOUND,
            )
            .await
            .expect("initialize");
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        if let (Some(nonce), Some(conn)) =
            (challenge["nonce"].as_str(), challenge["connection"].as_str())
        {
            let proof = acpmux::hub::person::person_proof(
                PERSON_KEY,
                acpmux::hub::person::TRANSPORT_UNIX,
                nonce,
                conn,
            )
            .unwrap();
            let _ = c.call("_acpmux/person_prove", json!({"proof": proof}), BOUND).await;
        }
        c
    }

    /// The whole response to `m`, or None after `within`.
    async fn call(&self, m: &str, p: Value, within: Duration) -> Option<Value> {
        let id = self.next.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        self.tx.send(RpcMessage::request(id, m, p).to_line()).await.ok()?;
        let got = tokio::time::timeout(within, rx).await.ok().and_then(Result::ok);
        self.pending.lock().unwrap().remove(&id);
        got
    }

    fn arm(&self, marker: &str) {
        *self.watch.lock().unwrap() = Watch { marker: Some(marker.to_owned()), ..Watch::default() };
    }

    /// When the armed marker first arrived, and whether one of its events came twice.
    async fn marker_by(&self, deadline: Instant) -> (Option<Instant>, bool) {
        loop {
            let notified = self.hit.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let w = self.watch.lock().unwrap();
                if w.first.is_some() {
                    return (w.first, w.dup);
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                let w = self.watch.lock().unwrap();
                return (w.first, w.dup);
            }
        }
    }
}

fn attach_params() -> Value {
    // The app's chat page (cmux-next-ios AcpmuxHub.swift, as mobile_link_conditions.rs sends it).
    json!({"sessionId": format!("box/{CHAT}"), "limit": 400, "maxBytes": 128 * 1024, "toolOutputMaxBytes": 64 * 1024, "eventStream": true})
}

fn rows(reply: &Value) -> usize {
    reply["result"]["events"].as_array().map(Vec::len).unwrap_or(0)
}

// ---------------------------------------------------------------------------------------------
// One load: B seeded once, then every condition x run

struct Load {
    name: &'static str,
    sessions: u64,
    turns: u64,
    /// A chat streams into the measured one while it is measured.
    streaming: bool,
}

/// Prompts ~1 KB turns into the measured chat on B until `stop`.
fn stream_into(
    b: &Arc<Hub>,
    session: String,
    stop: Arc<AtomicBool>,
    gap: Duration,
) -> tokio::task::JoinHandle<u64> {
    let mut control = Control::new(b);
    tokio::spawn(async move {
        let pad = "streamed ".repeat(110);
        let mut n = 0;
        while !stop.load(Ordering::SeqCst) {
            let _ = control.prompt(&session, &format!("stream {n}: {pad}")).await;
            n += 1;
            tokio::time::sleep(gap).await;
        }
        n
    })
}

struct Rig<'a> {
    b: Arc<Hub>,
    b_port: u16,
    peer_token: String,
    session: String,
    sshd: &'a Sshd,
    trace: Trace,
}

/// The marker: prompted on B now, waited for on A's client. Returns (arrival, dup).
async fn marker_round(rig: &Rig<'_>, client: &Client, tag: &str) -> (Option<Instant>, bool) {
    let marker = format!("pm-marker-{tag}-{}", uuid::Uuid::now_v7().simple());
    client.arm(&marker);
    let b = rig.b.clone();
    let session = rig.session.clone();
    let text = marker.clone();
    tokio::spawn(async move {
        let mut control = Control::new(&b);
        let _ = control.prompt(&session, &text).await;
    });
    client.marker_by(Instant::now() + BOUND).await
}

#[allow(clippy::too_many_arguments)]
async fn one_run(
    rig: &Rig<'_>,
    load: &Load,
    condition: &str,
    profile: &LinkProfile,
    run: u64,
    seed: u64,
    long_minutes: u64,
) {
    let label = profile.label(None);
    let cond_label = if condition == "long" && long_minutes < 60 {
        format!("long-{long_minutes}m")
    } else {
        condition.to_owned()
    };
    let k = Key { condition: &cond_label, load: load.name, run, seed, profile: &label };
    let shaper = match Shaper::start(
        ([127, 0, 0, 1], rig.sshd.port).into(),
        profile.clone(),
        seed,
        &rig.trace,
    )
    .await
    {
        Ok(s) => s,
        Err(e) => {
            emit(&k, "ttfc_ms", None, Some(&format!("shaper: {e}")));
            emit(&k, "fail", Some(1.0), None);
            return;
        }
    };
    std::fs::write(rig.sshd.dir.join("port"), shaper.addr().port().to_string()).unwrap();
    let tunnels_before = tunnels(&rig.sshd.dir);
    let stop = Arc::new(AtomicBool::new(false));
    let streamer = (load.streaming || condition == "long").then(|| {
        stream_into(
            &rig.b,
            rig.session.clone(),
            stop.clone(),
            if load.streaming { Duration::from_millis(200) } else { Duration::from_secs(2) },
        )
    });

    // Cold: A starts with no peer, then is given `box` over ssh and asked for its chat.
    let a = hub();
    let client = Client::open(a.clone()).await;
    let started = Instant::now();
    let url = format!("ssh://box.invalid:{}", rig.b_port);
    let added =
        a.add_peer("box", &url, Some("tok".into()), Some(rig.peer_token.clone()), false).await;
    let mut failed = false;
    let mut ttfc = None;
    if let Err(e) = added {
        emit(&k, "ttfc_ms", None, Some(&format!("add_peer: {e:?}")));
        failed = true;
    } else {
        let deadline = started + BOUND;
        let mut last = Value::Null;
        while Instant::now() < deadline {
            if let Some(reply) =
                client.call(method::MUX_ATTACH, attach_params(), Duration::from_secs(20)).await
            {
                if rows(&reply) > 0 {
                    ttfc = Some(started.elapsed());
                    break;
                }
                last = reply;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        match ttfc {
            Some(d) => emit(&k, "ttfc_ms", Some(ms(d)), None),
            None => {
                let why = format!(
                    "no rows within {BOUND:?}: {}",
                    last.to_string().chars().take(300).collect::<String>()
                );
                emit(&k, "ttfc_ms", None, Some(&why));
                failed = true;
            }
        }
    }

    if ttfc.is_some() {
        // The condition, then the marker after it.
        shaper.reset_counters();
        let mut per_minute = None;
        let end = match condition {
            "handoff" => {
                let now = Instant::now();
                shaper.address_change(None);
                now
            }
            "sleep" => {
                let until = shaper.blackout(Duration::from_secs(60));
                tokio::time::sleep_until(until).await;
                until
            }
            "long" => {
                let hold = Duration::from_secs(long_minutes * 60);
                tokio::time::sleep(hold).await;
                let c = shaper.counters();
                per_minute = Some((c.up_bytes + c.down_bytes) as f64 / long_minutes.max(1) as f64);
                shaper.reset_counters();
                let until = shaper.blackout(Duration::from_secs(5));
                tokio::time::sleep_until(until).await;
                until
            }
            // loss, latency: steady links; resume after a 5 s blip in them, as
            // pair_matrix_desktop.rs measures its steady rows.
            _ => {
                let until = shaper.blackout(Duration::from_secs(5));
                tokio::time::sleep_until(until).await;
                until
            }
        };
        let (arrived, dup) = marker_round(rig, &client, condition).await;
        match arrived {
            Some(at) => emit(&k, "resume_ms", Some(ms(at.saturating_duration_since(end))), None),
            None => {
                emit(
                    &k,
                    "resume_ms",
                    None,
                    Some(&format!("the marker did not arrive within {BOUND:?}")),
                );
                failed = true;
            }
        }
        if dup {
            emit(
                &k,
                "resume_ms",
                None,
                Some("a marker event arrived twice (afterSeq exactly-once)"),
            );
            failed = true;
        }
        let c = shaper.counters();
        match per_minute {
            Some(rate) => emit(&k, "delta_bytes", Some(rate), None),
            None if arrived.is_some() => {
                emit(&k, "delta_bytes", Some((c.up_bytes + c.down_bytes) as f64), None)
            }
            None => emit(&k, "delta_bytes", None, Some("never caught up")),
        }
    }
    emit(&k, "fail", Some(if failed { 1.0 } else { 0.0 }), None);
    eprintln!(
        "pairmatrix-ssh: {} {} run {run}: ssh tunnels {} connections {}",
        load.name,
        cond_label,
        tunnels(&rig.sshd.dir) - tunnels_before,
        shaper.counters().connections
    );
    stop.store(true, Ordering::SeqCst);
    if let Some(s) = streamer {
        let _ = tokio::time::timeout(Duration::from_secs(30), s).await;
    }
    let _ = a.remove_peer("box").await;
    drop(client);
    drop(a);
}

async fn bench() {
    let conditions = env_list("PAIRMATRIX_CONDITIONS", ALL_CONDITIONS);
    let loads = env_list("PAIRMATRIX_LOADS", &["idle", "duress"]);
    let paths = env_list("PAIRMATRIX_PATHS", &["direct", "relay"]);
    let n = env_u64("PAIRMATRIX_N", 5);
    let seed_base = env_u64("PAIRMATRIX_SEED_BASE", 0);
    let long_minutes = env_u64("PAIRMATRIX_LONG_MINUTES", 60);
    if !paths.iter().any(|p| p == "direct" || p == PATH_NAME) {
        eprintln!("pairmatrix-ssh: PAIRMATRIX_PATHS={paths:?} has no direct path; nothing to do");
        return;
    }
    let scratch = daemon_env::Scratch::new("pairmatrix-ssh");
    let sshd = match sshd_up(&scratch.path().join("ssh")) {
        Ok(s) => s,
        Err(why) => {
            for load in &loads {
                emit_na(
                    "*",
                    load,
                    &format!("ssh path cannot run here: {why} (pair_matrix_ssh.rs sshd_up)"),
                );
            }
            return;
        }
    };
    // A's `ssh` is the shim (the hubs run in this process and spawn `ssh` from its PATH).
    let path = std::env::var("PATH").unwrap_or_default();
    // SAFETY: set once before the runtime's work starts any agent or ssh; nothing reads PATH
    // concurrently with this write (the runtime's workers only start hubs after it).
    unsafe { std::env::set_var("PATH", format!("{}:{path}", sshd.dir.join("bin").display())) };

    let file = ProfileFile::builtin();
    let profile_for = |condition: &str| -> LinkProfile {
        let name = match condition {
            "loss" => "lossy-3",
            "handoff" => "5g-lte-handoff",
            _ => "lte",
        };
        file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone()
    };
    let trace = Trace::new();
    for load_name in &loads {
        let load = match load_name.as_str() {
            "idle" => Load { name: "idle", sessions: 5, turns: 20, streaming: false },
            "duress" => Load { name: "duress", sessions: 50, turns: 5_000, streaming: true },
            other => panic!("PAIRMATRIX_LOADS: unknown load {other}"),
        };
        let b = hub();
        let _ = b.person.install_spawn_key(PERSON_KEY);
        let (b_port, peer_token) =
            listen_with_peer_token(b.clone(), &scratch.path().join(format!("b-{}", load.name)))
                .await;
        let mut control = Control::new(&b);
        let cwd = scratch.path().join(format!("work-{}", load.name));
        std::fs::create_dir_all(&cwd).unwrap();
        let session = control.new_session(&cwd, CHAT).await;
        let seeded = Instant::now();
        control.seed(&session, load.turns).await;
        for i in 1..load.sessions {
            let other = control.new_session(&cwd, &format!("pm-other-{i}")).await;
            let _ = control.prompt(&other, "hello").await;
        }
        eprintln!(
            "pairmatrix-ssh: {} fixture ({} sessions, {} turns) seeded in {:?}",
            load.name,
            load.sessions,
            load.turns,
            seeded.elapsed()
        );
        let rig =
            Rig { b: b.clone(), b_port, peer_token, session, sshd: &sshd, trace: trace.clone() };
        for condition in &conditions {
            if condition == "failover" {
                emit_na(
                    "failover",
                    load.name,
                    "an ssh:// peer's only other path is the hub relay, which needs a hub daemonId and the hub-carrier feature (acpmux/src/peer_carriers.rs:11); ssh->relay failover is pair_matrix_desktop.rs's relay row",
                );
                continue;
            }
            if !ALL_CONDITIONS.contains(&condition.as_str()) {
                panic!("PAIRMATRIX_CONDITIONS: unknown condition {condition}");
            }
            let profile = profile_for(condition);
            for run in 0..n {
                one_run(&rig, &load, condition, &profile, run, run + seed_base, long_minutes).await;
            }
        }
        let _ = b.shutdown_all().await;
    }
}

#[test]
#[ignore = "the pair matrix bench: PAIRMATRIX_* env, run with --ignored --nocapture"]
fn pair_matrix_ssh() {
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(bench());
}
