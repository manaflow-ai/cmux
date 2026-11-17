//! The history search index at 1x and at scale: a cold index, one appended message, one
//! backfill step that finds one new message, and query p50/p95 (a prefix, a phrase, a word no
//! message holds, a common word with one no message holds, a common word for a rare kind, and a
//! one-character query), at 1k, 50k and 500k messages, plus degenerate input (one 50 MB message,
//! emoji and other non-Latin text, one very long line).
//!
//! Leo, 2026-11-17: "we should be stress testing everything that isn't already stress tested".
//! The bar: an append, a step and every query cost the same at every size, within
//! [`GROWTH`] times the 1k p95 (plus [`FLOOR_MS`] for timer noise), so cost that grows with
//! the index fails. Cold index time is printed per message, and bounded the same way.
//!
//! Run by hand (a few minutes at the default sizes):
//! `cargo test -p cmux-history --release --test search_index_scale -- --ignored --nocapture`.
//! `SEARCH_SCALE_SIZES=1000,50000` picks other sizes; the first is the 1x.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_history::{
    Backfill, HistoryError, MAX_TEXT_BYTES, SearchDoc, SearchFeed, SearchIndex, SearchKind,
};

/// Scale p95 over 1x p95 that fails the bench.
const GROWTH: f64 = 3.0;
/// Added to every bound: below it, a p95 is timer and scheduler noise.
const FLOOR_MS: f64 = 1.0;
/// Messages per chat (one source per chat).
const PER_CHAT: usize = 50;
const ROUNDS: usize = 200;
const LIMIT: usize = 50;

/// A word no message holds.
const ABSENT: &str = "zqxjvkw";

fn sizes() -> Vec<usize> {
    std::env::var("SEARCH_SCALE_SIZES")
        .ok()
        .map(|v| v.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![1_000, 50_000, 500_000])
}

/// xorshift64*: the same text on every run.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

const COMMON: &[&str] = &[
    "the", "and", "that", "this", "with", "for", "from", "sidebar", "deploy", "build", "test",
    "fix", "error", "chat", "window", "terminal", "branch", "merge", "review", "index", "query",
    "row", "render", "frame", "cache", "daemon", "socket", "agent", "prompt", "answer",
];

/// One message of 20 to 80 words: common words and made-up ones, so trigrams spread as in
/// real text and every common word is in many messages.
fn message(rng: &mut Rng) -> String {
    let words = 20 + rng.below(60);
    let mut text = String::new();
    for _ in 0..words {
        if !text.is_empty() {
            text.push(' ');
        }
        if rng.below(3) == 0 {
            let len = 3 + rng.below(6);
            for _ in 0..len {
                text.push(char::from(b'a' + rng.below(26) as u8));
            }
        } else {
            text.push_str(COMMON[rng.below(COMMON.len())]);
        }
    }
    // Never the absent word: a made-up word could spell it.
    text.replace(ABSENT, "absent")
}

/// Doc `i`: chats mostly, some commands and scrollback, one in a hundred a tab or workspace
/// name (none of which holds "the").
fn doc(i: usize, rng: &mut Rng) -> SearchDoc {
    let chat = i / PER_CHAT;
    let kind = match i % 100 {
        0 => SearchKind::Tab,
        1 => SearchKind::Workspace,
        2..=5 => SearchKind::Command,
        6..=11 => SearchKind::Scrollback,
        _ => SearchKind::Chat,
    };
    let (title, text) = if matches!(kind, SearchKind::Tab | SearchKind::Workspace) {
        let name = format!("{} {}", COMMON[7 + rng.below(COMMON.len() - 7)], chat);
        (name.clone(), name)
    } else {
        (format!("chat {chat}"), message(rng))
    };
    SearchDoc {
        key: format!("doc:{i}"),
        source: source(chat),
        kind,
        target: format!("session-{chat}"),
        position: Some((i % PER_CHAT) as i64),
        title,
        text,
        at_ms: 1_760_000_000_000 + i as i64,
    }
}

fn source(chat: usize) -> String {
    format!("acpmux:{chat}")
}

/// A scratch index file, removed on drop.
struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("search-index-scale-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Self(dir)
    }

    fn open(&self) -> SearchIndex {
        SearchIndex::open(&self.0.join("index.sqlite")).expect("open index")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A feed of `chats` chats, all caught up but the last, which has one message more than the
/// index holds: what the worker reads on each idle poll once new text arrives.
struct Feed {
    chats: usize,
    last: SearchDoc,
}

impl SearchFeed for Feed {
    fn sources(&self) -> Result<Vec<String>, HistoryError> {
        Ok((0..self.chats).map(source).collect())
    }

    fn read(
        &self,
        source: &str,
        after: Option<i64>,
        _max: usize,
    ) -> Result<(Vec<SearchDoc>, i64), HistoryError> {
        let cursor = after.unwrap_or(0);
        if source == self.last.source && after == Some(PER_CHAT as i64) {
            return Ok((vec![self.last.clone()], cursor + 1));
        }
        Ok((Vec::new(), cursor))
    }
}

#[derive(Clone, Copy, Debug)]
struct Stats {
    p50: f64,
    p95: f64,
}

fn stats(mut samples: Vec<Duration>) -> Stats {
    samples.sort_unstable();
    let at = |q: f64| {
        let i = ((samples.len() as f64 - 1.0) * q).round() as usize;
        samples[i].as_secs_f64() * 1e3
    };
    Stats { p50: at(0.50), p95: at(0.95) }
}

fn time<T>(mut f: impl FnMut() -> T) -> Stats {
    // One round warms the page cache and the statement cache.
    let _ = f();
    stats(
        (0..ROUNDS)
            .map(|_| {
                let start = Instant::now();
                std::hint::black_box(f());
                start.elapsed()
            })
            .collect(),
    )
}

const QUERIES: &[(&str, &str, &[SearchKind])] = &[
    ("prefix", "sideb", &[]),
    ("phrase", "deploy the sidebar", &[]),
    ("no-hit", ABSENT, &[]),
    ("common+no-hit", "the zqxjvkw", &[]),
    ("common, tabs only", "the", &[SearchKind::Tab]),
    ("1-char", "s", &[]),
];

struct Size {
    n: usize,
    cold_us_per_doc: f64,
    append: Stats,
    step: Stats,
    queries: Vec<Stats>,
}

fn run(n: usize) -> Size {
    let scratch = Scratch::new(&n.to_string());
    let mut index = scratch.open();
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let started = Instant::now();
    let chats = n.div_ceil(PER_CHAT);
    for chat in 0..chats {
        let docs: Vec<SearchDoc> =
            (chat * PER_CHAT..n.min((chat + 1) * PER_CHAT)).map(|i| doc(i, &mut rng)).collect();
        index.append(&source(chat), &docs, Some(docs.len() as i64)).expect("append");
    }
    let cold_us_per_doc = started.elapsed().as_secs_f64() * 1e6 / n as f64;

    // One new message appended to the newest chat, again and again under its own key.
    let mut next = n;
    let append = time(|| {
        let doc = doc(next, &mut rng);
        next += 1;
        index.append(&doc.source, std::slice::from_ref(&doc), None).expect("append one")
    });

    // One backfill step over every chat, the last with one new message. The cursor goes back
    // each round, so each step finds the message again.
    let last_chat = chats - 1;
    let mut last = doc(last_chat * PER_CHAT, &mut rng);
    last.key = "doc:step".to_owned();
    last.source = source(last_chat);
    let feed = Feed { chats, last };
    let step = time(|| {
        index.append(&source(last_chat), &[], Some(PER_CHAT as i64)).expect("rewind");
        let step = Backfill::step(&mut index, &feed, 256).expect("step");
        assert_eq!(step.indexed, 1);
    });

    let queries = QUERIES
        .iter()
        .map(|(label, query, kinds)| {
            let hits = index.search(query, kinds, LIMIT).expect("search").len();
            let stats = time(|| index.search(query, kinds, LIMIT).expect("search"));
            println!(
                "N={n:>7} query {label:<18} hits={hits:>3} p50={:>8.3} ms p95={:>8.3} ms",
                stats.p50, stats.p95
            );
            stats
        })
        .collect();
    println!(
        "N={n:>7} cold {cold_us_per_doc:.1} us/msg; append-1 p50={:.3} p95={:.3} ms; \
         step p50={:.3} p95={:.3} ms",
        append.p50, append.p95, step.p50, step.p95
    );
    Size { n, cold_us_per_doc, append, step, queries }
}

fn bound(base: f64) -> f64 {
    base * GROWTH + FLOOR_MS
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn search_index_cost_is_flat_as_messages_grow() {
    let sizes: Vec<Size> = sizes().into_iter().map(run).collect();
    let base = &sizes[0];
    let mut failures = Vec::new();
    println!("\n| N | what | p50 ms | p95 ms |\n|---|---|---|---|");
    for size in &sizes {
        let mut rows = vec![("append-1", size.append, base.append), ("step", size.step, base.step)];
        for (i, (label, _, _)) in QUERIES.iter().enumerate() {
            rows.push((label, size.queries[i], base.queries[i]));
        }
        for (label, stats, base_stats) in rows {
            println!("| {} | {label} | {:.3} | {:.3} |", size.n, stats.p50, stats.p95);
            if stats.p95 > bound(base_stats.p95) {
                failures.push(format!(
                    "{label} at {}: p95 {:.3} ms > {:.3} ms ({GROWTH}x the {} p95 {:.3} ms + {FLOOR_MS})",
                    size.n,
                    stats.p95,
                    bound(base_stats.p95),
                    base.n,
                    base_stats.p95
                ));
            }
        }
        // Cold indexing: the cost of one message stays the same however many came before.
        if size.cold_us_per_doc > base.cold_us_per_doc * GROWTH {
            failures.push(format!(
                "cold index at {}: {:.1} us/msg > {GROWTH}x the {} {:.1} us/msg",
                size.n, size.cold_us_per_doc, base.n, base.cold_us_per_doc
            ));
        }
    }
    assert!(failures.is_empty(), "cost grew with the index:\n{}", failures.join("\n"));
}

/// One 50 MB message, emoji and other non-Latin text, and one line of 1 MB without a space:
/// each indexes, each is found, and a query over them stays within budget.
#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn search_index_degenerate_input() {
    let scratch = Scratch::new("degenerate");
    let mut index = scratch.open();
    let mut rng = Rng(7);
    let base: Vec<SearchDoc> = (0..1_000).map(|i| doc(i, &mut rng)).collect();
    index.append("base", &base, None).expect("base");

    // The words looked for are in the first `MAX_TEXT_BYTES`: the index holds no more of a doc.
    let mut huge = String::from("hugeneedle ");
    huge.reserve(50 << 20);
    while huge.len() < 50 << 20 {
        huge.push_str(&message(&mut rng));
        huge.push('\n');
    }
    let emoji = "🚀 déploiement réussi ✅ 部署成功 развёртывание 🎉 ΟΣ ".repeat(2_000);
    let long = format!("{}longneedle{}", "x".repeat(200 << 10), "x".repeat(1 << 20));
    let docs = [("huge", huge), ("emoji", emoji), ("long", long)];
    for (key, text) in &docs {
        let mut doc = doc(0, &mut rng);
        doc.key = (*key).to_owned();
        doc.kind = SearchKind::Chat;
        doc.text.clone_from(text);
        let start = Instant::now();
        index.upsert(&doc).expect("upsert");
        println!("degenerate {key}: {} bytes indexed in {:?}", text.len(), start.elapsed());
    }
    // A doc where the words match thousands of times (the emoji one) costs its snippet's pick over
    // every match, bounded by `MAX_TEXT_BYTES`: 56 ms at p95 on a lane VM.
    let budget_ms = 100.0;
    for (query, key) in [
        ("hugeneedle", "huge"),
        ("部署成功", "emoji"),
        ("réussi", "emoji"),
        ("🚀", "emoji"),
        ("longneedle", "long"),
    ] {
        let hits = index.search(query, &[], LIMIT).expect("search");
        // "🚀" is one character, under the trigram's three: it matches names only.
        if query.chars().count() >= 3 {
            assert!(hits.iter().any(|hit| hit.key == key), "{query} finds {key}: {hits:?}");
        }
        let stats = time(|| index.search(query, &[], LIMIT).expect("search"));
        println!("degenerate query {query}: p50={:.3} ms p95={:.3} ms", stats.p50, stats.p95);
        assert!(stats.p95 <= budget_ms, "{query}: p95 {:.3} ms > {budget_ms} ms", stats.p95);
    }
    // Replacing the 50 MB message (an edited chat) costs its delete and insert, once.
    let start = Instant::now();
    let mut doc = doc(0, &mut rng);
    doc.key = "huge".to_owned();
    index.upsert(&doc).expect("replace huge");
    println!("degenerate replace huge: {:?}", start.elapsed());
}

/// A doc past [`MAX_TEXT_BYTES`] is held to its first that many bytes, cut on a character
/// boundary: a word past the bound is not found, one before it is. Without the bound, a query
/// that found a 50 MB message took 5.1 s at p95 (`search_index_degenerate_input`).
#[test]
fn a_doc_past_the_bound_is_held_to_it() {
    let scratch = Scratch::new("bound");
    let mut index = scratch.open();
    let mut doc = doc(2_000, &mut Rng(3));
    // Two-byte characters after an odd prefix: the bound falls inside one.
    let fill = "é".repeat(MAX_TEXT_BYTES / 2);
    doc.text = format!("insideword {fill} pastword");
    index.upsert(&doc).expect("upsert");
    assert_eq!(index.search("insideword", &[], LIMIT).expect("search").len(), 1);
    assert!(index.search("pastword", &[], LIMIT).expect("search").is_empty());
}
