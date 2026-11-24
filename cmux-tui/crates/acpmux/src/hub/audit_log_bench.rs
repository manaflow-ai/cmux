//! What recording one approvals audit entry costs its caller (`audit_log.rs`): p50 and p95 of one
//! `AuditLog::record` on a log on disk holding 100 entries (`home=small`) and 200,000
//! (`home=god`; `ACPMUX_GOD_SCALE=0.1` for a quick run). The record runs under a chat's append
//! lock, so its cost must not grow with the file: god p95 stays within 1.2 x small p95 plus a
//! floor for noise. It uses only `open`, `record`, `flush`, `all` and the module's `seal`, so the
//! same file runs on a build whose record only queues the entry: copy it beside `audit_log.rs`
//! there, with the `mod audit_log_bench` lines at the end of that file, for the before numbers.
//! Manual: `cargo test -p acpmux --release --lib audit_record_cost -- --ignored --nocapture
//! --test-threads=1`. One `AUDIT-RECORD-COST` line per home.

// `Write` (for `writeln!` and `flush`) comes with `super::*`: `audit_log.rs` imports it, here
// and in the build before.
use super::*;
use std::time::Instant;

/// Timed records per home.
const SAMPLES: usize = 400;
/// What god p95 may exceed 1.2 x small p95 by: scheduling noise, not cost.
const FLOOR_US: f64 = 25.0;

fn entry(i: usize) -> Value {
    json!({"at": i, "sessionId": format!("s{}", i % 50), "harness": "claude",
           "vendor": "anthropic", "kind": "approval", "permissionId": format!("p-{i}"),
           "ask": "Run: cargo test -p acpmux", "decision": {"optionId": "allow", "kind": "allow"},
           "answeredBy": {"person": true}})
}

/// `dir`'s audit file holding `n` chained entries, written directly (no writer, no syncs).
fn build(dir: &Path, n: usize) {
    crate::config::private_state_dir(dir).unwrap();
    let file = crate::config::private_state_create_new(&dir.join(FILE)).unwrap();
    let mut out = std::io::BufWriter::new(file);
    let mut head = Head::default();
    for i in 0..n {
        let (sealed, next) = seal(&head, entry(i)).unwrap();
        head = next;
        writeln!(out, "{sealed}").unwrap();
    }
    out.flush().unwrap();
}

fn percentile_us(sorted: &[Duration], p: usize) -> f64 {
    let at = (sorted.len() * p / 100).min(sorted.len().saturating_sub(1));
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

/// p50 and p95 of one record, in microseconds, on a log of `n` entries.
fn cost(home: &str, n: usize) -> (f64, f64) {
    let dir =
        std::env::temp_dir().join(format!("acpmux-audit-bench-{home}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    build(&dir, n);
    let log = AuditLog::open(Some(dir.clone()));
    // Not timed: the first record opens the file.
    log.record(entry(n));
    log.flush();
    let mut took = Vec::with_capacity(SAMPLES);
    for i in 0..SAMPLES {
        let e = entry(n + 1 + i);
        let started = Instant::now();
        log.record(e);
        took.push(started.elapsed());
        // Not timed: this record's sync (or, on a build that queues it, its write), so every
        // sample starts on a quiet log.
        log.flush();
    }
    took.sort();
    let all = log.all().unwrap();
    assert_eq!(all.len(), n + 1 + SAMPLES, "a record was lost");
    assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
    let (p50, p95) = (percentile_us(&took, 50), percentile_us(&took, 95));
    println!("AUDIT-RECORD-COST home={home} n={n} p50_us={p50:.1} p95_us={p95:.1}");
    drop(log);
    let _ = std::fs::remove_dir_all(&dir);
    (p50, p95)
}

#[test]
#[ignore = "manual per-record cost measurement"]
fn audit_record_cost() {
    let scale = std::env::var("ACPMUX_GOD_SCALE")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|s| *s > 0.0)
        .unwrap_or(1.0);
    let god = ((200_000.0 * scale) as usize).max(1_000);
    let (_, small_p95) = cost("small", 100);
    let (_, god_p95) = cost("god", god);
    assert!(
        god_p95 <= small_p95 * 1.2 + FLOOR_US,
        "one record costs more on a big audit file: p95 {god_p95:.1} us at {god} entries, \
         {small_p95:.1} us at 100"
    );
}
