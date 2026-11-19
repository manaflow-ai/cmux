//! Terminal latency as a terminal client feels it: one harness for the four
//! things a person does in a cmux terminal from the Mac app or the phone.
//!
//! A real headless daemon runs as the app runs it (`--state`: every shell in
//! its own terminal host process). Clients speak the daemon's JSON-lines
//! protocol on its socket, the way the Mac app's terminal and the phone's
//! `daemon` channel (DaemonTerminalSession) do: `attach-surface` in bytes
//! mode, `send {surface, bytes}` for input, base64 `output` events back.
//! The phone's link is emulated by a proxy that holds every chunk for half
//! the round trip in each direction (netem's delay, with no root), so a
//! protocol that needs more round trips than it should shows as a multiple
//! of the RTT.
//!
//! Measured at 1, 10 and 50 terminals (each with its own local viewer, as
//! the Mac app keeps every open terminal attached), p50, p95 and max:
//!
//! - `echo`: one key into an interactive shell until the client reads the
//!   echoed byte, keys sent one at a time;
//! - `attach`: a client attaching a terminal with 10K lines of scrollback
//!   until it has parsed the replay into its own terminal (a usable screen),
//!   whole history (`full`) and screen only (`tail`, the phone's
//!   `replay_history_rows: 0`), one terminal and all of them at once;
//! - `scroll`: paging back through the 10K lines, as `read-scrollback` pages
//!   of one screen and as the phone's history chunks (a new attach with 2,000
//!   more rows each time, `loadOlderHistory`);
//! - `burst`: `seq 1 200000` until the screen settles, with keys typed into
//!   the same terminal during it (input latency under a flood) and into
//!   another terminal (does one flood slow the others).
//!
//! Run (ignored in the normal test run):
//! `cargo test --release -p cmux-tui --test terminal_latency -- --ignored --nocapture`.
//! `CMUX_LATENCY_COUNTS` (default `1,10,50`), `CMUX_LATENCY_RTTS_MS` (default
//! `0,40`), `CMUX_LATENCY_KEYS` (default 60) pick the matrix. With
//! `FAST_CHECKS_OUT` set it also writes `terminal-latency.json` there.
#![cfg(unix)]

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Value, json};

const COLS: u16 = 120;
const ROWS: u16 = 40;
const SCROLLBACK_LINES: u32 = 10_000;
const BURST_LINES: u32 = 200_000;
const PHONE_HISTORY_CHUNK: u32 = 2_000;
const WAIT: Duration = Duration::from_secs(120);

fn b64() -> &'static base64::engine::GeneralPurpose {
    &base64::engine::general_purpose::STANDARD
}

// ---------------------------------------------------------------- daemon --

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // The daemon this test started, by its own handle. Its terminal hosts
        // end with their shells when the daemon's sockets close.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-latency-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let settings = dir.join("cmux-next.json");
        fs::write(&settings, "{}\n").unwrap();
        let home = dir.join("home");
        fs::create_dir_all(&home).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--session", "main", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("HOME", &home)
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .env("ACPMUX_SOCKET", dir.join("acpmux.sock"))
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    fn request(&self, value: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(WAIT)).unwrap();
        (&stream).write_all(format!("{value}\n").as_bytes()).unwrap();
        let mut reader = BufReader::new(&stream);
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0, "daemon closed for {value}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{value} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }

    /// A new workspace running an interactive `sh` at a `$ ` prompt.
    fn shell(&self, name: &str) -> u64 {
        let created = self.request(json!({
            "id": 1, "cmd": "run", "new_workspace": true, "name": name,
            "cols": COLS, "rows": ROWS,
            "argv": ["/bin/sh", "-c", "PS1='$ '; export PS1; exec /bin/sh -i"],
        }));
        created["surface"]
            .as_u64()
            .or_else(|| created["surface_id"].as_u64())
            .unwrap_or_else(|| panic!("run reply names no surface: {created}"))
    }
}

// ----------------------------------------------------------- delay proxy --

/// A Unix socket in front of the daemon's that holds every chunk for
/// `one_way` in each direction, in order: a link with that much latency and
/// no bandwidth limit.
struct DelayProxy {
    path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl DelayProxy {
    fn start(dir: &Path, upstream: &Path, rtt: Duration) -> Self {
        let path = dir.join(format!("proxy-{}.sock", rtt.as_millis()));
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let one_way = rtt / 2;
        let upstream = upstream.to_path_buf();
        let stop_accept = stop.clone();
        std::thread::spawn(move || {
            while !stop_accept.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((client, _)) => {
                        client.set_nonblocking(false).unwrap();
                        let server = UnixStream::connect(&upstream).unwrap();
                        pipe(client.try_clone().unwrap(), server.try_clone().unwrap(), one_way);
                        pipe(server, client, one_way);
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(2)),
                }
            }
        });
        Self { path, stop }
    }
}

impl Drop for DelayProxy {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = fs::remove_file(&self.path);
    }
}

fn pipe(mut from: UnixStream, mut to: UnixStream, delay: Duration) {
    let (tx, rx) = mpsc::channel::<(Instant, Vec<u8>)>();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 1 << 16];
        loop {
            match from.read(&mut buf) {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    if tx.send((Instant::now() + delay, buf[..n].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
    std::thread::spawn(move || {
        while let Ok((due, bytes)) = rx.recv() {
            let now = Instant::now();
            if due > now {
                std::thread::sleep(due - now);
            }
            if to.write_all(&bytes).is_err() {
                return;
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
}

// ---------------------------------------------------------------- client --

#[derive(Default)]
struct Inbox {
    /// Decoded `output` payloads with their arrival time.
    outputs: Vec<(Instant, Vec<u8>)>,
    /// Decoded `vt-state` replays: arrival, wire bytes, payload.
    states: Vec<(Instant, usize, Vec<u8>)>,
    replies: HashMap<u64, (Instant, Value)>,
    wire_bytes: u64,
    closed: bool,
}

/// One client connection: a reader thread files every line it reads.
struct Conn {
    stream: UnixStream,
    inbox: Arc<(Mutex<Inbox>, Condvar)>,
    next_id: AtomicU64,
}

impl Conn {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        let inbox = Arc::new((Mutex::new(Inbox::default()), Condvar::new()));
        let reader = stream.try_clone().unwrap();
        let shared = inbox.clone();
        std::thread::spawn(move || read_lines(reader, shared));
        Self { stream, inbox, next_id: AtomicU64::new(100) }
    }

    fn submit(&self, mut body: Value) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        body["id"] = json!(id);
        (&self.stream).write_all(format!("{body}\n").as_bytes()).unwrap();
        id
    }

    fn wait<T>(&self, mut ready: impl FnMut(&Inbox) -> Option<T>) -> T {
        let (lock, cond) = &*self.inbox;
        let deadline = Instant::now() + WAIT;
        let mut inbox = lock.lock().unwrap();
        loop {
            if let Some(value) = ready(&inbox) {
                return value;
            }
            assert!(!inbox.closed, "the daemon closed the connection");
            let now = Instant::now();
            assert!(now < deadline, "nothing arrived in {WAIT:?}");
            inbox = cond.wait_timeout(inbox, deadline - now).unwrap().0;
        }
    }

    fn reply(&self, id: u64) -> (Instant, Value) {
        let (at, reply) = self.wait(|inbox| inbox.replies.get(&id).cloned());
        assert_eq!(reply["ok"], true, "request {id} failed: {reply}");
        (at, reply)
    }

    fn request(&self, body: Value) -> Value {
        let id = self.submit(body);
        self.reply(id).1["data"].clone()
    }

    /// Attach `surface` in bytes mode; `history` limits the replay's history
    /// rows. Returns (replay arrival, replay wire bytes, replay payload).
    fn attach(&self, surface: u64, history: Option<u32>) -> (Instant, usize, Vec<u8>) {
        let states = self.wait(|inbox| Some(inbox.states.len()));
        let mut body = json!({"cmd": "attach-surface", "surface": surface});
        if let Some(rows) = history {
            body["replay_history_rows"] = json!(rows);
        }
        let id = self.submit(body);
        self.reply(id);
        self.wait(|inbox| inbox.states.get(states).cloned())
    }

    fn output_count(&self) -> usize {
        self.wait(|inbox| Some(inbox.outputs.len()))
    }

    /// The first output at index `from` or later that contains `needle`.
    fn output_with(&self, from: usize, needle: &[u8]) -> Instant {
        self.wait(|inbox| {
            inbox.outputs[from.min(inbox.outputs.len())..]
                .iter()
                .find(|(_, bytes)| contains(bytes, needle))
                .map(|(at, _)| *at)
        })
    }

    fn send(&self, surface: u64, bytes: &[u8]) {
        self.submit(json!({"cmd": "send", "surface": surface, "bytes": b64().encode(bytes)}));
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

fn field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let pattern = format!("\"{key}\":\"");
    let at = line.find(&pattern)? + pattern.len();
    let end = line[at..].find('"')?;
    Some(&line[at..at + end])
}

fn read_lines(stream: UnixStream, inbox: Arc<(Mutex<Inbox>, Condvar)>) {
    let mut reader = BufReader::with_capacity(1 << 20, stream);
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = reader.read_until(b'\n', &mut line).unwrap_or(0);
        let now = Instant::now();
        let (lock, cond) = &*inbox;
        if n == 0 {
            lock.lock().unwrap().closed = true;
            cond.notify_all();
            return;
        }
        let text = String::from_utf8_lossy(&line);
        let event = field(&text, "event").unwrap_or("");
        let mut got = lock.lock().unwrap();
        got.wire_bytes += n as u64;
        match event {
            "output" => {
                let data = field(&text, "data").map(|d| b64().decode(d).unwrap_or_default());
                got.outputs.push((now, data.unwrap_or_default()));
            }
            "vt-state" => {
                let data = field(&text, "data").map(|d| b64().decode(d).unwrap_or_default());
                got.states.push((now, n, data.unwrap_or_default()));
            }
            "" => {
                if let Ok(reply) = serde_json::from_str::<Value>(&text)
                    && let Some(id) = reply.get("id").and_then(Value::as_u64)
                {
                    got.replies.insert(id, (now, reply));
                }
            }
            _ => {}
        }
        drop(got);
        cond.notify_all();
    }
}

// ----------------------------------------------------------- measurement --

#[derive(Clone, Copy)]
struct Stats {
    n: usize,
    p50: f64,
    p95: f64,
    max: f64,
}

fn stats(mut samples: Vec<f64>) -> Stats {
    samples.sort_by(f64::total_cmp);
    let at = |q: f64| {
        if samples.is_empty() {
            return 0.0;
        }
        samples[((samples.len() - 1) as f64 * q).round() as usize]
    };
    Stats {
        n: samples.len(),
        p50: at(0.5),
        p95: at(0.95),
        max: samples.last().copied().unwrap_or(0.0),
    }
}

fn ms(from: Instant, to: Instant) -> f64 {
    to.saturating_duration_since(from).as_secs_f64() * 1000.0
}

/// Keys typed one at a time into `surface`, each timed to its echo.
fn echo(conn: &Conn, surface: u64, keys: usize) -> Vec<f64> {
    let mut samples = Vec::with_capacity(keys);
    for k in 0..keys {
        let key = [b'a' + (k % 26) as u8];
        let from = conn.output_count();
        let sent = Instant::now();
        conn.send(surface, &key);
        let at = conn.output_with(from, &key);
        samples.push(ms(sent, at));
        std::thread::sleep(Duration::from_millis(10));
    }
    // Ctrl-U: the line the keys typed goes.
    conn.send(surface, b"\x15");
    std::thread::sleep(Duration::from_millis(50));
    samples
}

/// Parse a replay into a client terminal the size of the screen and read
/// it: the screen is usable once this returns.
fn parse_replay(replay: &[u8]) {
    let mut term =
        ghostty_vt::Terminal::new(COLS, ROWS, 64 << 20, ghostty_vt::Callbacks::default()).unwrap();
    term.vt_write(replay);
    let _ = term.viewport_text().unwrap();
}

/// One attach on a new connection: (ms to the replay, ms to a usable screen,
/// replay KB).
fn attach_once(socket: &Path, surface: u64, history: Option<u32>) -> (f64, f64, f64) {
    let start = Instant::now();
    let conn = Conn::connect(socket);
    let (at, wire, replay) = conn.attach(surface, history);
    parse_replay(&replay);
    (ms(start, at), ms(start, Instant::now()), wire as f64 / 1000.0)
}

/// Every terminal attached at once, one connection each, as a client
/// coming back to a session does: ms until the last screen is usable.
fn attach_all(socket: &Path, surfaces: &[u64], history: Option<u32>) -> f64 {
    let start = Instant::now();
    let handles: Vec<_> = surfaces
        .iter()
        .map(|surface| {
            let socket = socket.to_path_buf();
            let surface = *surface;
            std::thread::spawn(move || {
                let conn = Conn::connect(&socket);
                let (_, _, replay) = conn.attach(surface, history);
                parse_replay(&replay);
            })
        })
        .collect();
    for handle in handles {
        handle.join().unwrap();
    }
    ms(start, Instant::now())
}

fn env_list(name: &str, default: &[u64]) -> Vec<u64> {
    std::env::var(name)
        .ok()
        .map(|value| value.split(',').filter_map(|v| v.trim().parse().ok()).collect())
        .unwrap_or_else(|| default.to_vec())
}

struct Run {
    rows: Vec<Value>,
}

impl Run {
    fn add(&mut self, count: u64, rtt: u64, metric: &str, stats: Stats, extra: Value) {
        eprintln!(
            "LATENCY terminals={count} rtt_ms={rtt} {metric}: n={} p50={:.1} p95={:.1} max={:.1} ms {extra}",
            stats.n, stats.p50, stats.p95, stats.max
        );
        self.rows.push(json!({
            "terminals": count, "rtt_ms": rtt, "metric": metric, "n": stats.n,
            "p50_ms": stats.p50, "p95_ms": stats.p95, "max_ms": stats.max, "extra": extra,
        }));
    }
}

fn measure_count(count: u64, rtts: &[u64], keys: usize, run: &mut Run) {
    let daemon = Daemon::start(&format!("n{count}"));
    let surfaces: Vec<u64> = (0..count).map(|i| daemon.shell(&format!("t{i}"))).collect();
    for surface in &surfaces {
        let deadline = Instant::now() + WAIT;
        while !daemon.request(json!({"id": 1, "cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .contains("$ ")
        {
            assert!(Instant::now() < deadline, "terminal {surface} shows no prompt");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    // Every terminal has a local viewer reading its stream, as the Mac app
    // keeps each open terminal attached.
    let viewers: Vec<Conn> = surfaces
        .iter()
        .map(|surface| {
            let conn = Conn::connect(&daemon.socket);
            conn.attach(*surface, None);
            conn
        })
        .collect();
    let proxies: Vec<(u64, PathBuf, Option<DelayProxy>)> = rtts
        .iter()
        .map(|rtt| {
            if *rtt == 0 {
                (0, daemon.socket.clone(), None)
            } else {
                let proxy =
                    DelayProxy::start(&daemon.dir, &daemon.socket, Duration::from_millis(*rtt));
                (*rtt, proxy.path.clone(), Some(proxy))
            }
        })
        .collect();

    // (a) Input to echo on an idle terminal.
    for (rtt, socket, _) in &proxies {
        let conn = Conn::connect(socket);
        conn.attach(surfaces[0], Some(0));
        run.add(count, *rtt, "echo", stats(echo(&conn, surfaces[0], keys)), json!({}));
    }

    // 10K lines of scrollback in every terminal.
    let fill = format!(
        "seq -f 'scrollback line %06g the quick brown fox jumps over the lazy dog' 1 {SCROLLBACK_LINES}; echo FILL-$((1+1))-DONE\r"
    );
    let marks: Vec<usize> = viewers.iter().map(Conn::output_count).collect();
    for (viewer, surface) in viewers.iter().zip(&surfaces) {
        viewer.send(*surface, fill.as_bytes());
    }
    for (viewer, mark) in viewers.iter().zip(marks) {
        viewer.output_with(mark, b"FILL-2-DONE");
    }
    std::thread::sleep(Duration::from_millis(200));

    for (rtt, socket, _) in &proxies {
        // (b) Attach with 10K lines of history.
        for (mode, history) in [("full", None), ("tail", Some(0))] {
            let mut to_state = Vec::new();
            let mut usable = Vec::new();
            let mut kb = 0.0;
            for _ in 0..5 {
                let (state, ready, size) = attach_once(socket, surfaces[0], history);
                to_state.push(state);
                usable.push(ready);
                kb = size;
            }
            let replay = stats(to_state);
            run.add(
                count,
                *rtt,
                &format!("attach-{mode}"),
                stats(usable),
                json!({"replay_kb": kb, "replay_p50_ms": replay.p50}),
            );
            let all: Vec<f64> = (0..3).map(|_| attach_all(socket, &surfaces, history)).collect();
            run.add(count, *rtt, &format!("attach-all-{mode}"), stats(all), json!({}));
        }

        // (c) Scroll back through the history: read-scrollback pages of one
        // screen, newest first, and the phone's history chunks.
        let conn = Conn::connect(socket);
        let total = conn.request(json!({"cmd": "read-scrollback", "surface": surfaces[0],
            "start": 0, "count": 0}))["total"]
            .as_u64()
            .unwrap_or(0);
        let mut pages = Vec::new();
        let mut start = total;
        while start > 0 && pages.len() < 250 {
            start = start.saturating_sub(u64::from(ROWS));
            let sent = Instant::now();
            conn.request(json!({"cmd": "read-scrollback", "surface": surfaces[0],
                "start": start, "count": ROWS}));
            pages.push(ms(sent, Instant::now()));
        }
        run.add(count, *rtt, "scroll-page", stats(pages), json!({"history_rows": total}));
        let mut chunks = Vec::new();
        let mut rows = PHONE_HISTORY_CHUNK;
        loop {
            let (_, ready, _) = attach_once(socket, surfaces[0], Some(rows));
            chunks.push(ready);
            if u64::from(rows) >= total {
                break;
            }
            rows += PHONE_HISTORY_CHUNK;
        }
        run.add(count, *rtt, "scroll-phone-chunk", stats(chunks), json!({}));
    }

    // (d) Burst: `seq 1 200000` in terminal 0 with every viewer attached,
    // keys typed into it during the burst, and into terminal 1 (if any).
    for (rtt, socket, _) in &proxies {
        let conn = Conn::connect(socket);
        conn.attach(surfaces[0], Some(0));
        let other = surfaces.get(1).map(|surface| {
            let other = Conn::connect(socket);
            other.attach(*surface, Some(0));
            (other, *surface)
        });
        let mark = conn.output_count();
        let started = Instant::now();
        conn.send(
            surfaces[0],
            format!("seq 1 {BURST_LINES}; echo BURST-$((1+1))-DONE\r").as_bytes(),
        );
        let stop = Arc::new(AtomicBool::new(false));
        let other_echo = other.map(|(other, surface)| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut samples = Vec::new();
                let mut k = 0;
                while !stop.load(Ordering::Relaxed) {
                    samples.extend(echo(&other, surface, 1));
                    k += 1;
                    if k > 2000 {
                        break;
                    }
                }
                samples
            })
        });
        // Letters typed into the flooding terminal every 25 ms: the tty
        // echoes each between `seq`'s lines.
        let mut typed: Vec<(Instant, u8, usize)> = Vec::new();
        let mut k = 0usize;
        let done_at = loop {
            let found = {
                let (lock, _) = &*conn.inbox;
                let inbox = lock.lock().unwrap();
                inbox.outputs[mark..]
                    .iter()
                    .find(|(_, bytes)| contains(bytes, b"BURST-2-DONE"))
                    .map(|(at, _)| *at)
            };
            if let Some(at) = found {
                break at;
            }
            assert!(started.elapsed() < WAIT, "the burst never settled");
            if k < 400 {
                let key = b'a' + (k % 26) as u8;
                let from = conn.output_count();
                typed.push((Instant::now(), key, from));
                conn.send(surfaces[0], &[key]);
                k += 1;
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        stop.store(true, Ordering::Relaxed);
        let in_burst: Vec<f64> = typed
            .iter()
            .map(|(sent, key, from)| ms(*sent, conn.output_with(*from, &[*key])))
            .collect();
        conn.send(surfaces[0], b"\x15");
        let settle = ms(started, done_at);
        run.add(count, *rtt, "burst-settle", stats(vec![settle]), json!({"lines": BURST_LINES}));
        run.add(count, *rtt, "burst-echo-same", stats(in_burst), json!({}));
        if let Some(handle) = other_echo {
            run.add(count, *rtt, "burst-echo-other", stats(handle.join().unwrap()), json!({}));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    drop(viewers);
    drop(proxies);
}

fn table(rows: &[Value]) -> String {
    let mut out = String::from(
        "| Terminals | RTT ms | Metric | n | p50 ms | p95 ms | max ms | Notes |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n",
    );
    for row in rows {
        out.push_str(&format!(
            "| {} | {} | {} | {} | {:.1} | {:.1} | {:.1} | {} |\n",
            row["terminals"],
            row["rtt_ms"],
            row["metric"].as_str().unwrap_or(""),
            row["n"],
            row["p50_ms"].as_f64().unwrap_or(0.0),
            row["p95_ms"].as_f64().unwrap_or(0.0),
            row["max_ms"].as_f64().unwrap_or(0.0),
            if row["extra"].as_object().is_some_and(|o| o.is_empty()) {
                String::new()
            } else {
                row["extra"].to_string()
            }
        ));
    }
    out
}

#[test]
#[ignore = "a bench of several minutes; run with --ignored --nocapture"]
fn terminal_latency_echo_attach_scroll_burst() {
    let counts = env_list("CMUX_LATENCY_COUNTS", &[1, 10, 50]);
    let rtts = env_list("CMUX_LATENCY_RTTS_MS", &[0, 40]);
    let keys = env_list("CMUX_LATENCY_KEYS", &[60])[0] as usize;
    let mut run = Run { rows: Vec::new() };
    for count in counts {
        measure_count(count, &rtts, keys, &mut run);
    }
    let table = table(&run.rows);
    println!("\nTerminal latency (cmux-tui tests/terminal_latency.rs)\n\n{table}");
    if let Ok(dir) = std::env::var("FAST_CHECKS_OUT") {
        let _ = fs::create_dir_all(&dir);
        fs::write(Path::new(&dir).join("terminal-latency.json"), json!(run.rows).to_string())
            .unwrap();
        fs::write(Path::new(&dir).join("terminal-latency.md"), &table).unwrap();
    }
}
