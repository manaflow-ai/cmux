//! The iPhone app's terminal tab under bad links, headless: a real `cmux-tui` daemon, reached the
//! way the phone's `daemon` service reaches it (a splice to the session socket,
//! cmux-next-ios/PROTOCOL.md), through `cmux_fault::shaper::Shaper` playing one named link profile
//! (`cmux-fault/link-profiles.json`). The client sends what `DaemonTerminalSession.swift` sends:
//! `set-client-info` and `identify` in one write, then `attach-surface` with the phone's size and
//! `replay_history_rows: 0`, keystrokes as `send` on a second (input lane) connection.
//!
//! Per profile, history scale and run (seed = run + `NETCOND_SEED_BASE`):
//! - cold: new connections, setup and attach; `first_content_ms` to the first `vt-state` of the
//!   surface, `interactive_ms` to a typed key's echo; `bytes_down`, `bytes_up` and `round_trips`
//!   (request turns, plus the connect) to first content;
//! - warm: the link up and set up already, a re-attach on it (a foreground return; an attach
//!   replaces the connection's last one);
//! - reconnect (profiles whose disruption drops the LAN link): attached to a surface printing every 250 ms, the
//!   profile's disruption, then the app's policy (the link gives up after 20 s with nothing in;
//!   an address change redials at once, iOS `NWPathMonitor` -> `path_changed`): a redial and
//!   re-attach. `gap_after_link_back_ms` from the link's return to the first fresh output,
//!   `gap_total_ms` from the disruption.
//!
//! One `NETCOND {json}` line per value on stdout; `scripts/measure/ios-network-conditions.sh`
//! makes the table. `#[ignore]`d: the script runs it (`--ignored`), not every test run.
//! Env: `NETCOND_PROFILES` (comma list, default every profile), `NETCOND_SCALES` (1x,10x,100x),
//! `NETCOND_RUNS` (5), `NETCOND_SEED_BASE` (0), `NETCOND_PROFILES_FILE` (the crate's file).

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use cmux_fault::Trace;
use cmux_fault::shaper::{LinkProfile, ProfileFile, Shaper};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::mpsc;
use tokio::time::{Instant, timeout};

/// Lines of shell history per scale step (1x); each about 100 bytes.
const HISTORY_LINES_1X: u64 = 1_000;
/// The phone's grid (an iPhone 15 portrait at the default font).
const COLS: u64 = 47;
const ROWS: u64 = 38;
/// The link's own give-up (cmux-mobile-link: pings every 15 s, gives up after 20 s with nothing in).
const LINK_GIVE_UP: Duration = Duration::from_secs(20);
/// Every measured wait's bound.
const WAIT: Duration = Duration::from_secs(90);

fn env_list(name: &str, default: &str) -> Vec<String> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_owned())
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_owned)
        .collect()
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.trim().parse().ok()).unwrap_or(default)
}

fn emit(
    profile: &LinkProfile,
    phase: &str,
    scale: &str,
    metric: &str,
    value: Option<f64>,
    run: u64,
    seed: u64,
) {
    let row = json!({"surface": "terminal", "profile": format!("{}@{}", profile.name, profile.version),
        "phase": phase, "scale": scale, "metric": metric,
        "value": value.map(|v| (v * 10.0).round() / 10.0), "run": run, "seed": seed});
    println!("NETCOND {row}");
}

fn error(profile: &LinkProfile, phase: &str, scale: &str, run: u64, what: &str) {
    println!(
        "NETCOND-ERROR terminal {}@{} {phase} {scale} run {run}: {what}",
        profile.name, profile.version
    );
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

/// The daemon, set up over its socket directly (unshaped): the surfaces the bench attaches.
struct Daemon {
    child: Child,
    dir: PathBuf,
    socket: PathBuf,
    /// `(scale label, surface)`: history then `cat` (echoes a typed key).
    history: Vec<(String, u64)>,
    /// Prints a tick every 250 ms (the reconnect's live output).
    ticker: u64,
}

struct SyncClient {
    reader: BufReader<std::os::unix::net::UnixStream>,
    writer: std::os::unix::net::UnixStream,
    next: u64,
}

impl SyncClient {
    fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }
}

fn surface_of(data: &Value) -> u64 {
    data["surface"].as_u64().unwrap_or_else(|| panic!("no surface in {data}"))
}

impl Daemon {
    fn start(scales: &[String]) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-netcond-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("SHELL", "/bin/sh")
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(60);
        let stream = loop {
            if let Ok(stream) = std::os::unix::net::UnixStream::connect(&socket) {
                break stream;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "daemon did not create {}",
                socket.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        };
        stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        let mut client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        let base = client
            .call(json!({"cmd": "new-workspace", "name": "netcond", "cols": 120, "rows": 40}));
        let tree = client.call(json!({"cmd": "list-workspaces"}));
        let pane = tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|ws| ws["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .find(|pane| {
                pane["tabs"].as_array().into_iter().flatten().any(|tab| {
                    tab == &base["surface"]
                        || tab["id"] == base["surface"]
                        || tab["surface"] == base["surface"]
                })
            })
            .map(|pane| pane["id"].clone())
            .unwrap_or_else(|| panic!("no pane holds the base surface: {tree}"));
        let mut serial = 0x100_u64;
        let mut tab = |client: &mut SyncClient, script: String| {
            serial += 1;
            let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), serial);
            surface_of(&client.call(json!({"cmd": "new-tab", "pane": pane, "terminal_id": terminal_id,
                "cols": 120, "rows": 40, "env": {"SHELL": "/bin/sh"}, "shell_args": ["-c", script]})))
        };
        let mut history = Vec::new();
        for scale in scales {
            let times: u64 = scale.trim_end_matches('x').parse().unwrap_or(1);
            let lines = HISTORY_LINES_1X * times;
            let script = format!(
                "awk 'BEGIN{{for(i=0;i<{lines};i++) printf \"%07d the quick brown fox jumps over the lazy dog, scrollback line for the mobile link bench\\n\", i}}'; printf 'READY-{scale}\\n'; exec cat"
            );
            history.push((scale.clone(), tab(&mut client, script)));
        }
        let ticker = tab(
            &mut client,
            "i=0; while :; do i=$((i+1)); printf 'tick %d\\n' $i; sleep 0.25; done".to_owned(),
        );
        // Every history is printed before anything is measured.
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        for (scale, surface) in &history {
            loop {
                let screen = client.call(json!({"cmd": "read-screen", "surface": surface}));
                if screen.to_string().contains(&format!("READY-{scale}")) {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "history {scale} did not finish printing"
                );
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        Self { child, dir, socket, history, ticker }
    }

    fn stop(mut self) {
        if let Ok(stream) = std::os::unix::net::UnixStream::connect(&self.socket) {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut client = SyncClient {
                writer: stream.try_clone().unwrap(),
                reader: BufReader::new(stream),
                next: 0,
            };
            let identity = client.call(json!({"cmd": "identify"}));
            let _ = writeln!(
                client.writer,
                "{}",
                json!({"id": 99, "cmd": "shutdown-daemon", "pid": identity["pid"],
                "generation": identity["generation"], "force": true, "end_terminals": true})
            );
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while std::time::Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The phone's host side: each TCP connection spliced to the daemon's session socket.
async fn splice(socket: &Path) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let socket = socket.to_owned();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = listener.accept().await {
            let socket = socket.clone();
            tokio::spawn(async move {
                let Ok(mut unix) = UnixStream::connect(&socket).await else { return };
                let _ = tokio::io::copy_bidirectional(&mut tcp, &mut unix).await;
            });
        }
    });
    addr
}

/// What arrived on a connection: replies by id, and a surface's output events.
enum Inbound {
    Reply(u64, Value),
    Output { surface: u64, data: Vec<u8>, vt_state: bool },
}

/// One phone channel to the daemon over the shaper.
struct Conn {
    writer: tokio::net::tcp::OwnedWriteHalf,
    inbound: mpsc::UnboundedReceiver<(Instant, Inbound)>,
    next: u64,
    down_bytes: Arc<AtomicU64>,
    up_bytes: u64,
}

impl Conn {
    async fn open(addr: std::net::SocketAddr) -> std::io::Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        stream.set_nodelay(true)?;
        let (read, writer) = stream.into_split();
        let (send, inbound) = mpsc::unbounded_channel();
        let down_bytes = Arc::new(AtomicU64::new(0));
        let counted = down_bytes.clone();
        tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(read);
            let mut line = String::new();
            loop {
                line.clear();
                match lines.read_line(&mut line).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        counted.fetch_add(n as u64, Ordering::SeqCst);
                    }
                }
                let at = Instant::now();
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                let item = if let Some(id) = value.get("id").and_then(Value::as_u64) {
                    Inbound::Reply(id, value)
                } else {
                    let event = value.get("event").and_then(Value::as_str).unwrap_or_default();
                    if !matches!(event, "output" | "vt-state") {
                        continue;
                    }
                    let Some(surface) = value.get("surface").and_then(Value::as_u64) else {
                        continue;
                    };
                    let data = value
                        .get("data")
                        .and_then(Value::as_str)
                        .and_then(|data| {
                            base64::engine::general_purpose::STANDARD.decode(data).ok()
                        })
                        .unwrap_or_default();
                    Inbound::Output { surface, data, vt_state: event == "vt-state" }
                };
                if send.send((at, item)).is_err() {
                    return;
                }
            }
        });
        Ok(Self { writer, inbound, next: 0, down_bytes, up_bytes: 0 })
    }

    /// Writes `requests` in one write; returns their ids.
    async fn send(&mut self, requests: Vec<(&str, Value)>) -> std::io::Result<Vec<u64>> {
        let mut bytes = Vec::new();
        let mut ids = Vec::new();
        for (cmd, mut params) in requests {
            self.next += 1;
            params["id"] = json!(self.next);
            params["cmd"] = json!(cmd);
            bytes.extend_from_slice(params.to_string().as_bytes());
            bytes.push(b'\n');
            ids.push(self.next);
        }
        self.up_bytes += bytes.len() as u64;
        self.writer.write_all(&bytes).await?;
        Ok(ids)
    }

    /// Waits for reply `id` (output events seen meanwhile go to `on_output`).
    async fn reply(
        &mut self,
        id: u64,
        mut on_output: impl FnMut(Instant, u64, &[u8], bool),
    ) -> Option<Value> {
        let deadline = Instant::now() + WAIT;
        loop {
            let (at, item) =
                tokio::time::timeout_at(deadline, self.inbound.recv()).await.ok()??;
            match item {
                Inbound::Reply(got, value) if got == id => return Some(value),
                Inbound::Reply(..) => {}
                Inbound::Output { surface, data, vt_state } => {
                    on_output(at, surface, &data, vt_state);
                }
            }
        }
    }

    /// The first output of `surface` (a `vt-state` if `vt_state`) or one holding `needle`, until `deadline`.
    async fn output(
        &mut self,
        surface: u64,
        needle: Option<&[u8]>,
        vt_state: bool,
        deadline: Instant,
    ) -> Option<Instant> {
        let mut seen = Vec::new();
        loop {
            let (at, item) =
                tokio::time::timeout_at(deadline, self.inbound.recv()).await.ok()??;
            if let Inbound::Output { surface: got, data, vt_state: is_state } = item {
                if got != surface || (vt_state && !is_state) {
                    continue;
                }
                match needle {
                    None => return Some(at),
                    Some(needle) => {
                        seen.extend_from_slice(&data);
                        if seen.windows(needle.len()).any(|window| window == needle) {
                            return Some(at);
                        }
                    }
                }
            }
        }
    }
}

fn client_info() -> Value {
    json!({"client": "cmux-ios", "device_kind": "iphone", "remote": true,
        "capabilities": ["size-lease-v2", "size-lease-v1", "shared-sizing-v1", "host-grid-view-v1"]})
}

fn attach_params(surface: u64) -> Value {
    json!({"surface": surface, "cols": COLS, "rows": ROWS, "replay_history_rows": 0})
}

/// Setup and attach on `conn`; returns when the surface's first `vt-state` (or its reply,
/// whichever is first) arrived.
async fn attach(conn: &mut Conn, surface: u64, setup: bool) -> Option<Instant> {
    if setup {
        let ids = conn
            .send(vec![("set-client-info", client_info()), ("identify", json!({}))])
            .await
            .ok()?;
        conn.reply(*ids.last()?, |_, _, _, _| {}).await?;
    }
    let ids = conn.send(vec![("attach-surface", attach_params(surface))]).await.ok()?;
    let mut first = None;
    let reply = conn
        .reply(ids[0], |at, got, _, is_state| {
            if got == surface && is_state && first.is_none() {
                first = Some(at);
            }
        })
        .await?;
    if reply["ok"] != json!(true) {
        return None;
    }
    if let Some(first) = first {
        return Some(first);
    }
    // The reply came first; the replay follows it.
    conn.output(surface, None, true, Instant::now() + WAIT).await
}

struct Bench {
    upstream: std::net::SocketAddr,
}

impl Bench {
    async fn cold_and_warm(
        &self,
        profile: &LinkProfile,
        scale: &str,
        surface: u64,
        run: u64,
        seed: u64,
    ) {
        let shaper = match Shaper::start(self.upstream, profile.clone(), seed, &Trace::new()).await
        {
            Ok(shaper) => shaper,
            Err(e) => return error(profile, "cold", scale, run, &format!("shaper: {e}")),
        };
        let started = Instant::now();
        // The attach channel and the input lane open together, as the app's do.
        let (attach_conn, input_conn) =
            tokio::join!(Conn::open(shaper.addr()), Conn::open(shaper.addr()));
        let (Ok(mut conn), Ok(mut input)) = (attach_conn, input_conn) else {
            return error(profile, "cold", scale, run, "connect failed");
        };
        let input_ready = async {
            let ids = input
                .send(vec![("set-client-info", client_info()), ("identify", json!({}))])
                .await
                .ok()?;
            input.reply(*ids.last()?, |_, _, _, _| {}).await
        };
        let (first, input_ok) = tokio::join!(attach(&mut conn, surface, true), input_ready);
        let Some(first) = first else {
            for metric in ["first_content_ms", "interactive_ms"] {
                emit(profile, "cold", scale, metric, None, run, seed);
            }
            return error(profile, "cold", scale, run, "no first content");
        };
        let counters = shaper.counters();
        emit(profile, "cold", scale, "first_content_ms", Some(ms(first - started)), run, seed);
        emit(
            profile,
            "cold",
            scale,
            "bytes_down",
            Some(conn.down_bytes.load(Ordering::SeqCst) as f64),
            run,
            seed,
        );
        emit(
            profile,
            "cold",
            scale,
            "bytes_up",
            Some((conn.up_bytes + input.up_bytes) as f64),
            run,
            seed,
        );
        emit(
            profile,
            "cold",
            scale,
            "round_trips",
            Some((counters.up_turns + 1) as f64),
            run,
            seed,
        );
        // A typed key round-trips: `send` on the input lane, its echo on the attach stream.
        let interactive = async {
            input_ok?;
            let key = format!("k{run}");
            let typed = base64::engine::general_purpose::STANDARD.encode(key.as_bytes());
            input.send(vec![("send", json!({"surface": surface, "bytes": typed}))]).await.ok()?;
            conn.output(surface, Some(key.as_bytes()), false, Instant::now() + WAIT).await
        };
        match interactive.await {
            Some(echo) => {
                emit(profile, "cold", scale, "interactive_ms", Some(ms(echo - started)), run, seed);
            }
            None => {
                emit(profile, "cold", scale, "interactive_ms", None, run, seed);
                error(profile, "cold", scale, run, "no echo of a typed key");
            }
        }
        // Warm: the link and its setup stand; the app comes back to the tab and re-attaches.
        shaper.reset_counters();
        let down_before = conn.down_bytes.load(Ordering::SeqCst);
        let up_before = conn.up_bytes;
        let started = Instant::now();
        match attach(&mut conn, surface, false).await {
            Some(first) => {
                emit(
                    profile,
                    "warm",
                    scale,
                    "first_content_ms",
                    Some(ms(first - started)),
                    run,
                    seed,
                );
                let down = conn.down_bytes.load(Ordering::SeqCst) - down_before;
                emit(profile, "warm", scale, "bytes_down", Some(down as f64), run, seed);
                emit(
                    profile,
                    "warm",
                    scale,
                    "bytes_up",
                    Some((conn.up_bytes - up_before) as f64),
                    run,
                    seed,
                );
                emit(
                    profile,
                    "warm",
                    scale,
                    "round_trips",
                    Some(shaper.counters().up_turns as f64),
                    run,
                    seed,
                );
            }
            None => {
                emit(profile, "warm", scale, "first_content_ms", None, run, seed);
                error(profile, "warm", scale, run, "no first content");
            }
        }
    }

    async fn reconnect(&self, profile: &LinkProfile, surface: u64, run: u64, seed: u64) {
        let scale = "1x";
        let shaper = match Shaper::start(self.upstream, profile.clone(), seed, &Trace::new()).await
        {
            Ok(shaper) => shaper,
            Err(e) => return error(profile, "reconnect", scale, run, &format!("shaper: {e}")),
        };
        let Ok(mut conn) = Conn::open(shaper.addr()).await else {
            return error(profile, "reconnect", scale, run, "connect failed");
        };
        if attach(&mut conn, surface, true).await.is_none() {
            return error(profile, "reconnect", scale, run, "first attach failed");
        }
        // Live: a tick has arrived since the attach.
        if conn
            .output(surface, None, false, Instant::now() + Duration::from_secs(10))
            .await
            .is_none()
        {
            return error(profile, "reconnect", scale, run, "the ticker is not live");
        }
        let address_change = matches!(
            profile.disruption,
            Some(cmux_fault::shaper::Disruption::AddressChange { .. })
        );
        let dropped = Instant::now();
        let Some(back) = shaper.disrupt() else { return };
        // The old link: anything fresh on it ends the gap; else the app gives up on it
        // (nothing in for LINK_GIVE_UP) or, on an address change, redials at once.
        let mut redial_at = None;
        let fresh = if address_change {
            redial_at = Some(Instant::now());
            None
        } else {
            let mut last_in = Instant::now();
            loop {
                let wait = (last_in + LINK_GIVE_UP).max(Instant::now());
                match timeout(wait.saturating_duration_since(Instant::now()), conn.inbound.recv())
                    .await
                {
                    Ok(Some((at, Inbound::Output { surface: got, .. }))) if got == surface => {
                        if at >= back {
                            break Some(at);
                        }
                        last_in = at;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        redial_at = Some(Instant::now());
                        break None;
                    }
                }
            }
        };
        let fresh = match fresh {
            Some(at) => Some(at),
            None => {
                drop(conn);
                match Conn::open(shaper.addr()).await {
                    Ok(mut new) => attach(&mut new, surface, true).await,
                    Err(_) => None,
                }
            }
        };
        let Some(fresh) = fresh else {
            for metric in ["gap_after_link_back_ms", "gap_total_ms"] {
                emit(profile, "reconnect", scale, metric, None, run, seed);
            }
            return error(
                profile,
                "reconnect",
                scale,
                run,
                "no fresh output after the link came back",
            );
        };
        emit(
            profile,
            "reconnect",
            scale,
            "gap_after_link_back_ms",
            Some(ms(fresh.saturating_duration_since(back))),
            run,
            seed,
        );
        emit(profile, "reconnect", scale, "gap_total_ms", Some(ms(fresh - dropped)), run, seed);
        if let Some(redial) = redial_at {
            emit(
                profile,
                "reconnect",
                scale,
                "redial_after_drop_ms",
                Some(ms(redial - dropped)),
                run,
                seed,
            );
        }
    }
}

#[test]
#[ignore = "the network-conditions bench: scripts/measure/ios-network-conditions.sh runs it"]
fn terminal_attach_under_link_profiles() {
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(path) => ProfileFile::load(Path::new(&path)).unwrap(),
        Err(_) => ProfileFile::builtin(),
    };
    let names = env_list("NETCOND_PROFILES", "");
    let profiles: Vec<LinkProfile> = if names.is_empty() {
        file.profiles
    } else {
        names
            .iter()
            .map(|name| file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone())
            .collect()
    };
    let scales = env_list("NETCOND_SCALES", "1x,10x,100x");
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let daemon = Daemon::start(&scales);
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    runtime.block_on(async {
        let bench = Bench { upstream: splice(&daemon.socket).await };
        for profile in &profiles {
            for (scale, surface) in &daemon.history {
                for run in 0..runs {
                    bench.cold_and_warm(profile, scale, *surface, run, seed_base + run).await;
                }
            }
            if profile.disrupts_lan() {
                for run in 0..runs {
                    bench.reconnect(profile, daemon.ticker, run, seed_base + run).await;
                }
            }
        }
    });
    drop(runtime);
    daemon.stop();
}
