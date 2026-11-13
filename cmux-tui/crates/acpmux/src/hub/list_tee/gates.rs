//! Linux release measurements for the list tee. These are ignored by default: they are the
//! actual 20/11k workloads used by the v2 registry, rather than unit-test fixtures or estimates.

use super::*;
use acpmux_book::index::SummaryIndex;
use acpmux_client::wire::{ListKey, ListView, Page, PageResult, PageSide, Sub, Window};
use acpmux_core::hub::Hub as CoreHub;
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn p95(values: &[u128]) -> u128 {
    let mut values = values.to_vec();
    values.sort_unstable();
    values[((values.len() * 95).div_ceil(100)).saturating_sub(1)]
}

fn measures(rounds: &[Vec<u128>]) -> (u128, u128) {
    let best = rounds.iter().map(|round| p95(round)).min().unwrap_or(0);
    let all = {
        let values: Vec<_> = rounds.iter().flat_map(|round| round.iter().copied()).collect();
        p95(&values)
    };
    (best, all)
}

fn emit(
    name: &str,
    small_rounds: &[Vec<u128>],
    god_rounds: &[Vec<u128>],
    unit: &str,
) -> (u128, u128, u128) {
    let (small_p95, _) = measures(small_rounds);
    let (god_p95, god_p95_all) = measures(god_rounds);
    let line = json!({
        "name": name,
        "small_p95": small_p95,
        "god_p95": god_p95,
        "god_p95_all": god_p95_all,
        "unit": unit,
    })
    .to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
    (small_p95, god_p95, god_p95_all)
}

/// Print the measured line first (so a red release run still has evidence), then enforce the
/// registry's ratio and all-sample bounds with integer arithmetic.
fn assert_bounds(name: &str, measures: (u128, u128, u128), all_limit_percent: Option<u128>) {
    let (small, god, god_all) = measures;
    assert!(small > 0, "{name}: small p95 is zero");
    assert!(
        god.saturating_mul(100) <= small.saturating_mul(120),
        "{name}: best p95 ratio exceeds 1.2 (small={small}, god={god})"
    );
    if let Some(limit) = all_limit_percent {
        assert!(
            god_all.saturating_mul(100) <= small.saturating_mul(limit),
            "{name}: all-sample p95 ratio exceeds {} (small={small}, god_all={god_all})",
            limit as f64 / 100.0
        );
    }
}

fn memory_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn fixture(count: usize) -> Arc<Hub> {
    let hub = memory_hub();
    for n in 0..count {
        let id = crate::god_fixture::chat_id(n);
        let value = crate::god_fixture::session_meta(
            &id,
            &format!("chat-{n}"),
            "/tmp",
            &crate::god_fixture::agent_session_id(n),
            400,
            1_791_540_000_000 + n as u64,
        );
        let meta: crate::store::SessionMeta = serde_json::from_value(value).unwrap();
        hub.insert_test_session(meta);
    }
    hub
}

async fn eventually(mut predicate: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(30), async move {
        loop {
            if predicate() {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}

fn index_for(v1: &Hub, live: usize) -> SummaryIndex {
    let mut index = SummaryIndex::new();
    let mut sessions = v1.session_handles();
    sessions.sort_unstable_by(|a, b| a.id.cmp(&b.id));
    for (seq, session) in sessions.into_iter().enumerate() {
        let mut summary = summary_from_session(v1, &session).unwrap();
        if seq >= live {
            summary.state = "closed".into();
        }
        index = index.apply(seq as u64 + 1, summary);
    }
    index
}

async fn tee_change_samples(count: usize) -> Vec<Vec<u128>> {
    let v1 = fixture(count);
    let (hub, writer) = CoreHub::new(SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let scope = cmux_scope::Scope::new("list-tee-gate");
    let writer_task = scope.spawn(v2.take_writer().unwrap().run());
    let tee_task = scope.spawn(task);
    eventually(|| v2.hub.snapshot().len() == count).await;
    let session = session_by_id(&v1, &crate::god_fixture::chat_id(0)).unwrap();
    let mut rounds = Vec::with_capacity(5);
    for round in 0..5_u64 {
        let mut samples = Vec::with_capacity(200);
        for n in 0..200_u64 {
            let before = v2.hub.snapshot().seq();
            let started = Instant::now();
            v1.set_status(
                &session,
                if (round * 200 + n).is_multiple_of(2) {
                    crate::store::SessionStatus::Ready
                } else {
                    crate::store::SessionStatus::Idle
                },
            );
            eventually(|| v2.hub.snapshot().seq() > before).await;
            samples.push(started.elapsed().as_nanos());
        }
        rounds.push(samples);
    }
    v2.hub.close();
    let _ = writer_task.await;
    tee_task.abort();
    let _ = tee_task.await;
    rounds
}

#[ignore = "Linux release gate: 20 vs 11,000 real v1 sessions"]
#[tokio::test]
async fn tee_change_gate() {
    let small = tee_change_samples(20).await;
    let god = tee_change_samples(11_000).await;
    let measured = emit("v2.pr05c.tee_change", &small, &god, "ns");
    assert_bounds("v2.pr05c.tee_change", measured, Some(200));
}

async fn stream_samples(count: usize, tee: bool) -> Vec<Vec<u128>> {
    let v1 = fixture(count);
    let session = session_by_id(&v1, &crate::god_fixture::chat_id(0)).unwrap();
    session.meta.lock().unwrap().status = crate::store::SessionStatus::Running;
    let marks = Arc::new(TeeState::default());
    if tee {
        v1.install_v2_tee(Arc::new(TeeHandle { state: marks.clone() }));
    }
    let mut rounds = Vec::with_capacity(5);
    for _ in 0..5 {
        let mut samples = Vec::with_capacity(20_000);
        for _ in 0..20_000 {
            let started = Instant::now();
            v1.append(&session, "in", "agent_message_chunk", json!({"delta":"x"}));
            samples.push(started.elapsed().as_nanos());
        }
        rounds.push(samples);
    }
    assert_eq!(marks.marks.load(Ordering::Relaxed), 0, "stream chunks must not mark");
    rounds
}

#[ignore = "Linux release gate: 100,000 real streamed chunks"]
#[tokio::test]
async fn stream_chunk_gate() {
    // Keep the session count matched: this isolates the tee branch and mark queue from fixture
    // construction or a different session population.
    let tee_off = stream_samples(11_000, false).await;
    let tee_on = stream_samples(11_000, true).await;
    let measured = emit("v2.pr05c.stream_chunk", &tee_off, &tee_on, "ns");
    assert_bounds("v2.pr05c.stream_chunk", measured, Some(200));
}

fn rss_bytes() -> u128 {
    let statm = std::fs::read_to_string("/proc/self/statm").unwrap();
    let pages: u128 = statm.split_whitespace().nth(1).unwrap().parse().unwrap();
    // Linux release runners use 4 KiB pages; keeping this probe dependency-free also keeps the
    // gate measurement on the same allocator and process as the workload.
    pages * 4096
}

async fn walk_rss_child(count: usize) -> (u128, u128, u128, u128, usize) {
    let v1 = fixture(count);
    let (hub, writer) = CoreHub::new(SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let before = rss_bytes();
    let scope = cmux_scope::Scope::new("list-tee-gate");
    let writer_task = scope.spawn(v2.take_writer().unwrap().run());
    let tee_task = scope.spawn(task);
    let mut peak = before;
    let mut observed = 0;
    let deadline = Instant::now() + Duration::from_secs(30);
    while v2.hub.snapshot().len() < count {
        assert!(Instant::now() < deadline, "startup walk did not publish every fixture row");
        let len = v2.hub.snapshot().len();
        if len != observed {
            observed = len;
            // Sample at every published boundary as well as between boundaries: this ties the
            // peak to the walk's actual page-sized progress rather than an arbitrary sleep.
            peak = peak.max(rss_bytes());
        }
        peak = peak.max(rss_bytes());
        tokio::task::yield_now().await;
    }
    peak = peak.max(rss_bytes());
    v2.hub.close();
    let _ = writer_task.await;
    peak = peak.max(rss_bytes());
    let after = rss_bytes();
    let retained = v2.hub.snapshot().iter().map(|row| serde_json::to_vec(row).unwrap().len()).sum();
    tee_task.abort();
    let _ = tee_task.await;
    (before, peak, peak.saturating_sub(before), after, retained)
}

#[ignore = "Linux release gate: startup walk RSS"]
#[tokio::test]
async fn walk_rss_gate() {
    if let Some(label) = std::env::var_os("V2_WALK_RSS_CHILD") {
        let count = if label == "small" { 20 } else { 11_000 };
        let (before, peak, increment, after, retained) = walk_rss_child(count).await;
        eprintln!(
            "WALK_RSS_CHILD label={:?} baseline={before} peak={peak} increment={increment} after={after} retained={retained}",
            label
        );
        return;
    }
    let exe = std::env::current_exe().unwrap();
    let run = |label: &str| {
        std::process::Command::new(&exe)
            .args(["--ignored", "--nocapture", "--exact", "hub::list_tee::gates::walk_rss_gate"])
            .env("V2_WALK_RSS_CHILD", label)
            .output()
            .unwrap()
    };
    let small = run("small");
    let god = run("god");
    assert!(
        small.status.success(),
        "small child failed: {}",
        String::from_utf8_lossy(&small.stderr)
    );
    assert!(god.status.success(), "god child failed: {}", String::from_utf8_lossy(&god.stderr));
    let parse = |bytes: &[u8]| {
        String::from_utf8_lossy(bytes)
            .lines()
            .find_map(|line| line.strip_prefix("WALK_RSS_CHILD "))
            .and_then(|line| {
                let value = |name: &str| {
                    line.split(name)
                        .nth(1)
                        .and_then(|rest| rest.split_whitespace().next())
                        .and_then(|value| value.parse::<u128>().ok())
                };
                Some((
                    value("baseline=")?,
                    value("peak=")?,
                    value("increment=")?,
                    value("after=")?,
                    value("retained=")?,
                ))
            })
    };
    let small_measure =
        parse(&small.stderr).expect("small RSS child omitted a complete diagnostic");
    let god_measure = parse(&god.stderr).expect("god RSS child omitted a complete diagnostic");
    eprintln!(
        "row=v2.pr05c.walk_rss walk RSS additive diagnostic: small baseline={} peak={} increment={} after={} retained={}, god baseline={} peak={} increment={} after={} retained={}",
        small_measure.0,
        small_measure.1,
        small_measure.2,
        small_measure.3,
        small_measure.4,
        god_measure.0,
        god_measure.1,
        god_measure.2,
        god_measure.3,
        god_measure.4,
    );
    // This is intentionally diagnostic-only. The design's additive one-page condition cannot be
    // reduced to a god/small ratio while allocator page retention and retained summary bytes are
    // both changing; do not emit a registry measure or assert an invented bound here.
}

fn live_page_samples(count: usize) -> (Vec<Vec<u128>>, usize, usize) {
    let v1 = fixture(count);
    let index = index_for(&v1, 20);
    let (hub, _writer) = CoreHub::new(index.clone());
    let mut sub = Sub::new("gate", "list");
    sub.view = Some(ListView::Live);
    sub.window = Some(10);
    let mut samples = Vec::with_capacity(5);
    let mut rows = 0;
    let mut bytes = 0;
    for _ in 0..5 {
        let mut round = Vec::with_capacity(200);
        for _ in 0..200 {
            let started = Instant::now();
            let frame = hub.list_window(&sub).unwrap();
            let mut window: Window<Summary> = frame.decode_json().unwrap();
            let mut one = window.rows.len();
            bytes += frame.encoded_len();
            while window.has_after {
                let key = window.after_key.take().expect("live window continuation key");
                let mut page = Page::new_list("gate", "list", PageSide::After, key);
                page.view = Some(ListView::Live);
                let frame = hub.page(&page).unwrap();
                let result: PageResult<Summary> = frame.decode_json().unwrap();
                one += result.rows.len();
                bytes += frame.encoded_len();
                window.has_after = result.has_after;
                window.after_key = result.after_key;
            }
            rows = one;
            round.push(started.elapsed().as_nanos());
        }
        samples.push(round);
    }
    (samples, rows, bytes)
}

#[ignore = "Linux release gate: live view pages"]
#[tokio::test]
async fn live_view_gate() {
    let (small, small_rows, small_bytes) = live_page_samples(20);
    let (god, god_rows, god_bytes) = live_page_samples(11_000);
    assert_eq!((small_rows, god_rows), (20, 20));
    assert!(small_bytes > 0 && god_bytes > 0);
    eprintln!("live view encoded/read bytes: small={small_bytes}, god={god_bytes}");
    let measured = emit("v2.pr05c.live_view", &small, &god, "ns");
    assert!(god_bytes.saturating_mul(100) <= small_bytes.saturating_mul(120));
    assert_bounds("v2.pr05c.live_view", measured, Some(200));
}

fn keyed_page_samples(count: usize) -> Vec<Vec<u128>> {
    let v1 = fixture(count);
    let (hub, writer) = CoreHub::new(SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    v2.hub.set_page_provider(Arc::new(V1PageProvider::new(v1.clone())));
    let valid = 96;
    let missing = 2;
    let unknown = 100 - valid - missing;
    for session in v1.session_handles() {
        v1.edit_test_meta(&session, |meta| meta.status = crate::store::SessionStatus::Closed);
    }
    let ids: Vec<_> = (0..valid)
        .map(|n| ListKey {
            last_activity: 0,
            chat_id: crate::god_fixture::chat_id(n % 20),
            origin: "local".into(),
        })
        .chain((0..2).map(|n| ListKey {
            last_activity: 0,
            chat_id: format!("missing-{n}"),
            origin: "local".into(),
        }))
        .chain((0..unknown).map(|n| ListKey {
            last_activity: 0,
            chat_id: format!("unknown-{n}"),
            origin: "peer".into(),
        }))
        .collect();
    // Use the protocol's default reply budget, as an ordinary client does.
    let mut request = Page::new("gate", "list", PageSide::After, 0);
    request.after = None;
    request.keys = Some(ids);
    let mut samples = Vec::with_capacity(5);
    for _ in 0..5 {
        let mut round = Vec::with_capacity(200);
        for _ in 0..200 {
            let started = Instant::now();
            let frame = v2.hub.page(&request).unwrap();
            let result: PageResult<Summary> = frame.decode_json().unwrap();
            assert_eq!(
                (result.rows.len(), result.missing.len(), result.unknown.len()),
                (valid, missing, unknown)
            );
            round.push(started.elapsed().as_nanos());
        }
        samples.push(round);
    }
    samples
}

#[ignore = "Linux release gate: keyed provider page"]
#[tokio::test]
async fn keyed_page_gate() {
    let small = keyed_page_samples(20);
    let god = keyed_page_samples(11_000);
    let measured = emit("v2.pr05c.keyed_page", &small, &god, "ns");
    assert_bounds("v2.pr05c.keyed_page", measured, Some(200));
}
