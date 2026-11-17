//! The chat index at 1x and at scale: a cold scan of a Claude Code root and a Codex root, then
//! one line appended to one transcript (the watcher burst every agent write makes), at 1k, 10k
//! and 50k transcripts, plus degenerate transcripts (one of 50 MB, emoji and other non-Latin
//! text, one very long line).
//!
//! Leo, 2026-11-17: "we should be stress testing everything that isn't already stress tested".
//! The bar: one appended line costs the same at every size, within [`GROWTH`] times the 1k p95
//! (plus [`FLOOR_MS`] for timer noise). A cold scan reads every file, so it is bounded per file.
//! A root holds at most `AdapterConfig::DEFAULT_MAX_FILES` newest files; past that the rest are
//! not listed. Manual (a few minutes):
//! `cargo test -p cmux-chat-index --release --test scale_bench -- --ignored --nocapture --test-threads=1`.
//! `CHAT_SCALE_SIZES=1000,10000` picks other sizes; the first is the 1x.

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Scale p95 over 1x p95 that fails the bench.
const GROWTH: f64 = 3.0;
/// Added to every bound: below it, a p95 is timer and scheduler noise.
const FLOOR_MS: f64 = 1.0;
const ROUNDS: usize = 100;

fn sizes() -> Vec<usize> {
    std::env::var("CHAT_SCALE_SIZES")
        .ok()
        .map(|v| v.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![1_000, 10_000, 50_000])
}

fn claude_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn codex_id(i: usize) -> String {
    format!("019a0000-0000-7000-8000-{i:012}")
}

fn claude_line(i: usize, second: usize, text: &str) -> String {
    let (m, s) = (second / 60 % 60, second % 60);
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"{}","timestamp":"2026-10-01T01:{m:02}:{s:02}.000Z","message":{{"role":"user","content":{}}}}}"#,
        i % 50,
        claude_id(i),
        serde_json::Value::from(text)
    )
}

fn claude_file(root: &Path, i: usize) -> PathBuf {
    root.join(format!("-work-p{}", i % 50)).join(format!("{}.jsonl", claude_id(i)))
}

fn codex_meta(i: usize) -> String {
    format!(
        r#"{{"timestamp":"2026-10-01T10:00:00.000Z","type":"session_meta","payload":{{"id":"{}","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/work/p{}","originator":"codex_cli_rs"}}}}"#,
        codex_id(i),
        i % 50
    )
}

fn codex_prompt(text: &str) -> String {
    format!(
        r#"{{"timestamp":"2026-10-01T10:00:01.000Z","type":"event_msg","payload":{{"type":"user_message","message":{}}}}}"#,
        serde_json::Value::from(text)
    )
}

fn codex_file(root: &Path, i: usize) -> PathBuf {
    root.join("sessions/2026/10")
        .join(format!("{:02}", 1 + i % 28))
        .join(format!("rollout-2026-10-01T10-00-00-{}.jsonl", codex_id(i)))
}

fn root(harness: AdapterKind, path: &Path) -> ChatRoot {
    ChatRoot {
        harness,
        path: path.to_path_buf(),
        real_path: path.canonicalize().unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    }
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn append(path: &Path, line: &str) {
    let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    writeln!(f, "{line}").unwrap();
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

struct Size {
    n: usize,
    chats: usize,
    cold_us_per_file: f64,
    claude_append: Stats,
    codex_append: Stats,
}

/// `n` transcripts, half Claude Code, half Codex, each of a few prompts.
fn run(n: usize) -> Size {
    let home = tempfile::tempdir().unwrap();
    let claude = home.path().join("claude/projects");
    let codex = home.path().join("codex");
    let half = n / 2;
    for i in 0..half {
        let lines: Vec<String> = (0..4)
            .map(|t| claude_line(i, (i + t) % 3600, &format!("chat {i} prompt {t}")))
            .collect();
        write(&claude_file(&claude, i), &(lines.join("\n") + "\n"));
        let lines = [codex_meta(i), codex_prompt(&format!("codex chat {i}"))];
        write(&codex_file(&codex, i), &(lines.join("\n") + "\n"));
    }
    let started = Instant::now();
    let mut index = ChatIndex::new(vec![
        root(AdapterKind::ClaudeCode, &claude),
        root(AdapterKind::Codex, &codex),
    ]);
    index.rescan_all();
    let cold_us_per_file = started.elapsed().as_secs_f64() * 1e6 / n as f64;
    let chats = index.len();

    let mut time_append = |file: PathBuf, line: &dyn Fn(usize) -> String| {
        let samples = (0..ROUNDS)
            .map(|round| {
                append(&file, &line(round));
                let started = Instant::now();
                let changes = index.paths_changed(std::slice::from_ref(&file));
                let took = started.elapsed();
                assert_eq!(changes.len(), 1, "one chat changed: {changes:?}");
                took
            })
            .collect();
        stats(samples)
    };
    let mid = half / 2;
    let claude_append = time_append(claude_file(&claude, mid), &|round| {
        claude_line(mid, 3599, &format!("next prompt {round}"))
    });
    let codex_append =
        time_append(codex_file(&codex, mid), &|round| codex_prompt(&format!("next {round}")));
    println!(
        "N={n:>6} chats={chats:>6} cold {cold_us_per_file:.1} us/file; append-1 claude \
         p50={:.3} p95={:.3} ms, codex p50={:.3} p95={:.3} ms",
        claude_append.p50, claude_append.p95, codex_append.p50, codex_append.p95
    );
    Size { n, chats, cold_us_per_file, claude_append, codex_append }
}

fn bound(base: f64) -> f64 {
    base * GROWTH + FLOOR_MS
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn chat_index_append_cost_is_flat_as_transcripts_grow() {
    let sizes: Vec<Size> = sizes().into_iter().map(run).collect();
    let base = &sizes[0];
    let mut failures = Vec::new();
    println!("\n| N files | chats | what | p50 ms | p95 ms |\n|---|---|---|---|---|");
    for size in &sizes {
        for (label, stats, base_stats) in [
            ("append-1 claude", size.claude_append, base.claude_append),
            ("append-1 codex", size.codex_append, base.codex_append),
        ] {
            println!(
                "| {} | {} | {label} | {:.3} | {:.3} |",
                size.n, size.chats, stats.p50, stats.p95
            );
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
        println!(
            "| {} | {} | cold scan us/file | {:.1} | |",
            size.n, size.chats, size.cold_us_per_file
        );
        if size.cold_us_per_file > base.cold_us_per_file * GROWTH {
            failures.push(format!(
                "cold scan at {}: {:.1} us/file > {GROWTH}x the {} {:.1} us/file",
                size.n, size.cold_us_per_file, base.n, base.cold_us_per_file
            ));
        }
    }
    assert!(failures.is_empty(), "cost grew with the transcripts:\n{}", failures.join("\n"));
}

/// A 50 MB transcript, emoji and other non-Latin prompts, and a 1 MB line without a space: each
/// is listed with its title, and appending one line to the 50 MB one reads only that line.
#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn chat_index_degenerate_transcripts() {
    let home = tempfile::tempdir().unwrap();
    let claude = home.path().join("projects");
    let mut huge = String::with_capacity(50 << 20);
    let mut t = 0;
    while huge.len() < 50 << 20 {
        huge.push_str(&claude_line(0, t % 3600, &"tool output line ".repeat(200)));
        huge.push('\n');
        t += 1;
    }
    write(&claude_file(&claude, 0), &huge);
    let emoji = "🚀 déploiement réussi ✅ 部署成功 развёртывание 🎉 ΟΣ İstanbul";
    write(&claude_file(&claude, 1), &(claude_line(1, 1, emoji) + "\n"));
    let long = "x".repeat(1 << 20);
    write(&claude_file(&claude, 2), &(claude_line(2, 2, &long) + "\n"));

    let started = Instant::now();
    let mut index = ChatIndex::new(vec![root(AdapterKind::ClaudeCode, &claude)]);
    index.rescan_all();
    println!("degenerate cold scan: {:?}, {} chats", started.elapsed(), index.len());
    assert_eq!(index.len(), 3);
    let title = |i: usize| {
        index
            .chats()
            .into_iter()
            .find(|c| c.entry.session_id == claude_id(i))
            .and_then(|c| c.entry.title.clone())
            .unwrap_or_default()
    };
    assert!(title(1).contains("部署成功"), "emoji title: {}", title(1));
    assert!(title(2).len() <= 4096, "a 1 MB title is held to a title's length: {}", title(2).len());

    let file = claude_file(&claude, 0);
    let samples: Vec<Duration> = (0..ROUNDS)
        .map(|round| {
            append(&file, &claude_line(0, 3599, &format!("next {round}")));
            let started = Instant::now();
            index.paths_changed(std::slice::from_ref(&file));
            started.elapsed()
        })
        .collect();
    let stats = stats(samples);
    println!("degenerate append-1 to 50 MB: p50={:.3} ms p95={:.3} ms", stats.p50, stats.p95);
    assert!(stats.p95 <= 10.0, "append to a 50 MB transcript: p95 {:.3} ms > 10 ms", stats.p95);
}
