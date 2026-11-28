//! The host-wide search's matcher at 10k and 100k messages: the full matcher (flatten, fold
//! with a character map, look) against the gated one (`Needle::may_match` first), for a query
//! no message holds, the case that reads every chat. Timings print with `ACPMUX_BENCH=1`; with
//! `ACPMUX_BENCH_SESSIONS=<dir>` (a daemon's `sessions` folder) it also runs over every text
//! copy (`store/text_index.rs`) there, the real messages a search on that host reads.

use super::*;
use crate::chats::search::{flatten, snippet};
use std::time::Instant;

fn messages(n: usize) -> Vec<String> {
    (0..n)
        .map(|i| {
            format!(
                "Message {i}: Ran `cargo test -p acpmux` in cmux-tui; 3 Failed, see the log at \
                 /tmp/run-{i}.log. The Fix is in src/hub/mod.rs line {}; retrying now.\n\n  \
                 Next: the bench, then the PR.",
                i % 977
            )
        })
        .collect()
}

/// Ungated: what each message cost before the gate.
fn full(needle: &Needle, texts: &[String]) -> usize {
    texts
        .iter()
        .filter(|t| {
            // `Folded::new` as it was: the folded text and a character index per byte.
            let flat = flatten(t);
            let mut folded = String::with_capacity(flat.len());
            let mut origin = Vec::with_capacity(flat.len());
            for (i, c) in flat.chars().enumerate() {
                for lower in c.to_lowercase().map(|l| if l == 'ς' { 'σ' } else { l }) {
                    folded.push(lower);
                    origin.extend(std::iter::repeat_n(i, lower.len_utf8()));
                }
            }
            std::hint::black_box(&origin);
            needle.words().iter().all(|w| folded.contains(w.as_str()))
        })
        .count()
}

/// Gated: the search's path now.
fn gated(needle: &Needle, texts: &[String]) -> usize {
    texts
        .iter()
        .filter(|t| {
            if !needle.may_match(t) {
                return false;
            }
            let flat = flatten(t);
            needle.find(&flat).map(|at| std::hint::black_box(snippet(&flat, at))).is_some()
        })
        .count()
}

fn best_ns(mut f: impl FnMut() -> usize) -> (u128, usize) {
    let mut best = u128::MAX;
    let mut found = 0;
    for _ in 0..3 {
        let t = Instant::now();
        found = f();
        best = best.min(t.elapsed().as_nanos());
    }
    (best, found)
}

#[test]
fn the_gate_keeps_each_message_s_cost_flat_and_finds_the_same() {
    let print = std::env::var_os("ACPMUX_BENCH").is_some();
    let needle = Needle::parse("zzqxvjk retry").expect("words");
    let hit = Needle::parse("bench retrying").expect("words");
    let mut per_message = Vec::new();
    for n in [10_000_usize, 100_000] {
        let texts = messages(n);
        let (old, old_found) = best_ns(|| full(&needle, &texts));
        let (new, new_found) = best_ns(|| gated(&needle, &texts));
        assert_eq!((old_found, new_found), (0, 0));
        assert_eq!(gated(&hit, &texts), n, "every message holds both words");
        per_message.push(new as f64 / n as f64);
        if print {
            println!(
                "bench session_search gate n={n}: full {:.1} ms, gated {:.1} ms ({:.1}x), \
                 {:.0} ns/message",
                old as f64 / 1e6,
                new as f64 / 1e6,
                old as f64 / new.max(1) as f64,
                new as f64 / n as f64,
            );
        }
    }
    // Flat: the cost of one message does not grow with how many there are (10x the messages,
    // well under 3x the cost each, fast-fail-open against a noisy machine).
    let ratio = per_message[1] / per_message[0];
    if print {
        println!("bench session_search gate 10x per-message ratio {ratio:.2}");
    }
    assert!(ratio < 3.0, "per-message cost grew {ratio:.2}x at 10x the messages");
}

#[test]
fn the_gate_over_a_host_s_real_text_copies() {
    let Some(dir) = std::env::var_os("ACPMUX_BENCH_SESSIONS") else { return };
    let mut texts = Vec::new();
    for chat in std::fs::read_dir(dir).expect("sessions dir").flatten() {
        let Ok(copies) = std::fs::read_dir(chat.path().join("search-index")) else {
            continue;
        };
        for copy in copies.flatten() {
            let Ok(bytes) = std::fs::read(copy.path()) else { continue };
            for line in bytes.split(|b| *b == b'\n').skip(1).filter(|l| !l.is_empty()) {
                if let Ok(entry) = serde_json::from_slice::<Entry>(line) {
                    texts.push(entry.text);
                }
            }
        }
    }
    let bytes: usize = texts.iter().map(String::len).sum();
    for query in ["zzqxvjk", "reply slot", "the"] {
        let needle = Needle::parse(query).expect("words");
        let (old, old_found) = best_ns(|| full(&needle, &texts));
        let (new, new_found) = best_ns(|| gated(&needle, &texts));
        assert_eq!(old_found, new_found, "{query}");
        println!(
            "bench session_search real {} messages, {:.1} MB, {query:?}: full {:.1} ms, gated \
             {:.1} ms ({:.1}x), {new_found} hits",
            texts.len(),
            bytes as f64 / 1e6,
            old as f64 / 1e6,
            new as f64 / 1e6,
            old as f64 / new.max(1) as f64,
        );
    }
}
