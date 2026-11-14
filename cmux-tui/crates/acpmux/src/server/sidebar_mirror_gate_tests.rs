//! Row 7's gates that Rust can measure: the sidebar's mirror connecting to a hub with the v2
//! list, 20 live chats on both sides and 11,000 closed beside them on god, through the C entry
//! points with `rows: "v1"` and 8 wanted closed keys. Ignored by default; the nightly gate run
//! (`scripts/cmux-next/run-v2-gates.sh`) runs them in the gate profile on Linux.

use super::*;

const LIVE: usize = 20;
const WANTED: usize = 8;
const GOD_CLOSED: usize = 11_000;
const ROUNDS: usize = 5;
const SAMPLES: usize = 40;
/// Connect to the last row delivered, god side, at most (the design doc: "under 200 ms after
/// listen").
const ROWS_WALL_MAX_NS: u128 = 200_000_000;

fn p95(values: &[u128]) -> u128 {
    let mut values = values.to_vec();
    values.sort_unstable();
    values[((values.len() * 95).div_ceil(100)).saturating_sub(1)]
}

/// The best round's p95 and the p95 of every sample.
fn measures(rounds: &[Vec<u128>]) -> (u128, u128) {
    let best = rounds.iter().map(|round| p95(round)).min().unwrap_or(0);
    let all: Vec<_> = rounds.iter().flatten().copied().collect();
    (best, p95(&all))
}

/// Prints the measured line first, so a red run still has its numbers, and appends it to
/// `V2_GATE_OUT` for the registry.
fn emit(name: &str, small: &[Vec<u128>], god: &[Vec<u128>], unit: &str) -> (u128, u128) {
    let (small_p95, _) = measures(small);
    let (god_p95, god_p95_all) = measures(god);
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
    (small_p95, god_p95)
}

fn fixture(closed: usize) -> Fixture {
    let live: Vec<(String, &str, Value)> =
        (0..LIVE).map(|n| (format!("live-{n:02}"), "idle", json!({}))).collect();
    let live: Vec<(&str, &str, Value)> =
        live.iter().map(|(id, status, tags)| (id.as_str(), *status, tags.clone())).collect();
    Fixture::new(&live, closed, WANTED, true)
}

/// One connect of the sidebar's mirror, to idle: wall time to the last row delivered as a
/// change, and the bytes the daemon sent until then.
async fn connect_once(fixture: &Fixture) -> (u128, u128) {
    let mut run = Run::new();
    run.ffi.subscribe_mirror(&mirror_request());
    run.ffi.want(&want_request(&fixture.wanted));
    let started = Instant::now();
    run.ffi.connected();
    run.connect(fixture.v2.clone(), "gate");
    let changes = run.step(Duration::ZERO, connected_whole(&fixture.wanted)).await;
    let wall = started.elapsed().as_nanos();
    let rows = changes
        .iter()
        .flat_map(rows)
        .filter_map(|row| row.get("sessionId").and_then(Value::as_str))
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(rows.len(), LIVE + WANTED, "the sidebar's rows: {rows:?}");
    run.drop_socket().await;
    (wall, run.bytes.len() as u128)
}

#[ignore = "Linux gate profile: the sidebar's mirror, 20 live with 11,000 closed beside them"]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sidebar_mirror_connect_gate() {
    let small = fixture(WANTED);
    let god = fixture(GOD_CLOSED);
    let (mut small_wall, mut god_wall) = (Vec::new(), Vec::new());
    let (mut small_bytes, mut god_bytes) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS {
        let (mut sw, mut gw, mut sb, mut gb) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        // Rounds alternate the sides, one connect each, so drift on the host lands on both.
        for _ in 0..SAMPLES {
            let (wall, bytes) = connect_once(&small).await;
            sw.push(wall);
            sb.push(bytes);
            let (wall, bytes) = connect_once(&god).await;
            gw.push(wall);
            gb.push(bytes);
        }
        small_wall.push(sw);
        god_wall.push(gw);
        small_bytes.push(sb);
        god_bytes.push(gb);
    }
    let (small_b, god_b) = emit("v2.pr07.mirror_connect_bytes", &small_bytes, &god_bytes, "bytes");
    let (small_w, god_w) = emit("v2.pr07.mirror_connect_rows_wall", &small_wall, &god_wall, "ns");
    assert!(
        god_b.saturating_mul(100) <= small_b.saturating_mul(120),
        "v2.pr07.mirror_connect_bytes: ratio exceeds 1.2 (small={small_b}, god={god_b})"
    );
    assert!(
        god_w.saturating_mul(100) <= small_w.saturating_mul(120),
        "v2.pr07.mirror_connect_rows_wall: ratio exceeds 1.2 (small={small_w}, god={god_w})"
    );
    assert!(
        god_w < ROWS_WALL_MAX_NS,
        "v2.pr07.mirror_connect_rows_wall: god p95 {god_w} ns is not under 200 ms"
    );
}
