//! Degenerate transcripts for the chat index: one of 50 MB, emoji and other non-Latin text, and
//! one 1 MB line without a space. Each is listed with its title, and one line appended to the
//! 50 MB one costs that line, not the file (`scale_stress.rs` covers the index at scale).
//!
//! Leo, 2026-11-17: "we should be stress testing everything that isn't already stress tested".
//! Manual: `cargo test -p cmux-chat-index --release --test degenerate_transcripts -- --ignored
//! --nocapture`.

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const ROUNDS: usize = 100;

fn claude_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
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
