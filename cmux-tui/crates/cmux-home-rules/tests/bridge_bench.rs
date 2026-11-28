//! The Swift<->Rust bridge's cost per call: `cmux_home_call` (cmux-app-ffi `src/home.rs`) runs
//! [`cmux_home_rules::call_json`] on the request bytes the app encodes. This measures bytes in and
//! out per call and wall time per call for the ops the app calls per conversation or per page
//! (`mapping.summary` once per listed conversation at an inbox snapshot, `mapping.conversationPage`
//! per open), at Leo scale (1,100 conversations, pages of 1,000 messages) and ten times that.
//!
//! The bench prints `BRIDGE-BENCH {json}` lines; run it with
//! `CMUX_STRESS=1 cargo test --release -p cmux-home-rules --test bridge_bench -- --nocapture`.
//! The always-on checks below are cheap: the bytes path answers what the `Value` path answers.

use std::time::{Duration, Instant};

use cmux_home_rules::{call, call_json};
use serde_json::{Value, json};

fn bench_selected() -> bool {
    std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1")
}

/// A small deterministic generator (no dev-dependency): xorshift64*.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
    fn text(&mut self, max: u64) -> String {
        const WORDS: &[&str] = &[
            "ship", "the", "fix", "café", "PR", "merged", "🚀", "build", "green", "\"q\"", "line\n",
        ];
        let n = self.below(max) + 1;
        (0..n).map(|_| WORDS[self.below(WORDS.len() as u64) as usize]).collect::<Vec<_>>().join(" ")
    }
}

fn participant(rng: &mut Rng, i: u64) -> Value {
    match rng.below(3) {
        0 => json!({"id": format!("p_{i}"), "kind": "human", "display_name": rng.text(2)}),
        1 => {
            json!({"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"})
        }
        _ => json!({"id": format!("agent_{i}"), "kind": "agent", "display_name": rng.text(2),
                    "agent_class": "codex", "acp_session": format!("s{i}")}),
    }
}

fn part(rng: &mut Rng) -> Value {
    match rng.below(6) {
        0 => json!({"type": "work", "session": format!("s{}", rng.below(99)), "status": "running"}),
        1 => json!({"type": "link_preview", "url": "https://example.com/a", "title": rng.text(4)}),
        2 => json!({"type": "widget", "kind": "pr", "fallback": rng.text(5)}),
        _ => json!({"type": "text", "text": rng.text(40)}),
    }
}

fn message(rng: &mut Rng, conversation: &str, seq: u64) -> Value {
    let mut m = json!({
        "id": format!("m{seq}"), "conversation": conversation, "seq": seq,
        "client_msg_id": format!("k{seq}"), "author": format!("p_{}", rng.below(4)),
        "parts": (0..rng.below(3) + 1).map(|_| part(rng)).collect::<Vec<_>>(),
        "created_at": "2026-11-25T20:16:00.000Z",
    });
    if rng.below(5) == 0 {
        m["reactions"] =
            json!([{"kind": {"emoji": "👍"}, "author": "p_1", "at": "2026-11-25T20:17:00.000Z"}]);
    }
    if rng.below(7) == 0 {
        m["thread_root"] = json!(format!("m{}", rng.below(seq.max(1))));
    }
    m
}

fn summary(rng: &mut Rng, i: u64) -> Value {
    let id = format!("c{i}");
    json!({
        "id": id, "title": rng.text(4),
        "participants": (0..rng.below(4) + 1).map(|p| participant(rng, p)).collect::<Vec<_>>(),
        "last_seq": i, "rev": i, "created_at": "2026-11-25T20:16:00.000Z",
        "updated_at": "2026-11-25T20:16:00.000Z", "last_message": message(rng, &id, i),
        "read_cursors": {"p_me": i}, "kind": if rng.below(4) == 0 { "group" } else { "direct" },
    })
}

fn page(rng: &mut Rng, messages: u64) -> Value {
    json!({
        "page": {
            "conversation": summary(rng, 1),
            "messages": (0..messages).map(|seq| message(rng, "c1", seq)).collect::<Vec<_>>(),
            "threads": (0..messages / 50).map(|t| json!({"root": format!("m{t}"), "reply_count": 3,
                "authors": ["p_1"]})).collect::<Vec<_>>(),
        },
        "chiefName": "Chief",
    })
}

/// The `Value` path `cmux_home_call` took: bytes to a `Value` tree, the op, the reply `Value` to bytes.
fn through_value(op: &str, bytes: &[u8]) -> Option<Vec<u8>> {
    let request: Value = serde_json::from_slice(bytes).ok().filter(Value::is_object)?;
    call(op, &request).ok().map(|reply| serde_json::to_vec(&reply).unwrap())
}

fn parsed(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).unwrap()
}

#[derive(Default)]
struct Samples(Vec<Duration>);

impl Samples {
    fn time<T>(&mut self, work: impl FnOnce() -> T) -> T {
        let at = Instant::now();
        let out = work();
        self.0.push(at.elapsed());
        out
    }
    fn pct(&self, p: f64) -> f64 {
        let mut v: Vec<Duration> = self.0.clone();
        v.sort();
        let at = ((v.len() as f64 - 1.0) * p).round() as usize;
        v[at].as_secs_f64() * 1e3
    }
    fn summary(&self) -> Value {
        json!({"p50_ms": self.pct(0.5), "p95_ms": self.pct(0.95), "n": self.0.len()})
    }
}

/// One way through the bridge: `Value` (the old path) or `bytes` ([`call_json`]).
fn run(path: &str, op: &str, bytes: &[u8]) -> Vec<u8> {
    match path {
        "value" => through_value(op, bytes).expect("value path answers"),
        _ => call_json(op, bytes).expect("bytes path answers"),
    }
}

#[test]
fn stress_bench_bridge_bytes_and_time_per_call() {
    if !bench_selected() {
        eprintln!("skipped: set CMUX_STRESS=1");
        return;
    }
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    for scale in [1u64, 10] {
        // An inbox snapshot: one `mapping.summary` per listed conversation.
        let conversations = 1_100 * scale;
        let requests: Vec<Vec<u8>> = (0..conversations)
            .map(|i| {
                serde_json::to_vec(&json!({"summary": summary(&mut rng, i), "chiefName": "Chief"}))
                    .unwrap()
            })
            .collect();
        let bytes_in: usize = requests.iter().map(Vec::len).sum();
        // A conversation's first page.
        let messages = 1_000 * scale;
        let page_request = serde_json::to_vec(&page(&mut rng, messages)).unwrap();
        for path in ["value", "bytes"] {
            let mut snapshot = Samples::default();
            let mut bytes_out = 0;
            for _ in 0..5 {
                bytes_out = snapshot
                    .time(|| requests.iter().map(|r| run(path, "mapping.summary", r).len()).sum());
            }
            let mut open = Samples::default();
            let mut page_out = 0;
            for _ in 0..5 {
                page_out = open.time(|| run(path, "mapping.conversationPage", &page_request).len());
            }
            println!(
                "BRIDGE-BENCH {}",
                json!({
                    "path": path, "scale": scale,
                    "snapshot": {"op": "mapping.summary", "calls": conversations,
                        "bytes_in": bytes_in, "bytes_out": bytes_out,
                        "bytes_per_call": (bytes_in + bytes_out) / conversations as usize,
                        "wall": snapshot.summary(),
                        "us_per_call": snapshot.pct(0.5) * 1e3 / conversations as f64},
                    "page": {"op": "mapping.conversationPage", "messages": messages,
                        "bytes_in": page_request.len(), "bytes_out": page_out,
                        "wall": open.summary(),
                        "us_per_message": open.pct(0.5) * 1e3 / messages as f64},
                })
            );
        }
    }
}

/// Model check: on random summaries and pages the bytes path answers the same JSON the `Value`
/// path answered (key order aside), and refuses what it refused.
#[test]
fn the_bytes_path_answers_what_the_value_path_answers() {
    let mut rng = Rng(7);
    for i in 0..300 {
        let request = serde_json::to_vec(&json!({"summary": summary(&mut rng, i)})).unwrap();
        let old = through_value("mapping.summary", &request).map(|b| parsed(&b));
        let new = call_json("mapping.summary", &request).ok().map(|b| parsed(&b));
        assert_eq!(old, new, "summary {i}");
    }
    for n in [0, 1, 7, 60] {
        let mut request = page(&mut rng, n);
        let bytes = serde_json::to_vec(&request).unwrap();
        for op in ["mapping.conversationPage", "mapping.historyPage"] {
            let old = through_value(op, &bytes).map(|b| parsed(&b));
            assert!(old.is_some(), "{op} {n}: {:?}", call(op, &parsed(&bytes)).err());
            assert_eq!(old, call_json(op, &bytes).ok().map(|b| parsed(&b)), "{op} {n}");
        }
        request["page"]["conversation"] = Value::Null;
        let bytes = serde_json::to_vec(&request).unwrap();
        assert_eq!(
            through_value("mapping.conversationPage", &bytes).is_some(),
            call_json("mapping.conversationPage", &bytes).is_ok()
        );
    }
}

/// Requests the `Value` path refused, the bytes path refuses too; ops off the fast path still answer.
#[test]
fn the_bytes_path_refuses_what_the_value_path_refused() {
    for bad in [&b""[..], b"[]", b"[{\"summary\": 1}]", b"null", b"{", b"{\"summary\": 3}", b"\xff"]
    {
        for op in ["mapping.summary", "mapping.conversationPage", "mapping.historyPage", "ops.list"]
        {
            assert_eq!(
                through_value(op, bad).is_some(),
                call_json(op, bad).is_ok(),
                "{op} {bad:?}"
            );
        }
    }
    let names = call_json("ops.list", b"{}").unwrap();
    assert_eq!(parsed(&names), parsed(&through_value("ops.list", b"{}").unwrap()));
    assert!(call_json("nope.op", b"{}").is_err());
}
