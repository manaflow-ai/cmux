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
//! `ACPMUX_BENCH_QUIET=0` attaches as a pane before `quietHidden`, the before of the same build).
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
        let home = std::env::temp_dir().join(format!("asb-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("work")).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": "approve-all"})
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
    /// The last `_acpmux/lagged` notice's params.
    lag: Option<Value>,
    /// The page's cursor (direct.ts `lastSeq`): the newest seq of its own chat's records it heard.
    cursor: u64,
    /// The seqs of its own chat's `agent_message_chunk` records it heard.
    chunks: Vec<u64>,
    /// Other chats' row changes it heard (`_acpmux/session_changed`, `_acpmux/session_patch`).
    other_rows: u64,
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
                    if !of_own
                        && (method == "_acpmux/session_changed"
                            || method == "_acpmux/session_patch")
                    {
                        c.other_rows += 1;
                    }
                    if method == "_acpmux/lagged" {
                        c.lagged += 1;
                        c.lag = Some(params.clone());
                    }
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
}

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
}

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

async fn measure(chats: usize, shown: usize, ticks: usize, tick_ms: usize, quiet: bool) -> Report {
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
    for (_, p) in &panes {
        p.counting(true);
    }
    let cpu0 = d.cpu();
    let t0 = Instant::now();
    stream_all(&d, &ids, ticks, tick_ms).await;
    // What the daemon queued by the turn's end reaches the panes.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let seconds = t0.elapsed().as_secs_f64();
    let cpu_ms = d.cpu().zip(cpu0).map(|(b, a)| (b - a).as_secs_f64() * 1000.0);
    let mut report = Report { seconds, cpu_ms, shown: BTreeMap::new(), hidden: BTreeMap::new() };
    for (visible, p) in &panes {
        p.counting(false);
        let into = if *visible { &mut report.shown } else { &mut report.hidden };
        for (k, (b, n)) in &p.counts.lock().unwrap().by_kind {
            let e = into.entry(k.clone()).or_default();
            e.0 += b;
            e.1 += n;
        }
    }
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
    let r = measure(chats, shown, ticks, tick_ms, quiet).await;
    let s = r.seconds;
    let out = json!({
        "quietHidden": quiet, "chats": chats, "shown": shown, "ticks": ticks, "tickMs": tick_ms,
        "seconds": (s * 1000.0).round() / 1000.0,
        "totalBytesPerSec": ((total(&r.shown) + total(&r.hidden)) as f64 / s).round(),
        "shownBytesPerSec": (total(&r.shown) as f64 / s).round(),
        "hiddenBytesPerSec": (total(&r.hidden) as f64 / s).round(),
        "daemonCpuMsPerSec": r.cpu_ms.map(|ms| (ms / s * 10.0).round() / 10.0),
    });
    println!("app-stream-bytes: {out}");
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
    for _ in 0..100 {
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

/// A pane whose every chat is hidden from it, and draws nothing then, hears no other chat's row
/// change: the app holds every list notice from a page out of sight (`AcpmuxPaneShedding`), so
/// they crossed the socket for nothing (205 kB/s, 8 chats streaming, 6 hidden). Shown, it hears one
/// `_acpmux/lagged` with `watch: true` (direct.ts reads the list and its asks again), then the
/// rows again. A hidden pane that did not ask, and a shown one, hear every row as before.
#[tokio::test(flavor = "multi_thread")]
async fn a_hidden_quiet_pane_hears_no_other_chats_rows_until_shown_then_one_watch_lag() {
    let d = Daemon::start("quiet-rows");
    let (ids, mut quiet, older, shown) = three_panes(&d).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let before = (quiet.other_rows(), quiet.lagged());
    stream_all(&d, &ids[1..], 30, 0).await;
    until(|| older.other_rows() > 0 && shown.other_rows() > 0).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let heard = (quiet.other_rows() - before.0, older.other_rows(), shown.other_rows());
    assert_eq!(heard.0, 0, "the hidden quiet pane heard other chats' rows: {heard:?}");
    assert!(heard.1 > 0, "a hidden pane that did not ask hears rows as before: {heard:?}");
    assert!(heard.2 > 0, "the shown pane hears every row: {heard:?}");
    assert_eq!(quiet.lagged(), before.1, "no lag notice while it stays hidden");
    quiet.view(true).await;
    until(|| quiet.lagged() > before.1).await;
    assert_eq!(quiet.lagged(), before.1 + 1, "one lag notice on show");
    let lag = quiet.counts.lock().unwrap().lag.clone().expect("a lag notice on show");
    assert_eq!(lag["watch"], json!(true), "the page reads the list again: {lag}");
    assert_eq!(lag["reason"], json!("hidden"), "{lag}");
    let shown_rows = quiet.other_rows();
    stream_all(&d, &ids[1..2], 10, 0).await;
    until(|| quiet.other_rows() > shown_rows).await;
    assert!(quiet.other_rows() > shown_rows, "a shown pane hears other chats' rows again");
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
