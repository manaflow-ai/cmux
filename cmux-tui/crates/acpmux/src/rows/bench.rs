//! What the fold costs (hq#9655 stage 2): a 1.5M-record chat folded from empty, and one token
//! appended to the streaming reply of a table of 1k and of 100k rows. Run with
//! `cargo test -p acpmux --release --lib rows::bench -- --ignored --nocapture`; each prints one
//! `rows bench:` line. A plain `cargo test` runs a small copy of each as a check that it works.

use std::time::{Duration, Instant};

use serde_json::json;

use super::fold::RowTable;
use super::tests::{chunk, mux, update};
use crate::store::EventRecord;

/// The records of turn `turn`, from seq `seq`: a prompt, 40 reply tokens, 4 tool calls with a
/// start and an end, 40 more tokens and the turn's end: 90 records, 8 rows.
fn turn(turn: u64, seq: &mut u64, out: &mut Vec<EventRecord>) {
    let mut next = || {
        *seq += 1;
        *seq
    };
    let t = format!("t{turn}");
    out.push(mux(
        next(),
        "user_message",
        json!({"promptId": format!("p{turn}"), "turnId": t, "text": "do the thing"}),
    ));
    for _ in 0..40 {
        out.push(chunk(next(), "word ", Some("m"), None));
    }
    for c in 0..4 {
        let id = format!("c{turn}-{c}");
        out.push(update(
            next(),
            json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "Read file",
            "kind": "read", "status": "pending"}),
        ));
        out.push(update(
            next(),
            json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "fn main() {}"}}]}),
        ));
    }
    for _ in 0..40 {
        out.push(chunk(next(), "more ", Some("m2"), None));
    }
    out.push(mux(next(), "turn_result", json!({"turnId": t, "status": "completed"})));
}

/// Folds `records` records of whole turns, built 100k at a time off the clock. Returns the fold's
/// time and the table.
fn fold_records(records: u64) -> (Duration, RowTable) {
    let mut table = RowTable::new();
    let mut sink = Vec::new();
    let (mut seq, mut n, mut spent) = (0u64, 0u64, Duration::ZERO);
    while seq < records {
        let mut batch = Vec::with_capacity(100_100);
        while batch.len() < 100_000 && seq < records {
            turn(n, &mut seq, &mut batch);
            n += 1;
        }
        let start = Instant::now();
        for rec in &batch {
            table.apply(rec, &mut sink);
            sink.clear();
        }
        spent += start.elapsed();
    }
    (spent, table)
}

/// The time of one token appended to the open reply of a table of about `rows` rows: the
/// median of 101 runs of 10k tokens each.
fn token_cost(rows: usize) -> Duration {
    // 8 rows a turn; enough turns for `rows`, then a turn left open with its reply streaming.
    let (_, mut table) = fold_records((rows as u64).div_ceil(8) * 90);
    let mut seq = table.last_seq();
    let mut sink = Vec::with_capacity(1);
    table.apply(
        &mux(seq + 1, "user_message", json!({"promptId": "open", "turnId": "open", "text": "go"})),
        &mut sink,
    );
    table.apply(&chunk(seq + 2, "start", Some("open"), None), &mut sink);
    seq += 2;
    let tokens: Vec<EventRecord> =
        (1..=10_000).map(|n| chunk(seq + n, "tok ", Some("open"), None)).collect();
    let mut runs = Vec::with_capacity(101);
    for run in 0..101u64 {
        let tokens: Vec<EventRecord> =
            tokens.iter().map(|r| EventRecord { seq: r.seq + run * 10_000, ..r.clone() }).collect();
        let start = Instant::now();
        for rec in &tokens {
            sink.clear();
            table.apply(rec, &mut sink);
        }
        runs.push(start.elapsed() / 10_000);
        assert_eq!(sink.len(), 1);
    }
    runs.sort();
    runs[50]
}

#[test]
fn small_runs_of_the_bench_fold_as_expected() {
    let (_, table) = fold_records(9_000);
    assert_eq!(table.rows().len(), 800);
    assert!(token_cost(100) < Duration::from_millis(5));
}

#[test]
#[ignore = "a bench: run with --release --ignored --nocapture"]
fn bench_fold_1_5m_records_and_a_token_at_1k_and_100k_rows() {
    let (spent, table) = fold_records(1_500_000);
    let at_1k = token_cost(1_000);
    let at_100k = token_cost(100_000);
    println!(
        "rows bench: fold 1.5M records -> {} rows in {:.1} ms; a token at 1k rows {} ns, at 100k rows {} ns",
        table.rows().len(),
        spent.as_secs_f64() * 1000.0,
        at_1k.as_nanos(),
        at_100k.as_nanos(),
    );
}
