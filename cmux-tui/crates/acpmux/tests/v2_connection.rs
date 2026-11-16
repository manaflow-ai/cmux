//! PR4's release gates use the shared small/god shapes and the real Unix stream
//! driver. Run alone: cargo test -p acpmux --release --test v2_connection -- --ignored --nocapture --test-threads=1
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&["V2_GATE_OUT"]);

use acpmux_book::gate_rounds::{self, all_p95, best_p95};
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

fn file_bytes(root: &std::path::Path) -> u64 {
    std::fs::read_dir(root)
        .expect("fixture directory")
        .map(|entry| {
            let path = entry.expect("fixture entry").path();
            let metadata = std::fs::symlink_metadata(&path).expect("fixture metadata");
            if metadata.is_dir() { file_bytes(&path) } else { metadata.len() }
        })
        .sum()
}

fn chat_count(root: &std::path::Path) -> usize {
    std::fs::read_dir(root)
        .expect("fixture sessions directory")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .count()
}

fn start_fixture(mut shape: acpmux::god_fixture::Shape) -> tempfile::TempDir {
    let scratch = tempfile::tempdir().expect("fixture scratch");
    std::fs::write(scratch.path().join("config.json"), json!({"acpmux.v2": ["start"]}).to_string())
        .expect("v2 config");
    if shape.name == "god" {
        shape.chats = 527;
        shape.god_bytes = 4 * 1024 * 1024 * 1024;
    }
    let made = acpmux::god_fixture::write_home(
        scratch.path(),
        &scratch.path().join("claude"),
        &scratch.path().join("work"),
        &shape,
    )
    .expect("store-backed fixture");
    assert_eq!(made.others.len() + 1, shape.chats, "fixture chat count");
    assert_eq!(chat_count(&scratch.path().join("sessions")), shape.chats, "fixture chat dirs");
    if shape.name == "god" {
        assert!(
            file_bytes(&scratch.path().join("sessions")) >= shape.god_bytes,
            "fixture store size"
        );
    }
    scratch
}

async fn daemon_hello(socket: &std::path::Path) {
    tokio::time::timeout(Duration::from_secs(30), daemon_hello_inner(socket))
        .await
        .expect("daemon hello timed out");
}

/// Reads v1's status gauges over a fresh connection after the readiness clock has ended.
async fn daemon_status(socket: &std::path::Path) -> serde_json::Value {
    tokio::time::timeout(Duration::from_secs(30), daemon_status_inner(socket))
        .await
        .expect("status request timed out")
}

async fn daemon_status_inner(socket: &std::path::Path) -> serde_json::Value {
    let mut client = UnixStream::connect(socket).await.expect("connect status daemon");
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "_acpmux/status",
        "params": {}
    });
    client.write_all(format!("{request}\n").as_bytes()).await.expect("send status request");
    let bytes = tokio::time::timeout(Duration::from_secs(30), async {
        let mut bytes = Vec::new();
        loop {
            let byte = client.read_u8().await.expect("read status response");
            if byte == b'\n' {
                break;
            }
            bytes.push(byte);
        }
        bytes
    })
    .await
    .expect("read status response timed out");
    let reply: serde_json::Value = serde_json::from_slice(&bytes).expect("status response JSON");
    assert_eq!(reply.get("id"), Some(&json!(1)), "status response id");
    assert!(reply.get("error").is_none(), "status request failed: {reply}");
    let startup = reply
        .pointer("/result/gauges/startup")
        .and_then(serde_json::Value::as_array)
        .expect("status gauges startup array");
    for name in ["store open", "hub construct"] {
        let phase = startup.iter().find(|phase| phase["name"] == name).unwrap_or_else(|| {
            panic!("status gauges missing completed phase {name:?}: {startup:?}")
        });
        assert!(
            phase["ms"].as_u64().is_some(),
            "status gauges phase {name:?} was not complete: {phase}"
        );
    }
    reply["result"].clone()
}

#[derive(Default)]
struct PhaseSamples {
    at_ms: Vec<u64>,
    at_us: Vec<u64>,
    ms: Vec<u64>,
    us: Vec<u64>,
    cpu_us: Vec<u64>,
    major_faults: Vec<u64>,
    minor_faults: Vec<u64>,
    voluntary_switches: Vec<u64>,
    involuntary_switches: Vec<u64>,
}

fn distribution(values: &mut [u64]) -> serde_json::Value {
    if values.is_empty() {
        return json!({"p95": 0, "median": 0, "max": 0});
    }
    values.sort_unstable();
    let p95 = values[((values.len() * 95).saturating_add(99) / 100).saturating_sub(1)];
    let median = values[values.len() / 2];
    let max = *values.last().unwrap_or(&0);
    json!({"p95": p95, "median": median, "max": max})
}

fn startup_phase_summary(samples: &[serde_json::Value]) -> serde_json::Value {
    let mut by_name: BTreeMap<String, PhaseSamples> = BTreeMap::new();
    for startup in samples {
        for phase in startup.as_array().into_iter().flatten() {
            let (Some(name), Some(at_ms), Some(at_us), Some(ms), Some(us)) = (
                phase["name"].as_str(),
                phase["atMs"].as_u64(),
                phase["atUs"].as_u64(),
                phase["ms"].as_u64(),
                phase["us"].as_u64(),
            ) else {
                continue;
            };
            let phase_samples = by_name.entry(name.to_owned()).or_default();
            phase_samples.at_ms.push(at_ms);
            phase_samples.at_us.push(at_us);
            phase_samples.ms.push(ms);
            phase_samples.us.push(us);
            phase_samples.cpu_us.push(phase["cpuUs"].as_u64().unwrap_or(0));
            phase_samples.major_faults.push(phase["majorFaults"].as_u64().unwrap_or(0));
            phase_samples.minor_faults.push(phase["minorFaults"].as_u64().unwrap_or(0));
            phase_samples.voluntary_switches.push(phase["voluntarySwitches"].as_u64().unwrap_or(0));
            phase_samples
                .involuntary_switches
                .push(phase["involuntarySwitches"].as_u64().unwrap_or(0));
        }
    }
    serde_json::Value::Object(
        by_name
            .into_iter()
            .map(|(name, mut phase)| {
                let samples = phase.at_ms.len();
                (
                    name,
                    json!({
                        "samples": samples,
                        "atMs": distribution(&mut phase.at_ms),
                        "atUs": distribution(&mut phase.at_us),
                        "ms": distribution(&mut phase.ms),
                        "us": distribution(&mut phase.us),
                        "cpuUs": distribution(&mut phase.cpu_us),
                        "majorFaults": distribution(&mut phase.major_faults),
                        "minorFaults": distribution(&mut phase.minor_faults),
                        "voluntarySwitches": distribution(&mut phase.voluntary_switches),
                        "involuntarySwitches": distribution(&mut phase.involuntary_switches),
                    }),
                )
            })
            .collect(),
    )
}

fn startup_thread_summary(samples: &[serde_json::Value]) -> serde_json::Value {
    samples.first().cloned().unwrap_or(serde_json::Value::Null)
}

fn outside_session_file_sizes(root: &std::path::Path) -> BTreeMap<String, u64> {
    fn visit(root: &std::path::Path, path: &std::path::Path, sizes: &mut BTreeMap<String, u64>) {
        let Ok(relative) = path.strip_prefix(root) else { return };
        if relative.components().next().is_some_and(|component| component.as_os_str() == "sessions")
        {
            return;
        }
        let Ok(metadata) = std::fs::symlink_metadata(path) else { return };
        if metadata.is_dir() {
            let Ok(entries) = std::fs::read_dir(path) else { return };
            for entry in entries.flatten() {
                visit(root, &entry.path(), sizes);
            }
        } else {
            sizes.insert(relative.to_string_lossy().into_owned(), metadata.len());
        }
    }

    let mut sizes = BTreeMap::new();
    visit(root, root, &mut sizes);
    sizes
}

fn outside_file_summary(
    samples: &Option<(BTreeMap<String, u64>, BTreeMap<String, u64>)>,
) -> serde_json::Value {
    match samples {
        Some((first, last)) => json!({"first": first, "last": last}),
        None => serde_json::Value::Null,
    }
}

async fn daemon_hello_inner(socket: &std::path::Path) {
    let mut client = tokio::time::timeout(Duration::from_secs(30), UnixStream::connect(socket))
        .await
        .expect("connect ready daemon timed out")
        .expect("connect ready daemon");
    let upgrade = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "_acpmux/v2",
        "params": {"protocol": 2, "surfaces": ["chat"]}
    });
    client.write_all(format!("{}\n", upgrade).as_bytes()).await.expect("send v2 upgrade");
    let bytes = tokio::time::timeout(Duration::from_secs(30), async {
        let mut bytes = Vec::new();
        loop {
            let byte = client.read_u8().await.expect("read v2 upgrade");
            if byte == b'\n' {
                break;
            }
            bytes.push(byte);
        }
        bytes
    })
    .await
    .expect("read v2 upgrade timed out");
    let reply: serde_json::Value = serde_json::from_slice(&bytes).expect("v2 upgrade reply");
    assert_eq!(reply.pointer("/result/upgrade"), Some(&json!(true)));
    let surfaces = reply
        .pointer("/result/surfaces")
        .and_then(serde_json::Value::as_array)
        .expect("advertised v2 surfaces");
    assert!(surfaces.iter().any(|surface| surface == "chat"));
    hello(&mut client).await;
}

#[test]
#[ignore = "release startup gate; run through scripts/cmux-next/run-v2-gates.sh"]
fn v2_pr09_listen_start() {
    const ROUNDS: usize = 5;
    const SAMPLES: usize = 20;
    let fixture_started = Instant::now();
    let small_fixture = start_fixture(acpmux::god_fixture::Shape {
        chats: 1,
        ..acpmux::god_fixture::Shape::small()
    });
    let god_fixture = start_fixture(acpmux::god_fixture::Shape::god());
    let fixture_build_seconds = fixture_started.elapsed().as_secs_f64();
    let mut small = Vec::with_capacity(ROUNDS);
    let mut god = Vec::with_capacity(ROUNDS);
    let mut startup_phases =
        [Vec::with_capacity(ROUNDS * SAMPLES), Vec::with_capacity(ROUNDS * SAMPLES)];
    let mut diagnostic_threads = [Vec::with_capacity(1), Vec::with_capacity(1)];
    let mut outside_files: Vec<Option<(BTreeMap<String, u64>, BTreeMap<String, u64>)>> =
        vec![None, None];
    let mut forced_kills = 0;
    for round in 0..ROUNDS {
        let mut small_round = Vec::with_capacity(SAMPLES);
        let mut god_round = Vec::with_capacity(SAMPLES);
        for side in 0..2 {
            let (chats, samples) =
                if (round + side) % 2 == 0 { (1, &mut small_round) } else { (527, &mut god_round) };
            for _ in 0..SAMPLES {
                let scratch = if chats == 527 { &god_fixture } else { &small_fixture };
                let daemon = daemon_env::spawn_ready_daemon(scratch.path());
                samples.push(daemon.startup.as_nanos());
                // The readiness clock ends before this hello and child stop.
                let runtime = tokio::runtime::Runtime::new().expect("gate runtime");
                runtime.block_on(daemon_hello(&daemon.socket));
                assert!(daemon.ready.contains("\"ready\":true"));
                let side = if chats == 527 { 1 } else { 0 };
                startup_phases[side].push(
                    runtime.block_on(daemon_status(&daemon.socket))["gauges"]["startup"].clone(),
                );
                forced_kills += usize::from(daemon.stop());
                let sizes = outside_session_file_sizes(scratch.path());
                match &mut outside_files[side] {
                    Some((_, last)) => *last = sizes,
                    slot @ None => *slot = Some((sizes.clone(), sizes)),
                }
            }
        }
        small.push(small_round);
        god.push(god_round);
    }
    for (side, scratch) in [&small_fixture, &god_fixture].into_iter().enumerate() {
        let options = daemon_env::ReadyDaemonOptions {
            env: vec![("ACPMUX_STARTUP_THREAD_TABLE".into(), "1".into())],
            ..Default::default()
        };
        let daemon = daemon_env::spawn_ready_daemon_with(scratch.path(), &options);
        let runtime = tokio::runtime::Runtime::new().expect("diagnostic gate runtime");
        runtime.block_on(daemon_hello(&daemon.socket));
        diagnostic_threads[side]
            .push(runtime.block_on(daemon_status(&daemon.socket))["gauges"]["startup"].clone());
        forced_kills += usize::from(daemon.stop());
    }
    assert_eq!(small.len(), ROUNDS);
    assert_eq!(god.len(), ROUNDS);
    let measures = |rounds: Vec<Vec<u128>>| rounds;
    let small = measures(small);
    let god = measures(god);
    gate_rounds::report("v2.pr09.listen_start", &[("small", &small), ("god", &god)]);
    let small_p95 = best_p95(&small);
    let god_p95 = best_p95(&god);
    let god_p95_all = all_p95(&god);
    eprintln!(
        "v2.pr09.listen_start startup phases small={} god={} startup threads small={} god={} outside files small={} god={}",
        startup_phase_summary(&startup_phases[0]),
        startup_phase_summary(&startup_phases[1]),
        startup_thread_summary(&diagnostic_threads[0]),
        startup_thread_summary(&diagnostic_threads[1]),
        outside_file_summary(&outside_files[0]),
        outside_file_summary(&outside_files[1])
    );
    assert_eq!(forced_kills, 0, "daemon required force-kill during orderly gate stop");
    assert_eq!(chat_count(&god_fixture.path().join("sessions")), 527, "god fixture chats");
    assert!(
        file_bytes(&god_fixture.path().join("sessions")) >= 4 * 1024 * 1024 * 1024,
        "god fixture store size"
    );
    let line = json!({
        "name": "v2.pr09.listen_start",
        "small_p95": small_p95,
        "god_p95": god_p95,
        "god_p95_all": god_p95_all,
        "unit": "ns",
    })
    .to_string();
    eprintln!("{line} fixture_build_seconds={fixture_build_seconds:.3}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| writeln!(file, "{line}"))
            .expect("gate output");
    }
    assert!(
        god_p95.saturating_mul(10) <= small_p95.saturating_mul(12),
        "god/small startup ratio exceeded 1.2x: small_p95={small_p95}ns god_p95={god_p95}ns"
    );
    assert!(small_p95 > 0);
    assert!(god_p95 <= 100_000_000, "god listener startup exceeded 100 ms");
    assert!(god_p95_all <= 100_000_000, "all god listener samples exceeded 100 ms");
}

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

#[cfg(target_os = "linux")]
fn trim_allocator() {
    // The RSS gate must measure pages retained by this connection, not free
    // allocator arenas left by fixture construction.
    unsafe {
        libc::malloc_trim(0);
    }
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
    allow_resume_window: bool,
}
impl View {
    fn apply(&mut self, frame: &Frame) {
        self.consumed += frame.encoded_len() as u64;
        match frame.kind {
            FrameKind::Window => {
                let window: Window<Summary> = frame.decode_json().unwrap();
                // A window is the initial viewport or an explicit resume
                // replacement. A second live window at the same cursor would
                // hide a duplicate/repeated delivery, so reject it unless a
                // resume generation is active.
                assert!(
                    self.rows.is_empty() || self.replaying || self.allow_resume_window,
                    "repeated window delivery"
                );
                self.allow_resume_window = false;
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
                        DeltaOp::Gone { seq, chat_id, .. } => {
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
        conn::run(rd, wr, driver, "pr4-gate", &["list".into()], conn::Role::Local).await
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
    whole_run_rise: usize,
    rss_end: usize,
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
    // Return free arenas before measuring, then reset only this worker's kernel
    // RSS high-water mark after fixture setup.
    trim_allocator();
    // Subtracting a setup HWM instead of current RSS could hide a later rise.
    std::fs::write("/proc/self/clear_refs", b"5\n").unwrap();
    let baseline = memory_kib("VmRSS:");
    let mut result = Stopped {
        rss_rise: 0,
        whole_run_rise: 0,
        rss_end: 0,
        retained: 0,
        peak_queue: 0,
        peak_outside: 0,
        drops: 0,
    };
    let mut bytes = 0_u64;
    let mut iteration = 0_u64;
    let mut target = view.cursor;
    let mut send_credit = dishonest_credit;
    let final_stretch_start = shape.connection_change_bytes().saturating_sub(8 << 20);
    let mut final_hwm_reset = false;
    let mut stretch_peak_queue = 0usize;
    while bytes < shape.connection_change_bytes() {
        for _ in 0..128 {
            let row = summary(0, 2_000_000 + iteration);
            bytes += row.encoded_len() as u64;
            target = writer.apply(row).unwrap().seq;
            iteration += 1;
        }
        caught_up(&mut progress, target).await;
        let hwm_before_reset = memory_kib("VmHWM:").saturating_sub(baseline);
        result.whole_run_rise = result.whole_run_rise.max(hwm_before_reset);
        if !final_hwm_reset && bytes >= final_stretch_start {
            // Keep the baseline from before the stream, but reset the kernel
            // high-water mark so both sides sample the same final 8 MiB.
            std::fs::write("/proc/self/clear_refs", b"5\n").unwrap();
            final_hwm_reset = true;
        }
        if send_credit {
            // Deliberately lying: no reads on this socket after its initial windows.
            credit(&mut slow, "slow", u64::MAX).await;
            if metrics.notices() != 0 {
                send_credit = false;
            }
        }
        result.retained = result.retained.max(source.not_fed_bytes());
        let hwm_rise = memory_kib("VmHWM:").saturating_sub(baseline);
        if final_hwm_reset {
            result.rss_rise = result.rss_rise.max(hwm_rise);
            stretch_peak_queue = stretch_peak_queue.max(metrics.queued_bytes());
        }
        result.peak_queue = result.peak_queue.max(metrics.queued_bytes());
        result.peak_outside = result.peak_outside.max(metrics.outside_budget_bytes());
        assert!(metrics.queued_bytes() <= wire::CONNECTION_BUDGET_BYTES);
        assert!(metrics.notices() <= wire::MAX_SUBSCRIPTIONS);
        assert_eq!(source.not_fed_bytes(), 0);
    }
    // Resume the honest reader by consuming queued frames and sending real credit.
    // The dishonest one must first drain its old generation's dropped notice.
    credit(&mut slow, "slow", view.consumed).await;
    view.allow_resume_window = true;
    if dishonest_credit {
        credit(&mut slow, "other", other.consumed).await;
        other.allow_resume_window = true;
    }
    let mut credited = BTreeMap::<String, u64>::new();
    while view.cursor < target || (dishonest_credit && (result.drops == 0 || other.cursor < target))
    {
        let frame = receive(&mut slow).await;
        let payload: serde_json::Value = frame.decode_json().unwrap();
        let sid = payload.get("sid").and_then(|s| s.as_str()).unwrap().to_owned();
        // A credit in flight when the connection dropped its sid is answered with nothing.
        assert_ne!(frame.kind, FrameKind::Error, "{payload}");
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
    assert_eq!(expected.windows, 1, "reference reader received a repeated window");
    assert_eq!(view.rows, expected.rows);
    assert_eq!(view.cursor, expected.cursor);
    assert_eq!(view.windows, 2, "stopped reader did not receive exactly one resume window");
    if dishonest_credit {
        assert_eq!(result.drops, 1);
        assert_eq!(other.windows, 2, "second sid did not receive exactly one resume window");
        assert_eq!(other.rows, expected.rows);
        assert_eq!(other.cursor, target);
    }
    drop(slow);
    driver.await.unwrap().unwrap();
    stop.send(()).unwrap();
    fast_reader.await.unwrap();
    fast_driver.await.unwrap().unwrap();
    assert_eq!(source.task_count(), 0);
    assert_eq!(fast_source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
    // Include resume and shutdown in the process high-water mark. Sampling only
    // the stopped-reader loop could miss an allocation spike during recovery.
    result.rss_rise = result.rss_rise.max(memory_kib("VmHWM:").saturating_sub(baseline));
    result.peak_queue = metrics.peak_queued_bytes();
    result.peak_outside = metrics.peak_outside_budget_bytes();
    result.rss_end = memory_kib("VmRSS:").saturating_sub(baseline);
    result.whole_run_rise = result.whole_run_rise.max(result.rss_rise);
    assert!(result.peak_queue <= wire::CONNECTION_BUDGET_BYTES);
    let whole_run_budget = if dishonest_credit {
        wire::CONNECTION_BUDGET_BYTES * 2
    } else {
        wire::CONNECTION_BUDGET_BYTES
    };
    assert!(result.whole_run_rise < whole_run_budget, "{result:?}");
    assert!(result.rss_rise >= stretch_peak_queue, "{result:?}");
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

fn offer_round(subscriptions: usize) -> Vec<u128> {
    let mut state = ConnectionState::default();
    for i in 0..subscriptions {
        state.subscribe(format!("sid-{i}"), Cursor(0)).unwrap();
    }
    let mut values = Vec::new();
    for n in 0..20_000 {
        let frame = Frame::json(FrameKind::Delta, &json!({"sid":"sid-0","ops":[]})).unwrap();
        let start = Instant::now();
        let result = state.offer("sid-0", std::hint::black_box(frame), Cursor(n));
        let elapsed = start.elapsed().as_nanos();
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
    gate_rounds::report("v2.pr04.offer_256_subscriptions", &[("small", &small), ("god", &god)]);
    let small_best = best_p95(&small);
    let god_best = best_p95(&god);
    let god_all = all_p95(&god);
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
    let mut saw_end = first_delta.replay == Some(ReplayMark::End);
    while view.cursor < final_seq || !saw_end {
        let frame = receive(&mut client).await;
        if frame.kind == FrameKind::Delta {
            let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
            if delta.replay == Some(ReplayMark::End) {
                saw_end = true;
            }
        }
        view.apply(&frame);
    }
    assert!(saw_end, "resume did not emit its end mark");
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
