//! What the daemon sends the app's chat panes while chats stream, by message kind, and the
//! daemon's CPU for it (CMUX-571).
//!
//! Leo, 2026-11-16: "for ios i mean but i guess you can look at the bandwidth of the regar app
//! too". On his nightly, nettop showed acpmux sending about 5.3 MB/s over its WebSocket to the app
//! with chats open.
//!
//! The app opens one WebSocket per chat pane (`AgentPaneTransport`), and each pane's page
//! (`webviews/src/agent-session/acpmux/direct.ts` `open`) sends `initialize`, `_acpmux/status`,
//! `_acpmux/watch {enabled, limit}` (every chat's row changes) and `_acpmux/attach` of its own chat
//! with `eventStream: true`, the kinds of `attachParams.ts` `plainAttach` and `visible` (a pane in
//! a background tab attaches `visible: false` and sends `_acpmux/view {visible}` when that
//! changes). This harness opens those panes on a real daemon, some shown and some hidden, has every
//! chat stream a reply, and counts each pane's received bytes by method (and record kind).
//!
//! Run by hand, as the other acpmux benches:
//! `cargo test -p acpmux --release --test app_stream_bytes -- --ignored --nocapture`
//! (`ACPMUX_BENCH_CHATS`, `ACPMUX_BENCH_SHOWN`, `ACPMUX_BENCH_TICKS`, `ACPMUX_BENCH_TICK_MS`;
//! `ACPMUX_BENCH_QUIET=0` attaches as a pane before `quietHidden`, the before of the same build;
//! `ACPMUX_BENCH_IDLE_SECS`, the idle arm after the streams: every pane open, nothing streaming;
//! `ACPMUX_BENCH_WATCHERS`, the app-level watchers of each `rows` mode beside the panes: the
//! unix socket watches of the harness settings and the feed bridge, which draw no row).
//! It prints one `app-stream-bytes: {json}` line and one `app-stream-bytes-kind:` line per kind.
//! The plain tests below hold the fix: a hidden
//! pane hears no stream of its chat until it is shown, and then it is told to read again.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;

const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_BENCH_CHATS",
    "ACPMUX_BENCH_SHOWN",
    "ACPMUX_BENCH_TICKS",
    "ACPMUX_BENCH_TICK_MS",
    "ACPMUX_BENCH_QUIET",
    "ACPMUX_BENCH_IDLE_SECS",
    "ACPMUX_BENCH_WATCHERS",
]);

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PANE: &str = "cmux-agent://pane";

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
    ws: String,
    listener_token: String,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        Self::start_with(tag, "approve-all")
    }

    fn start_with(tag: &str, policy: &str) -> Self {
        let home = std::env::temp_dir().join(format!("asb-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("work")).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": policy})
            .to_string(),
        )
        .unwrap();
        let socket = home.join("s.sock");
        let mut child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut out = BufReader::new(stdout);
            let mut line = String::new();
            while out.read_line(&mut line).unwrap_or(0) > 0 {
                if line.contains("\"ready\":true") {
                    let _ = tx.send(line.clone());
                    return;
                }
                line.clear();
            }
        });
        let ready: Value =
            serde_json::from_str(&rx.recv_timeout(Duration::from_secs(30)).unwrap()).unwrap();
        let url = ready["webUrl"].as_str().unwrap();
        let (base, token) = url.split_once("/#token=").unwrap();
        let socket = ready["socket"].as_str().map_or(socket, PathBuf::from);
        Self {
            child: Some(child),
            ws: format!("{}/", base.replace("http://", "ws://")),
            listener_token: token.to_owned(),
            home,
            socket,
        }
    }

    fn pid(&self) -> u32 {
        self.child.as_ref().unwrap().id()
    }

    /// The daemon's CPU time so far (user + system), from /proc; None where there is none.
    fn cpu(&self) -> Option<Duration> {
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", self.pid())).ok()?;
        // After the command's closing paren: state is field 3, utime 14, stime 15.
        let rest = &stat[stat.rfind(')')? + 2..];
        let fields: Vec<&str> = rest.split_whitespace().collect();
        let ticks: u64 =
            fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?;
        // SAFETY: sysconf reads a constant.
        let hz = u64::try_from(unsafe { libc::sysconf(libc::_SC_CLK_TCK) }).ok()?.max(1);
        Some(Duration::from_micros(ticks * 1_000_000 / hz))
    }

    fn local_token(&self) -> String {
        std::fs::read_to_string(self.home.join("run/localapp.token")).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        for dir in [self.home.join("hosts"), self.home.join("hosts/pool")] {
            for r in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let Ok(v) =
                    serde_json::from_slice::<Value>(&std::fs::read(r.path()).unwrap_or_default())
                else {
                    continue;
                };
                for pid in [v["harness_pid"].as_i64(), v["host_pid"].as_i64()].into_iter().flatten()
                {
                    // Only a real group this daemon made: never 0 or 1 (this test's own group, init).
                    if pid > 1 {
                        // SAFETY: a process group this test's daemon created.
                        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

/// The driver: the unix socket, as the CLI uses it.
struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(d: &Daemon) -> Self {
        let s = tokio::net::UnixStream::connect(&d.socket).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(120), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Bytes and messages one pane received, by label.
#[derive(Default)]
struct Counts {
    by_kind: BTreeMap<String, (u64, u64)>,
    /// Records of the pane's own chat's stream (`session/update`, `_acpmux/event`).
    own_stream: u64,
    /// `_acpmux/lagged` notices: read again from your cursor.
    lagged: u64,
    /// `_acpmux/session_changed` notices of other chats than the pane's own.
    other_rows: u64,
    /// Every byte received since `reset_bytes`, whatever `counting` says.
    bytes: u64,
    /// The last `_acpmux/lagged` notice's params.
    lag: Option<Value>,
    /// The page's cursor (direct.ts `lastSeq`): the newest seq of its own chat's records it heard.
    cursor: u64,
    /// The seqs of its own chat's `agent_message_chunk` records it heard.
    chunks: Vec<u64>,
    counting: bool,
}

/// What a frame is: its method, with the record kind of an event or row change.
fn label(v: &Value) -> String {
    let Some(method) = v.get("method").and_then(Value::as_str) else {
        return "reply".to_owned();
    };
    let params = v.get("params").unwrap_or(&Value::Null);
    let kind = match method {
        "_acpmux/event" => params.get("kind").and_then(Value::as_str),
        "_acpmux/session_changed" => params.get("kind").and_then(Value::as_str),
        "session/update" => params.pointer("/update/sessionUpdate").and_then(Value::as_str),
        _ => None,
    };
    match kind {
        Some(kind) => format!("{method}:{kind}"),
        None => method.to_owned(),
    }
}

struct Pane {
    session: String,
    tx: futures_util::stream::SplitSink<Ws, Message>,
    replies: tokio::sync::mpsc::UnboundedReceiver<Value>,
    counts: Arc<Mutex<Counts>>,
    next: i64,
    /// The attach reply's `lastSeq`: where the page's cursor starts.
    attached_seq: u64,
}

impl Pane {
    /// A chat pane as the app opens it: the LocalApp hello, the status read, the row watch, the
    /// plain attach of its chat (`attachParams.ts`), shown or not.
    async fn open(d: &Daemon, session: &str, visible: bool, quiet: bool) -> Self {
        let mut req = d.ws.as_str().into_client_request().unwrap();
        let h = req.headers_mut();
        h.insert("authorization", format!("Bearer {}", d.listener_token).parse().unwrap());
        h.insert("origin", PANE.parse().unwrap());
        let (ws, _) = tokio_tungstenite::connect_async(req).await.expect("upgrade");
        let (tx, mut rx) = ws.split();
        let counts = Arc::new(Mutex::new(Counts::default()));
        let (reply_tx, replies) = tokio::sync::mpsc::unbounded_channel();
        let own = session.to_owned();
        let counted = counts.clone();
        tokio::spawn(async move {
            while let Some(Ok(frame)) = rx.next().await {
                let text = match frame {
                    Message::Text(t) => t.to_string(),
                    Message::Close(_) => break,
                    _ => continue,
                };
                let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                {
                    let mut c = counted.lock().unwrap();
                    let method = v.get("method").and_then(Value::as_str).unwrap_or("");
                    let params = v.get("params").unwrap_or(&Value::Null);
                    let of_own =
                        params.get("sessionId").and_then(Value::as_str) == Some(own.as_str());
                    // The agent's stream: `session/update`, or an event of a record it sent (`dir: in`).
                    let stream = method == "session/update"
                        || (method == "_acpmux/event"
                            && params.get("dir").and_then(Value::as_str) == Some("in"));
                    if of_own && stream {
                        c.own_stream += 1;
                    }
                    if method == "_acpmux/lagged" {
                        c.lagged += 1;
                        c.lag = Some(params.clone());
                    }
                    if method == "_acpmux/session_changed" && !of_own {
                        c.other_rows += 1;
                    }
                    c.bytes += text.len() as u64;
                    if of_own && method == "_acpmux/event" {
                        let seq = params.get("seq").and_then(Value::as_u64).unwrap_or(0);
                        c.cursor = c.cursor.max(seq);
                        let kind = params.get("kind").and_then(Value::as_str);
                        if kind == Some("agent_message_chunk") {
                            c.chunks.push(seq);
                        }
                    }
                    if c.counting {
                        let e = c.by_kind.entry(label(&v)).or_default();
                        e.0 += text.len() as u64;
                        e.1 += 1;
                    }
                }
                if v.get("id").is_some() && v.get("method").is_none() {
                    let _ = reply_tx.send(v);
                }
            }
        });
        let mut pane =
            Self { session: session.to_owned(), tx, replies, counts, next: 0, attached_seq: 0 };
        let init = pane
            .call("initialize", json!({"protocolVersion": 1,
                "clientInfo": {"name": "cmux-react-agent-pane", "version": "1"}, "clientCapabilities": {},
                "_meta": {"acpmux": {"localAppToken": d.local_token()}}}))
            .await;
        assert_eq!(init["result"]["_meta"]["acpmux"]["origin"], "local", "{init}");
        pane.call("_acpmux/status", json!({})).await;
        pane.call("_acpmux/watch", json!({"enabled": true, "limit": 50})).await;
        let kinds = json!([
            "transcript",
            "available_commands_update",
            "usage_update",
            "config_option_update",
            "bookmarks",
            "secret_request",
            "secret_decision",
            "subsession",
            "queue_order",
            "queue_updated",
            "prompt_refused",
            "elevation_request",
            "elevation_decision",
            "preset_approval_request",
            "preset_approval_decision"
        ]);
        let attached = pane
            .call(
                "_acpmux/attach",
                json!({"sessionId": session, "waitLogs": false, "limit": 400,
                "maxBytes": 4 << 20, "kinds": kinds, "eventStream": true, "visible": visible,
                "attending": true, "quietHidden": quiet}),
            )
            .await;
        assert!(attached.get("error").is_none(), "{attached}");
        let last = attached.pointer("/result/lastSeq").and_then(Value::as_u64).unwrap_or(0);
        {
            let mut c = pane.counts.lock().unwrap();
            c.cursor = c.cursor.max(last);
        }
        pane.attached_seq = last;
        pane
    }

    /// The seqs of the chat's `agent_message_chunk` records after `after_seq`, as the page's lag
    /// read pages them (direct.ts `fetchMissedEvents`).
    async fn chunks_after(&mut self, after_seq: u64) -> Vec<u64> {
        let session = self.session.clone();
        let mut cursor = after_seq;
        let mut out = Vec::new();
        loop {
            let params = json!({"sessionId": session, "afterSeq": cursor, "limit": 5000});
            let page = self.call("_acpmux/events", params).await;
            let events = page
                .pointer("/result/events")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for event in &events {
                let seq = event.get("seq").and_then(Value::as_u64).unwrap_or(0);
                cursor = cursor.max(seq);
                if event.get("kind").and_then(Value::as_str) == Some("agent_message_chunk") {
                    out.push(seq);
                }
            }
            if events.is_empty() || page.pointer("/result/hasMore") != Some(&json!(true)) {
                return out;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.tx.send(Message::Text(req.to_string().into())).await.unwrap();
        loop {
            let v = tokio::time::timeout(Duration::from_secs(60), self.replies.recv())
                .await
                .expect("an answer in time")
                .expect("open");
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// `_acpmux/view`: the page's `syncView` as its pane shows or hides.
    async fn view(&mut self, visible: bool) {
        let session = self.session.clone();
        let done =
            self.call("_acpmux/view", json!({"sessionId": session, "visible": visible})).await;
        assert!(done.get("error").is_none(), "{done}");
    }

    fn counting(&self, on: bool) {
        self.counts.lock().unwrap().counting = on;
    }

    fn own_stream(&self) -> u64 {
        self.counts.lock().unwrap().own_stream
    }

    fn lagged(&self) -> u64 {
        self.counts.lock().unwrap().lagged
    }

    fn other_rows(&self) -> u64 {
        self.counts.lock().unwrap().other_rows
    }

    fn lag(&self) -> Option<Value> {
        self.counts.lock().unwrap().lag.clone()
    }

    /// Every byte received since the last call, which starts the count again.
    fn take_bytes(&self) -> u64 {
        std::mem::take(&mut self.counts.lock().unwrap().bytes)
    }
}

/// What one app-level watcher received.
#[derive(Default)]
struct WatchCounts {
    /// Every byte since `take_bytes`.
    bytes: u64,
    /// `_acpmux/session_changed` notices, and the `kind` of each.
    rows: Vec<String>,
    /// Of those, the ones whose `session` held more than its `sessionId` (a row).
    full_rows: u64,
    /// Each `session` an ids notice carried (the notice's other keys are checked as sent).
    sessions: Vec<Value>,
    harnesses: u64,
    /// `_acpmux/permission_pending` params.
    pending: Vec<Value>,
}

/// An app-level watcher, as the app's harness settings (`AcpmuxEnvironment+Harnesses.swift`) and
/// its permission feed bridge (`AcpmuxPermissionFeedBridge`) open one: the unix socket,
/// `initialize`, then `_acpmux/watch {enabled, limit: 1, rows}`. It draws no row.
struct Watcher {
    counts: Arc<Mutex<WatchCounts>>,
    _wr: tokio::net::unix::OwnedWriteHalf,
}

impl Watcher {
    async fn open(d: &Daemon, rows: Option<&str>) -> Self {
        let s = tokio::net::UnixStream::connect(&d.socket).await.expect("connect to daemon socket");
        let (rd, mut wr) = s.into_split();
        let counts = Arc::new(Mutex::new(WatchCounts::default()));
        let counted = counts.clone();
        let (watched_tx, watched) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(rd).lines();
            let mut watched_tx = Some(watched_tx);
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let mut c = counted.lock().unwrap();
                c.bytes += line.len() as u64 + 1;
                let params = v.get("params").unwrap_or(&Value::Null);
                match v.get("method").and_then(Value::as_str) {
                    Some("_acpmux/session_changed") => {
                        c.rows.push(params["kind"].as_str().unwrap_or("").to_owned());
                        let session = params.get("session").cloned().unwrap_or(Value::Null);
                        if session.as_object().is_some_and(|o| o.keys().any(|k| k != "sessionId")) {
                            c.full_rows += 1;
                        }
                        c.sessions.push(session);
                    }
                    Some("_acpmux/harnesses_changed") => c.harnesses += 1,
                    Some("_acpmux/permission_pending") => c.pending.push(params.clone()),
                    Some(_) => {}
                    None if v.get("id") == Some(&json!(2)) => {
                        assert!(v.get("error").is_none(), "the watch failed: {v}");
                        if let Some(tx) = watched_tx.take() {
                            let _ = tx.send(());
                        }
                    }
                    None => {}
                }
            }
        });
        let mut watch = json!({"enabled": true, "limit": 1});
        if let Some(rows) = rows {
            watch["rows"] = json!(rows);
        }
        for request in [
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1,
                "clientInfo": {"name": "cmux-next-feed-bridge", "version": "1"}, "clientCapabilities": {}}}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": watch}),
        ] {
            wr.write_all(format!("{request}\n").as_bytes()).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(30), watched)
            .await
            .expect("the watch answered in time")
            .unwrap();
        Self { counts, _wr: wr }
    }

    fn take_bytes(&self) -> u64 {
        std::mem::take(&mut self.counts.lock().unwrap().bytes)
    }
}

/// The `rows` modes of the bench's app-level watchers: `full` is the watch as it was (and as an
/// older app asks it), the before; `ids` and `none` the after.
const WATCH_MODES: [&str; 3] = ["full", "ids", "none"];

async fn new_chat(rpc: &mut Rpc, d: &Daemon, n: usize) -> String {
    let r = rpc
        .call(
            "session/new",
            json!({"cwd": d.home.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"name": format!("chat-{n}")}}}),
        )
        .await;
    r["sessionId"].as_str().unwrap().to_owned()
}

/// Every chat streams `ticks` chunks `tick_ms` apart at once; answers when every turn ended.
async fn stream_all(d: &Daemon, chats: &[String], ticks: usize, tick_ms: usize) {
    let mut turns = Vec::new();
    for chat in chats {
        let mut rpc = Rpc::connect(d).await;
        let chat = chat.clone();
        turns.push(tokio::spawn(async move {
            rpc.call(
                "session/prompt",
                json!({"sessionId": chat,
                "prompt": [{"type": "text", "text": format!("ticking:{ticks}:{tick_ms}")}]}),
            )
            .await;
        }));
    }
    for turn in turns {
        turn.await.unwrap();
    }
}

struct Report {
    seconds: f64,
    cpu_ms: Option<f64>,
    shown: BTreeMap<String, (u64, u64)>,
    hidden: BTreeMap<String, (u64, u64)>,
    /// Every pane's bytes over `idle_seconds` after the streams ended and settled (`IDLE_SETTLE`).
    idle_bytes: u64,
    idle_seconds: f64,
    /// The app-level watchers' bytes by `rows` mode: (while streaming, idle), summed over the
    /// mode's watchers.
    watchers: BTreeMap<&'static str, (u64, u64)>,
}

/// After the last turn ends, what its end still sends (usage reads, unread) before the idle arm.
const IDLE_SETTLE: Duration = Duration::from_secs(2);

fn total(m: &BTreeMap<String, (u64, u64)>) -> u64 {
    m.values().map(|(b, _)| b).sum()
}

fn as_rows(m: &BTreeMap<String, (u64, u64)>, seconds: f64) -> Vec<Value> {
    let mut rows: Vec<(&String, &(u64, u64))> = m.iter().collect();
    rows.sort_by_key(|row| std::cmp::Reverse(row.1.0));
    rows.into_iter()
        .map(|(k, (b, n))| json!({"kind": k, "bytesPerSec": (*b as f64 / seconds).round(), "messages": n}))
        .collect()
}

async fn measure(
    chats: usize,
    shown: usize,
    ticks: usize,
    tick_ms: usize,
    quiet: bool,
    idle: Duration,
    watchers: usize,
) -> Report {
    let d = Daemon::start("bench");
    let mut rpc = Rpc::connect(&d).await;
    let mut ids = Vec::new();
    for n in 0..chats {
        ids.push(new_chat(&mut rpc, &d, n).await);
    }
    // Warm every agent: the first turn starts it.
    stream_all(&d, &ids, 1, 0).await;
    let mut panes = Vec::new();
    for (n, id) in ids.iter().enumerate() {
        panes.push((n < shown, Pane::open(&d, id, n < shown, quiet).await));
    }
    let mut watches = Vec::new();
    for mode in WATCH_MODES {
        for _ in 0..watchers {
            watches.push((mode, Watcher::open(&d, Some(mode)).await));
        }
    }
    for (_, p) in &panes {
        p.counting(true);
    }
    for (_, w) in &watches {
        w.take_bytes();
    }
    let cpu0 = d.cpu();
    let t0 = Instant::now();
    stream_all(&d, &ids, ticks, tick_ms).await;
    // What the daemon queued by the turn's end reaches the panes.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let seconds = t0.elapsed().as_secs_f64();
    let cpu_ms = d.cpu().zip(cpu0).map(|(b, a)| (b - a).as_secs_f64() * 1000.0);
    let mut report = Report {
        seconds,
        cpu_ms,
        shown: BTreeMap::new(),
        hidden: BTreeMap::new(),
        idle_bytes: 0,
        idle_seconds: 0.0,
        watchers: BTreeMap::new(),
    };
    for (mode, w) in &watches {
        report.watchers.entry(*mode).or_default().0 += w.take_bytes();
    }
    for (visible, p) in &panes {
        p.counting(false);
        let into = if *visible { &mut report.shown } else { &mut report.hidden };
        for (k, (b, n)) in &p.counts.lock().unwrap().by_kind {
            let e = into.entry(k.clone()).or_default();
            e.0 += b;
            e.1 += n;
        }
    }
    // The idle arm: no chat streams, every pane stays open; what the daemon still sends them.
    tokio::time::sleep(IDLE_SETTLE).await;
    for (_, p) in &panes {
        p.take_bytes();
    }
    for (_, w) in &watches {
        w.take_bytes();
    }
    tokio::time::sleep(idle).await;
    report.idle_bytes = panes.iter().map(|(_, p)| p.take_bytes()).sum();
    for (mode, w) in &watches {
        report.watchers.entry(*mode).or_default().1 += w.take_bytes();
    }
    report.idle_seconds = idle.as_secs_f64();
    report
}

/// The bench: N chats streaming, S panes shown and the rest hidden. One `app-stream-bytes:` line,
/// then one `app-stream-bytes-kind:` line per kind and scope (a log may cut a long line).
#[tokio::test(flavor = "multi_thread")]
#[ignore = "bench: run by hand with --ignored --nocapture"]
async fn app_stream_bytes_bench() {
    let chats = env_usize("ACPMUX_BENCH_CHATS", 8);
    let shown = env_usize("ACPMUX_BENCH_SHOWN", 2).min(chats);
    let ticks = env_usize("ACPMUX_BENCH_TICKS", 400);
    let tick_ms = env_usize("ACPMUX_BENCH_TICK_MS", 10);
    let quiet = env_usize("ACPMUX_BENCH_QUIET", 1) == 1;
    let idle = Duration::from_secs(env_usize("ACPMUX_BENCH_IDLE_SECS", 5) as u64);
    let watchers = env_usize("ACPMUX_BENCH_WATCHERS", 5);
    let r = measure(chats, shown, ticks, tick_ms, quiet, idle, watchers).await;
    let s = r.seconds;
    let idle_per_min =
        (r.idle_seconds > 0.0).then(|| (r.idle_bytes as f64 * 60.0 / r.idle_seconds).round());
    let out = json!({
        "quietHidden": quiet, "chats": chats, "shown": shown, "ticks": ticks, "tickMs": tick_ms,
        "seconds": (s * 1000.0).round() / 1000.0,
        "totalBytesPerSec": ((total(&r.shown) + total(&r.hidden)) as f64 / s).round(),
        "shownBytesPerSec": (total(&r.shown) as f64 / s).round(),
        "hiddenBytesPerSec": (total(&r.hidden) as f64 / s).round(),
        "daemonCpuMsPerSec": r.cpu_ms.map(|ms| (ms / s * 10.0).round() / 10.0),
        "idleSeconds": r.idle_seconds,
        "idleBytesPerMin": idle_per_min,
    });
    println!("app-stream-bytes: {out}");
    // Per watcher of each mode: what one app-level watch receives while the chats stream, and a
    // minute of the idle arm.
    for (mode, (streaming, idle_bytes)) in &r.watchers {
        let per = watchers.max(1) as f64;
        println!(
            "app-stream-bytes-watcher: {}",
            json!({"rows": mode, "watchers": watchers,
                "bytesPerSecEach": (*streaming as f64 / per / s).round(),
                "idleBytesPerMinEach": (r.idle_seconds > 0.0)
                    .then(|| (*idle_bytes as f64 / per * 60.0 / r.idle_seconds).round())})
        );
    }
    for (scope, kinds) in [("shown", &r.shown), ("hidden", &r.hidden)] {
        for kind in as_rows(kinds, s) {
            println!(
                "app-stream-bytes-kind: {}",
                json!({"quietHidden": quiet, "scope": scope, "row": kind})
            );
        }
    }
}

/// One quiet hidden pane, one hidden pane of an older app (no `quietHidden`), one shown pane, each
/// on its own chat, every agent started.
async fn three_panes(d: &Daemon) -> (Vec<String>, Pane, Pane, Pane) {
    let mut rpc = Rpc::connect(d).await;
    let mut ids = Vec::new();
    for n in 0..3 {
        ids.push(new_chat(&mut rpc, d, n).await);
    }
    stream_all(d, &ids, 1, 0).await;
    let quiet = Pane::open(d, &ids[0], false, true).await;
    let older = Pane::open(d, &ids[1], false, false).await;
    let shown = Pane::open(d, &ids[2], true, true).await;
    (ids, quiet, older, shown)
}

/// Waits up to 2 s for `done`.
async fn until(done: impl Fn() -> bool) {
    until_for(100, done).await;
}

/// Waits up to `ticks` times 20 ms for `done`.
async fn until_for(ticks: usize, done: impl Fn() -> bool) {
    for _ in 0..ticks {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A pane that draws nothing while hidden hears none of its chat's stream until it is shown, then
/// one `_acpmux/lagged` naming the chat, and the stream again. A hidden pane that did not ask, and
/// a shown one, hear every record as before.
#[tokio::test(flavor = "multi_thread")]
async fn a_hidden_quiet_pane_hears_no_stream_until_shown_then_one_lag() {
    let d = Daemon::start("quiet");
    let (ids, mut quiet, older, shown) = three_panes(&d).await;
    stream_all(&d, &ids, 50, 0).await;
    until(|| older.own_stream() >= 50 && shown.own_stream() >= 50).await;
    let heard = (quiet.own_stream(), older.own_stream(), shown.own_stream());
    assert_eq!(heard.0, 0, "the hidden quiet pane heard its chat's stream: {heard:?}");
    assert!(heard.1 >= 50, "a hidden pane that did not ask hears the stream as before: {heard:?}");
    assert!(heard.2 >= 50, "the shown pane hears every record: {heard:?}");
    assert_eq!(quiet.lagged(), 0, "no lag notice while it stays hidden");
    // Shown: one lag notice for what it missed, and the stream again.
    quiet.view(true).await;
    until(|| quiet.lagged() > 0).await;
    assert_eq!(quiet.lagged(), 1, "one lag notice on show");
    stream_all(&d, &ids[..1], 20, 0).await;
    until(|| quiet.own_stream() >= 20).await;
    assert!(quiet.own_stream() >= 20, "a shown pane hears the stream again");
    // Hidden again: nothing more. Shown and hidden with nothing missed: no lag notice.
    quiet.view(false).await;
    let before = quiet.own_stream();
    stream_all(&d, &ids[..1], 20, 0).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(quiet.own_stream(), before, "hidden again, no stream");
    quiet.view(true).await;
    quiet.view(false).await;
    quiet.view(true).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(quiet.lagged(), 2, "one more lag for the second hide, none for an empty one");
}

/// A chat streams while its quiet pane is hidden: the pane hears none of its chunks, but its turn
/// records still move its cursor past them. Shown, the pane reads from where the show's lag notice
/// says (direct.ts `lagCursor`: the older of its cursor and the notice's `afterSeq`) and has every
/// chunk, in order. Before `afterSeq` it read from its cursor, after the last chunk, and the hidden
/// turn's text never came back (cmux#44453 review).
#[tokio::test(flavor = "multi_thread")]
async fn a_quiet_pane_shown_again_reads_back_every_chunk_it_missed_in_order() {
    let d = Daemon::start("quiet-read");
    let (ids, mut quiet, _older, _shown) = three_panes(&d).await;
    let start = quiet.attached_seq;
    stream_all(&d, &ids[..1], 50, 0).await;
    let truth = quiet.chunks_after(start).await;
    assert!(truth.len() >= 50, "the hidden turn's chunks: {}", truth.len());
    let last_chunk = *truth.last().unwrap();
    until(|| quiet.counts.lock().unwrap().cursor > last_chunk).await;
    let (heard, cursor) = {
        let c = quiet.counts.lock().unwrap();
        (c.chunks.clone(), c.cursor)
    };
    assert!(heard.is_empty(), "a hidden quiet pane hears no chunk: {heard:?}");
    assert!(
        cursor > last_chunk,
        "the turn's own records still went out and moved the cursor past the chunks: {cursor}"
    );
    quiet.view(true).await;
    until(|| quiet.lagged() > 0).await;
    let lag = quiet.counts.lock().unwrap().lag.clone().expect("a lag notice on show");
    let from = match lag.get("afterSeq").and_then(Value::as_u64) {
        Some(after) => cursor.min(after),
        None => cursor,
    };
    let mut got = quiet.chunks_after(from).await;
    got.extend(heard);
    got.sort_unstable();
    got.dedup();
    assert_eq!(got, truth, "every chunk it missed, in order (lag {lag}, cursor {cursor})");
}

/// Every pane watches every chat's row (`_acpmux/watch`), so each row change went to every pane,
/// shown or not (Leo's Mac, 2026-11-19: about 280 MB a minute from acpmux to the app, most of it
/// `session_changed` copies). A hidden quiet pane hears no other chat's row change; a hidden pane
/// that did not ask, and a shown one, hear each as before. Shown, the quiet pane gets one
/// `_acpmux/lagged {watch: true}` (read the list again from its cursor), then the rows again.
#[tokio::test(flavor = "multi_thread")]
async fn a_hidden_quiet_pane_hears_no_other_chats_rows_until_shown() {
    let d = Daemon::start("quiet-rows");
    let (ids, mut quiet, older, shown) = three_panes(&d).await;
    // Rows the opens themselves changed are told on the first show, not counted here.
    tokio::time::sleep(Duration::from_millis(300)).await;
    // Before its attach, the pane has no attachment to be hidden by: rows then reach it.
    let (quiet0, older0, shown0) = (quiet.other_rows(), older.other_rows(), shown.other_rows());
    stream_all(&d, &ids[1..], 5, 0).await;
    until(|| older.other_rows() > older0 && shown.other_rows() > shown0).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(quiet.other_rows(), quiet0, "a hidden quiet pane heard other chats' rows");
    assert!(older.other_rows() > older0, "a hidden pane that did not ask hears rows as before");
    assert!(shown.other_rows() > shown0, "a shown pane hears every row");
    assert_eq!(quiet.lagged(), 0, "no lag notice while it stays hidden");
    quiet.view(true).await;
    until(|| quiet.lagged() > 0).await;
    assert_eq!(quiet.lagged(), 1, "one lag notice on show");
    let lag = quiet.lag().expect("the show's lag notice");
    assert_eq!(lag["watch"], json!(true), "the lag says to read the list again: {lag}");
    assert_eq!(lag["reason"], json!("hidden"), "{lag}");
    assert!(lag["dropped"].as_u64().unwrap_or(0) > 0, "{lag}");
    // Shown: other chats' rows reach it again.
    stream_all(&d, &ids[1..2], 2, 0).await;
    until(|| quiet.other_rows() > quiet0).await;
    assert!(quiet.other_rows() > quiet0, "a shown pane hears other chats' rows again");
}

/// Nothing changes, nothing is sent: with every chat at rest, the panes the app keeps open (shown
/// and hidden) receive no byte at all. The target is under 1 MB a minute at idle; any periodic
/// frame (a heartbeat carrying state, a snapshot on a timer, a row re-sent unchanged) fails this.
#[tokio::test(flavor = "multi_thread")]
async fn idle_panes_are_sent_nothing() {
    let d = Daemon::start("idle");
    let (_ids, quiet, older, shown) = three_panes(&d).await;
    tokio::time::sleep(IDLE_SETTLE).await;
    let panes = [&quiet, &older, &shown];
    for p in panes {
        p.take_bytes();
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    let bytes: Vec<u64> = panes.iter().map(|p| p.take_bytes()).collect();
    assert_eq!(bytes, [0, 0, 0], "bytes sent to idle panes (quiet hidden, hidden, shown)");
}

/// The app's watchers that draw no row (the harness settings' `harnesses_changed` reader, the
/// permission feed bridge) heard every chat's whole row on every change, as the panes did. A watch
/// with `rows: "none"` hears no row change, one with `rows: "ids"` hears each with the chat's ids
/// and `kind` and no row, and both still hear `harnesses_changed` and `permission_pending`. A watch
/// that names no `rows` (an older app) hears the rows as before.
#[tokio::test(flavor = "multi_thread")]
async fn a_notice_only_watcher_hears_harnesses_and_permissions_but_no_row() {
    let d = Daemon::start_with("notice", "ask");
    let mut rpc = Rpc::connect(&d).await;
    let chat = new_chat(&mut rpc, &d, 0).await;
    let old = Watcher::open(&d, None).await;
    let full = Watcher::open(&d, Some("full")).await;
    let ids = Watcher::open(&d, Some("ids")).await;
    let none = Watcher::open(&d, Some("none")).await;
    let all = [&old, &full, &ids, &none];
    // A harness profile written: every watcher hears `harnesses_changed`.
    rpc.call("_acpmux/harness/add", json!({"id": "notice-probe", "command": "/bin/echo"})).await;
    until_for(1000, || all.iter().all(|w| w.counts.lock().unwrap().harnesses > 0)).await;
    for (name, w) in [("old", &old), ("full", &full), ("ids", &ids), ("none", &none)] {
        assert!(w.counts.lock().unwrap().harnesses > 0, "{name} heard no harnesses_changed");
    }
    // A prompt asks: every watcher hears `permission_pending` and the ask's row change.
    let mut turn_rpc = Rpc::connect(&d).await;
    let asked = chat.clone();
    let turn = tokio::spawn(async move {
        turn_rpc
            .call(
                "session/prompt",
                json!({"sessionId": asked, "prompt": [{"type": "text", "text": "ask: run it"}]}),
            )
            .await;
    });
    until_for(1000, || all.iter().all(|w| !w.counts.lock().unwrap().pending.is_empty())).await;
    for (name, w) in [("old", &old), ("full", &full), ("ids", &ids), ("none", &none)] {
        assert!(!w.counts.lock().unwrap().pending.is_empty(), "{name} heard no permission_pending");
    }
    let pending = ids.counts.lock().unwrap().pending[0].clone();
    assert_eq!(pending["sessionId"], json!(chat), "{pending}");
    assert!(pending["permissionId"].as_str().is_some(), "{pending}");
    // The ask's own row change (`permission_request`): what the feed bridge's withdraw keys on is
    // its kind and ids. The prompt is left unanswered: only the cmux app may allow it
    // (`permission.person_required`), and the daemon ends with the test.
    let decided =
        |w: &Watcher| w.counts.lock().unwrap().rows.iter().any(|k| k == "permission_request");
    until_for(1000, || decided(&old) && decided(&full) && decided(&ids)).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    turn.abort();
    // `full` and an older app's watch: rows as before.
    for (name, w) in [("old", &old), ("full", &full)] {
        let heard = decided(w);
        let c = w.counts.lock().unwrap();
        assert!(heard, "{name} heard no ask's row change: {:?}", c.rows);
        assert!(c.full_rows > 0, "{name} heard no row: {:?}", c.rows);
    }
    // `ids`: the same notices, the chat's id and kind only (what the feed bridge reads).
    {
        let heard = decided(&ids);
        let c = ids.counts.lock().unwrap();
        assert!(heard, "ids heard no ask's row change: {:?}", c.rows);
        assert_eq!(c.full_rows, 0, "an ids watcher heard a row: {:?}", c.sessions);
        assert!(
            c.sessions.iter().all(|s| s == &json!({"sessionId": chat})),
            "an ids notice's session is its id alone: {:?}",
            c.sessions
        );
    }
    // `none`: no row change at all.
    let c = none.counts.lock().unwrap();
    assert!(c.rows.is_empty(), "a rows: none watcher heard row changes: {:?}", c.rows);
}

/// A `rows` the daemon does not know is refused, not read as `full`.
#[tokio::test(flavor = "multi_thread")]
async fn a_watch_refuses_an_unknown_rows_mode() {
    let d = Daemon::start("rows-bad");
    let s = tokio::net::UnixStream::connect(&d.socket).await.unwrap();
    let (rd, mut wr) = s.into_split();
    let mut lines = tokio::io::BufReader::new(rd).lines();
    let request = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/watch",
        "params": {"enabled": true, "limit": 1, "rows": "some"}});
    wr.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            assert!(v.get("error").is_some(), "rows: some was accepted: {v}");
            return;
        }
    }
}
