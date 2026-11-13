//! PR4's release gates use the shared small/god shapes and the real Unix stream
//! driver. Run alone: cargo test -p acpmux --release --test v2_connection -- --ignored --nocapture --test-threads=1
#![cfg(target_os = "linux")]

use acpmux_book::index::{Summary, SummaryIndex};
use acpmux_core::conn::{self, ConnectionState, HubSource, Offer};
use acpmux_core::hub::Hub;
use acpmux_core::wire::{
    self, Credit, Cursor, DeltaFrame, DeltaOp, Frame, FrameKind, ReplayMark, Window,
};
use serde_json::json;
use std::collections::BTreeMap;
use std::io::Write as _;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::watch;

#[path = "../benches/v2/mod.rs"]
#[allow(dead_code)]
mod home;

async fn request(w: &mut (impl AsyncWrite + Unpin), value: serde_json::Value) {
    w.write_all(&Frame::json(FrameKind::Request, &value).unwrap().encode()).await.unwrap();
}
async fn receive(r: &mut (impl AsyncRead + Unpin)) -> Frame {
    tokio::time::timeout(Duration::from_secs(30), async {
        let mut header = [0; 4];
        r.read_exact(&mut header).await.unwrap();
        let length = u32::from_be_bytes(header) as usize;
        assert!(length < wire::MAX_FRAME_BYTES);
        let mut bytes = header.to_vec();
        bytes.resize(length + 4, 0);
        r.read_exact(bytes.get_mut(4..).unwrap()).await.unwrap();
        Frame::from_encoded(&bytes).unwrap()
    })
    .await
    .unwrap()
}
async fn hello(client: &mut UnixStream) {
    request(client, json!({"method":"hello","params":{"clientKind":"test","protocol":2}})).await;
    assert_eq!(receive(client).await.kind, FrameKind::Hello);
}
async fn sub(client: &mut UnixStream, sid: &str, cursor: Option<u64>) {
    request(client, json!({"method":"sub","params":{"sid":sid,"stream":"list","cursor":cursor,"edition":0,"window":100}})).await;
}
async fn credit(client: &mut (impl AsyncWrite + Unpin), sid: &str, consumed: u64) {
    request(client, json!({"method":"credit","params":{"sid":sid,"consumed":consumed}})).await;
}
fn memory_kib(field: &str) -> usize {
    std::fs::read_to_string("/proc/self/status")
        .unwrap()
        .lines()
        .find_map(|line| {
            line.strip_prefix(field)
                .and_then(|s| s.split_whitespace().next())
                .and_then(|s| s.parse::<usize>().ok())
        })
        .unwrap()
        * 1024
}
fn summary(id: usize, version: u64) -> Summary {
    let mut row = Summary::new(format!("chat-{id:05}"));
    row.title = "bounded summary ".repeat(15);
    row.harness = "codex".into();
    row.state = "running".into();
    row.last_activity = version;
    row.extra = serde_json::value::RawValue::from_string(
        serde_json::to_string(&json!({"text":"x".repeat(480)})).unwrap(),
    )
    .unwrap();
    row
}
#[derive(Clone, Default, Debug, PartialEq)]
struct View {
    rows: BTreeMap<String, u64>,
    cursor: u64,
    consumed: u64,
    replaying: bool,
    windows: usize,
}
impl View {
    fn apply(&mut self, frame: &Frame) {
        self.consumed += frame.encoded_len() as u64;
        match frame.kind {
            FrameKind::Window => {
                let window: Window<Summary> = frame.decode_json().unwrap();
                assert!(window.cursor >= self.cursor);
                self.rows = window.rows.into_iter().map(|s| (s.chat_id, s.last_activity)).collect();
                self.cursor = window.cursor;
                self.replaying = false;
                self.windows += 1;
            }
            FrameKind::Delta => {
                let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
                assert!(!self.replaying || delta.replay.is_some(), "live before resume end");
                for op in delta.ops {
                    match op {
                        DeltaOp::Summary { seq, summary } => {
                            assert_eq!(seq, self.cursor + 1, "lost or repeated record");
                            self.cursor = seq;
                            self.rows.insert(summary.chat_id, summary.last_activity);
                        }
                        DeltaOp::Gone { seq, chat_id } => {
                            assert_eq!(seq, self.cursor + 1);
                            self.cursor = seq;
                            self.rows.remove(&chat_id);
                        }
                        _ => panic!("unexpected op"),
                    }
                }
                self.replaying = delta.replay == Some(ReplayMark::Replay);
            }
            FrameKind::Error => {
                panic!("unexpected Error: {:?}", frame.decode_json::<serde_json::Value>())
            }
            _ => panic!("unexpected {:?}", frame.kind),
        }
    }
}
fn pair(
    hub: Arc<Hub>,
) -> (UnixStream, Arc<HubSource>, tokio::task::JoinHandle<Result<(), conn::ConnError>>) {
    let (client, server) = UnixStream::pair().unwrap();
    let source = Arc::new(HubSource::new(hub));
    let driver = source.clone();
    let task = tokio::spawn(async move {
        let (rd, wr) = server.into_split();
        conn::run(rd, wr, driver, "pr4-gate", &["list".into()]).await
    });
    (client, source, task)
}
async fn caught_up(rx: &mut watch::Receiver<u64>, target: u64) {
    tokio::time::timeout(Duration::from_secs(30), async {
        while *rx.borrow_and_update() < target {
            rx.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct Stopped {
    rss_rise: usize,
    retained: usize,
    peak_queue: usize,
    peak_outside: usize,
    drops: usize,
}
async fn stopped(shape: acpmux::god_fixture::Shape, dishonest_credit: bool) -> Stopped {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    // The complete shared list shape is present before measuring the connection.
    let rows = shape.chats + shape.peers * shape.peer_rows;
    for id in 0..rows {
        writer.apply(summary(id, id as u64)).unwrap();
    }
    // Warm the source's bounded history before measuring subscriber memory.
    for n in 0..2048 {
        writer.apply(summary(0, 1_000_000 + n)).unwrap();
    }
    let hub = Arc::new(hub);
    let (mut slow, source, driver) = pair(hub.clone());
    let (mut fast, fast_source, fast_driver) = pair(hub.clone());
    hello(&mut slow).await;
    hello(&mut fast).await;
    sub(&mut slow, "slow", None).await;
    let mut view = View::default();
    view.apply(&receive(&mut slow).await);
    let mut other = View::default();
    if dishonest_credit {
        sub(&mut slow, "other", None).await;
        other.apply(&receive(&mut slow).await);
    }
    sub(&mut fast, "fast", None).await;
    let mut fast_view = View::default();
    fast_view.apply(&receive(&mut fast).await);
    let shared_view = Arc::new(Mutex::new(fast_view.clone()));
    let output_view = shared_view.clone();
    let (advanced, mut progress) = watch::channel(fast_view.cursor);
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let fast_reader = tokio::spawn(async move {
        let (mut rd, mut wr) = fast.into_split();
        let mut credited = 0;
        let mut stopped = std::pin::pin!(stopped);
        loop {
            let frame = tokio::select! {
                frame = receive(&mut rd) => frame,
                _ = &mut stopped => break,
            };
            let (consumed, cursor) = {
                let mut view = output_view.lock().unwrap();
                view.apply(&frame);
                (view.consumed, view.cursor)
            };
            if consumed - credited >= wire::CREDIT_WINDOW_BYTES / 4 {
                credit(&mut wr, "fast", consumed).await;
                credited = consumed;
            }
            advanced.send_replace(cursor);
        }
    });
    let metrics = source.connection_metrics().unwrap();
    let baseline = memory_kib("VmRSS:");
    let mut result = Stopped { rss_rise: 0, retained: 0, peak_queue: 0, peak_outside: 0, drops: 0 };
    let mut bytes = 0_u64;
    let mut iteration = 0_u64;
    let mut target = view.cursor;
    let mut send_credit = dishonest_credit;
    while bytes < shape.connection_change_bytes() {
        for _ in 0..128 {
            let row = summary(0, 2_000_000 + iteration);
            bytes += row.encoded_len() as u64;
            target = writer.apply(row).unwrap().seq;
            iteration += 1;
        }
        caught_up(&mut progress, target).await;
        if send_credit {
            // Deliberately lying: no reads on this socket after its initial windows.
            credit(&mut slow, "slow", u64::MAX).await;
            if metrics.notices() != 0 {
                send_credit = false;
            }
        }
        result.retained = result.retained.max(source.not_fed_bytes());
        result.rss_rise = result.rss_rise.max(memory_kib("VmHWM:").saturating_sub(baseline));
        result.peak_queue = result.peak_queue.max(metrics.queued_bytes());
        result.peak_outside = result.peak_outside.max(metrics.outside_budget_bytes());
        assert!(metrics.queued_bytes() <= wire::CONNECTION_BUDGET_BYTES);
        assert!(metrics.notices() <= wire::MAX_SUBSCRIPTIONS);
        assert_eq!(source.not_fed_bytes(), 0);
    }
    // Resume the honest reader by consuming queued frames and sending real credit.
    // The dishonest one must first drain its old generation's dropped notice.
    credit(&mut slow, "slow", view.consumed).await;
    if dishonest_credit {
        credit(&mut slow, "other", other.consumed).await;
    }
    let mut credited = BTreeMap::<String, u64>::new();
    while view.cursor < target || (dishonest_credit && (result.drops == 0 || other.cursor < target))
    {
        let frame = receive(&mut slow).await;
        let payload: serde_json::Value = frame.decode_json().unwrap();
        let sid = payload.get("sid").and_then(|s| s.as_str()).unwrap().to_owned();
        if frame.kind == FrameKind::Error {
            // A credit already in flight when a drop happened is correlated and harmless.
            assert_eq!(payload.get("code"), Some(&json!("unknown_sid")));
            continue;
        }
        if frame.kind == FrameKind::Dropped {
            assert_eq!(sid, "slow");
            result.drops += 1;
            let dropped: wire::Dropped = frame.decode_json().unwrap();
            assert_eq!(dropped.cursor, Some(Cursor(view.cursor)));
            sub(&mut slow, "slow", Some(view.cursor)).await;
            view.consumed = 0;
            view.replaying = true;
            credited.insert(sid, 0);
            continue;
        }
        let current = if sid == "slow" {
            &mut view
        } else {
            assert_eq!(sid, "other");
            &mut other
        };
        current.apply(&frame);
        let last = credited.entry(sid.clone()).or_default();
        if current.consumed - *last >= wire::CREDIT_WINDOW_BYTES / 4 {
            credit(&mut slow, &sid, current.consumed).await;
            *last = current.consumed;
        }
    }
    let expected = shared_view.lock().unwrap().clone();
    assert_eq!(view.rows, expected.rows);
    assert_eq!(view.cursor, expected.cursor);
    if dishonest_credit {
        assert_eq!(result.drops, 1);
        assert_eq!(other.rows, expected.rows);
        assert_eq!(other.cursor, target);
    } else {
        assert!(result.rss_rise < wire::CONNECTION_BUDGET_BYTES, "{result:?}");
    }
    drop(slow);
    driver.await.unwrap().unwrap();
    stop.send(()).unwrap();
    fast_reader.await.unwrap();
    fast_driver.await.unwrap().unwrap();
    assert_eq!(source.task_count(), 0);
    assert_eq!(fast_source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
    println!(
        "stopped {} dishonest={dishonest_credit} bytes={bytes} records={iteration} {result:?}",
        shape.name
    );
    result
}
fn report(name: &str, small: f64, god: f64, unit: &str) {
    let line = json!({"name":name,"small_p95":small,"god_p95":god,"unit":unit});
    println!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut out = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(out, "{line}").unwrap();
    }
}

// Each case runs in a fresh process, so the kernel RSS high-water mark covers
// every allocation of this connection, without a preceding fixture's allocator.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "child entry point for the stopped-reader gate"]
async fn v2_pr04_stopped_worker() {
    let Ok(case) = std::env::var("V2_PR04_CASE") else { return };
    let shape = if case.starts_with("god") { home::god() } else { home::small() };
    let result = stopped(shape, case.ends_with("credit")).await;
    println!("PR4_STOPPED {}", serde_json::to_string(&result).unwrap());
}
fn stopped_worker(case: &str) -> Stopped {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "v2_pr04_stopped_worker", "--ignored", "--nocapture", "--test-threads=1"])
        .env("V2_PR04_CASE", case)
        .output()
        .unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    print!("{stdout}");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let result = stdout.lines().find_map(|line| line.strip_prefix("PR4_STOPPED ")).unwrap();
    serde_json::from_str(result).unwrap()
}
#[test]
#[ignore = "release Unix socket/RSS gate; run once through cmux-ci"]
fn v2_pr04_stopped_readers() {
    let small = stopped_worker("small-honest");
    let god = stopped_worker("god-honest");
    report("v2.pr04.byte_credit_drop_resume", small.rss_rise as f64, god.rss_rise as f64, "bytes");
    report("v2.pr04.not_fed_bytes", small.retained as f64, god.retained as f64, "bytes");
    let small = stopped_worker("small-credit");
    let god = stopped_worker("god-credit");
    report("v2.pr04.credit_without_read_drop", small.drops as f64, god.drops as f64, "notices");
}

fn percentile(mut values: Vec<u64>) -> u64 {
    values.sort_unstable();
    *values.get((values.len() * 95 / 100).min(values.len() - 1)).unwrap()
}
fn offer_round(subscriptions: usize) -> Vec<u64> {
    let mut state = ConnectionState::default();
    for i in 0..subscriptions {
        state.subscribe(format!("sid-{i}"), Cursor(0)).unwrap();
    }
    let mut values = Vec::new();
    for n in 0..20_000 {
        let frame = Frame::json(FrameKind::Delta, &json!({"sid":"sid-0","ops":[]})).unwrap();
        let start = Instant::now();
        let result = state.offer("sid-0", std::hint::black_box(frame), Cursor(n));
        let elapsed = start.elapsed().as_nanos() as u64;
        assert_eq!(result, Offer::Taken);
        let lease = state.take().unwrap();
        state.written(&lease);
        state.credit(Credit { sid: "sid-0".into(), consumed: u64::MAX }).unwrap();
        if n >= 1000 {
            values.push(elapsed);
        }
    }
    values
}
#[test]
#[ignore = "release offer timing gate; run once through cmux-ci"]
fn v2_pr04_offer_256_subscriptions() {
    let mut small = Vec::new();
    let mut god = Vec::new();
    for _ in 0..5 {
        small.push(offer_round(1));
        god.push(offer_round(wire::MAX_SUBSCRIPTIONS));
    }
    let small_best = small.iter().map(|s| percentile(s.clone())).min().unwrap();
    let god_best = god.iter().map(|s| percentile(s.clone())).min().unwrap();
    let god_all = percentile(god.into_iter().flatten().collect());
    println!("offer small_best={small_best}ns god_best={god_best}ns god_all_p95={god_all}ns");
    report("v2.pr04.offer_256_subscriptions", small_best as f64, god_best as f64, "ns");
    assert!(god_best as f64 <= small_best as f64 * 1.2);
    assert!(god_all as f64 <= small_best as f64 * 2.0);
}

async fn resume_marks(shape: acpmux::god_fixture::Shape) -> usize {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for id in 0..shape.chats + shape.peers * shape.peer_rows {
        writer.apply(summary(id, id as u64)).unwrap();
    }
    let hub = Arc::new(hub);
    let cursor = hub.snapshot().seq();
    let (mut client, source, task) = pair(hub.clone());
    hello(&mut client).await;
    sub(&mut client, "caught-up", Some(cursor)).await;
    let frame = receive(&mut client).await;
    let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
    assert_eq!(frame.kind, FrameKind::Delta);
    assert_eq!(delta.replay, Some(ReplayMark::End));
    assert!(delta.ops.is_empty());
    request(&mut client, json!({"method":"unsub","params":{"sid":"caught-up"}})).await;
    for n in 0..128 {
        writer.apply(summary(0, 1_000_000 + n)).unwrap();
    }
    sub(&mut client, "resume", Some(cursor)).await;
    let first = receive(&mut client).await;
    let first_delta: DeltaFrame<Summary> = first.decode_json().unwrap();
    assert!(first_delta.replay.is_some());
    // Publish while the old resume is still arriving on the same connection.
    let final_seq = writer.apply(summary(0, 2_000_000)).unwrap().seq;
    let mut view = View { cursor, replaying: true, ..View::default() };
    view.apply(&first);
    while view.cursor < final_seq {
        view.apply(&receive(&mut client).await);
    }
    assert!(!view.replaying);
    drop(client);
    task.await.unwrap().unwrap();
    assert_eq!(source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
    1 // exactly one empty end frame for the caught-up resume
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "release resume-order gate; run once through cmux-ci"]
async fn v2_pr04_list_resume_end() {
    let small = resume_marks(home::small()).await;
    let god = resume_marks(home::god()).await;
    report("v2.pr04.list_resume_end", small as f64, god as f64, "frames");
}
