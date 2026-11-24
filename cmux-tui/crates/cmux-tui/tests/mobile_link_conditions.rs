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
//!   an address change or the path coming back redials at once, iOS `NWPathMonitor` ->
//!   `path_changed`): a redial and
//!   re-attach. `gap_after_link_back_ms` from the link's return to the first fresh output,
//!   `gap_total_ms` from the disruption.
//!
//! One `NETCOND {json}` line per value on stdout; `scripts/measure/ios-network-conditions.sh`
//! makes the table. `#[ignore]`d: the script runs it (`--ignored`), not every test run.
//! Env: `NETCOND_PROFILES` (comma list, default every profile), `NETCOND_SCALES` (1x,10x,100x),
//! `NETCOND_RUNS` (5), `NETCOND_SEED_BASE` (0), `NETCOND_PROFILES_FILE` (the crate's file).
//!
//! The Cloud machine peer: `NETCOND_RELAY=<profile>` puts a second shaped hop between the phone's
//! link and the daemon, so the daemon stands for the one a Cloud machine runs and the hop for
//! the relay between the signed-in Mac and that machine (PROTOCOL.md `cloud-acpmux`: the phone
//! reaches a Cloud machine through the Mac's link to it). Each hop ends its own TCP connection,
//! as the Mac does. Rows then name both hops: `lte@1+relay-80@1`.

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

/// The second hop of the Cloud machine peer (`NETCOND_RELAY`), if this run has one.
static RELAY: std::sync::OnceLock<Option<LinkProfile>> = std::sync::OnceLock::new();

fn relay() -> Option<&'static LinkProfile> {
    RELAY
        .get_or_init(|| {
            let name =
                std::env::var("NETCOND_RELAY").ok().filter(|name| !name.trim().is_empty())?;
            let file = match std::env::var("NETCOND_PROFILES_FILE") {
                Ok(path) => ProfileFile::load(Path::new(&path)).unwrap(),
                Err(_) => ProfileFile::builtin(),
            };
            Some(
                file.get(name.trim())
                    .unwrap_or_else(|| panic!("no link profile {name} for NETCOND_RELAY"))
                    .clone(),
            )
        })
        .as_ref()
}

/// A row's profile: the phone's link, then the relay hop when the peer is a Cloud machine.
fn label(profile: &LinkProfile) -> String {
    profile.label(relay())
}

/// The phone's link to `upstream`, and the relay hop behind it when there is one.
async fn link(
    upstream: std::net::SocketAddr,
    profile: &LinkProfile,
    seed: u64,
) -> std::io::Result<(Shaper, Option<Shaper>)> {
    Shaper::start_through(upstream, profile.clone(), relay(), seed, &Trace::new()).await
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
    let row = json!({"surface": "terminal", "profile": label(profile),
        "phase": phase, "scale": scale, "metric": metric,
        "value": value.map(|v| (v * 10.0).round() / 10.0), "run": run, "seed": seed});
    println!("NETCOND {row}");
}

fn error(profile: &LinkProfile, phase: &str, scale: &str, run: u64, what: &str) {
    println!("NETCOND-ERROR terminal {} {phase} {scale} run {run}: {what}", label(profile));
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
    /// Streams a line every 20 ms (the streaming duress: output on the link while another
    /// surface attaches); none in the bytes-per-minute bench.
    streamer: Option<u64>,
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
    /// A fresh daemon (private socket, state and config) and a control client on it.
    fn launch() -> (Self, SyncClient) {
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
        let client = SyncClient {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        };
        (
            Self {
                child,
                dir,
                socket,
                history: Vec::new(),
                ticker: 0,
                streamer: None,
                pane: Value::Null,
                serial: AtomicU64::new(0x800),
            },
            client,
        )
    }

    /// The pane that holds `surface`.
    fn pane_of(client: &mut SyncClient, surface: &Value) -> Value {
        let tree = client.call(json!({"cmd": "list-workspaces"}));
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|ws| ws["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .find(|pane| {
                pane["tabs"].as_array().into_iter().flatten().any(|tab| {
                    tab == surface || &tab["id"] == surface || &tab["surface"] == surface
                })
            })
            .map(|pane| pane["id"].clone())
            .unwrap_or_else(|| panic!("no pane holds the base surface: {tree}"))
    }

    fn start(scales: &[String]) -> Self {
        let (mut daemon, mut client) = Self::launch();
        let base = client
            .call(json!({"cmd": "new-workspace", "name": "netcond", "cols": 120, "rows": 40}));
        let pane = Self::pane_of(&mut client, &base["surface"]);
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
        let streamer = (!scales.is_empty()).then(|| {
            tab(
                &mut client,
                "i=0; while :; do i=$((i+1)); printf 'stream %07d the quick brown fox jumps over the lazy dog\\n' $i; sleep 0.02; done".to_owned(),
            )
        });
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
        daemon.history = history;
        daemon.ticker = ticker;
        daemon.streamer = streamer;
        daemon.pane = pane;
        daemon
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

/// The app's wait after a path change before it redials (cmux-next-ios
/// LinkController.swift:180 `networkSettle`).
const NETWORK_SETTLE: Duration = Duration::from_millis(150);

/// One phone channel to the daemon over the shaper.
struct Conn {
    writer: tokio::net::tcp::OwnedWriteHalf,
    /// Each item with when it was read and the bytes read on the connection up to it.
    inbound: mpsc::UnboundedReceiver<(Instant, u64, Inbound)>,
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
                let read = match lines.read_line(&mut line).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n as u64,
                };
                let total = counted.fetch_add(read, Ordering::SeqCst) + read;
                let at = Instant::now();
                let parsed = serde_json::from_str::<Value>(&line);
                tapped.lock().unwrap().down(parsed.as_ref().ok(), line.len());
                let Ok(value) = parsed else { continue };
                // A `cmux.protocol/2` reply's id is the string `rN` (`Conn::send_resources`).
                let id = value.get("id").and_then(|id| {
                    id.as_u64().or_else(|| id.as_str()?.strip_prefix('r')?.parse().ok())
                });
                let item = if let Some(id) = id {
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
                if send.send((at, total, item)).is_err() {
                    return;
                }
            }
        });
        Ok(Self { writer, inbound, next: 0, down_bytes, up_bytes: 0, tap })
    }

    /// Writes `requests` in one write; returns their ids.
    async fn send(&mut self, requests: Vec<(&str, Value)>) -> std::io::Result<Vec<u64>> {
        self.send_with_resources(requests, Vec::new()).await
    }

    /// Writes `requests`, then `operations` as `cmux.protocol/2` requests
    /// (DaemonClient.resourceRequest's form, id `rN`), in one write; returns every id in order.
    async fn send_with_resources(
        &mut self,
        requests: Vec<(&str, Value)>,
        operations: Vec<(&str, Value)>,
    ) -> std::io::Result<Vec<u64>> {
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
        for (operation, mut params) in operations {
            self.next += 1;
            params["machine"] = json!("current");
            params["session"] = json!("current");
            let line = json!({"protocol": "cmux.protocol/2", "type": "request",
                "id": format!("r{}", self.next), "operation": operation, "params": params})
            .to_string();
            self.tap.lock().unwrap().up(self.next, operation, line.len() + 1);
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
            let (at, _, item) =
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
            let (at, _, item) =
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
        let (shaper, _relay) = match link(self.upstream, profile, seed).await {
            Ok(link) => link,
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

    /// Duress: another surface streams on the link while this one attaches.
    async fn streaming(
        &self,
        profile: &LinkProfile,
        scale: &str,
        surface: u64,
        streamer: u64,
        run: u64,
        seed: u64,
    ) {
        let phase = "streaming";
        let (shaper, _relay) = match link(self.upstream, profile, seed).await {
            Ok(link) => link,
            Err(e) => return error(profile, phase, scale, run, &format!("shaper: {e}")),
        };
        let Ok(mut conn) = Conn::open(shaper.addr()).await else {
            return error(profile, phase, scale, run, "connect failed");
        };
        if attach(&mut conn, streamer, true).await.is_none()
            || conn
                .output(streamer, None, false, Instant::now() + Duration::from_secs(10))
                .await
                .is_none()
        {
            emit(profile, phase, scale, "first_content_ms", None, run, seed);
            return error(profile, phase, scale, run, "the stream is not live");
        }
        shaper.reset_counters();
        let down_before = conn.down_bytes.load(Ordering::SeqCst);
        let started = Instant::now();
        match attach(&mut conn, surface, false).await {
            Some(first) => {
                emit(
                    profile,
                    phase,
                    scale,
                    "first_content_ms",
                    Some(ms(first - started)),
                    run,
                    seed,
                );
                let down = conn.down_bytes.load(Ordering::SeqCst) - down_before;
                emit(profile, phase, scale, "bytes_down", Some(down as f64), run, seed);
            }
            None => {
                emit(profile, phase, scale, "first_content_ms", None, run, seed);
                error(profile, phase, scale, run, "no first content");
            }
        }
    }

    /// `path_back` (the path-change row, the app's behaviour): a dial from the dark still pending
    /// when the link comes back is dropped for a new one after `NETWORK_SETTLE`, as the app does
    /// on its NWPathMonitor event (cmux-next-ios NetworkPathMonitor.swift:55, LinkController.swift
    /// :180, :193). Without it, on a blackout (the harness-dark-dial row), the harness's own dial
    /// from the dark rides the shaper's SYN backoff; the app does not do that.
    async fn reconnect(
        &self,
        profile: &LinkProfile,
        surface: u64,
        run: u64,
        seed: u64,
        path_back: bool,
    ) {
        let blackout =
            matches!(profile.disruption, Some(cmux_fault::shaper::Disruption::Blackout { .. }));
        let phase = match (path_back, blackout) {
            (true, _) => "path-change",
            (false, true) => "harness-dark-dial",
            (false, false) => "reconnect",
        };
        let scale = "1x";
        let (shaper, _relay) = match link(self.upstream, profile, seed).await {
            Ok(link) => link,
            Err(e) => return error(profile, phase, scale, run, &format!("shaper: {e}")),
        };
        let Ok(mut conn) = Conn::open(shaper.addr()).await else {
            return error(profile, phase, scale, run, "connect failed");
        };
        if attach(&mut conn, surface, true).await.is_none() {
            return error(profile, phase, scale, run, "first attach failed");
        }
        // Live: a tick has arrived since the attach.
        if conn
            .output(surface, None, false, Instant::now() + Duration::from_secs(10))
            .await
            .is_none()
        {
            return error(profile, phase, scale, run, "the ticker is not live");
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
                    Ok(Some((at, _, Inbound::Output { surface: got, .. }))) if got == surface => {
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
                let addr = shaper.addr();
                // The fresh output's time, and the dial's: when it went out, when it opened. The
                // local connect to the shaper returns at once (it holds the upstream connect, SYN
                // backoff included), so the dial is open at the first answer through it: the
                // client-info/identify reply, as chat's is at `initialize`.
                let dial = move || async move {
                    let sent = Instant::now();
                    let mut new = Conn::open(addr).await.ok()?;
                    let ids = new
                        .send(vec![("set-client-info", client_info()), ("identify", json!({}))])
                        .await
                        .ok()?;
                    new.reply(*ids.last()?, |_, _, _, _| {}).await?;
                    let open = Instant::now();
                    Some((attach(&mut new, surface, false).await?, sent, open))
                };
                let now = Instant::now();
                let got = if path_back && now < back {
                    match timeout(back - now, dial()).await.ok().flatten() {
                        Some(got) => Some(got),
                        None => {
                            tokio::time::sleep_until(back + NETWORK_SETTLE).await;
                            dial().await
                        }
                    }
                } else {
                    dial().await
                };
                if let Some((_, sent, open)) = got {
                    let from_back = if sent >= back { ms(sent - back) } else { -ms(back - sent) };
                    emit(
                        profile,
                        phase,
                        scale,
                        "dial_from_link_back_ms",
                        Some(from_back),
                        run,
                        seed,
                    );
                    emit(profile, phase, scale, "dial_open_ms", Some(ms(open - sent)), run, seed);
                }
                got.map(|(at, _, _)| at)
            }
        };
        let Some(fresh) = fresh else {
            for metric in ["gap_after_link_back_ms", "gap_total_ms"] {
                emit(profile, phase, scale, metric, None, run, seed);
            }
            return error(profile, phase, scale, run, "no fresh output after the link came back");
        };
        emit(
            profile,
            phase,
            scale,
            "gap_after_link_back_ms",
            Some(ms(fresh.saturating_duration_since(back))),
            run,
            seed,
        );
        emit(profile, phase, scale, "gap_total_ms", Some(ms(fresh - dropped)), run, seed);
        // The path-change gap split: the app's fixed settle before its redial, then the rest.
        if phase == "path-change" {
            let settle = ms(NETWORK_SETTLE);
            let after = ms(fresh.saturating_duration_since(back));
            emit(profile, phase, scale, "settle_ms", Some(settle), run, seed);
            emit(profile, phase, scale, "gap_after_settle_ms", Some(after - settle), run, seed);
        }
        if let Some(redial) = redial_at {
            emit(
                profile,
                phase,
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
                    if let Some(streamer) = daemon.streamer {
                        bench
                            .streaming(profile, scale, *surface, streamer, run, seed_base + run)
                            .await;
                    }
                }
            }
            if profile.disrupts_lan() {
                // path-change only differs on a blackout: an address change redials at once.
                let blackout = matches!(
                    profile.disruption,
                    Some(cmux_fault::shaper::Disruption::Blackout { .. })
                );
                for run in 0..runs {
                    bench.reconnect(profile, daemon.ticker, run, seed_base + run, false).await;
                    if blackout {
                        bench.reconnect(profile, daemon.ticker, run, seed_base + run, true).await;
                    }
                }
            }
        }
    });
    drop(runtime);
    daemon.stop();
}

// ---------------------------------------------------------------------------------------------
// Duress (Leo, 2026-11-22, ask-bb9c69b84e: "testing under duress"): the phone's open path, the
// Home first window and the terminal reattach, against a daemon that holds many workspaces and a
// terminal with a long scrollback and output streaming into it while the measurement runs, over
// the shaped link, next to an idle fixture (no shaper, no stream, small counts) for the 2x check.
//
// The requests are the phone's at each daemon (scripts/measure/mobile-open-path.py's forms):
// - home: WorkspaceSync.prepare's one write: set-client-info, identify, subscribe {tree_events:
//   deltas}, list-agents, list-workspaces, with {limit: 40} when the daemon's identify lists
//   `list-workspaces-page-v1` (ListFirstWindow). First content: the last of the five replies.
// - reattach: DaemonTerminalSession's reattach on a fresh connection, its input lane opening
//   beside it: resolve-terminal, then set-client-info + identify, then attach-surface (3 round
//   trips); with `attach-terminal-id-v1` listed, set-client-info, identify and attach-surface
//   {terminal_id} in one write (1 round trip). First content: the surface's first vt-state;
//   interactive: a typed key's echo on the attach stream.
// The phone remembers the capabilities from its earlier connect: a probe identify before the runs.
//
// Env: NETCOND_DURESS_PROFILES (lte,lossy-3), NETCOND_RUNS (5), NETCOND_SEED_BASE (0),
// NETCOND_IDLE_WORKSPACES (5), NETCOND_IDLE_SCROLLBACK (1000), NETCOND_DURESS_WORKSPACES (50),
// NETCOND_DURESS_SCROLLBACK (10000), NETCOND_DURESS_STREAM_LINES (50 lines of ~80 bytes per
// 20 ms tick). Rows: profile `none` (no shaper) or `NAME@VERSION`, phase `home` or `reattach`,
// scale the fixture (`idle` or `duress`), plus phase `fixture` (the daemon's capabilities and the
// stream's measured rate).

const ATTACH_TERMINAL_ID_CAPABILITY: &str = "attach-terminal-id-v1";
const FIRST_WINDOW_CAPABILITY: &str = "list-workspaces-page-v1";
/// ListFirstWindow.limit.
const FIRST_WINDOW_LIMIT: u64 = 40;
const INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";
const REPLAY_HISTORY_ROWS_CAPABILITY: &str = "attach-replay-history-rows-v1";
/// The Mac pane's grid (the phone attaches at COLS x ROWS).
const MAC_COLS: u64 = 160;
const MAC_ROWS: u64 = 50;

struct Fixture {
    name: &'static str,
    workspaces: u64,
    scrollback: u64,
    stream_lines: u64,
    /// `none` (no shaper) or a link profile.
    links: Vec<Option<LinkProfile>>,
}

/// The duress daemon: `workspaces` workspaces, one terminal (by `terminal_id`) with `scrollback`
/// lines drawn, then output streaming into it until the daemon's directory goes, and `cat`
/// echoing what is typed.
struct OpenDaemon {
    daemon: Daemon,
    surface: u64,
    terminal_id: String,
    capabilities: Vec<String>,
}

fn duress_emit(link: &str, phase: &str, fixture: &str, metric: &str, value: Option<f64>, run: u64) {
    let row = json!({"surface": "terminal", "profile": link, "phase": phase, "scale": fixture,
        "metric": metric, "value": value.map(|v| (v * 10.0).round() / 10.0), "run": run, "seed": run});
    println!("NETCOND {row}");
}

fn duress_error(link: &str, phase: &str, fixture: &str, run: u64, what: &str) {
    println!("NETCOND-ERROR terminal {link} {phase} {fixture} run {run}: {what}");
}

impl OpenDaemon {
    fn start(fixture: &Fixture) -> Self {
        let (daemon, mut client) = Daemon::launch();
        let base = client.call(json!({"cmd": "new-workspace", "name": "netcond-open",
            "cols": MAC_COLS, "rows": MAC_ROWS}));
        for index in 1..fixture.workspaces {
            client.call(json!({"cmd": "new-workspace", "name": format!("netcond-ws-{index}"),
                "cols": MAC_COLS, "rows": MAC_ROWS}));
        }
        let pane = Daemon::pane_of(&mut client, &base["surface"]);
        let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), 0x200);
        // The stream starts once the scrollback is drawn (the go file) and stops when the
        // daemon's directory is removed, so no writer outlives the bench.
        let go = daemon.dir.join("stream-go");
        let go = go.display();
        let lines = fixture.scrollback;
        let stream = if fixture.stream_lines > 0 {
            format!(
                "(while [ ! -f '{go}' ]; do sleep 0.05; done; exec awk 'BEGIN{{for(n=0;;){{for(i=0;i<{per};i++) printf \"stream %09d an agent build log line streaming into the attached terminal\\n\", n++; fflush(); if (system(\"[ -f {go} ] && sleep 0.02\") != 0) exit}}}}') & ",
                per = fixture.stream_lines
            )
        } else {
            String::new()
        };
        let script = format!(
            "awk 'BEGIN{{for(i=0;i<{lines};i++) printf \"%07d the quick brown fox jumps over the lazy dog, scrollback line for the mobile link bench\\n\", i}}'; printf 'READY-open\\n'; {stream}exec cat"
        );
        let surface = surface_of(&client.call(json!({"cmd": "new-tab", "pane": pane,
            "terminal_id": terminal_id, "cols": MAC_COLS, "rows": MAC_ROWS,
            "env": {"SHELL": "/bin/sh"}, "shell_args": ["-c", script]})));
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        loop {
            let screen = client.call(json!({"cmd": "read-screen", "surface": surface}));
            if screen.to_string().contains("READY-open") {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "the scrollback did not finish drawing");
            std::thread::sleep(Duration::from_millis(100));
        }
        if fixture.stream_lines > 0 {
            fs::write(daemon.dir.join("stream-go"), b"go").unwrap();
        }
        let capabilities = client.call(json!({"cmd": "identify"}))["capabilities"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c.as_str().map(str::to_owned))
            .collect();
        Self { daemon, surface, terminal_id, capabilities }
    }

    fn lists(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|c| c == capability)
    }
}

fn lists(capabilities: &Value, capability: &str) -> bool {
    capabilities.as_array().into_iter().flatten().any(|c| c.as_str() == Some(capability))
}

/// set-client-info of the phone's setup batch (WorkspaceSync.prepare).
fn setup_client_info() -> Value {
    json!({"name": "bench iPhone", "kind": "ios", "device_kind": "iphone",
        "device_name": "bench iPhone", "device_id": "bench-device-0001",
        "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]})
}

/// set-client-info of the phone's attach channel (DaemonTerminalSession).
fn attach_client_info() -> Value {
    json!({"name": "bench iPhone", "kind": "ios", "device_kind": "iphone",
        "device_name": "bench iPhone", "device_id": "bench-device-0001",
        "capabilities": ["size-lease-v2", "size-lease-v1", "shared-sizing-v1", "host-grid-view-v1"]})
}

/// attach-surface as the phone sends it to a daemon with `capabilities`.
fn phone_attach_params(surface: u64, capabilities: &Value) -> Value {
    let mut params = json!({"surface": surface});
    if lists(capabilities, INITIAL_SIZE_CAPABILITY) {
        params["cols"] = json!(COLS);
        params["rows"] = json!(ROWS);
    }
    if lists(capabilities, REPLAY_HISTORY_ROWS_CAPABILITY) {
        params["replay_history_rows"] = json!(0);
    }
    params
}

/// Until reply `id` is ok and `surface`'s first vt-state came (either order): when, and the
/// bytes read on the connection up to it.
async fn first_state(conn: &mut Conn, id: u64, surface: u64) -> Result<(Instant, u64), String> {
    let deadline = Instant::now() + WAIT;
    loop {
        let (at, total, item) = tokio::time::timeout_at(deadline, conn.inbound.recv())
            .await
            .map_err(|_| "no vt-state within the bound".to_owned())?
            .ok_or("the connection closed")?;
        match item {
            Inbound::Reply(got, reply) if got == id && reply["ok"] != json!(true) => {
                return Err(format!("attach-surface failed: {reply}"));
            }
            Inbound::Output { surface: got, vt_state: true, .. } if got == surface => {
                return Ok((at, total));
            }
            _ => {}
        }
    }
}

/// Until every reply of `ids` came, each ok: when the last did, the bytes up to it, the replies.
async fn all_replies(conn: &mut Conn, ids: &[u64]) -> Result<(Instant, u64, Vec<Value>), String> {
    let deadline = Instant::now() + WAIT;
    let mut pending: Vec<u64> = ids.to_vec();
    let mut replies = Vec::new();
    loop {
        let (at, total, item) = tokio::time::timeout_at(deadline, conn.inbound.recv())
            .await
            .map_err(|_| format!("replies {pending:?} missing at the bound"))?
            .ok_or("the connection closed")?;
        if let Inbound::Reply(got, reply) = item
            && let Some(index) = pending.iter().position(|id| *id == got)
        {
            if reply["ok"] != json!(true) {
                return Err(format!("request {got} failed: {reply}"));
            }
            pending.remove(index);
            replies.push(reply);
            if pending.is_empty() {
                return Ok((at, total, replies));
            }
        }
    }
}

struct OpenSample {
    first_content_ms: f64,
    interactive_ms: Option<f64>,
    bytes_down: u64,
    bytes_up: u64,
    round_trips: u64,
    /// home: the workspaces the first window holds.
    shown: Option<u64>,
}

/// `list-workspaces-known-v1` (WorkspaceSync.knownCapability): the refresh sends `known`.
const KNOWN_CAPABILITY: &str = "list-workspaces-known-v1";

/// Until every reply of `ids` came, the first `must_ok` of them ok (the arrangement reads after
/// them are best effort, as on the phone): when the last came and the bytes read up to it.
async fn answered(conn: &mut Conn, ids: &[u64], must_ok: usize) -> Result<(Instant, u64), String> {
    answered_keeping(conn, ids, must_ok, None).await.map(|(at, total, _)| (at, total))
}

/// `answered`, also returning the reply to `keep` (Null when not asked).
async fn answered_keeping(
    conn: &mut Conn,
    ids: &[u64],
    must_ok: usize,
    keep: Option<u64>,
) -> Result<(Instant, u64, Value), String> {
    let deadline = Instant::now() + WAIT;
    let mut pending: Vec<u64> = ids.to_vec();
    let mut kept = Value::Null;
    loop {
        let (at, total, item) = tokio::time::timeout_at(deadline, conn.inbound.recv())
            .await
            .map_err(|_| format!("replies {pending:?} missing at the bound"))?
            .ok_or("the connection closed")?;
        if let Inbound::Reply(got, reply) = item
            && let Some(index) = pending.iter().position(|id| *id == got)
        {
            if ids[..must_ok].contains(&got) && reply["ok"] != json!(true) {
                return Err(format!("request {got} failed: {reply}"));
            }
            if keep == Some(got) {
                kept = reply;
            }
            pending.remove(index);
            if pending.is_empty() {
                return Ok((at, total, kept));
            }
        }
    }
}

/// The Workspaces list settled (the Mac's order and pins applied) on a fresh connection.
/// `batched` false is the phone before this change: the five-request setup, then `refresh()`'s
/// `list-personal`, `sidebar_layout.get` and `list-workspaces` one after another (4 round
/// trips). `batched` true is WorkspaceSync.prepare now: all seven in one write (1), its list
/// with `known` `{}` so the reply carries the tree's revision, and the check `refresh()` makes
/// after the list is drawn sends it back and gets `unchanged` (off the critical path: in
/// `bytes_down`, not in `setup_ms` or `round_trips`). Both lists are the phone's: no `limit`.
async fn settled_once(
    addr: std::net::SocketAddr,
    daemon: &OpenDaemon,
    batched: bool,
) -> Result<OpenSample, String> {
    let started = Instant::now();
    let mut conn = Conn::open(addr).await.map_err(|e| format!("connect: {e}"))?;
    let knows = daemon.lists(KNOWN_CAPABILITY);
    let list = if batched && knows { json!({"known": {}}) } else { json!({}) };
    let setup = vec![
        ("set-client-info", setup_client_info()),
        ("identify", json!({})),
        ("subscribe", json!({"tree_events": "deltas"})),
        ("list-agents", json!({})),
        ("list-workspaces", list),
    ];
    let write = |e: std::io::Error| format!("write: {e}");
    let (at, bytes_down, round_trips) = if batched {
        let mut setup = setup;
        setup.push(("list-personal", json!({})));
        let ids = conn
            .send_with_resources(setup, vec![("sidebar_layout.get", json!({}))])
            .await
            .map_err(write)?;
        let (at, mut bytes, reply) = answered_keeping(&mut conn, &ids, 5, Some(ids[4])).await?;
        let revision = &reply["data"]["tree_revision"];
        if knows && revision.is_string() {
            let mut known = json!({"tree_revision": revision});
            for field in [
                "registry_id",
                "generation",
                "workspace_revision",
                "pane_revision",
                "terminal_revision",
            ] {
                if !reply["data"][field].is_null() {
                    known[field] = reply["data"][field].clone();
                }
            }
            let ids = conn
                .send(vec![("list-workspaces", json!({"known": known}))])
                .await
                .map_err(write)?;
            (_, bytes) = answered(&mut conn, &ids, 1).await?;
        }
        (at, bytes, 1)
    } else {
        let ids = conn.send(setup).await.map_err(write)?;
        answered(&mut conn, &ids, 5).await?;
        let ids = conn.send(vec![("list-personal", json!({}))]).await.map_err(write)?;
        answered(&mut conn, &ids, 0).await?;
        let ids = conn
            .send_with_resources(Vec::new(), vec![("sidebar_layout.get", json!({}))])
            .await
            .map_err(write)?;
        answered(&mut conn, &ids, 0).await?;
        // The setup's list carried no `known` (no tree_revision held): the refresh sends `{}`.
        let params = if knows { json!({"known": {}}) } else { json!({}) };
        let ids = conn.send(vec![("list-workspaces", params)]).await.map_err(write)?;
        let (at, bytes) = answered(&mut conn, &ids, 1).await?;
        (at, bytes, 4)
    };
    Ok(OpenSample {
        first_content_ms: ms(at - started),
        interactive_ms: None,
        bytes_down,
        bytes_up: conn.up_bytes,
        round_trips,
        shown: None,
    })
}

/// The Home tab's first window on a fresh connection.
async fn home_once(addr: std::net::SocketAddr, daemon: &OpenDaemon) -> Result<OpenSample, String> {
    let started = Instant::now();
    let mut conn = Conn::open(addr).await.map_err(|e| format!("connect: {e}"))?;
    let mut list = json!({});
    if daemon.lists(FIRST_WINDOW_CAPABILITY) {
        list["limit"] = json!(FIRST_WINDOW_LIMIT);
    }
    let ids = conn
        .send(vec![
            ("set-client-info", setup_client_info()),
            ("identify", json!({})),
            ("subscribe", json!({"tree_events": "deltas"})),
            ("list-agents", json!({})),
            ("list-workspaces", list),
        ])
        .await
        .map_err(|e| format!("write: {e}"))?;
    let (at, bytes_down, replies) = all_replies(&mut conn, &ids).await?;
    let list_id = ids.last().copied();
    let shown = replies
        .iter()
        .find(|reply| reply["id"].as_u64() == list_id)
        .and_then(|reply| reply["data"]["workspaces"].as_array())
        .map(|rows| rows.len() as u64);
    Ok(OpenSample {
        first_content_ms: ms(at - started),
        interactive_ms: None,
        bytes_down,
        bytes_up: conn.up_bytes,
        round_trips: 1,
        shown,
    })
}

/// The reattach on the attach channel: the first vt-state, the bytes read to it, round trips.
async fn attach_path(conn: &mut Conn, daemon: &OpenDaemon) -> Result<(Instant, u64, u64), String> {
    let surface = daemon.surface;
    if daemon.lists(ATTACH_TERMINAL_ID_CAPABILITY) {
        let mut params = phone_attach_params(surface, &json!(daemon.capabilities));
        params["terminal_id"] = json!(daemon.terminal_id);
        let ids = conn
            .send(vec![
                ("set-client-info", attach_client_info()),
                ("identify", json!({})),
                ("attach-surface", params),
            ])
            .await
            .map_err(|e| format!("write: {e}"))?;
        let (at, bytes) = first_state(conn, ids[2], surface).await?;
        return Ok((at, bytes, 1));
    }
    let ids = conn
        .send(vec![("resolve-terminal", json!({"terminal_id": daemon.terminal_id}))])
        .await
        .map_err(|e| format!("write: {e}"))?;
    let (_, _, resolved) = all_replies(conn, &ids).await?;
    if resolved.first().map(|r| r["data"]["surface"].clone()) != Some(json!(surface)) {
        return Err(format!("resolve-terminal named another surface: {resolved:?}"));
    }
    let ids = conn
        .send(vec![("set-client-info", attach_client_info()), ("identify", json!({}))])
        .await
        .map_err(|e| format!("write: {e}"))?;
    let (_, _, setup) = all_replies(conn, &ids).await?;
    let capabilities = setup
        .iter()
        .find(|reply| reply["id"].as_u64() == ids.last().copied())
        .map(|reply| reply["data"]["capabilities"].clone())
        .unwrap_or(Value::Null);
    let ids = conn
        .send(vec![("attach-surface", phone_attach_params(surface, &capabilities))])
        .await
        .map_err(|e| format!("write: {e}"))?;
    let (at, bytes) = first_state(conn, ids[0], surface).await?;
    Ok((at, bytes, 3))
}

/// The input lane's own set-client-info and identify.
async fn input_ready(input: &mut Conn) -> Result<(), String> {
    let ids = input
        .send(vec![("set-client-info", attach_client_info()), ("identify", json!({}))])
        .await
        .map_err(|e| format!("input write: {e}"))?;
    all_replies(input, &ids).await.map(|_| ())
}

/// The terminal reattach on fresh connections (attach channel and input lane), then a typed key.
async fn reattach_once(
    addr: std::net::SocketAddr,
    daemon: &OpenDaemon,
    run: u64,
) -> Result<OpenSample, String> {
    let surface = daemon.surface;
    let started = Instant::now();
    let (attach_conn, input_conn) = tokio::join!(Conn::open(addr), Conn::open(addr));
    let mut conn = attach_conn.map_err(|e| format!("connect: {e}"))?;
    let mut input = input_conn.map_err(|e| format!("connect: {e}"))?;
    let (attached, input_ok) =
        tokio::join!(attach_path(&mut conn, daemon), input_ready(&mut input));
    let (first, bytes_down, round_trips) = attached?;
    let bytes_up = conn.up_bytes + input.up_bytes;
    let interactive = async {
        input_ok.ok()?;
        let key = format!("KQ{run}Z");
        let typed = base64::engine::general_purpose::STANDARD.encode(key.as_bytes());
        input.send(vec![("send", json!({"surface": surface, "bytes": typed}))]).await.ok()?;
        conn.output(surface, Some(key.as_bytes()), false, Instant::now() + WAIT).await
    };
    let interactive_ms = interactive.await.map(|echo| ms(echo - started));
    Ok(OpenSample {
        first_content_ms: ms(first - started),
        interactive_ms,
        bytes_down,
        bytes_up,
        round_trips,
        shown: None,
    })
}

/// The stream's rate at the daemon, as a viewer on the unshaped socket sees it over 2 s.
async fn stream_rate(addr: std::net::SocketAddr, surface: u64) -> Option<f64> {
    let mut conn = Conn::open(addr).await.ok()?;
    let ids = conn
        .send(vec![("identify", json!({})), ("attach-surface", json!({"surface": surface}))])
        .await
        .ok()?;
    first_state(&mut conn, ids[1], surface).await.ok()?;
    let start = Instant::now();
    let end = start + Duration::from_secs(2);
    let mut bytes = 0_u64;
    while let Ok(Some((_, _, item))) = tokio::time::timeout_at(end, conn.inbound.recv()).await {
        if let Inbound::Output { surface: got, data, vt_state: false } = item
            && got == surface
        {
            bytes += data.len() as u64;
        }
    }
    Some(bytes as f64 / ms(start.elapsed()) * 1000.0)
}

fn emit_sample(link: &str, phase: &str, fixture: &str, run: u64, sample: &OpenSample) {
    duress_emit(link, phase, fixture, "first_content_ms", Some(sample.first_content_ms), run);
    if phase.starts_with("settled") {
        // Link up to the settled list: the setup's round trips and the daemon's handler time.
        duress_emit(link, phase, fixture, "setup_ms", Some(sample.first_content_ms), run);
    }
    if phase == "reattach" {
        duress_emit(link, phase, fixture, "interactive_ms", sample.interactive_ms, run);
        if sample.interactive_ms.is_none() {
            duress_error(link, phase, fixture, run, "no echo of a typed key");
        }
    }
    duress_emit(link, phase, fixture, "bytes_down", Some(sample.bytes_down as f64), run);
    duress_emit(link, phase, fixture, "bytes_up", Some(sample.bytes_up as f64), run);
    duress_emit(link, phase, fixture, "round_trips", Some(sample.round_trips as f64), run);
    if let Some(shown) = sample.shown {
        duress_emit(link, phase, fixture, "workspaces_shown", Some(shown as f64), run);
    }
}

#[test]
#[ignore = "the duress bench: scripts/measure/ios-network-conditions.sh mode=duress runs it"]
fn open_path_under_duress() {
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(path) => ProfileFile::load(Path::new(&path)).unwrap(),
        Err(_) => ProfileFile::builtin(),
    };
    let mut duress_links = vec![None];
    for name in env_list("NETCOND_DURESS_PROFILES", "lte,lossy-3") {
        let profile = file.get(&name).unwrap_or_else(|| panic!("no link profile {name}"));
        duress_links.push(Some(profile.clone()));
    }
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let fixtures = [
        Fixture {
            name: "idle",
            workspaces: env_u64("NETCOND_IDLE_WORKSPACES", 5),
            scrollback: env_u64("NETCOND_IDLE_SCROLLBACK", 1_000),
            stream_lines: 0,
            // The same links as duress, so a duress number is judged against the idle
            // fixture on its own link, not against loopback.
            links: duress_links.clone(),
        },
        Fixture {
            name: "duress",
            workspaces: env_u64("NETCOND_DURESS_WORKSPACES", 50),
            scrollback: env_u64("NETCOND_DURESS_SCROLLBACK", 10_000),
            stream_lines: env_u64("NETCOND_DURESS_STREAM_LINES", 50),
            links: duress_links,
        },
    ];
    for fixture in &fixtures {
        let daemon = OpenDaemon::start(fixture);
        println!(
            "NETCOND-FIXTURE {} workspaces={} scrollback={} stream_lines_per_20ms={} attach-terminal-id-v1={} list-workspaces-page-v1={}",
            fixture.name,
            fixture.workspaces,
            fixture.scrollback,
            fixture.stream_lines,
            daemon.lists(ATTACH_TERMINAL_ID_CAPABILITY),
            daemon.lists(FIRST_WINDOW_CAPABILITY)
        );
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let upstream = splice(&daemon.daemon.socket).await;
            if fixture.stream_lines > 0 {
                let rate = stream_rate(upstream, daemon.surface).await;
                duress_emit("none", "fixture", fixture.name, "stream_bytes_per_s", rate, 0);
            }
            for link in &fixture.links {
                let label = link
                    .as_ref()
                    .map_or_else(|| "none".to_owned(), |p| format!("{}@{}", p.name, p.version));
                for run in 0..runs {
                    let seed = seed_base + run;
                    // One shaper per run: home, then the reattach, each on fresh connections.
                    let shaper = match link {
                        Some(profile) => {
                            match Shaper::start(upstream, profile.clone(), seed, &Trace::new())
                                .await
                            {
                                Ok(shaper) => Some(shaper),
                                Err(e) => {
                                    duress_error(
                                        &label,
                                        "home",
                                        fixture.name,
                                        run,
                                        &format!("shaper: {e}"),
                                    );
                                    continue;
                                }
                            }
                        }
                        None => None,
                    };
                    let addr = shaper.as_ref().map_or(upstream, |s| s.addr());
                    // settled_serial / settled_batched: link up to the settled Workspaces list,
                    // the phone's setup before and after the arrangement joined its one write.
                    for phase in ["home", "settled_serial", "settled_batched", "reattach"] {
                        let sample = match phase {
                            "home" => home_once(addr, &daemon).await,
                            "settled_serial" => settled_once(addr, &daemon, false).await,
                            "settled_batched" => settled_once(addr, &daemon, true).await,
                            _ => reattach_once(addr, &daemon, run).await,
                        };
                        match sample {
                            Ok(sample) => emit_sample(&label, phase, fixture.name, run, &sample),
                            Err(why) => {
                                duress_emit(
                                    &label,
                                    phase,
                                    fixture.name,
                                    "first_content_ms",
                                    None,
                                    run,
                                );
                                duress_error(&label, phase, fixture.name, run, &why);
                            }
                        }
                    }
                }
            }
        });
        drop(runtime);
        daemon.daemon.stop();
    }
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
                        if matches!(event, "output" | "vt-state")
                            && let Some(data) = v.get("data").and_then(Value::as_str)
                        {
                            self.terminal_bytes += (data.len() as u64 / 4) * 3;
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
            let (shaper, _relay) = link(upstream, &profile, 0).await.unwrap();
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
// Background: the time-away table (Leo, 2026-11-24: "the syncing can arguably happen in the
// background too, so deltas can be sipped and maintained"; cmux-next-ios/design/
// background-delta-sync.md). The phone's link is closed while the Mac produces what a span of
// time away produces (simulated: the events are made at once, no real time is slept), then the
// link reopens through the shaper and each surface catches up.
//
// Loads (per span of time away):
// - idle: a Mac with nothing running. The terminal is quiet; the workspace list changes once
//   per BG_IDLE_LIST_EVERY_S (a clock-like status).
// - busy: one agent streaming. The terminal gets build-log text at BG_BUSY_TERMINAL_BYTES_PER_S
//   (lines of ~85 bytes); the list changes once per BG_BUSY_LIST_EVERY_S (the agent's status and
//   title). A span past the host's terminal resume ring (4 MiB, cmux-tui-core resume_ring.rs)
//   produces the ring plus BG_PAST_RING_BYTES: the host holds no more, so what it can answer is
//   the same past it (`events_behind` says the span's full count, `held_behind` what was made).
//
// Phone forms, phase:
// - before (the phone today): the terminal re-attaches with no resume_offset (a full screen
//   replay, `replay_history_rows: 0`, DaemonTerminalSession.historyAttachParams); the list after
//   a cold relaunch has no `known` (`known: {}`, WorkspaceSync.swift).
// - after (the cursor form): the terminal re-attaches with resume_offset + resume_generation of
//   the stream it held; the list sends the persisted `known`.
// - after_bounded (only when the daemon lists `terminal-resume-bounded-v1`): the after form plus
//   `resume_max_bytes` = the byte size of the phone's previous full replay.
// Each surface's catch-up runs on its own fresh connection through the shaper: setup and the
// request in one write. `catch_up_ms` from the connect to the surface current (terminal: the
// first vt-state or the exact resume's output; list: every reply of the setup write), bytes and
// round trips (request turns + the connect) from the shaper's counters.
//
// Env: NETCOND_PROFILES (good-wifi,lte,lossy-3), NETCOND_AWAY (1m,10m,1h,8h), NETCOND_LOADS
// (idle,busy), NETCOND_RUNS, NETCOND_SEED_BASE. Rows: surface `terminal` or `workspaces`,
// scale `<away>-<load>` (`1h-busy`).

const BG_BUSY_TERMINAL_BYTES_PER_S: u64 = 2_048;
const BG_IDLE_LIST_EVERY_S: u64 = 600;
const BG_BUSY_LIST_EVERY_S: u64 = 60;
/// cmux-tui-core surface/resume_ring.rs RESUME_RING_BYTES.
const BG_RESUME_RING_BYTES: u64 = 4 * 1024 * 1024;
const BG_PAST_RING_BYTES: u64 = 512 * 1024;
const BG_WORKSPACES: u64 = 10;
const BG_SCROLLBACK: u64 = 2_000;
const TERMINAL_RESUME_CAPABILITY: &str = "terminal-resume-v1";
const TERMINAL_RESUME_BOUNDED_CAPABILITY: &str = "terminal-resume-bounded-v1";

/// `30s`, `10m`, `8h`: seconds.
fn away_secs(label: &str) -> u64 {
    let (number, unit) = label.split_at(label.len() - 1);
    let n: u64 = number.parse().unwrap_or_else(|_| panic!("time away {label}: 30s, 10m or 8h"));
    match unit {
        "s" => n,
        "m" => n * 60,
        "h" => n * 3600,
        _ => panic!("time away {label}: 30s, 10m or 8h"),
    }
}

#[allow(clippy::too_many_arguments)]
fn bg_emit(
    surface: &str,
    link: &str,
    phase: &str,
    scale: &str,
    metric: &str,
    value: Option<f64>,
    run: u64,
    seed: u64,
) {
    let row = json!({"surface": surface, "profile": link, "phase": phase, "scale": scale,
        "metric": metric, "value": value.map(|v| (v * 10.0).round() / 10.0), "run": run,
        "seed": seed});
    println!("NETCOND {row}");
}

/// A raw line connection: every line in, parsed, with when it came.
struct BgConn {
    writer: tokio::net::tcp::OwnedWriteHalf,
    rx: mpsc::UnboundedReceiver<(Instant, Value)>,
    next: u64,
}

impl BgConn {
    async fn open(addr: std::net::SocketAddr) -> Result<Self, String> {
        let stream = TcpStream::connect(addr).await.map_err(|e| format!("connect: {e}"))?;
        stream.set_nodelay(true).map_err(|e| e.to_string())?;
        let (read, writer) = stream.into_split();
        let (send, rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(read);
            let mut line = String::new();
            loop {
                line.clear();
                match lines.read_line(&mut line).await {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {}
                }
                let at = Instant::now();
                if let Ok(value) = serde_json::from_str::<Value>(&line)
                    && send.send((at, value)).is_err()
                {
                    return;
                }
            }
        });
        Ok(Self { writer, rx, next: 0 })
    }

    async fn send(&mut self, requests: Vec<(&str, Value)>) -> Result<Vec<u64>, String> {
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
        self.writer.write_all(&bytes).await.map_err(|e| format!("write: {e}"))?;
        Ok(ids)
    }

    async fn recv(&mut self, deadline: Instant) -> Result<(Instant, Value), String> {
        tokio::time::timeout_at(deadline, self.rx.recv())
            .await
            .map_err(|_| "nothing within the bound".to_owned())?
            .ok_or_else(|| "the connection closed".to_owned())
    }
}

/// What the phone held when it left: the terminal stream's cursor and the list's revision.
struct BgCursor {
    offset: u64,
    generation: String,
    /// The byte size of the full replay it last got (resume_max_bytes).
    replay_bytes: u64,
    cols: u64,
    rows: u64,
    known: Value,
}

struct BgFixture {
    daemon: Daemon,
    upstream: std::net::SocketAddr,
    surface: u64,
    workspaces: Vec<Value>,
    capabilities: Vec<String>,
    renames: AtomicU64,
    produced: AtomicU64,
}

fn bg_client_info(resume: bool) -> Value {
    let mut info = attach_client_info();
    if resume {
        info["capabilities"].as_array_mut().unwrap().push(json!(TERMINAL_RESUME_CAPABILITY));
    }
    info
}

impl BgFixture {
    fn start() -> Self {
        let (daemon, mut client) = Daemon::launch();
        let base = client.call(json!({"cmd": "new-workspace", "name": "netcond-bg-0",
            "cols": COLS, "rows": ROWS}));
        for index in 1..BG_WORKSPACES {
            client.call(json!({"cmd": "new-workspace", "name": format!("netcond-bg-{index}"),
                "cols": COLS, "rows": ROWS}));
        }
        let pane = Daemon::pane_of(&mut client, &base["surface"]);
        let dir = daemon.dir.display().to_string();
        // Scrollback, then a producer: `req` names a byte count and a tag; it prints that many
        // bytes of build-log lines and `EMITTED-<tag>`.
        let script = format!(
            "awk 'BEGIN{{for(i=0;i<{BG_SCROLLBACK};i++) printf \"%07d the quick brown fox jumps over the lazy dog, scrollback line for the mobile link bench\\n\", i}}'; printf 'READY-bg\\n'; \
             while :; do if [ -f '{dir}/req' ]; then set -- $(cat '{dir}/req'); rm -f '{dir}/req'; \
             awk -v n=\"$1\" 'BEGIN{{for(b=0;b<n;){{k++; s=sprintf(\"[%7d] Compiling netcond-crate-%04d v0.1.%d (/build/src/netcond/crate_%04d) in 0.%02ds\", k, k%9973, k%97, k%9973, k%100); print s; b+=length(s)+2}}}}'; \
             printf 'EMITTED-%s\\n' \"$2\"; fi; sleep 0.05; done"
        );
        let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), 0x300);
        let surface = surface_of(&client.call(json!({"cmd": "new-tab", "pane": pane,
            "terminal_id": terminal_id, "cols": COLS, "rows": ROWS,
            "env": {"SHELL": "/bin/sh"}, "shell_args": ["-c", script]})));
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        loop {
            let screen = client.call(json!({"cmd": "read-screen", "surface": surface}));
            if screen.to_string().contains("READY-bg") {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "the scrollback did not finish drawing");
            std::thread::sleep(Duration::from_millis(100));
        }
        let tree = client.call(json!({"cmd": "list-workspaces"}));
        let workspaces: Vec<Value> =
            tree["workspaces"].as_array().unwrap().iter().map(|ws| ws["id"].clone()).collect();
        let capabilities = client.call(json!({"cmd": "identify"}))["capabilities"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c.as_str().map(str::to_owned))
            .collect();
        Self {
            daemon,
            upstream: "127.0.0.1:0".parse().unwrap(),
            surface,
            workspaces,
            capabilities,
            renames: AtomicU64::new(0),
            produced: AtomicU64::new(0),
        }
    }

    fn lists(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|c| c == capability)
    }

    fn client(&self) -> SyncClient {
        let stream = std::os::unix::net::UnixStream::connect(&self.daemon.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        SyncClient { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 }
    }

    /// What the phone held when it left: an attach as the after form's phone makes it (unshaped),
    /// its vt-state's stamp and size, and the list's revision.
    async fn cursor(&self) -> Result<BgCursor, String> {
        let mut conn = BgConn::open(self.upstream).await?;
        let ids = conn
            .send(vec![
                ("set-client-info", bg_client_info(true)),
                ("identify", json!({})),
                (
                    "attach-surface",
                    json!({"surface": self.surface, "cols": COLS, "rows": ROWS,
                    "replay_history_rows": 0}),
                ),
                ("list-workspaces", json!({"known": {}})),
            ])
            .await?;
        let deadline = Instant::now() + WAIT;
        let (mut state, mut list) = (None, None);
        while state.is_none() || list.is_none() {
            let (_, value) = conn.recv(deadline).await?;
            if value["event"] == "vt-state" && value["surface"] == json!(self.surface) {
                state = Some(value);
            } else if value["id"] == json!(ids[3]) {
                list = Some(value);
            } else if value["id"] == json!(ids[2]) && value["ok"] != json!(true) {
                return Err(format!("attach-surface: {value}"));
            }
        }
        let (state, list) = (state.unwrap(), list.unwrap());
        let data = &list["data"];
        let mut known = json!({"tree_revision": data["tree_revision"]});
        for field in [
            "registry_id",
            "generation",
            "workspace_revision",
            "pane_revision",
            "terminal_revision",
        ] {
            if !data[field].is_null() {
                known[field] = data[field].clone();
            }
        }
        let replay_bytes = state["data"].as_str().map_or(0, |data| {
            base64::engine::general_purpose::STANDARD.decode(data).map_or(0, |b| b.len() as u64)
        });
        Ok(BgCursor {
            offset: state["offset"].as_u64().ok_or(format!("vt-state has no offset: {state}"))?,
            generation: state["generation"]
                .as_str()
                .ok_or("vt-state has no generation")?
                .to_owned(),
            replay_bytes,
            cols: state["cols"].as_u64().unwrap_or(COLS),
            rows: state["rows"].as_u64().unwrap_or(ROWS),
            known,
        })
    }

    /// The Mac while the phone is away: `bytes` of build log into the terminal and `changes`
    /// list changes (a workspace renamed, as a status or title change).
    fn produce(&self, bytes: u64, changes: u64) {
        let mut client = self.client();
        for _ in 0..changes {
            let n = self.renames.fetch_add(1, Ordering::SeqCst);
            let workspace = &self.workspaces[(n as usize) % self.workspaces.len()];
            client.call(json!({"cmd": "rename-workspace", "workspace": workspace,
                "name": format!("netcond-status-{n}")}));
        }
        if bytes == 0 {
            return;
        }
        let tag = self.produced.fetch_add(1, Ordering::SeqCst);
        let dir = &self.daemon.dir;
        fs::write(dir.join("req.tmp"), format!("{bytes} {tag}\n")).unwrap();
        fs::rename(dir.join("req.tmp"), dir.join("req")).unwrap();
        let needle = format!("EMITTED-{tag}");
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        loop {
            let screen = client.call(json!({"cmd": "read-screen", "surface": self.surface}));
            if screen.to_string().contains(&needle) {
                return;
            }
            assert!(std::time::Instant::now() < deadline, "the producer did not finish {bytes} B");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

struct BgSample {
    catch_up_ms: f64,
    bytes_down: u64,
    bytes_up: u64,
    round_trips: u64,
    /// The host answered from the cursor (an exact resume, an `unchanged` list); None: the
    /// form sent none.
    cursor_hit: Option<bool>,
    /// Terminal: the bytes the host held after the cursor (the exact resume's `through`).
    held_behind: Option<u64>,
}

/// The terminal's catch-up on a fresh connection.
async fn bg_terminal_once(
    shaper: &Shaper,
    fx: &BgFixture,
    cursor: &BgCursor,
    phase: &str,
) -> Result<BgSample, String> {
    shaper.reset_counters();
    let started = Instant::now();
    let mut conn = BgConn::open(shaper.addr()).await?;
    let resume = phase != "before";
    let mut params = json!({"surface": fx.surface, "cols": cursor.cols, "rows": cursor.rows,
        "replay_history_rows": 0});
    if resume {
        params["resume_offset"] = json!(cursor.offset);
        params["resume_generation"] = json!(cursor.generation);
    }
    if phase == "after_bounded" {
        params["resume_max_bytes"] = json!(cursor.replay_bytes);
    }
    let ids = conn
        .send(vec![
            ("set-client-info", bg_client_info(resume)),
            ("identify", json!({})),
            ("attach-surface", params),
        ])
        .await?;
    let deadline = Instant::now() + WAIT;
    let (mut content, mut reply) = (None, None);
    while content.is_none() || reply.is_none() {
        let (at, value) = conn.recv(deadline).await?;
        if value["id"] == json!(ids[2]) {
            if value["ok"] != json!(true) {
                return Err(format!("attach-surface: {value}"));
            }
            reply = Some(value);
        } else if value["surface"] == json!(fx.surface)
            && (value["event"] == "vt-state"
                || (value["event"] == "output" && value.get("resume").is_some()))
        {
            content = Some(at);
        }
    }
    let at = content.unwrap();
    let reply = reply.unwrap();
    let counters = shaper.counters();
    let resumed = reply["data"]["resume"].as_str();
    let through = reply["data"]["through"].as_u64();
    Ok(BgSample {
        catch_up_ms: ms(at - started),
        bytes_down: counters.down_bytes,
        bytes_up: counters.up_bytes,
        round_trips: counters.up_turns + 1,
        cursor_hit: resume.then_some(resumed == Some("exact")),
        held_behind: through.map(|through| through.saturating_sub(cursor.offset)),
    })
}

/// The workspace list's catch-up on a fresh connection: WorkspaceSync.prepare's setup write.
async fn bg_list_once(shaper: &Shaper, cursor: &BgCursor, phase: &str) -> Result<BgSample, String> {
    shaper.reset_counters();
    let started = Instant::now();
    let mut conn = BgConn::open(shaper.addr()).await?;
    let known = if phase == "before" { json!({}) } else { cursor.known.clone() };
    let ids = conn
        .send(vec![
            ("set-client-info", setup_client_info()),
            ("identify", json!({})),
            ("subscribe", json!({"tree_events": "deltas"})),
            ("list-agents", json!({})),
            ("list-workspaces", json!({"known": known})),
        ])
        .await?;
    let deadline = Instant::now() + WAIT;
    let mut pending = ids.clone();
    let mut list = Value::Null;
    let mut last = started;
    while !pending.is_empty() {
        let (at, value) = conn.recv(deadline).await?;
        let Some(id) = value["id"].as_u64() else { continue };
        let Some(index) = pending.iter().position(|p| *p == id) else { continue };
        if value["ok"] != json!(true) {
            return Err(format!("request {id}: {value}"));
        }
        pending.remove(index);
        if id == ids[4] {
            list = value;
        }
        last = at;
    }
    let counters = shaper.counters();
    Ok(BgSample {
        catch_up_ms: ms(last - started),
        bytes_down: counters.down_bytes,
        bytes_up: counters.up_bytes,
        round_trips: counters.up_turns + 1,
        cursor_hit: (phase != "before").then_some(list["data"]["unchanged"] == json!(true)),
        held_behind: None,
    })
}

#[allow(clippy::too_many_arguments)]
fn bg_emit_sample(
    surface: &str,
    link: &str,
    phase: &str,
    scale: &str,
    run: u64,
    seed: u64,
    sample: Result<BgSample, String>,
    behind: (u64, u64),
) {
    let (events_behind, stale_s) = behind;
    bg_emit(surface, link, phase, scale, "events_behind", Some(events_behind as f64), run, seed);
    bg_emit(surface, link, phase, scale, "stale_s", Some(stale_s as f64), run, seed);
    match sample {
        Ok(sample) => {
            bg_emit(
                surface,
                link,
                phase,
                scale,
                "catch_up_ms",
                Some(sample.catch_up_ms),
                run,
                seed,
            );
            for (metric, value) in [
                ("bytes_down", sample.bytes_down),
                ("bytes_up", sample.bytes_up),
                ("round_trips", sample.round_trips),
            ] {
                bg_emit(surface, link, phase, scale, metric, Some(value as f64), run, seed);
            }
            if let Some(hit) = sample.cursor_hit {
                bg_emit(
                    surface,
                    link,
                    phase,
                    scale,
                    "cursor_hit",
                    Some(f64::from(u8::from(hit))),
                    run,
                    seed,
                );
            }
            if let Some(held) = sample.held_behind {
                bg_emit(surface, link, phase, scale, "held_behind", Some(held as f64), run, seed);
            }
        }
        Err(why) => {
            bg_emit(surface, link, phase, scale, "catch_up_ms", None, run, seed);
            println!("NETCOND-ERROR {surface} {link} {phase} {scale} run {run}: {why}");
        }
    }
}

#[test]
#[ignore = "the time-away bench: scripts/measure/ios-network-conditions.sh mode=background runs it"]
fn background_catch_up_after_time_away() {
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(path) => ProfileFile::load(Path::new(&path)).unwrap(),
        Err(_) => ProfileFile::builtin(),
    };
    let profiles: Vec<LinkProfile> = env_list("NETCOND_PROFILES", "good-wifi,lte,lossy-3")
        .iter()
        .map(|name| file.get(name).unwrap_or_else(|| panic!("no link profile {name}")).clone())
        .collect();
    let aways = env_list("NETCOND_AWAY", "1m,10m,1h,8h");
    let loads = env_list("NETCOND_LOADS", "idle,busy");
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let mut fx = BgFixture::start();
    let mut phases = vec!["before", "after"];
    if fx.lists(TERMINAL_RESUME_BOUNDED_CAPABILITY) {
        phases.push("after_bounded");
    }
    println!(
        "NETCOND-FIXTURE background: {BG_WORKSPACES} workspaces, terminal {COLS}x{ROWS} with \
         {BG_SCROLLBACK} lines of scrollback; busy: {BG_BUSY_TERMINAL_BYTES_PER_S} B/s of build \
         log, a list change every {BG_BUSY_LIST_EVERY_S} s; idle: a list change every \
         {BG_IDLE_LIST_EVERY_S} s; terminal capped at {} B (ring {BG_RESUME_RING_BYTES} B); \
         phases {phases:?}",
        BG_RESUME_RING_BYTES + BG_PAST_RING_BYTES
    );
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    runtime.block_on(async {
        fx.upstream = splice(&fx.daemon.socket).await;
        for load in &loads {
            let busy = load == "busy";
            for away in &aways {
                let secs = away_secs(away);
                let scale = format!("{away}-{load}");
                let span_bytes = if busy { secs * BG_BUSY_TERMINAL_BYTES_PER_S } else { 0 };
                let made_bytes = span_bytes.min(BG_RESUME_RING_BYTES + BG_PAST_RING_BYTES);
                let changes = secs / if busy { BG_BUSY_LIST_EVERY_S } else { BG_IDLE_LIST_EVERY_S };
                for run in 0..runs {
                    let seed = seed_base + run;
                    let cursor = match fx.cursor().await {
                        Ok(cursor) => cursor,
                        Err(why) => {
                            println!("NETCOND-ERROR background {scale} run {run}: cursor: {why}");
                            continue;
                        }
                    };
                    let produced = Instant::now();
                    fx.produce(made_bytes, changes);
                    eprintln!(
                        "netcond: {scale} run {run}: made {made_bytes} B and {changes} list changes in {:?}",
                        produced.elapsed()
                    );
                    for profile in &profiles {
                        let label = label(profile);
                        let (shaper, _relay) = match link(fx.upstream, profile, seed).await {
                            Ok(link) => link,
                            Err(e) => {
                                println!("NETCOND-ERROR background {label} {scale}: shaper: {e}");
                                continue;
                            }
                        };
                        for phase in &phases {
                            let sample = bg_terminal_once(&shaper, &fx, &cursor, phase).await;
                            bg_emit_sample("terminal", &label, phase, &scale, run, seed, sample,
                                (span_bytes, secs));
                            if *phase == "after_bounded" {
                                continue; // the list has no bounded form
                            }
                            let sample = bg_list_once(&shaper, &cursor, phase).await;
                            bg_emit_sample("workspaces", &label, phase, &scale, run, seed, sample,
                                (changes, secs));
                        }
                    }
                }
            }
        }
    });
    drop(runtime);
    fx.daemon.stop();
}
