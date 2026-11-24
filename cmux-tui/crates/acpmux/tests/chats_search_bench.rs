//! The Cmd-K chats page's search, typed a key at a time on a 2,000-chat device (cmuxterm-hq goal
//! chat-history-search: at most 150 ms p95 per keystroke). Ignored by `cargo test`; the perf cron's
//! chat-search Linux part runs it:
//!
//!   cargo test --release -p acpmux --test chats_search_bench -- --ignored --nocapture
//!
//! `chats/text_scale_bench_tests.rs` times the text index alone on small chats at 1k to 500k
//! chats. This bench times what the page waits for, through the daemon's protocol, on stores the
//! size of real ones. The fixture copies the stores measured on a fleet host (2026-11-17, 440 real
//! chats): 54% Claude Code and 46% Codex, each chat's JSONL from a log-normal with median 1 MiB and
//! p95 about 8 MiB (at most 64 MiB), and about 3% of its bytes prompt and answer text; the rest is
//! tool output, which no search reads. 2,000 chats come to about 4.4 GB.
//! `CHAT_SEARCH_BENCH_CHATS` and `CHAT_SEARCH_BENCH_MIB` shrink it for a local run.
//!
//! Each query is a three-word phrase that is in one planted chat only, in an answer in the middle
//! of its history; the planted chats are spread from the newest to the oldest. The bench types
//! each phrase a key at a time into the page's window, `_acpmux/chats_window {window, gen, query,
//! content: true, limit: 200, topLevel, untitled, count}` as the Cmd-K chats page asks for it, and times each key from the request to the window's first rows for
//! that `gen` (`_acpmux/chats_window_changed`, `full: true`). On a phrase's last key it waits
//! until a message for that `gen` holds the planted chat, at most [`MISS_MS`]; a phrase whose
//! chat never comes counts each of its keys as [`MISS_MS`], so a search that cannot find a chat
//! by what was said reads as a number, not as nothing.
//!
//! Before typing, it times the text index's fill: from the daemon's start until the window's
//! message no longer says `filling` (`chat_search.fill`, report-only). The same keys of one phrase also go
//! to `_acpmux/chats_search`, the scan the CLI uses (`chat_search.scan_keystroke`, report-only; a
//! `partial` answer is a miss).
//!
//! Its lines, beside the human ones: `PERF_ROW {"name":"chat_search.keystroke",...}` and the two
//! report-only rows; the cron stores them as `webui.chat_search.*`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent; it keeps only its own size knobs.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["CHAT_SEARCH_BENCH_CHATS", "CHAT_SEARCH_BENCH_MIB"]);

use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, UNIX_EPOCH};
use tokio::sync::mpsc;

/// A keystroke of a phrase that is not found counts as this many ms; it is also the longest the
/// bench waits for a phrase's chat.
const MISS_MS: f64 = 10_000.0;
/// The goal's budget per keystroke.
const TARGET_MS: f64 = 150.0;
/// The longest the bench waits for the text index to fill.
const FILL_WAIT: Duration = Duration::from_secs(600);
const PHRASES: usize = 8;
const MEDIAN_BYTES: f64 = 1024.0 * 1024.0;
/// ln(8) / 1.645: p95 at 8x the median.
const SIGMA: f64 = 1.264;
const MAX_BYTES: f64 = 64.0 * 1024.0 * 1024.0;
/// One turn's prompt and answer text, and the tool output beside it: text is about 3% of a turn.
const PROMPT_WORDS: usize = 30;
const ANSWER_WORDS: usize = 120;
const TOOL_BYTES: usize = 30_000;
const VOCABULARY: usize = 20_000;
const WINDOW_CHANGED: &str = "_acpmux/chats_window_changed";
/// 2026-11-01T00:00:00Z, the fixture's first day, in Unix seconds.
const NOV_1_2026_S: u64 = 1_793_491_200;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// xorshift64*: the same fixture on every run, with no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn normal(&mut self) -> f64 {
        let (u, v) = (self.unit().max(f64::MIN_POSITIVE), self.unit());
        (-2.0 * u.ln()).sqrt() * (std::f64::consts::TAU * v).cos()
    }

    /// A Zipf-like index into the vocabulary: a few words are in nearly every chat, most are rare.
    fn zipf(&mut self, n: usize) -> usize {
        ((n as f64).powf(self.unit()) as usize).saturating_sub(1).min(n - 1)
    }
}

fn vocabulary(rng: &mut Rng) -> Vec<String> {
    const ON: [&str; 16] =
        ["b", "c", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z", "h"];
    const NU: [&str; 6] = ["a", "e", "i", "o", "u", "ai"];
    (0..VOCABULARY)
        .map(|_| {
            let syllables = 1 + (rng.next() % 4) as usize;
            (0..syllables)
                .map(|_| {
                    format!("{}{}", ON[(rng.next() % 16) as usize], NU[(rng.next() % 6) as usize])
                })
                .collect()
        })
        .collect()
}

fn sentence(rng: &mut Rng, words: &[String], count: usize) -> String {
    let mut out = String::new();
    for i in 0..count {
        if i > 0 {
            out.push(' ');
        }
        out.push_str(&words[rng.zipf(words.len())]);
    }
    out
}

/// The phrase planted in the n-th planted chat: words no other chat holds, in no vocabulary word.
fn phrase(n: usize) -> String {
    const PLANTED: [&str; PHRASES] = [
        "quorvax thrennel 7731",
        "wexmund plyratic jorvane",
        "zubrik halcyonde 4419",
        "fennowick sardaxis quell",
        "trowbaine oxyllan vetch",
        "mirquade 2207 calloweth",
        "jusperin draxholm yewt",
        "orvelline kestrix 9058",
    ];
    PLANTED[n].to_owned()
}

struct Chat {
    key: String,
    planted: Option<String>,
}

/// One chat's store, `bytes` long, with `planted` in an answer halfway through.
fn write_chat(
    h: &Path,
    n: usize,
    bytes: usize,
    planted: Option<&str>,
    rng: &mut Rng,
    words: &[String],
) -> String {
    let codex = n % 100 >= 54;
    let id = format!("{:08x}-0000-4000-8000-{:012x}", n, n);
    let project = h.join(format!("work/p{}", n % 40));
    let path = if codex {
        h.join(format!(
            ".codex/sessions/2026/11/{:02}/rollout-2026-11-{:02}T10-00-00-{id}.jsonl",
            1 + n % 28,
            1 + n % 28
        ))
    } else {
        h.join(format!(".claude/projects/-work-p{}/{id}.jsonl", n % 40))
    };
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
    let mut out = BufWriter::new(std::fs::File::create(&path).expect("store"));
    let turns = (bytes / (TOOL_BYTES + 1_200)).max(2);
    let tool = "x".repeat(TOOL_BYTES);
    // Chat n was last active 20 minutes before chat n - 1, and its turns fit in those 20 minutes, so
    // the page lists the chats in order, newest first, over 28 days (past 2,016 chats they tie).
    let minute = |turn: usize| (28 * 1440 - 1usize).saturating_sub(n * 20) + turn * 19 / turns;
    let at = |turn: usize| {
        let minute = minute(turn);
        format!(
            "2026-11-{:02}T{:02}:{:02}:00.000Z",
            1 + minute / 1440,
            (minute / 60) % 24,
            minute % 60
        )
    };
    if codex {
        let meta = json!({"type": "session_meta", "payload": {"id": id, "cwd": project, "timestamp": at(0)}});
        writeln!(out, "{meta}").expect("write");
    }
    for turn in 0..turns {
        let prompt = sentence(rng, words, PROMPT_WORDS);
        let mut answer = sentence(rng, words, ANSWER_WORDS);
        if turn == turns / 2
            && let Some(planted) = planted
        {
            answer = format!("{answer} {planted} {}", sentence(rng, words, 20));
        }
        let lines = if codex {
            vec![
                json!({"type": "event_msg", "timestamp": at(turn), "payload": {"type": "user_message", "message": prompt}}),
                json!({"type": "response_item", "timestamp": at(turn), "payload": {"type": "function_call_output", "call_id": format!("c{turn}"), "output": tool}}),
                json!({"type": "event_msg", "timestamp": at(turn), "payload": {"type": "agent_message", "message": answer}}),
            ]
        } else {
            let line = |kind: &str, content: Value| {
                json!({"type": kind, "isSidechain": false, "cwd": project, "sessionId": id,
                       "timestamp": at(turn), "message": {"role": kind, "content": content}})
            };
            vec![
                line("user", json!(prompt)),
                line(
                    "assistant",
                    json!([{"type": "tool_use", "id": format!("t{turn}"), "name": "Bash", "input": {}}]),
                ),
                line(
                    "user",
                    json!([{"type": "tool_result", "tool_use_id": format!("t{turn}"), "content": tool}]),
                ),
                line("assistant", json!([{"type": "text", "text": answer}])),
            ]
        };
        for line in lines {
            writeln!(out, "{line}").expect("write");
        }
    }
    out.flush().expect("flush");
    // The chat index stamps a chat by its file's mtime (cmux-chat-index `stamp.rs`): the store's mtime is
    // its last turn's time, so the index's newest-first order is the fixture's, not the order of writing.
    let last = NOV_1_2026_S + 60 * minute(turns - 1) as u64;
    let file = out.into_inner().expect("store");
    file.set_modified(UNIX_EPOCH + Duration::from_secs(last)).expect("mtime");
    if codex { format!("codex:{id}") } else { format!("claude-code:{id}") }
}

fn fixture(h: &Path, chats: usize, scale: f64) -> Vec<Chat> {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let words = vocabulary(&mut rng);
    // Planted chats spread from the newest to the oldest.
    let planted_at: Vec<usize> =
        (0..PHRASES).map(|i| (i * 2 + 1) * chats / (PHRASES * 2)).collect();
    (0..chats)
        .map(|n| {
            let bytes = (MEDIAN_BYTES * (SIGMA * rng.normal()).exp()).min(MAX_BYTES) * scale;
            let planted = planted_at.iter().position(|&at| at == n).map(phrase);
            let key = write_chat(h, n, bytes as usize, planted.as_deref(), &mut rng, &words);
            Chat { key, planted }
        })
        .collect()
}

async fn hub_on(h: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({"harnesses": {}})).expect("config");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(cfg, store);
    let sources = ChatSources {
        home: h.to_path_buf(),
        acpmux_home: h.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    hub.start_chats(sources).await.expect("chat index");
    hub
}

/// One local connection: requests in order, and the notifications that came meanwhile, kept.
struct Conn {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    id: i64,
    notes: VecDeque<Value>,
}

impl Conn {
    async fn open(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut conn = Self { tx, rx, id: 0, notes: VecDeque::new() };
        conn.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "bench"}}),
        )
        .await;
        conn
    }

    async fn recv(&mut self, until: Instant) -> Option<Value> {
        let left = until.saturating_duration_since(Instant::now());
        let line = tokio::time::timeout(left, self.rx.recv()).await.ok()?.expect("connection open");
        Some(serde_json::from_str(&line).expect("json"))
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.id += 1;
        self.tx.send(Message::request(self.id, m, params).to_line()).await.expect("send");
        let until = Instant::now() + Duration::from_secs(60);
        loop {
            let v = self.recv(until).await.unwrap_or_else(|| panic!("{m}: no answer in 60 s"));
            if v.get("id") == Some(&json!(self.id)) {
                return v;
            }
            if v.get("method").is_some() {
                self.notes.push_back(v);
            }
        }
    }

    /// The window's next message for `generation`, kept or still to come, before `until`.
    async fn window_message(&mut self, generation: u64, until: Instant) -> Option<Value> {
        loop {
            let v = match self.notes.pop_front() {
                Some(v) => v,
                None => self.recv(until).await?,
            };
            let params = &v["params"];
            if v["method"] == WINDOW_CHANGED && params["gen"] == json!(generation) {
                return Some(params.clone());
            }
        }
    }
}

/// The keys a window message shows.
fn shown(params: &Value) -> Vec<&str> {
    params["keys"].as_array().into_iter().flatten().filter_map(Value::as_str).collect()
}

/// The Cmd-K chats page's window spec for `query`, at generation `generation`
/// (AgentChatsPalettePage.answers). The page also sends the person's choice history, which a new
/// device does not have yet.
fn window(generation: u64, query: &str) -> Value {
    json!({"window": "bench", "gen": generation, "query": query, "content": true, "limit": 200,
        "topLevel": true, "untitled": "New chat", "count": true})
}

/// Types `phrase` a key at a time into the page's window: each key's ms to the window's first
/// rows, and whether the finished phrase found `key` within [`MISS_MS`] (every key is
/// [`MISS_MS`] when it did not).
async fn type_into_window(
    conn: &mut Conn,
    generation: &mut u64,
    phrase: &str,
    key: &str,
) -> (Vec<f64>, bool) {
    let mut times = Vec::new();
    let mut found = false;
    for end in phrase.char_indices().map(|(i, c)| i + c.len_utf8()) {
        // Every key counts, a space too: it adds no word, but the page still asks again and waits.
        let query = &phrase[..end];
        *generation += 1;
        let started = Instant::now();
        let answer = conn.call("_acpmux/chats_window", window(*generation, query)).await;
        assert!(answer.get("error").is_none(), "{query:?}: {answer}");
        let until = started + Duration::from_millis(MISS_MS as u64);
        let first = conn.window_message(*generation, until).await;
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        times.push(if first.is_some() { ms } else { MISS_MS });
        if end == phrase.len() {
            let mut message = first;
            while let Some(params) = message {
                if shown(&params).contains(&key) {
                    found = true;
                    break;
                }
                message = conn.window_message(*generation, until).await;
            }
        }
    }
    if !found {
        times.iter_mut().for_each(|t| *t = MISS_MS);
    }
    (times, found)
}

/// Types `phrase` into `_acpmux/chats_search` (the scan): each key's ms, [`MISS_MS`] for a partial
/// answer, and every key [`MISS_MS`] when the finished phrase did not find `key`.
async fn type_into_scan(conn: &mut Conn, phrase: &str, key: &str) -> (Vec<f64>, bool) {
    let mut times = Vec::new();
    let mut found = false;
    for end in phrase.char_indices().map(|(i, c)| i + c.len_utf8()) {
        let query = &phrase[..end];
        let started = Instant::now();
        let answer = conn
            .call("_acpmux/chats_search", json!({"query": query, "limit": 50, "budgetMs": 10_000}))
            .await;
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        assert!(answer.get("error").is_none(), "{query:?}: {answer}");
        let result = &answer["result"];
        let partial = result["partial"].as_bool().unwrap_or(false);
        if end == phrase.len() {
            let hits = result["hits"].as_array().into_iter().flatten();
            found =
                !partial && hits.filter_map(|hit| hit["chat"]["key"].as_str()).any(|k| k == key);
        }
        times.push(if partial { MISS_MS } else { ms });
    }
    if !found {
        times.iter_mut().for_each(|t| *t = MISS_MS);
    }
    (times, found)
}

fn nearest_rank(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1]
}

fn row(name: &str, mut times: Vec<f64>, found: usize, phrases: usize) {
    times.sort_by(f64::total_cmp);
    let (p50, p95) = (nearest_rank(&times, 0.5), nearest_rank(&times, 0.95));
    println!(
        "{name}: {} keystrokes, {found}/{phrases} phrases found, p50 {p50:.1} ms, p95 {p95:.1} ms",
        times.len()
    );
    let line = json!({"name": name, "p50": p50, "p95": p95, "unit": "ms", "target": TARGET_MS});
    println!("PERF_ROW {line}");
}

fn env_number(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a benchmark: the perf cron's chat-search part runs it"]
async fn the_chats_page_finds_a_chat_by_what_was_said_within_150_ms_a_keystroke() {
    let chats = env_number("CHAT_SEARCH_BENCH_CHATS", 2_000.0) as usize;
    let scale = env_number("CHAT_SEARCH_BENCH_MIB", 1.0);
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume, where no chat
    // root is listed (tests/chats_search.rs).
    let base = PathBuf::from("/tmp").join(format!("acpmux-search-bench-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).expect("home");
    let h = Home(std::fs::canonicalize(&base).expect("canonical home"));

    let started = Instant::now();
    let fixture = fixture(&h.0, chats, scale);
    let bytes: u64 = walk_bytes(&h.0);
    println!(
        "fixture: {chats} chats, {:.0} MB, written in {:.1} s",
        bytes as f64 / 1e6,
        started.elapsed().as_secs_f64()
    );
    let planted: Vec<(&str, &str)> =
        fixture.iter().filter_map(|c| c.planted.as_deref().map(|p| (p, c.key.as_str()))).collect();

    // The fill: from the daemon's start until the window's message no longer says `filling`; the
    // oldest planted chat must show by then.
    let started = Instant::now();
    let hub = hub_on(&h.0).await;
    let mut conn = Conn::open(&hub).await;
    let mut generation = 0;
    let (oldest, oldest_key) = *planted.last().expect("planted chats");
    generation += 1;
    conn.call("_acpmux/chats_window", window(generation, oldest)).await;
    let until = started + FILL_WAIT;
    let mut filled = None;
    while let Some(params) = conn.window_message(generation, until).await {
        if params["filling"] != json!(true) {
            filled = Some((started.elapsed(), shown(&params).contains(&oldest_key)));
            break;
        }
    }
    match filled {
        Some((took, seen)) => {
            let seen = if seen {
                "the oldest planted chat found"
            } else {
                "the oldest planted chat NOT found"
            };
            println!("fill: done {:.1} s after the daemon's start, {seen}", took.as_secs_f64());
            let ms = took.as_secs_f64() * 1000.0;
            println!(
                "PERF_ROW {}",
                json!({"name": "chat_search.fill", "p50": ms, "p95": ms, "unit": "ms"})
            );
        }
        None => println!("fill: still filling after {} s", FILL_WAIT.as_secs()),
    }

    let (mut times, mut found) = (Vec::new(), 0);
    for (phrase, key) in &planted {
        let (t, hit) = type_into_window(&mut conn, &mut generation, phrase, key).await;
        println!("  {phrase:?}: {}", if hit { "found" } else { "not found" });
        times.extend(t);
        found += usize::from(hit);
    }
    row("chat_search.keystroke", times, found, planted.len());

    // The scan, report-only: one phrase, at the scan's longest budget.
    let (phrase, key) = planted[planted.len() / 2];
    let (t, hit) = type_into_scan(&mut conn, phrase, key).await;
    row("chat_search.scan_keystroke", t, usize::from(hit), 1);
}

fn walk_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => walk_bytes(&e.path()),
            _ => e.metadata().map_or(0, |m| m.len()),
        })
        .sum()
}
