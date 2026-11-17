//! Stress harness for the shared Rust under the phone's lists: the
//! `cmux.wire/1` stream mirror (`cmux_mobile_core::wire::StreamMirror`), its
//! phone binding (`OwnershipMirror`, what Swift and Kotlin call per frame) and
//! the conversation reducer and Home list projection (`cmux-conversation`).
//!
//! Each case builds a stream at 1x and at scale (10 / 500 / 5000 workspace
//! rows, 100 / 100k message rows), then times one interaction many times:
//! a single-row change (a workspace rename) and a streaming message append.
//! The rule is constant cost as the list grows (object-sync DESIGN.md, "One
//! change, one event ... No client diffs whole lists"): the scale p95 must
//! stay within [`RATIO`] of the 1x p95 (plus [`SLACK_US`] for timer noise),
//! so a cost that grows with the list fails here. Cold loads (snapshot
//! decode, load and encode) are O(rows) by nature; they are checked per row,
//! so only a superlinear load fails.
//!
//! Run: `cargo test -p cmux-mobile-ffi --test list_stress -- --nocapture`
//! (prints an N | p50 | p95 table per case).

use cmux_conversation::{HomeInboxInput, Op, OpRequest, Part, Summary};
use cmux_mobile_core::wire::StreamMirror;
use cmux_mobile_ffi::ownership::{OwnershipMirror, OwnershipMirrorListener, OwnershipMirrorView};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Scale p95 may be at most this many times the 1x p95.
const RATIO: f64 = 3.0;
/// Absolute allowance on top of the ratio: scheduler and timer noise on a
/// shared runner, far below any O(rows) cost at 5000 rows.
const SLACK_US: f64 = 100.0;

const WORKSPACES: [usize; 3] = [10, 500, 5000];
const MESSAGES: [usize; 2] = [100, 100_000];
const STREAM: &str = "host:h/session";

#[derive(Clone, Copy)]
struct Stats {
    n: usize,
    p50: f64,
    p95: f64,
}

/// Runs `f` `rounds` times after a short warm-up; microseconds.
fn measure(n: usize, rounds: usize, mut f: impl FnMut(usize)) -> Stats {
    for i in 0..rounds.min(8) {
        f(i);
    }
    let mut samples: Vec<Duration> = (0..rounds)
        .map(|i| {
            let start = Instant::now();
            f(rounds.min(8) + i);
            start.elapsed()
        })
        .collect();
    samples.sort();
    let at = |q: f64| {
        let index = ((samples.len() as f64 * q).ceil() as usize).saturating_sub(1);
        samples[index.min(samples.len() - 1)].as_secs_f64() * 1e6
    };
    Stats { n, p50: at(0.50), p95: at(0.95) }
}

fn table(case: &str, rows: &[Stats]) {
    println!("\n{case}\n  N        | p50 us      | p95 us");
    for s in rows {
        println!("  {:<8} | {:>11.1} | {:>11.1}", s.n, s.p50, s.p95);
    }
}

/// Fails when the largest N's p95 grew past the bound of the smallest's.
fn assert_constant(case: &str, rows: &[Stats]) {
    table(case, rows);
    let (small, large) = (rows[0], rows[rows.len() - 1]);
    let bound = small.p95 * RATIO + SLACK_US;
    assert!(
        large.p95 <= bound,
        "{case}: p95 at N={} is {:.1} us, over {RATIO}x the p95 at N={} ({:.1} us) + {SLACK_US} us \
         = {bound:.1} us: the cost grows with the list",
        large.n,
        large.p95,
        small.n,
        small.p95,
    );
}

/// Per-row cost of an O(rows) step must not grow either (no superlinear load).
fn assert_per_row(case: &str, rows: &[Stats]) {
    table(case, rows);
    let per_row: Vec<f64> = rows.iter().map(|s| s.p95 / s.n as f64).collect();
    let (small, large) = (rows.len() - 2, rows.len() - 1);
    // The smallest N is dominated by fixed cost; compare the two largest.
    let bound = per_row[small] * RATIO + SLACK_US / rows[large].n as f64;
    assert!(
        per_row[large] <= bound,
        "{case}: per-row p95 at N={} is {:.3} us, over {RATIO}x the per-row p95 at N={} ({:.3} us)",
        rows[large].n,
        per_row[large],
        rows[small].n,
        per_row[small],
    );
}

fn workspace_row(i: usize, title: &str) -> Value {
    json!({
        "id": format!("ws_{i:06}"),
        "title": title,
        "order_key": format!("a{i:06}"),
        "status": "idle",
        "tabs": 3,
        "rev": 1,
    })
}

fn message_row(i: usize) -> Value {
    json!({
        "id": format!("msg_{i:07}"),
        "author": if i % 2 == 0 { "user_local" } else { "agent_chief" },
        "text": format!("message {i}: a line of streamed agent text that is about this long"),
        "created_at": "2026-11-17T10:00:00.000Z",
    })
}

fn snapshot(
    table: &str,
    rows: impl Iterator<Item = (String, Option<i64>, Value)>,
    seq: u64,
) -> Value {
    let rows: Vec<Value> =
        rows.map(|(key, n, row)| json!({"key": key, "n": n, "row": row})).collect();
    json!({
        "t": "snapshot",
        "stream": STREAM,
        "seq": seq,
        "state": {"name": "session"},
        "decided": [],
        "rows": {"table": table, "rows": rows},
    })
}

fn workspace_snapshot(n: usize) -> Value {
    snapshot(
        "workspace",
        (0..n).map(|i| (format!("ws_{i:06}"), Some(i as i64), workspace_row(i, "workspace"))),
        1,
    )
}

fn message_snapshot(n: usize) -> Value {
    snapshot("msg", (1..=n).map(|i| (format!("msg_{i:07}"), Some(i as i64), message_row(i))), 1)
}

fn event(seq: u64, writes: Value) -> String {
    json!({
        "t": "event",
        "stream": STREAM,
        "seq": seq,
        "tx": format!("tx-{seq}"),
        "op": "put",
        "params": {},
        "actor": {"identity": "u", "install": "i"},
        "origin": "user",
        "at": seq,
        "effects": {"state": {"name": "session"}, "writes": writes},
    })
    .to_string()
}

/// A rename of one workspace in the middle of the list.
fn rename(n: usize, seq: u64) -> String {
    let i = n / 2;
    let row = workspace_row(i, &format!("renamed {seq}"));
    event(
        seq,
        json!([{"table": "workspace", "op": "upsert", "key": format!("ws_{i:06}"), "n": i, "row": row}]),
    )
}

/// The next message of a streaming reply.
fn append(seq: u64, index: usize) -> String {
    event(
        seq,
        json!([{"table": "msg", "op": "upsert", "key": format!("msg_{index:07}"), "n": index, "row": message_row(index)}]),
    )
}

// --- The engine (cmux_mobile_core::wire::StreamMirror) ---------------------

fn core_mirror(snap: &Value) -> StreamMirror {
    let mut mirror = StreamMirror::new("p", json!({}));
    let received = mirror.receive_value(snap.clone(), 0);
    assert_eq!(received.applied.len(), 1, "the snapshot applies");
    mirror
}

#[test]
fn engine_single_row_change_costs_the_same_at_5000_workspaces() {
    let rows: Vec<Stats> = WORKSPACES
        .iter()
        .map(|&n| {
            let mut mirror = core_mirror(&workspace_snapshot(n));
            let mut seq = 1;
            measure(n, 400, |_| {
                seq += 1;
                let frame: Value = serde_json::from_str(&rename(n, seq)).unwrap();
                let received = mirror.receive_value(frame, 0);
                assert_eq!(received.applied.len(), 1);
            })
        })
        .collect();
    assert_constant("engine: decode + apply one workspace rename", &rows);
}

#[test]
fn engine_message_append_costs_the_same_at_100k_messages() {
    let rows: Vec<Stats> = MESSAGES
        .iter()
        .map(|&n| {
            let mut mirror = core_mirror(&message_snapshot(n));
            let mut seq = 1;
            measure(n, 400, |_| {
                seq += 1;
                let index = n + seq as usize;
                let frame: Value = serde_json::from_str(&append(seq, index)).unwrap();
                let received = mirror.receive_value(frame, 0);
                assert_eq!(received.applied.len(), 1);
            })
        })
        .collect();
    assert_constant("engine: decode + apply one streamed message", &rows);
}

#[test]
fn engine_snapshot_decode_load_and_encode_stay_linear() {
    let sizes = [10, 500, 5000, 100_000];
    let mut decode = Vec::new();
    let mut encode = Vec::new();
    for n in sizes {
        let text = message_snapshot(n).to_string();
        let rounds = if n >= 100_000 { 5 } else { 30 };
        decode.push(measure(n, rounds, |_| {
            let mut mirror = StreamMirror::new("p", json!({}));
            let frame: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(mirror.receive_value(frame, 0).applied.len(), 1);
        }));
        let mirror = core_mirror(&serde_json::from_str(&text).unwrap());
        encode.push(measure(n, rounds, |_| {
            assert!(!mirror.rows().dump().to_string().is_empty());
        }));
    }
    assert_per_row("engine: snapshot decode + load (cold list)", &decode);
    assert_per_row("engine: rows encode (whole list as JSON)", &encode);
}

#[test]
fn engine_survives_a_burst_of_10k_changes_and_a_gap_at_5000_workspaces() {
    // Degenerate: a burst far past the gap buffer, then a resync.
    let n = 5000;
    let mut mirror = core_mirror(&workspace_snapshot(n));
    let start = Instant::now();
    for seq in 2..10_002u64 {
        let frame: Value = serde_json::from_str(&rename(n, seq)).unwrap();
        mirror.receive_value(frame, 0);
    }
    let burst = start.elapsed();
    // A gap: the mirror buffers and asks for a snapshot, which closes it.
    let frame: Value = serde_json::from_str(&rename(n, 10_005)).unwrap();
    let received = mirror.receive_value(frame, 0);
    assert!(mirror.is_awaiting_snapshot() && !received.send.is_empty());
    let mut snap = workspace_snapshot(n);
    snap["seq"] = json!(10_004);
    mirror.receive_value(snap, 0);
    assert_eq!(mirror.seq(), 10_005, "the buffered event applies after the snapshot");
    assert_eq!(mirror.rows().table("workspace").count(), n);
    println!("\nengine: 10k renames at 5000 workspaces in {burst:?}");
    assert!(burst < Duration::from_secs(5), "10k single-row events took {burst:?}");
}

// --- The phone binding (OwnershipMirror with a listener) ---------------------

/// A listener like the app's: counts the views it was told about.
#[derive(Default)]
struct Told(AtomicU64);

impl OwnershipMirrorListener for Told {
    fn on_change(&self, _view: OwnershipMirrorView) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

fn phone_mirror(snap: &Value) -> (Arc<OwnershipMirror>, Arc<Told>) {
    let mirror = OwnershipMirror::new("p".into(), "{}".into()).unwrap();
    let told = Arc::new(Told::default());
    mirror.set_listener(Some(told.clone()));
    assert_eq!(mirror.receive(snap.to_string(), 0).unwrap().applied, 1);
    (mirror, told)
}

#[test]
fn phone_single_row_change_costs_the_same_at_5000_workspaces() {
    let rows: Vec<Stats> = WORKSPACES
        .iter()
        .map(|&n| {
            let (mirror, told) = phone_mirror(&workspace_snapshot(n));
            let mut seq = 1;
            let stats = measure(n, 200, |_| {
                seq += 1;
                assert_eq!(mirror.receive(rename(n, seq), 0).unwrap().applied, 1);
            });
            assert!(told.0.load(Ordering::Relaxed) > 200, "every rename is told");
            stats
        })
        .collect();
    assert_constant("phone binding: receive one workspace rename (listener set)", &rows);
}

#[test]
fn phone_message_append_costs_the_same_at_100k_messages() {
    let rows: Vec<Stats> = MESSAGES
        .iter()
        .map(|&n| {
            let (mirror, told) = phone_mirror(&message_snapshot(n));
            let mut seq = 1;
            let rounds = if n >= 100_000 { 40 } else { 200 };
            let stats = measure(n, rounds, |_| {
                seq += 1;
                let index = n + seq as usize;
                assert_eq!(mirror.receive(append(seq, index), 0).unwrap().applied, 1);
            });
            assert!(told.0.load(Ordering::Relaxed) > rounds as u64, "every append is told");
            stats
        })
        .collect();
    assert_constant("phone binding: receive one streamed message (listener set)", &rows);
}

// --- The conversation reducer and the Home list -----------------------------

fn participants() -> Value {
    json!([
        {"id": "user_local", "kind": "human", "display_name": "Me"},
        {"id": "agent_chief", "kind": "agent", "display_name": "Chief"},
    ])
}

#[test]
fn reducer_message_send_costs_the_same_at_100k_messages() {
    let rows: Vec<Stats> = MESSAGES
        .iter()
        .map(|&n| {
            let mut head: cmux_conversation::ConversationHead = serde_json::from_value(json!({
                "id": "c1", "title": "", "participants": participants(),
                "last_seq": n, "rev": n + 1,
                "created_at": "2026-11-17T10:00:00.000Z", "updated_at": "2026-11-17T10:00:00.000Z",
                "read_cursors": {"user_local": n},
            }))
            .unwrap();
            measure(n, 400, |i| {
                let key = format!("k{i:08}");
                let op = Op::MessageSend {
                    client_msg_id: key.clone(),
                    parts: vec![Part::Text { text: format!("reply {i}"), runs: None }],
                    reply_to: None,
                    answers: Vec::new(),
                    answers_pending: Vec::new(),
                    thread_root: None,
                };
                let id = format!("m{i}");
                let request = OpRequest {
                    actor: "user_local",
                    idempotency_key: &key,
                    op: &op,
                    now: "2026-11-17T10:00:01.000Z",
                    new_message_id: &id,
                    target: None,
                    reply_target: None,
                    thread_target: None,
                    last_message: None,
                };
                head = cmux_conversation::apply(&head, &request).expect("send").head;
            })
        })
        .collect();
    assert_constant("reducer: message.send", &rows);
}

fn summaries(n: usize) -> Vec<Summary> {
    (0..n)
        .map(|i| {
            serde_json::from_value(json!({
                "id": format!("c{i:06}"), "owner": "local", "title": format!("channel {i}"),
                "participants": participants(), "last_seq": 5, "rev": 6,
                "created_at": "2026-11-17T10:00:00.000Z",
                "updated_at": format!("2026-11-17T10:{:02}:{:02}.000Z", (i / 60) % 60, i % 60),
                "read_cursors": {"user_local": 3},
            }))
            .unwrap()
        })
        .collect()
}

/// The Home (conversation) list is a whole-list projection: one changed
/// conversation re-projects and re-sorts every row (`home-inbox` answers the
/// whole list). It is O(rows) per change today; this checks it stays linear
/// and prints the cost the constant-cost rule would remove.
#[test]
fn home_list_rebuild_after_one_change_stays_linear() {
    let rows: Vec<Stats> = [10, 500, 5000]
        .iter()
        .map(|&n| {
            let mut list = summaries(n);
            let input = HomeInboxInput { me: "user_local", ..HomeInboxInput::default() };
            measure(n, 60, |i| {
                let at = n / 2;
                list[at].updated_at = format!("2026-11-18T00:00:{:02}.{:03}Z", i % 60, i % 1000);
                let home = cmux_conversation::home_inbox(&list, &input);
                assert_eq!(home.len(), n);
            })
        })
        .collect();
    assert_per_row("home list: re-project after one conversation changed", &rows);
}
