//! The phone apps' binding of the stream mirror replays every trace of
//! `schemas/ownership-mirror/vectors.json` (the real TypeScript
//! `ProjectionClient`'s): through the exported JSON-text surface, for each
//! input the frames to send and the view after it equal the TypeScript
//! client's. Swift and Kotlin call exactly these methods. The app observes
//! the view through the listener: after every input that changed the view
//! it is told once, with the view `view()` returns (its rows: every row, or
//! the rows written since the last view, applied here as the app does);
//! otherwise not at all.

use cmux_mobile_ffi::ownership::{
    OwnershipMirror, OwnershipMirrorError, OwnershipMirrorListener, OwnershipMirrorView,
};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// What the app's listener saw.
#[derive(Default)]
struct Seen(Mutex<Vec<OwnershipMirrorView>>);

impl OwnershipMirrorListener for Seen {
    fn on_change(&self, view: OwnershipMirrorView) {
        self.0.lock().unwrap().push(view);
    }
}

impl Seen {
    fn take(&self) -> Vec<OwnershipMirrorView> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}

/// The view without its generation: what a screen renders.
fn shown(view: &OwnershipMirrorView) -> OwnershipMirrorView {
    OwnershipMirrorView { generation: 0, ..view.clone() }
}

/// The app's rows after a told view: replaced by a full view, else the
/// written rows applied (`{table: {key: {key, n, row}}}`).
fn fold(rows: &mut Value, view: &OwnershipMirrorView) {
    if view.rows_full {
        *rows = parse(&view.rows_json);
        return;
    }
    assert!(view.rows_json.is_empty(), "a change view carries no full rows");
    for change in &view.rows_changed {
        let table = rows
            .as_object_mut()
            .expect("rows")
            .entry(change.table.clone())
            .or_insert_with(|| json!({}));
        let table = table.as_object_mut().expect("table");
        match &change.row_json {
            Some(row) => {
                let stored = json!({"key": change.key, "n": change.n, "row": parse(row)});
                table.insert(change.key.clone(), stored);
            }
            None => {
                table.remove(&change.key);
            }
        }
    }
}

/// A told view against `view()`: equal but for how the rows came.
fn same_view(told: &OwnershipMirrorView, rows: &Value, now: &OwnershipMirrorView) -> bool {
    let bare = |v: &OwnershipMirrorView| OwnershipMirrorView {
        rows_json: String::new(),
        rows_full: false,
        rows_changed: Vec::new(),
        ..v.clone()
    };
    bare(told) == bare(now) && same(rows, &parse(&now.rows_json))
}

fn vectors() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/ownership-mirror/vectors.json");
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&raw).expect("vectors JSON")
}

/// JSON equality where numbers compare by value (`1` equals `1.0`).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x == y || x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn parse(text: &str) -> Value {
    serde_json::from_str(text).expect("JSON text from the binding")
}

fn view_json(view: &OwnershipMirrorView) -> Value {
    let keys = |list: &[cmux_mobile_ffi::ownership::OwnershipIntent]| {
        Value::Array(list.iter().map(|i| json!(i.idempotency_key)).collect())
    };
    json!({
        "seq": view.seq,
        "state": parse(&view.state_json),
        "rows": parse(&view.rows_json),
        "pending": keys(&view.pending),
        "expired": keys(&view.expired),
        "awaiting": view.awaiting_snapshot,
        "connected": view.connected,
        "desyncs": view.desyncs,
    })
}

fn now(input: &Value) -> i64 {
    input["now"].as_i64().expect("now")
}

fn step(m: &OwnershipMirror, input: &Value) -> Vec<Value> {
    let sent = match input["t"].as_str().expect("input t") {
        "issue" => {
            let op = input["op"].as_str().expect("op").to_owned();
            match m.issue(op, input["params"].to_string(), "user".into(), now(input)) {
                Ok(issued) => issued.send,
                Err(OwnershipMirrorError::OwnerUnreachable) => {
                    return vec![json!({"error": "owner_unreachable"})];
                }
                Err(e) => panic!("issue: {e}"),
            }
        }
        "receive" => {
            let at = input["now"].as_i64().unwrap_or(0);
            m.receive(input["frame"].to_string(), at).expect("owner frame decodes").send
        }
        "disconnect" => {
            m.disconnect();
            Vec::new()
        }
        "reconnect" => m.reconnect(now(input)),
        "retry" => m.retry(input["key"].as_str().expect("key").to_owned(), now(input)),
        "expire" => {
            m.expire_stale(now(input));
            Vec::new()
        }
        other => panic!("unknown input {other}"),
    };
    sent.iter().map(|text| parse(text)).collect()
}

#[test]
fn the_binding_replays_every_trace_of_the_typescript_client() {
    let doc = vectors();
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20, "expected hand and simulated cases, got {}", cases.len());
    let mut steps = 0;
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let m = OwnershipMirror::new(
            case["key_prefix"].as_str().expect("key_prefix").to_owned(),
            case["initial"].to_string(),
        )
        .expect("initial JSON");
        let seen = Arc::new(Seen::default());
        let mut before = m.set_listener(Some(seen.clone()));
        assert_eq!(before, m.view(), "{name}: set_listener returns the view now");
        assert!(before.rows_full, "{name}: set_listener returns every row");
        let mut rows = parse(&before.rows_json);
        for (i, s) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let got = Value::Array(step(&m, &s["in"]));
            let now = m.view();
            let told = seen.take();
            if shown(&now) == shown(&before) {
                assert!(told.is_empty(), "{name} step {i}: told without a change: {told:?}");
                assert_eq!(now.generation, before.generation, "{name} step {i}");
            } else {
                assert_eq!(told.len(), 1, "{name} step {i}: the change, told once: {told:?}");
                fold(&mut rows, &told[0]);
                assert!(
                    same_view(&told[0], &rows, &now),
                    "{name} step {i}: told {:?} (rows {rows}), view {now:?}",
                    told[0]
                );
                assert_eq!(now.generation, before.generation + 1, "{name} step {i}");
            }
            before = now;
            let want: Vec<Value> = s["out"]
                .as_array()
                .expect("out")
                .iter()
                .map(|o| {
                    if o.get("error").is_some() { json!({"error": o["error"]}) } else { o.clone() }
                })
                .collect();
            assert!(
                same(&got, &Value::Array(want.clone())),
                "{name} step {i} ({}): sent {got:?}, TypeScript sent {want:?}",
                s["in"]["t"]
            );
            let mut after = s["after"].clone();
            for k in ["held", "settled_ok"] {
                after.as_object_mut().expect("after").remove(k);
            }
            let view = view_json(&m.view());
            assert!(
                same(&view, &after),
                "{name} step {i} ({}): binding {view:#}\nTypeScript {after:#}",
                s["in"]["t"]
            );
            steps += 1;
        }
    }
    assert!(steps > 500, "expected the simulated traces, got {steps} steps");
}

#[test]
fn bad_json_and_bad_origins_are_refused_not_panics() {
    let m = OwnershipMirror::new("c".into(), "{}".into()).expect("mirror");
    assert!(matches!(m.receive("{".into(), 1), Err(OwnershipMirrorError::Invalid { .. })));
    assert!(matches!(
        m.issue("message.send".into(), "{}".into(), "robot".into(), 1),
        Err(OwnershipMirrorError::Invalid { .. })
    ));
    m.disconnect();
    assert_eq!(
        m.issue("message.send".into(), "{}".into(), "user".into(), 1),
        Err(OwnershipMirrorError::OwnerUnreachable)
    );
}

/// One row write event of the stream at `seq`.
fn upsert(seq: u64, key: &str) -> String {
    json!({
        "t": "event", "stream": "s", "seq": seq, "tx": format!("tx{seq}"), "op": "put",
        "params": {}, "actor": {}, "origin": "user", "at": seq,
        "effects": {"state": {"seq": seq}, "writes": [
            {"table": "t", "op": "upsert", "key": key, "n": seq, "row": {"k": key}},
        ]},
    })
    .to_string()
}

fn snapshot_with_one_row() -> String {
    json!({
        "t": "snapshot", "stream": "s", "seq": 1, "state": {"seq": 1}, "decided": [],
        "rows": {"table": "t", "rows": [{"key": "r1", "n": 1, "row": {"k": "r1"}}]},
    })
    .to_string()
}

/// Checks what a listener was told: every view once, in generation order,
/// and its rows folded the way an app does equal `view()`'s.
fn told_in_order(m: &OwnershipMirror, first: &OwnershipMirrorView, told: &[OwnershipMirrorView]) {
    let generations: Vec<u64> = told.iter().map(|v| v.generation).collect();
    let want: Vec<u64> = (first.generation + 1..=first.generation + told.len() as u64).collect();
    assert_eq!(generations, want, "every view once, in generation order");
    let mut rows = parse(&first.rows_json);
    for view in told {
        fold(&mut rows, view);
    }
    assert!(same(&rows, &parse(&m.view().rows_json)), "folded rows {rows} differ from view()");
}

/// A listener that holds its first view until `go`, as a slow main-thread
/// render does, while another thread changes the mirror.
struct Held {
    told: Mutex<Vec<OwnershipMirrorView>>,
    entered: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    go: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl OwnershipMirrorListener for Held {
    fn on_change(&self, view: OwnershipMirrorView) {
        // Taken first: a guard held across the wait would block the other
        // thread's call into this listener.
        let entered = self.entered.lock().unwrap().take();
        if let Some(entered) = entered {
            entered.send(()).unwrap();
            self.go.lock().unwrap().recv().unwrap();
        }
        self.told.lock().unwrap().push(view);
    }
}

#[test]
fn views_reach_a_slow_listener_in_order_while_another_thread_changes_the_mirror() {
    let m = OwnershipMirror::new("c".into(), "{}".into()).unwrap();
    m.receive(snapshot_with_one_row(), 1).unwrap();
    let (entered_tx, entered) = std::sync::mpsc::channel();
    let (go, go_rx) = std::sync::mpsc::channel();
    let held = Arc::new(Held {
        told: Mutex::default(),
        entered: Mutex::new(Some(entered_tx)),
        go: Mutex::new(go_rx),
    });
    let first = m.set_listener(Some(held.clone()));
    let other = {
        let m = m.clone();
        std::thread::spawn(move || m.receive(upsert(2, "a"), 2).unwrap())
    };
    entered.recv().unwrap();
    // The listener still renders view 2; this call makes view 3.
    m.receive(upsert(3, "b"), 3).unwrap();
    go.send(()).unwrap();
    other.join().unwrap();
    told_in_order(&m, &first, &held.told.lock().unwrap());
}

/// A listener that calls the mirror back from its first view (an app that
/// applies a queued frame when it renders), then records the view.
#[derive(Default)]
struct Reentrant {
    mirror: Mutex<Option<Arc<OwnershipMirror>>>,
    told: Mutex<Vec<OwnershipMirrorView>>,
}

impl OwnershipMirrorListener for Reentrant {
    fn on_change(&self, view: OwnershipMirrorView) {
        let mirror = self.mirror.lock().unwrap().take();
        if let Some(m) = mirror {
            m.receive(upsert(3, "b"), 3).unwrap();
        }
        self.told.lock().unwrap().push(view);
    }
}

#[test]
fn a_listener_that_calls_the_mirror_back_is_told_in_order() {
    let m = OwnershipMirror::new("c".into(), "{}".into()).unwrap();
    m.receive(snapshot_with_one_row(), 1).unwrap();
    let listener = Arc::new(Reentrant::default());
    *listener.mirror.lock().unwrap() = Some(m.clone());
    let first = m.set_listener(Some(listener.clone()));
    m.receive(upsert(2, "a"), 2).unwrap();
    told_in_order(&m, &first, &listener.told.lock().unwrap());
}
