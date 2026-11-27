//! The Cmd-K chats page's search as an on-disk FTS5 index ([`SearchIndex`], trigram) instead of
//! acpmux's in-memory text (`acpmux/src/chats/text.rs`), at 2,000, 20,000 and 50,000 chats.
//!
//! acpmux's index scans at most 128 MiB of text a keystroke, newest chats first: its p95 is bounded
//! by that cap, and a chat older than the cap is not found at all (about 2,300 chats sized like real
//! stores; `acpmux/tests/chats_search_bench.rs` prints how much of the cap its fixture holds). This
//! bench asks whether an index updated on write keeps every chat findable at a keystroke cost that
//! does not grow with history: the same text as that bench's fixture (its store sizes, turns,
//! prompt and answer lengths, Zipf vocabulary and planted phrases), one doc per prompt or answer,
//! each planted phrase typed a key at a time from its third letter (the trigram index's shortest
//! word), the p95 over every keystroke at each size, every planted chat found, the cost of one
//! appended turn (a chat that grew), the build time and the file size.
//!
//! Shadow-leo, 2026-11-26: "run the same bench at 20k and 50k and tell me where p95 bends ... then
//! try a prebuilt local index (sqlite fts5, updated on write) so keystroke cost stops scaling with
//! history at all."
//!
//! Run by hand, release (tens of minutes at 50,000 chats):
//! `cargo test -p cmux-history --release --test chat_search_fts_scale -- --ignored --nocapture`.
//! `CHAT_FTS_SIZES=2000,20000` picks the sizes; `CHAT_FTS_MIB=0.1` scales the stores as
//! `chats_search_bench`'s `CHAT_SEARCH_BENCH_MIB` does.

use std::path::PathBuf;
use std::time::Instant;

use cmux_history::{SearchDoc, SearchIndex, SearchKind};

const PHRASES: usize = 8;
const MEDIAN_BYTES: f64 = 1024.0 * 1024.0;
const SIGMA: f64 = 1.264;
const MAX_BYTES: f64 = 64.0 * 1024.0 * 1024.0;
const PROMPT_WORDS: usize = 30;
const ANSWER_WORDS: usize = 120;
const TOOL_BYTES: usize = 30_000;
const VOCABULARY: usize = 20_000;
const TARGET_MS: f64 = 150.0;
const LIMIT: usize = 50;
/// Docs written a transaction.
const BATCH: usize = 4_096;

const PLANTED: [&str; PHRASES] = [
    "quorvax thrennel 7731",
    "wexmund plyratic jorvane",
    "zubrik halcyonde 4419",
    "fennowick sardaxis quell",
    "trowbaine oxyllan vetch",
    "mirquade 2207 calloweth",
    "jusperin draxholm yewt",
    "orvelline kestrix 9058",
];

/// xorshift64*, seeded as `chats_search_bench`'s fixture is.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn normal(&mut self) -> f64 {
        let (u, v) = (self.unit().max(f64::MIN_POSITIVE), self.unit());
        (-2.0 * u.ln()).sqrt() * (std::f64::consts::TAU * v).cos()
    }

    fn zipf(&mut self, n: usize) -> usize {
        ((n as f64).powf(self.unit()) as usize).saturating_sub(1).min(n - 1)
    }
}

fn vocabulary(rng: &mut Rng) -> Vec<String> {
    const ON: [&str; 16] =
        ["b", "c", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z", "h"];
    const NU: [&str; 6] = ["a", "e", "i", "o", "u", "ai"];
    (0..VOCABULARY)
        .map(|_| {
            let syllables = 1 + (rng.next() % 4) as usize;
            (0..syllables)
                .map(|_| {
                    format!("{}{}", ON[(rng.next() % 16) as usize], NU[(rng.next() % 6) as usize])
                })
                .collect()
        })
        .collect()
}

fn sentence(rng: &mut Rng, words: &[String], count: usize) -> String {
    let mut out = String::new();
    for i in 0..count {
        if i > 0 {
            out.push(' ');
        }
        out.push_str(&words[rng.zipf(words.len())]);
    }
    out
}

/// A scratch index file and its WAL, removed on drop.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let mut path = self.0.clone().into_os_string();
            path.push(suffix);
            let _ = std::fs::remove_file(PathBuf::from(path));
        }
    }
}

fn file_bytes(path: &PathBuf) -> u64 {
    ["", "-wal"]
        .iter()
        .map(|suffix| {
            let mut p = path.clone().into_os_string();
            p.push(suffix);
            std::fs::metadata(PathBuf::from(p)).map_or(0, |m| m.len())
        })
        .sum()
}

fn doc(chat: usize, turn: usize, role: &str, text: String, at_ms: i64) -> SearchDoc {
    SearchDoc {
        key: format!("chat:{chat}:{turn}:{role}"),
        source: format!("acpmux:{chat}"),
        kind: SearchKind::Chat,
        target: format!("session-{chat}"),
        position: Some(turn as i64),
        title: format!("chat {chat}"),
        text,
        at_ms,
    }
}

fn nearest_rank(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1]
}

fn env_sizes() -> Vec<usize> {
    std::env::var("CHAT_FTS_SIZES")
        .ok()
        .map(|v| v.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![2_000, 20_000, 50_000])
}

struct Run {
    chats: usize,
    p50: f64,
    p95: f64,
    max: f64,
    found: usize,
    append_p95: f64,
}

fn run(chats: usize, scale: f64) -> Run {
    let path =
        std::env::temp_dir().join(format!("chat-fts-scale-{}-{chats}.sqlite", std::process::id()));
    let scratch = Scratch(path.clone());
    let mut index = SearchIndex::open(&scratch.0).expect("open");
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let words = vocabulary(&mut rng);
    let planted_at: Vec<usize> =
        (0..PHRASES).map(|i| (i * 2 + 1) * chats / (PHRASES * 2)).collect();

    let started = Instant::now();
    let (mut docs, mut text_bytes, mut messages) = (Vec::with_capacity(BATCH), 0_u64, 0_u64);
    let mut flush = |index: &mut SearchIndex, docs: &mut Vec<SearchDoc>| {
        if !docs.is_empty() {
            index.append("bench", docs, None).expect("append");
            docs.clear();
        }
    };
    for n in 0..chats {
        let bytes = (MEDIAN_BYTES * (SIGMA * rng.normal()).exp()).min(MAX_BYTES) * scale;
        let turns = (bytes as usize / (TOOL_BYTES + 1_200)).max(2);
        let planted = planted_at.iter().position(|&at| at == n).map(|i| PLANTED[i]);
        // Newest first, as the fixture lists them: chat n is 20 minutes older than chat n - 1.
        let at_ms = 1_795_000_000_000 - (n as i64) * 1_200_000;
        for turn in 0..turns {
            let prompt = sentence(&mut rng, &words, PROMPT_WORDS);
            let mut answer = sentence(&mut rng, &words, ANSWER_WORDS);
            if let Some(planted) = planted.filter(|_| turn == turns / 2) {
                answer = format!("{answer} {planted} {}", sentence(&mut rng, &words, 20));
            }
            text_bytes += (prompt.len() + answer.len()) as u64;
            messages += 2;
            docs.push(doc(n, turn, "prompt", prompt, at_ms + turn as i64));
            docs.push(doc(n, turn, "answer", answer, at_ms + turn as i64));
            if docs.len() >= BATCH {
                flush(&mut index, &mut docs);
            }
        }
    }
    flush(&mut index, &mut docs);
    let built = started.elapsed().as_secs_f64();
    println!(
        "{chats} chats: {messages} messages, {:.0} MiB of text, built in {built:.1} s ({:.1} MiB/s), \
         file {:.0} MiB",
        text_bytes as f64 / 1048576.0,
        text_bytes as f64 / 1048576.0 / built,
        file_bytes(&path) as f64 / 1048576.0
    );

    // Each planted phrase typed a key at a time, from its third letter.
    let (mut times, mut found) = (Vec::new(), 0);
    for (i, phrase) in PLANTED.iter().enumerate() {
        let target = format!("session-{}", planted_at[i]);
        let mut hit = false;
        for end in 3..=phrase.len() {
            if !phrase.is_char_boundary(end) {
                continue;
            }
            let query = &phrase[..end];
            let started = Instant::now();
            let hits = index.search(query, &[SearchKind::Chat], LIMIT).expect("search");
            times.push(started.elapsed().as_secs_f64() * 1000.0);
            if end == phrase.len() {
                hit = hits.iter().any(|h| h.target == target);
            }
        }
        println!("  {phrase:?}: {}", if hit { "found" } else { "NOT found" });
        found += usize::from(hit);
    }
    times.sort_by(f64::total_cmp);

    // One turn appended to the newest chat (a chat that grew), committed alone.
    let mut appends = Vec::new();
    for k in 0..50 {
        let prompt = sentence(&mut rng, &words, PROMPT_WORDS);
        let answer = sentence(&mut rng, &words, ANSWER_WORDS);
        let batch = [
            doc(0, 100_000 + k, "prompt", prompt, 1_795_000_100_000 + k as i64),
            doc(0, 100_000 + k, "answer", answer, 1_795_000_100_000 + k as i64),
        ];
        let started = Instant::now();
        index.append("acpmux:0", &batch, None).expect("append turn");
        appends.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    appends.sort_by(f64::total_cmp);

    let run = Run {
        chats,
        p50: nearest_rank(&times, 0.5),
        p95: nearest_rank(&times, 0.95),
        max: *times.last().expect("times"),
        found,
        append_p95: nearest_rank(&appends, 0.95),
    };
    println!(
        "{chats} chats: keystroke p50 {:.2} ms, p95 {:.2} ms, max {:.2} ms over {} keys; {found}/{PHRASES} \
         found; one appended turn p95 {:.2} ms",
        run.p50,
        run.p95,
        run.max,
        times.len(),
        run.append_p95
    );
    println!(
        "PERF_ROW {}",
        serde_json::json!({"name": format!("chat_search.fts.{chats}.keystroke"), "p50": run.p50,
                           "p95": run.p95, "unit": "ms", "found": found, "phrases": PHRASES})
    );
    run
}

#[test]
#[ignore = "a benchmark: tens of minutes at 50,000 chats"]
fn an_fts5_chat_index_finds_every_chat_at_a_flat_keystroke_cost() {
    let scale: f64 = std::env::var("CHAT_FTS_MIB").ok().and_then(|v| v.parse().ok()).unwrap_or(1.0);
    let runs: Vec<Run> = env_sizes().into_iter().map(|chats| run(chats, scale)).collect();
    println!("chats    p50 ms   p95 ms   max ms  found  append p95 ms");
    for r in &runs {
        println!(
            "{:>6} {:>8.2} {:>8.2} {:>8.2}  {}/{PHRASES}  {:>8.2}",
            r.chats, r.p50, r.p95, r.max, r.found, r.append_p95
        );
    }
    for r in &runs {
        assert_eq!(r.found, PHRASES, "{} chats: a planted chat was not found", r.chats);
        assert!(
            r.p95 <= TARGET_MS,
            "{} chats: keystroke p95 {:.1} ms over {TARGET_MS} ms",
            r.chats,
            r.p95
        );
    }
}
