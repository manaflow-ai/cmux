//! Row 8's gates for the list stream on a peer link. Ignored by default; each writes its
//! `V2_GATE_OUT` line. Run one with
//! `cargo test --profile gate -p acpmux --lib NAME -- --ignored --nocapture`.

use super::tests::{Wire, link, memory_hub, peers_on, request_frame, row};
use super::*;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

const LINKS: usize = 30;
const WAIT: Duration = Duration::from_secs(60);

/// The owner of the gates' own tasks: the sampler and each link's reconnect.
fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: OnceLock<cmux_scope::Scope> = OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("v2 pr08 gates"))
}

fn emit(
    name: &str,
    small: &[Vec<u128>],
    god: &[Vec<u128>],
    unit: &str,
    more: Value,
) -> (u128, u128) {
    let p95 = |values: &[u128]| {
        let mut values = values.to_vec();
        values.sort_unstable();
        values[((values.len() * 95).div_ceil(100)).saturating_sub(1)]
    };
    let best = |rounds: &[Vec<u128>]| rounds.iter().map(|round| p95(round)).min().unwrap_or(0);
    let all = |rounds: &[Vec<u128>]| p95(&rounds.concat());
    let (small_p95, god_p95) = (best(small), best(god));
    let mut line = json!({
        "name": name, "small_p95": small_p95, "god_p95": god_p95,
        "god_p95_all": all(god), "unit": unit,
    });
    if let (Some(line), Value::Object(more)) = (line.as_object_mut(), more) {
        line.extend(more);
    }
    let line = line.to_string();
    eprintln!("V2_GATE {line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
    (small_p95, god_p95)
}

/// A daemon with `total` chats of its own, `live` of them live, and `peers` on or off.
fn daemon(total: usize, live: usize, peers: bool) -> Arc<crate::hub::Hub> {
    let hub = memory_hub();
    if peers {
        let mut writer = peers_on(&hub);
        for n in 0..total {
            let state = if n < live { "running" } else { "closed" };
            writer.apply(row("local", &format!("chat-{n}"), 1_000 + n as u64, state)).unwrap();
        }
        // The writer drives the gates' changes from the test; keep it with the hub.
        WRITERS.lock().unwrap().push((Arc::as_ptr(&hub) as usize, writer));
    }
    hub
}

static WRITERS: Mutex<Vec<(usize, acpmux_core::hub::HubWriter)>> = Mutex::new(Vec::new());

fn apply(hub: &Arc<crate::hub::Hub>, summary: acpmux_book::index::Summary) {
    let key = Arc::as_ptr(hub) as usize;
    let mut writers = WRITERS.lock().unwrap();
    let (_, writer) = writers.iter_mut().find(|(at, _)| *at == key).unwrap();
    writer.apply(summary).unwrap();
}

fn hello() -> String {
    request_frame(json!({"method":"hello","params":{"clientKind":"peer","protocol":2}}))
}

fn sub(cursor: u64) -> String {
    request_frame(
        json!({"method":"sub","params":{"sid":"s","stream":"list","view":"live","cursor":cursor}}),
    )
}

/// A link that said hello and subscribed from `cursor`, with its first frame.
async fn subscribed(hub: &Arc<crate::hub::Hub>, cursor: u64) -> (Wire, (u8, Value)) {
    let mut wire = link(hub);
    let mut v1 = Vec::new();
    wire.send(hello()).await;
    assert_eq!(wire.frame(&mut v1).await.0, 1);
    wire.send(sub(cursor)).await;
    let first = wire.frame(&mut v1).await;
    (wire, first)
}

fn rss_bytes() -> u128 {
    let statm = std::fs::read_to_string("/proc/self/statm").unwrap();
    let pages: u128 = statm.split_whitespace().nth(1).unwrap().parse().unwrap();
    pages * 4096
}

fn trim() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    // SAFETY: malloc_trim only returns free heap pages to the system.
    unsafe {
        libc::malloc_trim(0);
    }
}

/// How the 30 links come back.
#[derive(Clone, Copy, Debug)]
enum Storm {
    /// To the daemon they left, nothing missed: one empty frame marked `end` to each.
    Resume,
    /// To a restarted daemon: its peer store is new, every saved cursor is under its floor, and
    /// each link gets a window.
    Restart,
}

/// 30 links with a subscription and a saved cursor reconnect at once. Returns the RSS rise over
/// the trimmed baseline and the peak of bytes the links held.
async fn reconnect(total: usize, live: usize, storm: Storm) -> (u128, u64) {
    let hub = daemon(total, live, true);
    let mut cursors = Vec::new();
    for _ in 0..LINKS {
        match storm {
            Storm::Resume => {
                let (wire, (kind, window)) = subscribed(&hub, 0).await;
                assert_eq!(kind, 2, "a first subscription gets a window: {window}");
                cursors.push(window["cursor"].as_u64().unwrap());
                wire.serving.abort();
            }
            // The daemon that issued them is gone; this one's floor is above them.
            Storm::Restart => cursors.push(0),
        }
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    trim();
    let baseline = rss_bytes();
    let held_before = hub.link_v2.counters.held_bytes.load(Ordering::Relaxed);
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let sampler = {
        let done = done.clone();
        let hub = hub.clone();
        scope().spawn(async move {
            let (mut peak, mut held) = (0, 0);
            while !done.load(Ordering::Relaxed) {
                peak = peak.max(rss_bytes());
                held = held.max(hub.link_v2.counters.held_bytes.load(Ordering::Relaxed));
                tokio::time::sleep(Duration::from_micros(200)).await;
            }
            (peak.max(rss_bytes()), held)
        })
    };
    let parses = hub.link_v2.counters.value_parses.load(Ordering::Relaxed);
    let reconnects: Vec<_> = cursors
        .into_iter()
        .map(|cursor| {
            let hub = hub.clone();
            scope().spawn(async move {
                let (wire, (kind, frame)) = subscribed(&hub, cursor).await;
                match storm {
                    Storm::Resume => {
                        assert_eq!(kind, 3, "{frame}");
                        assert_eq!(frame["replay"], "end", "{frame}");
                        assert!(
                            frame["ops"].as_array().unwrap().is_empty(),
                            "nothing missed: {frame}"
                        );
                    }
                    Storm::Restart => {
                        assert_eq!(kind, 2, "a cursor under the floor gets a window: {frame}");
                        assert!(!frame["rows"].as_array().unwrap().is_empty(), "{frame}");
                    }
                }
                wire
            })
        })
        .collect();
    let mut wires = Vec::new();
    for task in reconnects {
        wires.push(tokio::time::timeout(WAIT, task).await.unwrap().unwrap());
    }
    done.store(true, Ordering::Relaxed);
    let (peak, held) = sampler.await.unwrap();
    assert_eq!(
        hub.link_v2.counters.value_parses.load(Ordering::Relaxed),
        parses,
        "the link's reader built no Value for a frame line"
    );
    assert_eq!(hub.link_v2.counters.dropped.load(Ordering::Relaxed), 0);
    eprintln!(
        "RECONNECT {storm:?} total={total} live={live} baseline={baseline} peak={peak} held_before={held_before} held_peak={held}"
    );
    drop(wires);
    (peak.saturating_sub(baseline), held)
}

#[ignore = "Linux gate: 30 peers reconnect at once at 11k chats and 500 live, resumed and restarted"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn v2_pr08_reconnect_30() {
    let (small_resume, _) = reconnect(20, 20, Storm::Resume).await;
    let (small_restart, _) = reconnect(20, 20, Storm::Restart).await;
    let (god_resume, held_resume) = reconnect(11_000, 500, Storm::Resume).await;
    let (god_restart, held_restart) = reconnect(11_000, 500, Storm::Restart).await;
    let more = json!({
        "god_resume": god_resume, "god_restart": god_restart,
        "held_peak": held_resume.max(held_restart),
    });
    let small = [vec![small_resume.max(small_restart)]];
    emit("v2.pr08.reconnect_30", &small, &[vec![god_resume.max(god_restart)]], "bytes", more);
    for (storm, rise) in [("resume", god_resume), ("restart", god_restart)] {
        assert!(rise < 20 * 1024 * 1024, "{storm}: RSS rose {rise} bytes");
    }
    let held = held_resume.max(held_restart);
    assert!(held <= (LINKS * 2 * acpmux_core::wire::MAX_FRAME_BYTES) as u64, "held {held}");
}

/// v1's ack on each of the 30 links while they reconnect: a v1 request sent right behind the
/// link's `hello` and `sub` frames, timed to its reply.
async fn ack_round(hub: &Arc<crate::hub::Hub>, cursor: u64) -> Vec<u128> {
    let tasks: Vec<_> = (0..LINKS)
        .map(|n| {
            let hub = hub.clone();
            scope().spawn(async move {
                let mut wire = link(&hub);
                wire.send(hello()).await;
                wire.send(sub(cursor)).await;
                let started = Instant::now();
                let reply = wire.call(n as u64 + 1, method::MUX_STATUS, json!({})).await;
                let elapsed = started.elapsed().as_nanos();
                assert!(reply.get("result").is_some(), "{reply}");
                wire.serving.abort();
                elapsed
            })
        })
        .collect();
    let mut samples = Vec::new();
    for task in tasks {
        samples.push(tokio::time::timeout(WAIT, task).await.unwrap().unwrap());
    }
    samples
}

#[ignore = "Linux gate: v1's ack p95 on 30 reconnecting links, peers on against off"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn v2_pr08_v1_ack_peers_on_off() {
    let off = daemon(11_000, 500, false);
    let on = daemon(11_000, 500, true);
    let (_, (_, window)) = subscribed(&on, 0).await;
    let cursor = window["cursor"].as_u64().unwrap();
    let (mut off_rounds, mut on_rounds) = (Vec::new(), Vec::new());
    for _ in 0..7 {
        off_rounds.push(ack_round(&off, cursor).await);
        on_rounds.push(ack_round(&on, cursor).await);
    }
    let (small, god) =
        emit("v2.pr08.v1_ack_peers_on_off", &off_rounds, &on_rounds, "ns", json!({}));
    assert!(god * 100 <= small * 120, "peers on {god} ns against off {small} ns");
}

/// One local change to 30 peer subscribers, from the submit to the last link's slot.
async fn fanout_round(
    hub: &Arc<crate::hub::Hub>,
    wires: &[Wire],
    at: &mut u64,
    samples: usize,
) -> Vec<u128> {
    let core = hub.link_v2.v2().unwrap().hub();
    let mut out = Vec::with_capacity(samples);
    for _ in 0..samples {
        *at += 1;
        let (encodes, scans, parses) =
            (core.peer_encodes(), crate::secret_scan::scans(), acpmux_core::hub::extra_parses());
        let started = Instant::now();
        apply(hub, row("local", "chat-0", *at, "running"));
        let deadline = Instant::now() + WAIT;
        while !wires.iter().all(|wire| wire.slot.holds()) {
            assert!(Instant::now() < deadline, "a link's slot never got the change");
            tokio::task::yield_now().await;
        }
        out.push(started.elapsed().as_nanos());
        assert_eq!(core.peer_encodes(), encodes + 1, "one change is encoded once for 30 peers");
        assert_eq!(crate::secret_scan::scans(), scans, "nothing scans at send");
        assert_eq!(acpmux_core::hub::extra_parses(), parses, "nothing parses extra at send");
        for wire in wires {
            let line = wire.slot.take().unwrap();
            assert!(parse(&line).is_some_and(|frame| frame.kind == 3));
        }
    }
    out
}

async fn fanout_links(hub: &Arc<crate::hub::Hub>) -> Vec<Wire> {
    let mut wires = Vec::new();
    for _ in 0..LINKS {
        let (wire, (kind, _)) = subscribed(hub, 0).await;
        assert_eq!(kind, 2);
        // The link's writer stops, so each change waits in the slot for the test to read.
        wire.stop_writer.send_replace(true);
        wires.push(wire);
    }
    wires
}

#[ignore = "Linux gate: one change to 30 peers at 11k chats and 500 live against 20 live"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn v2_pr08_fanout_30() {
    let small = daemon(20, 20, true);
    let god = daemon(11_000, 500, true);
    let small_links = fanout_links(&small).await;
    let god_links = fanout_links(&god).await;
    let (mut small_at, mut god_at) = (1_000_000, 1_000_000);
    let (mut small_rounds, mut god_rounds) = (Vec::new(), Vec::new());
    for _ in 0..7 {
        small_rounds.push(fanout_round(&small, &small_links, &mut small_at, 40).await);
        god_rounds.push(fanout_round(&god, &god_links, &mut god_at, 40).await);
    }
    let (small_p95, god_p95) =
        emit("v2.pr08.fanout_30", &small_rounds, &god_rounds, "ns", json!({}));
    assert!(god_p95 * 100 <= small_p95 * 120, "god {god_p95} ns against small {small_p95} ns");
}

#[test]
fn a_v1_request_line_is_never_a_frame_line() {
    assert!(!is_frame_line(&Message::request(1, method::MUX_STATUS, json!({})).to_line()));
}
