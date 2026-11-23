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
    /// The pane new tabs go in, and the next tab's serial (`Daemon::tab`).
    pane: Value,
    serial: AtomicU64,
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
        Self { child, dir, socket, history, ticker, pane, serial: AtomicU64::new(0x800) }
    }

    /// A new tab in the bench's pane running `script`; its surface.
    fn tab(&self, script: &str) -> u64 {
        let stream = std::os::unix::net::UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        let serial = self.serial.fetch_add(1, Ordering::SeqCst);
        let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), serial);
        surface_of(&client.call(json!({"cmd": "new-tab", "pane": self.pane,
            "terminal_id": terminal_id, "cols": 120, "rows": 40, "env": {"SHELL": "/bin/sh"},
            "shell_args": ["-c", script]})))
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
    /// Every line either way by type (the bytes-per-minute bench reads it).
    tap: Arc<std::sync::Mutex<Tap>>,
}

impl Conn {
    async fn open(addr: std::net::SocketAddr) -> std::io::Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        stream.set_nodelay(true)?;
        let (read, writer) = stream.into_split();
        let (send, inbound) = mpsc::unbounded_channel();
        let down_bytes = Arc::new(AtomicU64::new(0));
        let counted = down_bytes.clone();
        let tap = Arc::new(std::sync::Mutex::new(Tap::default()));
        let tapped = tap.clone();
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
                let parsed = serde_json::from_str::<Value>(&line);
                tapped.lock().unwrap().down(parsed.as_ref().ok(), line.len());
                let Ok(value) = parsed else { continue };
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
        Ok(Self { writer, inbound, next: 0, down_bytes, up_bytes: 0, tap })
    }

    /// Writes `requests` in one write; returns their ids.
    async fn send(&mut self, requests: Vec<(&str, Value)>) -> std::io::Result<Vec<u64>> {
        let mut bytes = Vec::new();
        let mut ids = Vec::new();
        for (cmd, mut params) in requests {
            self.next += 1;
            params["id"] = json!(self.next);
            params["cmd"] = json!(cmd);
            let line = params.to_string();
            self.tap.lock().unwrap().up(self.next, cmd, line.len() + 1);
            bytes.extend_from_slice(line.as_bytes());
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

// ---------------------------------------------------------------------------------------------
// Bytes per minute, by line type

/// What one connection carried, both ways, keyed by line type: a request's `cmd` up, its reply
/// as `reply:<cmd>` down, an event as `event:<name>`. Bytes are the JSON line with its newline.
#[derive(Default, Clone)]
struct Tap {
    cmds: std::collections::HashMap<u64, String>,
    down: std::collections::BTreeMap<String, (u64, u64)>,
    up: std::collections::BTreeMap<String, (u64, u64)>,
    /// The terminal bytes `output` and `vt-state` events carried, decoded (their payload).
    terminal_bytes: u64,
    /// The last `vt-state`'s `history_rows_omitted` and `history_rows_skipped` (the scroll-step
    /// bench walks the phone's history fetches from them).
    vt_history: Option<(u64, u64)>,
    /// `output` and `vt-state` lines whose terminal bytes repaint from the top (`ESC [ H`, a
    /// full-screen program's whole-screen redraw): the redraws they carry (one per `ESC [ H`)
    /// and their line bytes; the rest of those lines' bytes are incremental output.
    full_redraws: u64,
    full_redraw_bytes: u64,
    incremental_bytes: u64,
}

impl Tap {
    fn add(map: &mut std::collections::BTreeMap<String, (u64, u64)>, key: String, bytes: u64) {
        let slot = map.entry(key).or_default();
        slot.0 += 1;
        slot.1 += bytes;
    }

    fn up(&mut self, id: u64, cmd: &str, len: usize) {
        self.cmds.insert(id, cmd.to_owned());
        Self::add(&mut self.up, cmd.to_owned(), len as u64);
    }

    fn down(&mut self, value: Option<&Value>, len: usize) {
        let key = match value {
            None => "unparsed".to_owned(),
            Some(v) => {
                match (v.get("event").and_then(Value::as_str), v.get("id").and_then(Value::as_u64))
                {
                    (Some(event), _) => {
                        if event == "vt-state" {
                            let field =
                                |name: &str| v.get(name).and_then(Value::as_u64).unwrap_or(0);
                            self.vt_history = Some((
                                field("history_rows_omitted"),
                                field("history_rows_skipped"),
                            ));
                        }
                        if matches!(event, "output" | "vt-state")
                            && let Some(data) = v.get("data").and_then(Value::as_str)
                        {
                            self.terminal_bytes += (data.len() as u64 / 4) * 3;
                            let bytes = base64::engine::general_purpose::STANDARD
                                .decode(data)
                                .unwrap_or_default();
                            let homes =
                                bytes.windows(3).filter(|window| *window == b"\x1b[H").count();
                            if homes > 0 {
                                self.full_redraws += homes as u64;
                                self.full_redraw_bytes += len as u64;
                            } else {
                                self.incremental_bytes += len as u64;
                            }
                        }
                        format!("event:{event}")
                    }
                    (None, Some(id)) => {
                        format!("reply:{}", self.cmds.get(&id).map(String::as_str).unwrap_or("?"))
                    }
                    (None, None) => "?".to_owned(),
                }
            }
        };
        Self::add(&mut self.down, key, len as u64);
    }

    /// Everything so far, and a fresh start (the request ids stay known).
    fn take(&mut self) -> Tap {
        let out = self.clone();
        self.down.clear();
        self.up.clear();
        self.terminal_bytes = 0;
        self.full_redraws = 0;
        self.full_redraw_bytes = 0;
        self.incremental_bytes = 0;
        out
    }
}

/// Which app's requests the bandwidth bench sends.
#[derive(Clone, Copy, PartialEq)]
enum App {
    /// cmux-next-ios: `WorkspaceSync.swift` on the control connection, `DaemonTerminalSession.swift`
    /// on the attach (as `client_info` and `attach_params`).
    Ios,
    /// The macOS app: `DaemonConnection.swift` (identify, set-client-info, subscribe deltas) and
    /// `AttachSurfaceRequest` (`Input.swift`: `mode: "bytes"`, the view's size).
    Macos,
    /// The phone with Settings > Transport > Agent CLI Screen Changes on, as #44619 declares it:
    /// the hybrid frames (`agent-cli-hybrid-v1`, lean `-v2`), a shell as lean lines
    /// (`terminal-shell-lines-v1`) and coalesced PTY output (`attach-output-coalesce-v1`).
    IosLean,
}

/// What the lean phone adds to `client_info`'s capabilities.
const LEAN_CAPABILITIES: &[&str] = &[
    "agent-cli-hybrid-v1",
    "agent-cli-hybrid-v2",
    "terminal-shell-lines-v1",
    "attach-output-coalesce-v1",
];

impl App {
    fn name(self) -> &'static str {
        match self {
            App::Ios => "ios",
            App::IosLean => "ios-lean",
            App::Macos => "macos",
        }
    }

    fn of(name: &str) -> Self {
        match name {
            "macos" => App::Macos,
            "ios-lean" => App::IosLean,
            _ => App::Ios,
        }
    }

    fn control(self) -> Vec<(&'static str, Value)> {
        match self {
            App::Ios | App::IosLean => vec![
                (
                    "set-client-info",
                    json!({"name": "bench", "kind": "ios", "device_kind": "iphone",
                    "device_name": "bench", "device_id": "bench",
                    "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]}),
                ),
                ("identify", json!({})),
                ("subscribe", json!({"tree_events": "deltas"})),
                ("list-agents", json!({})),
                ("list-workspaces", json!({})),
            ],
            App::Macos => vec![
                ("identify", json!({})),
                ("set-client-info", json!({"name": "cmux-next", "kind": "macos"})),
                ("subscribe", json!({"tree_events": "deltas"})),
                ("list-workspaces", json!({})),
            ],
        }
    }

    fn setup(self) -> Vec<(&'static str, Value)> {
        match self {
            App::Ios => vec![("set-client-info", client_info()), ("identify", json!({}))],
            App::IosLean => {
                let mut info = client_info();
                let caps = info["capabilities"].as_array_mut().unwrap();
                caps.extend(LEAN_CAPABILITIES.iter().map(|c| json!(c)));
                vec![("set-client-info", info), ("identify", json!({}))]
            }
            App::Macos => vec![
                ("identify", json!({})),
                ("set-client-info", json!({"name": "cmux-next", "kind": "macos"})),
            ],
        }
    }

    fn attach(self, surface: u64) -> Value {
        match self {
            App::Ios | App::IosLean => attach_params(surface),
            App::Macos => json!({"surface": surface, "mode": "bytes", "cols": 120, "rows": 40}),
        }
    }
}

fn emit_rates(
    profile: &LinkProfile,
    phase: &str,
    app: App,
    taps: &[Tap],
    wire: (u64, u64),
    secs: Option<f64>,
) {
    let scale = secs.map_or(1.0, |s| 60.0 / s);
    let unit = if secs.is_some() { "_per_min" } else { "" };
    let put = |metric: String, bytes: u64| {
        emit(profile, phase, app.name(), &metric, Some((bytes as f64 * scale).round()), 0, 0);
    };
    put(format!("bytes{unit}_down"), wire.1);
    put(format!("bytes{unit}_up"), wire.0);
    let mut all = Tap::default();
    for tap in taps {
        all.terminal_bytes += tap.terminal_bytes;
        for (key, (n, b)) in &tap.down {
            let slot = all.down.entry(key.clone()).or_default();
            slot.0 += n;
            slot.1 += b;
        }
        for (key, (n, b)) in &tap.up {
            let slot = all.up.entry(key.clone()).or_default();
            slot.0 += n;
            slot.1 += b;
        }
    }
    put(format!("terminal_bytes{unit}"), all.terminal_bytes);
    for (way, map) in [("down", &all.down), ("up", &all.up)] {
        let mut rows: Vec<_> = map.iter().collect();
        rows.sort_by(|a, b| b.1.1.cmp(&a.1.1).then(a.0.cmp(b.0)));
        for (name, (n, bytes)) in rows.into_iter().take(5) {
            put(format!("{way}:{name}"), *bytes);
            put(format!("msgs_{way}:{name}"), *n);
        }
    }
}

/// Bytes per minute of a terminal tab in each app through the shaper, the app's control
/// connection (`subscribe` deltas) open beside it: the attach, an idle terminal, then a
/// `seq 1 200000` burst and a line a second for the rest of the window. One `NETCOND` line per
/// value, `phase` `bw_attach|bw_idle|bw_burst`, `scale` the app. Env: `NETCOND_BW_PROFILE`
/// (lte), `NETCOND_BW_SECS` (60), `NETCOND_BW_APPS` (ios,macos).
#[test]
#[ignore = "the bandwidth bench: run with --ignored --nocapture"]
fn terminal_bytes_per_minute() {
    let file = ProfileFile::builtin();
    let name = std::env::var("NETCOND_BW_PROFILE").unwrap_or_else(|_| "lte".to_owned());
    let profile = file.get(&name).unwrap_or_else(|| panic!("no link profile {name}")).clone();
    let secs = env_u64("NETCOND_BW_SECS", 60);
    let daemon = Daemon::start(&[]);
    // The reconnect's ticker would make the idle tree busy: ^C ends it.
    {
        let stream = std::os::unix::net::UnixStream::connect(&daemon.socket).unwrap();
        let mut client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        let ctrl_c = base64::engine::general_purpose::STANDARD.encode([3u8]);
        client.call(json!({"cmd": "send", "surface": daemon.ticker, "bytes": ctrl_c}));
    }
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    runtime.block_on(async {
        let upstream = splice(&daemon.socket).await;
        for app_name in env_list("NETCOND_BW_APPS", "ios,ios-lean,macos") {
            let app = App::of(&app_name);
            let idle = daemon.tab("exec cat");
            let burst = daemon.tab(
                "read go; seq 1 200000; i=0; while :; do i=$((i+1)); printf 'trickle %06d\\n' $i; sleep 1; done",
            );
            tokio::time::sleep(Duration::from_secs(1)).await;
            let shaper =
                Shaper::start(upstream, profile.clone(), 0, &Trace::new()).await.unwrap();
            let (Ok(mut control), Ok(mut conn)) =
                (Conn::open(shaper.addr()).await, Conn::open(shaper.addr()).await)
            else {
                return error(&profile, "bw_attach", app.name(), 0, "connect failed");
            };
            let ids = control.send(app.control()).await.unwrap();
            control.reply(*ids.last().unwrap(), |_, _, _, _| {}).await;
            let ids = conn.send(app.setup()).await.unwrap();
            conn.reply(*ids.last().unwrap(), |_, _, _, _| {}).await;
            let ids = conn.send(vec![("attach-surface", app.attach(idle))]).await.unwrap();
            let reply = conn.reply(ids[0], |_, _, _, _| {}).await;
            if reply.as_ref().map(|r| r["ok"] != json!(true)).unwrap_or(true) {
                error(&profile, "bw_attach", app.name(), 0, &format!("attach: {reply:?}"));
                continue;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
            let take = |control: &Conn, conn: &Conn| {
                let c = shaper.counters();
                shaper.reset_counters();
                (
                    [control.tap.lock().unwrap().take(), conn.tap.lock().unwrap().take()],
                    (c.up_bytes, c.down_bytes),
                )
            };
            let (taps, wire) = take(&control, &conn);
            emit_rates(&profile, "bw_attach", app, &taps, wire, None);

            let t0 = Instant::now();
            tokio::time::sleep(Duration::from_secs(secs)).await;
            let (taps, wire) = take(&control, &conn);
            emit_rates(&profile, "bw_idle", app, &taps, wire, Some(t0.elapsed().as_secs_f64()));

            let ids = conn.send(vec![("attach-surface", app.attach(burst))]).await.unwrap();
            let _ = conn.reply(ids[0], |_, _, _, _| {}).await;
            tokio::time::sleep(Duration::from_secs(1)).await;
            let _ = take(&control, &conn);
            let go = base64::engine::general_purpose::STANDARD.encode(b"\n");
            let t0 = Instant::now();
            let _ = conn.send(vec![("send", json!({"surface": burst, "bytes": go}))]).await;
            tokio::time::sleep(Duration::from_secs(secs)).await;
            let (taps, wire) = take(&control, &conn);
            emit_rates(&profile, "bw_burst", app, &taps, wire, Some(t0.elapsed().as_secs_f64()));
            // The trickle ends, so the next app's idle terminal is idle.
            let ctrl_c = base64::engine::general_purpose::STANDARD.encode([3u8]);
            let _ = conn.send(vec![("send", json!({"surface": burst, "bytes": ctrl_c}))]).await;
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });
    drop(runtime);
    daemon.stop();
}

// ---------------------------------------------------------------------------------------------
// Bytes per scroll step: the phone's history fetches over a long, streaming terminal

/// `DaemonTerminalSession.swift`: rows each `loadOlderHistory()` adds to the tail allowance.
const HISTORY_CHUNK_ROWS: u64 = 2_000;
/// The newest rows the phone holds before it switches to a window (`maxTailHistoryRows`).
const MAX_TAIL_HISTORY_ROWS: u64 = 5 * HISTORY_CHUNK_ROWS;
/// The window far above the screen (`historyWindowRows`) and its step (`historyWindowStep`).
const HISTORY_WINDOW_ROWS: u64 = 2 * HISTORY_CHUNK_ROWS;
const HISTORY_WINDOW_STEP: u64 = 1_500;

/// One scroll step's request, as `DaemonTerminalSession.loadOlderHistory()` makes it from the
/// last `vt-state`'s `history_rows_omitted`: against a daemon with
/// `attach-replay-history-window-v1`, the tail grows to `MAX_TAIL_HISTORY_ROWS` and past it a
/// window moves up `HISTORY_WINDOW_STEP`; against one without, the tail allowance grows a chunk per
/// step (the whole history once a chunk or less is left). `None`: the phone sends nothing.
struct ScrollPolicy {
    tail: bool,
    window: bool,
    allowance: Option<u64>,
    start: Option<u64>,
}

impl ScrollPolicy {
    fn next(&mut self, surface: u64, omitted: u64) -> Option<Value> {
        if !self.tail || omitted == 0 {
            return None;
        }
        if self.window
            && (self.start.is_some()
                || self.allowance.unwrap_or(0) + HISTORY_CHUNK_ROWS > MAX_TAIL_HISTORY_ROWS)
        {
            let start = omitted.saturating_sub(HISTORY_WINDOW_STEP);
            self.start = Some(start);
            return Some(json!({"surface": surface, "cols": COLS, "rows": ROWS,
                "replay_history_rows": HISTORY_WINDOW_ROWS, "replay_history_start": start}));
        }
        let allowance = self.allowance?;
        self.allowance =
            if omitted <= HISTORY_CHUNK_ROWS { None } else { Some(allowance + HISTORY_CHUNK_ROWS) };
        let mut params = json!({"surface": surface, "cols": COLS, "rows": ROWS});
        if let Some(rows) = self.allowance {
            params["replay_history_rows"] = json!(rows);
        }
        Some(params)
    }
}

/// Bytes per scroll step: a terminal with `NETCOND_SCROLL_LINES` (20000) lines of history that
/// keeps streaming a line every 50 ms, attached the phone's way (`replay_history_rows: 0`), then
/// `NETCOND_SCROLL_STEPS` (10) history fetches up toward line 1, each the request the phone's
/// `loadOlderHistory()` sends to this daemon (`ScrollPolicy`), through the shaper. Per step
/// (`phase` `scroll_step`, `scale` `step<N>`): `bytes_down` (everything down from the request to
/// its replay: the `vt-state`, its reply and the streamed output meanwhile), `replay_bytes`
/// (the `vt-state` and the reply), `rows_asked`, `history_rows_omitted`, `step_ms`. Env:
/// `NETCOND_PROFILES` (lte,good-wifi), `NETCOND_RUNS` (1), `NETCOND_SEED_BASE` (0).
#[test]
#[ignore = "the scroll-step bench: run with --ignored --nocapture"]
fn terminal_scroll_steps() {
    let file = ProfileFile::builtin();
    let profiles = env_list("NETCOND_PROFILES", "lte,good-wifi");
    let lines = env_u64("NETCOND_SCROLL_LINES", 20_000);
    let steps = env_u64("NETCOND_SCROLL_STEPS", 10);
    let runs = env_u64("NETCOND_RUNS", 1);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let daemon = Daemon::start(&[]);
    let surface = daemon.tab(&format!(
        "awk 'BEGIN{{for(i=0;i<{lines};i++) printf \"%07d the quick brown fox jumps over the lazy dog, scrollback line for the mobile link bench\\n\", i}}'; i=0; while :; do i=$((i+1)); printf 'stream %07d an agent streaming its answer while the reader scrolls\\n' $i; sleep 0.05; done"
    ));
    {
        let stream = std::os::unix::net::UnixStream::connect(&daemon.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        while !client
            .call(json!({"cmd": "read-screen", "surface": surface}))
            .to_string()
            .contains("stream ")
        {
            assert!(std::time::Instant::now() < deadline, "history did not finish printing");
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    println!(
        "NETCOND-SCROLL lines={lines} steps={steps} streaming=20 lines/s (about 1.5 KB/s) cols={COLS} rows={ROWS}"
    );
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    let failed = runtime.block_on(async {
        let upstream = splice(&daemon.socket).await;
        let mut failed = 0;
        for name in &profiles {
            let profile =
                file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone();
            for run in 0..runs {
                let seed = seed_base + run;
                if let Err(why) = scroll_steps(upstream, &profile, surface, steps, run, seed).await
                {
                    error(&profile, "scroll_step", "all", run, &why);
                    failed += 1;
                }
            }
        }
        failed
    });
    drop(runtime);
    daemon.stop();
    assert_eq!(failed, 0, "scroll-step runs failed (NETCOND-ERROR lines above)");
}

async fn scroll_steps(
    upstream: std::net::SocketAddr,
    profile: &LinkProfile,
    surface: u64,
    steps: u64,
    run: u64,
    seed: u64,
) -> Result<(), String> {
    let shaper = Shaper::start(upstream, profile.clone(), seed, &Trace::new())
        .await
        .map_err(|e| format!("shaper: {e}"))?;
    let mut conn = Conn::open(shaper.addr()).await.map_err(|e| format!("connect: {e}"))?;
    let mut info = client_info();
    info["capabilities"].as_array_mut().unwrap().push(json!("attach-replay-history-window-v1"));
    let ids = conn
        .send(vec![("set-client-info", info), ("identify", json!({}))])
        .await
        .map_err(|e| e.to_string())?;
    let identify = conn.reply(ids[1], |_, _, _, _| {}).await.ok_or("no identify reply")?;
    let caps = identify.to_string();
    let tail = caps.contains("attach-replay-history-rows-v1");
    let window = tail && caps.contains("attach-replay-history-window-v1");
    println!(
        "NETCOND-SCROLL {}@{} run {run}: daemon tail={tail} window={window}",
        profile.name, profile.version
    );
    attach(&mut conn, surface, false).await.ok_or("no first attach")?;
    let mut policy = ScrollPolicy { tail, window, allowance: Some(0), start: None };
    for step in 1..=steps {
        let (omitted, _) = conn.tap.lock().unwrap().vt_history.unwrap_or((0, 0));
        let Some(params) = policy.next(surface, omitted) else { break };
        let rows_asked = params["replay_history_rows"].as_u64();
        conn.tap.lock().unwrap().take();
        let down_before = conn.down_bytes.load(Ordering::SeqCst);
        let started = Instant::now();
        let ids = conn.send(vec![("attach-surface", params)]).await.map_err(|e| e.to_string())?;
        let mut replayed = false;
        let reply = conn
            .reply(ids[0], |_, got, _, is_state| replayed |= got == surface && is_state)
            .await
            .ok_or(format!("step {step}: no reply"))?;
        if reply["ok"] != json!(true) {
            return Err(format!("step {step}: {reply}"));
        }
        if !replayed {
            conn.output(surface, None, true, Instant::now() + WAIT)
                .await
                .ok_or(format!("step {step}: no replay"))?;
        }
        let took = started.elapsed();
        let down = conn.down_bytes.load(Ordering::SeqCst) - down_before;
        let tap = conn.tap.lock().unwrap().take();
        let of = |key: &str| tap.down.get(key).map(|slot| slot.1).unwrap_or(0);
        let replay = of("event:vt-state") + of("reply:attach-surface");
        let scale = format!("step{step:02}");
        let put = |metric: &str, value: f64| {
            emit(profile, "scroll_step", &scale, metric, Some(value), run, seed);
        };
        put("bytes_down", down as f64);
        put("replay_bytes", replay as f64);
        put("streamed_bytes", of("event:output") as f64);
        put("rows_asked", rows_asked.map(|r| r as f64).unwrap_or(-1.0));
        put("history_rows_omitted", omitted as f64);
        put("step_ms", ms(took));
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Bytes per alt-screen pan: a one-finger drag over a full-screen app (#49954's path)

/// A pager on the alternate screen over `NETCOND_PAN_LINES` lines that asked for the mouse
/// (DECSET 1000 + 1006), appends a line every 50 ms and redraws its whole screen on each line and
/// on each input read; a wheel report (button 64 up, 65 down) moves its view a line.
const PAGER: &str = r#"
import os, re, select, sys, time, tty
n = int(sys.argv[1])
lines = ["%07d the quick brown fox jumps over the lazy dog, pager line for the mobile link bench" % i for i in range(n)]
tty.setraw(0)
out = sys.stdout.buffer
out.write(b"\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l")
off, pending, tick, due = 0, b"", 0, time.time() + 0.05
wheel = re.compile(rb"\x1b\[<(\d+);\d+;\d+[Mm]")
def draw():
    cols, rows = os.get_terminal_size(1)
    end = len(lines) - off
    view = lines[max(0, end - (rows - 1)):end]
    body = "".join(line[:cols] + "\x1b[K\r\n" for line in view)
    out.write(("\x1b[H" + body + "\x1b[7m PAGER %d/%d \x1b[0m\x1b[K" % (end, len(lines))).encode())
    out.flush()
draw()
while True:
    ready, _, _ = select.select([0], [], [], max(0.0, due - time.time()))
    dirty = False
    if ready:
        pending += os.read(0, 4096)
        last = 0
        for m in wheel.finditer(pending):
            off += {64: 1, 65: -1}.get(int(m.group(1)), 0)
            last = m.end()
        pending = pending[last:][-64:]
        off = max(0, min(off, len(lines) - 1))
        dirty = True
    if time.time() >= due:
        tick += 1
        lines.append("stream %07d an agent streaming its answer while the reader pans" % tick)
        if off:
            off += 1
        due += 0.05
        dirty = True
    if dirty:
        draw()
"#;

/// The phone's display rate, and the pan's drag: `PAN_FRAMES` frames at `PAN_SPEED` points per
/// second (a reading drag, released without a fling).
const PAN_FRAME: Duration = Duration::from_micros(16_667);
const PAN_FRAMES: u64 = 30;
const PAN_SPEED: f64 = 600.0;
/// Points of wheel per line Ghostty reports (a cell's height at the phone's default font).
const PAN_CELL_PT: f64 = 16.0;
/// After the finger lifts, the window waits this long for the app's last redraw.
const PAN_SETTLE: Duration = Duration::from_millis(500);

/// `TerminalTUIScroll.gain(speed:)`: 1:1 up to 300 pt/s, rising to 3x at 3000 pt/s.
fn pan_gain(speed: f64) -> f64 {
    if speed <= 300.0 { 1.0 } else { 1.0 + 2.0 * ((speed - 300.0) / 2700.0).min(1.0) }
}

/// Bytes per alt-screen pan: the pager above over `NETCOND_PAN_LINES` (20000) lines, streaming
/// 20 lines/s, attached the phone's way, then `NETCOND_PAN_PANS` (10) one-finger pans up, each the
/// phone's rule (`TerminalTUIScrollController` + `TerminalTUIScroll`, unchanged by #49954, and
/// `DaemonTerminalSession.scheduleInputDrain`): every display frame the finger's movement times
/// the gain becomes wheel points, each `PAN_CELL_PT` of them one SGR wheel-up report at the
/// finger, and a frame's reports go out as one `send {surface, bytes, key}` that nothing waits
/// on. Per pan (`phase` `alt_pan`, `scale` `pan<N>`): `bytes_down` (everything down from the first
/// frame to `PAN_SETTLE` after the last: the app's redraws, the send replies and the stream
/// meanwhile), `bytes_up`, `sends`, `wheel_reports`, `output_bytes`, `pan_ms`; and `scale`
/// `idle`: `bytes_down` over the same window length with no finger (the stream alone). Env:
/// `NETCOND_PROFILES` (lte,good-wifi), `NETCOND_SEED_BASE` (0).
#[test]
#[ignore = "the alt-screen pan bench: run with --ignored --nocapture"]
fn alt_screen_pan_bytes() {
    let file = ProfileFile::builtin();
    let profiles = env_list("NETCOND_PROFILES", "lte,good-wifi");
    let lines = env_u64("NETCOND_PAN_LINES", 20_000);
    let pans = env_u64("NETCOND_PAN_PANS", 10);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let daemon = Daemon::start(&[]);
    let pager = daemon.dir.join("pager.py");
    fs::write(&pager, PAGER).unwrap();
    let surface = daemon.tab(&format!("exec python3 {} {lines}", pager.display()));
    {
        let stream = std::os::unix::net::UnixStream::connect(&daemon.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        let deadline = std::time::Instant::now() + Duration::from_secs(120);
        while !client
            .call(json!({"cmd": "read-screen", "surface": surface}))
            .to_string()
            .contains("PAGER ")
        {
            assert!(std::time::Instant::now() < deadline, "the pager did not start");
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    println!(
        "NETCOND-PAN lines={lines} pans={pans} streaming=20 lines/s, a full-screen redraw each \
         frames={PAN_FRAMES} speed={PAN_SPEED}pt/s cell={PAN_CELL_PT}pt cols={COLS} rows={ROWS}"
    );
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    let failed = runtime.block_on(async {
        let upstream = splice(&daemon.socket).await;
        let mut failed = 0;
        for name in &profiles {
            let profile =
                file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone();
            let run = profiles.iter().position(|p| p == name).unwrap_or(0) as u64;
            if let Err(why) = alt_pans(upstream, &profile, surface, pans, seed_base, run).await {
                error(&profile, "alt_pan", "all", 0, &why);
                failed += 1;
            }
        }
        failed
    });
    drop(runtime);
    daemon.stop();
    assert_eq!(failed, 0, "alt-screen pan runs failed (NETCOND-ERROR lines above)");
}

/// Reads everything the connection got so far (the reader task already counted its bytes).
fn drain_inbound(conn: &mut Conn) {
    while conn.inbound.try_recv().is_ok() {}
}

async fn alt_pans(
    upstream: std::net::SocketAddr,
    profile: &LinkProfile,
    surface: u64,
    pans: u64,
    seed: u64,
    run: u64,
) -> Result<(), String> {
    let shaper = Shaper::start(upstream, profile.clone(), seed, &Trace::new())
        .await
        .map_err(|e| format!("shaper: {e}"))?;
    let mut conn = Conn::open(shaper.addr()).await.map_err(|e| format!("connect: {e}"))?;
    // `NETCOND_PAN_CAPS`: capabilities the phone declares besides `client_info`'s (a transport
    // setting under test, e.g. `terminal-full-screen-frames-v1` with the lean ones it needs).
    let mut info = client_info();
    for cap in env_list("NETCOND_PAN_CAPS", "") {
        info["capabilities"].as_array_mut().unwrap().push(json!(cap));
    }
    let ids = conn
        .send(vec![("set-client-info", info), ("identify", json!({}))])
        .await
        .map_err(|e| e.to_string())?;
    let identify = conn.reply(ids[1], |_, _, _, _| {}).await.ok_or("no identify reply")?;
    let keyed = identify.to_string().contains("send-key-v1");
    // The attach's reply; what draws the screen (a `vt-state`, or a frames viewer's keyframe)
    // lands in the second before the first window.
    let ids = conn
        .send(vec![("attach-surface", attach_params(surface))])
        .await
        .map_err(|e| e.to_string())?;
    let reply = conn.reply(ids[0], |_, _, _, _| {}).await.ok_or("no attach reply")?;
    if reply["ok"] != json!(true) {
        return Err(format!("attach: {reply}"));
    }
    let window = PAN_FRAME * PAN_FRAMES as u32 + PAN_SETTLE;
    tokio::time::sleep(Duration::from_secs(1)).await;
    drain_inbound(&mut conn);
    let put = |scale: &str, metric: &str, value: f64| {
        emit(profile, "alt_pan", scale, metric, Some(value), 0, seed);
    };
    // Per category: whole-screen redraws vs incremental output, lean frames (a frames viewer's
    // `agent-cli-lean`/`agent-cli-frame`), and the shaper's own count of what it carried down (a
    // lost segment is delayed one RTO, never sent twice: equal to `bytes_down` when no byte
    // is retransmitted).
    let categories = |scale: &str, tap: &Tap, shaper_down: u64| {
        let of = |key: &str| tap.down.get(key).copied().unwrap_or((0, 0));
        let (lean_n, lean_b) = of("event:agent-cli-lean");
        let (frame_n, frame_b) = of("event:agent-cli-frame");
        put(scale, "full_redraws", tap.full_redraws as f64);
        put(scale, "full_redraw_bytes", tap.full_redraw_bytes as f64);
        put(scale, "incremental_output_bytes", tap.incremental_bytes as f64);
        put(scale, "frame_events", (lean_n + frame_n) as f64);
        put(scale, "frame_bytes", (lean_b + frame_b) as f64);
        put(scale, "shaper_down_bytes", shaper_down as f64);
    };
    // The stream alone over one pan's window.
    let down_before = conn.down_bytes.load(Ordering::SeqCst);
    conn.tap.lock().unwrap().take();
    shaper.reset_counters();
    tokio::time::sleep(window).await;
    drain_inbound(&mut conn);
    let tap = conn.tap.lock().unwrap().take();
    put("idle", "bytes_down", (conn.down_bytes.load(Ordering::SeqCst) - down_before) as f64);
    put("idle", "output_bytes", tap.down.get("event:output").map(|s| s.1).unwrap_or(0) as f64);
    categories("idle", &tap, shaper.counters().down_bytes);
    // The finger at the screen's middle, 1-based (Ghostty reports the cell under it).
    let report = format!("\x1b[<64;{};{}M", COLS / 2 + 1, ROWS / 2 + 1);
    let per_frame = PAN_SPEED * PAN_FRAME.as_secs_f64() * pan_gain(PAN_SPEED);
    for pan in 1..=pans {
        conn.tap.lock().unwrap().take();
        shaper.reset_counters();
        let down_before = conn.down_bytes.load(Ordering::SeqCst);
        let up_before = conn.up_bytes;
        let started = Instant::now();
        let mut ticks = tokio::time::interval(PAN_FRAME);
        let (mut points, mut sends, mut reports) = (0.0_f64, 0_u64, 0_u64);
        for frame in 0..PAN_FRAMES {
            ticks.tick().await;
            points += per_frame;
            let lines = (points / PAN_CELL_PT).floor();
            points -= lines * PAN_CELL_PT;
            if lines < 1.0 {
                continue;
            }
            let bytes = report.repeat(lines as usize);
            let mut params = json!({"surface": surface,
                "bytes": base64::engine::general_purpose::STANDARD.encode(bytes.as_bytes())});
            if keyed {
                // Unique per profile run too: the daemon remembers applied keys daemon-wide
                // for 600 s (`send_once`), so a second profile reusing the first's keys had
                // every wheel send answered and dropped (good-wifi's pans never reached the
                // pager in run 45101382894).
                params["key"] = json!(format!(
                    "00000000-0000-4000-{:04x}-{:06x}{:06x}",
                    0x8000 + run,
                    pan,
                    frame
                ));
            }
            conn.send(vec![("send", params)]).await.map_err(|e| e.to_string())?;
            sends += 1;
            reports += lines as u64;
            drain_inbound(&mut conn);
        }
        tokio::time::sleep_until(started + window).await;
        drain_inbound(&mut conn);
        let took = started.elapsed();
        let down = conn.down_bytes.load(Ordering::SeqCst) - down_before;
        let tap = conn.tap.lock().unwrap().take();
        let of = |key: &str| tap.down.get(key).map(|slot| slot.1).unwrap_or(0);
        let scale = format!("pan{pan:02}");
        put(&scale, "bytes_down", down as f64);
        put(&scale, "bytes_up", (conn.up_bytes - up_before) as f64);
        put(&scale, "sends", sends as f64);
        put(&scale, "wheel_reports", reports as f64);
        put(&scale, "output_bytes", of("event:output") as f64);
        put(&scale, "send_reply_bytes", of("reply:send") as f64);
        put(&scale, "pan_ms", ms(took));
        categories(&scale, &tap, shaper.counters().down_bytes);
        // The finger lifts and comes back.
        tokio::time::sleep(Duration::from_millis(300)).await;
        drain_inbound(&mut conn);
    }
    Ok(())
}
