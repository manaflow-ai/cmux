//! The chat index at 100, 5,000, 20,000 and 100,000 chats: what All chats, its search and Home
//! wait on. A synthetic corpus in the layouts the adapters read (Claude Code
//! `projects/<enc cwd>/<id>.jsonl`, Codex `sessions/YYYY/MM/DD/rollout-*.jsonl` with its
//! `session_index.jsonl` names), then: the cold scan, a rescan with nothing changed (the daemon's
//! start after it loads its cache, and each lost-events rescan), one transcript appended and
//! applied, one Codex rollout appended and applied, the first page a client reads, and the cache
//! save and load.
//!
//! The rule: a rescan of unchanged files costs a stat each and reads no transcript; one changed
//! file costs that file, not the corpus; the first page costs the page.
//!
//! The timing sweep runs only when asked: `CMUX_STRESS=1`, or a `cargo test` filter naming
//! `stress_bench` (nextest's `--exact` run skips it). It prints one `STRESS-CHAT-INDEX` JSON line
//! per size. The counted tests below run on every `cargo test`: they count bytes read (Linux
//! `/proc/thread-self/io`), not time, so they are the same on every machine.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Instant;

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use serde_json::{Value, json};

/// Every this many Claude chats, one long transcript (past the 64 KiB head and tail windows).
const LONG_EVERY: usize = 500;
/// Codex chats per Claude chat: one in five chats is a Codex rollout.
const CODEX_EVERY: usize = 5;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("stress_bench")) && !args.iter().any(|a| a == "--exact")
}

fn claude_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn codex_id(i: usize) -> String {
    format!("019a0000-0000-7000-8000-{i:012}")
}

fn clock(i: usize) -> String {
    let (h, m, s) = (i / 3600 % 24, i / 60 % 60, i % 60);
    format!("2026-10-01T{h:02}:{m:02}:{s:02}.000Z")
}

fn claude_line(i: usize, kind: &str, text: &str) -> String {
    format!(
        r#"{{"type":"{kind}","isSidechain":false,"cwd":"/work/p{}","sessionId":"{}","timestamp":"{}","message":{{"role":"{kind}","content":"{text}"}}}}"#,
        i % 50,
        claude_id(i),
        clock(i)
    )
}

fn claude_file(projects: &Path, i: usize) -> PathBuf {
    projects.join(format!("-work-p{}", i % 50)).join(format!("{}.jsonl", claude_id(i)))
}

fn codex_file(codex: &Path, i: usize) -> PathBuf {
    codex.join(format!("sessions/2026/10/{:02}", 1 + i % 28)).join(format!(
        "rollout-2026-10-{:02}T00-00-00-{}.jsonl",
        1 + i % 28,
        codex_id(i)
    ))
}

fn codex_prompt(i: usize, text: &str) -> String {
    json!({"timestamp": clock(i), "type": "event_msg",
        "payload": {"type": "user_message", "message": text}})
    .to_string()
}

/// One Claude transcript: a typed prompt, an answer, a title; a long one pads its middle.
fn write_claude(projects: &Path, i: usize) {
    let mut body = String::new();
    // Unicode prompts and duplicate titles too: every 7th chat asks the same thing.
    let prompt =
        if i % 7 == 0 { "fix the build".to_owned() } else { format!("chat {i} über ✓ build") };
    body += &claude_line(i, "user", &prompt);
    body.push('\n');
    body += &claude_line(i, "assistant", &format!("answer {i} {}", "lorem ipsum ".repeat(30)));
    body.push('\n');
    if i % LONG_EVERY == 0 {
        let filler = claude_line(i, "assistant", &"x".repeat(2_000));
        for _ in 0..100 {
            body += &filler;
            body.push('\n');
        }
    }
    body +=
        &format!(r#"{{"type":"ai-title","aiTitle":"Title {i}","sessionId":"{}"}}"#, claude_id(i));
    body.push('\n');
    let file = claude_file(projects, i);
    std::fs::write(file, body).unwrap();
}

/// One Codex rollout: `session_meta` with instructions (as Codex writes them), then prompts.
fn write_codex(codex: &Path, i: usize) {
    let meta = json!({"timestamp": clock(i), "type": "session_meta", "payload": {
        "id": codex_id(i), "timestamp": clock(i), "cwd": format!("/work/c{}", i % 20),
        "originator": "codex_cli_rs", "instructions": "Be careful. ".repeat(400)}});
    let body = format!("{meta}\n{}\n", codex_prompt(i, &format!("codex chat {i}")));
    std::fs::write(codex_file(codex, i), body).unwrap();
}

/// A corpus of `chats` chats under `home`: `projects` (Claude Code) and `codex` (no state
/// database, so the rollouts are read). Every third Codex chat has a name in the session index.
struct Corpus {
    projects: PathBuf,
    codex: PathBuf,
    claude: usize,
    codex_chats: usize,
}

impl Corpus {
    fn build(home: &Path, chats: usize) -> Self {
        let projects = home.join(".claude/projects");
        let codex = home.join(".codex");
        let codex_chats = chats / CODEX_EVERY;
        let claude = chats - codex_chats;
        for p in 0..50.min(claude.max(1)) {
            std::fs::create_dir_all(projects.join(format!("-work-p{p}"))).unwrap();
        }
        for d in 1..=28 {
            std::fs::create_dir_all(codex.join(format!("sessions/2026/10/{d:02}"))).unwrap();
        }
        for i in 0..claude {
            write_claude(&projects, i);
        }
        let mut names = String::new();
        for i in 0..codex_chats {
            write_codex(&codex, i);
            if i % 3 == 0 {
                names += &json!({"id": codex_id(i), "thread_name": format!("named {i}"),
                    "updated_at": clock(i)})
                .to_string();
                names.push('\n');
            }
        }
        std::fs::write(codex.join("session_index.jsonl"), names).unwrap();
        Self { projects, codex, claude, codex_chats }
    }

    fn roots(&self) -> Vec<ChatRoot> {
        [(AdapterKind::ClaudeCode, &self.projects), (AdapterKind::Codex, &self.codex)]
            .into_iter()
            .map(|(harness, path)| ChatRoot {
                harness,
                path: path.clone(),
                real_path: path.canonicalize().unwrap(),
                source: RootSource::Default,
                aliases: Vec::new(),
                accounts: Vec::new(),
            })
            .collect()
    }

    /// Appends a prompt to Claude chat `i`; returns its path.
    fn append_claude(&self, i: usize, n: usize) -> PathBuf {
        let file = claude_file(&self.projects, i);
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(f, "{}", claude_line(i, "user", &format!("next prompt {n}"))).unwrap();
        file
    }

    fn append_codex(&self, i: usize, n: usize) -> PathBuf {
        let file = codex_file(&self.codex, i);
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(f, "{}", codex_prompt(i, &format!("next codex prompt {n}"))).unwrap();
        file
    }
}

/// Bytes this thread has read so far: every read(2) the index makes runs on the calling thread.
/// A stat or a directory listing reads none.
#[cfg(target_os = "linux")]
fn thread_read_bytes() -> u64 {
    let io = std::fs::read_to_string("/proc/thread-self/io").unwrap();
    io.lines().find_map(|line| line.strip_prefix("rchar: ")).unwrap().trim().parse().unwrap()
}

#[cfg(not(target_os = "linux"))]
fn thread_read_bytes() -> u64 {
    0
}

/// Bytes `work` read on this thread (the counter file's own read excluded).
fn bytes_read(work: impl FnOnce()) -> u64 {
    let calibrate = thread_read_bytes();
    let probe = thread_read_bytes() - calibrate;
    let before = thread_read_bytes();
    work();
    (thread_read_bytes() - before).saturating_sub(probe)
}

/// Milliseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn time<T>(&mut self, work: impl FnOnce() -> T) -> T {
        let since = Instant::now();
        let out = work();
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
        out
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 1000.0).round() / 1000.0
        };
        json!({ "n": v.len(), "p50": at(0.5), "p95": at(0.95), "max": at(1.0) })
    }
}

const PAGE: usize = 50;

fn first_page(index: &ChatIndex) -> Vec<cmux_chat_index::IndexedChat> {
    index.newest_first().take(PAGE).cloned().collect()
}

#[test]
fn stress_bench_chat_index_scale() {
    if !bench_selected() {
        eprintln!("skipped: set CMUX_STRESS=1 or name stress_bench in the filter");
        return;
    }
    for chats in [100, 5_000, 20_000, 100_000] {
        let home = tempfile::tempdir().unwrap();
        let build = Instant::now();
        let corpus = Corpus::build(home.path(), chats);
        let build_ms = build.elapsed().as_millis();
        let cache = home.path().join("chat-index.json");

        let mut cold = Samples::default();
        let mut index = ChatIndex::new(corpus.roots());
        let cold_bytes = bytes_read(|| {
            cold.time(|| index.rescan_all());
        });
        let indexed = index.len();

        let mut warm = Samples::default();
        let mut warm_bytes = 0;
        for _ in 0..5 {
            warm_bytes = bytes_read(|| {
                let changes = warm.time(|| index.rescan_all());
                assert!(changes.is_empty(), "nothing changed: {} changes", changes.len());
            });
        }

        // One transcript written, as the watcher applies it (each a different chat).
        let mut update = Samples::default();
        let mut update_bytes = Vec::new();
        for n in 0..20 {
            let file = corpus.append_claude((n * 37) % corpus.claude, n);
            update_bytes.push(bytes_read(|| {
                let changes = update.time(|| index.paths_changed(std::slice::from_ref(&file)));
                assert_eq!(changes.len(), 1);
            }));
        }
        let mut codex_update = Samples::default();
        let mut codex_bytes = Vec::new();
        for n in 0..20.min(corpus.codex_chats) {
            let file = corpus.append_codex((n * 37) % corpus.codex_chats, n);
            codex_bytes.push(bytes_read(|| {
                codex_update.time(|| index.paths_changed(std::slice::from_ref(&file)));
            }));
        }

        let mut page = Samples::default();
        for _ in 0..200 {
            let rows = page.time(|| first_page(&index));
            assert_eq!(rows.len(), PAGE.min(indexed));
        }

        let mut save = Samples::default();
        for _ in 0..3 {
            save.time(|| index.save(&cache).unwrap());
        }
        let cache_bytes = std::fs::metadata(&cache).unwrap().len();
        let mut load = Samples::default();
        let mut loaded = ChatIndex::default();
        for _ in 0..3 {
            loaded = load.time(|| ChatIndex::load(&cache, corpus.roots()));
        }
        // The daemon's start: the cache, then a rescan that should find nothing to read.
        let mut start = Samples::default();
        let start_bytes = bytes_read(|| {
            start.time(|| loaded.rescan_all());
        });

        let max = |v: &[u64]| v.iter().copied().max().unwrap_or(0);
        println!(
            "STRESS-CHAT-INDEX {}",
            json!({
                "chats": chats, "indexed": indexed, "build_ms": build_ms,
                "cold_scan": cold.summary(), "cold_bytes": cold_bytes,
                "warm_rescan": warm.summary(), "warm_bytes": warm_bytes,
                "start_rescan_after_load": start.summary(), "start_bytes": start_bytes,
                "claude_update": update.summary(), "claude_update_bytes_max": max(&update_bytes),
                "codex_update": codex_update.summary(), "codex_update_bytes_max": max(&codex_bytes),
                "first_page": page.summary(),
                "save": save.summary(), "load": load.summary(), "cache_bytes": cache_bytes,
            })
        );
    }
}

/// The bytes one rescan with nothing changed reads, and the most one Claude and one Codex
/// append read, at `chats` chats.
#[cfg(target_os = "linux")]
fn counted(chats: usize) -> (u64, u64, u64) {
    let home = tempfile::tempdir().unwrap();
    let corpus = Corpus::build(home.path(), chats);
    let mut index = ChatIndex::new(corpus.roots());
    index.rescan_all();
    assert_eq!(index.len(), chats);
    let warm = bytes_read(|| assert!(index.rescan_all().is_empty()));
    let claude = (0..5)
        .map(|n| {
            let file = corpus.append_claude(n * 11 % corpus.claude, n);
            bytes_read(|| assert_eq!(index.paths_changed(&[file]).len(), 1))
        })
        .max()
        .unwrap();
    let codex = (0..5)
        .map(|n| {
            let file = corpus.append_codex(n * 7 % corpus.codex_chats, n);
            bytes_read(|| assert_eq!(index.paths_changed(&[file]).len(), 1))
        })
        .max()
        .unwrap();
    (warm, claude, codex)
}

/// A rescan that finds every file as it was reads no transcript (a stat each), and one written
/// file costs that file: the same bytes at 2,000 chats as at 200. Counted, so it fails the day a
/// rescan reads every chat again or an update reads something that grows with the corpus.
#[cfg(target_os = "linux")]
#[test]
fn unchanged_rescan_and_one_update_cost_the_same_at_ten_times_the_chats() {
    let (warm_small, claude_small, codex_small) = counted(200);
    let (warm_big, claude_big, codex_big) = counted(2_000);
    eprintln!(
        "bytes read: rescan {warm_small} -> {warm_big}, claude update {claude_small} -> \
         {claude_big}, codex update {codex_small} -> {codex_big}"
    );
    // The root-level files a rescan reads whatever the corpus holds (none in this corpus once
    // they are unchanged) are a fixed few KB at most.
    assert!(
        warm_big <= 16 * 1024,
        "a rescan with nothing changed read {warm_big} bytes at 2,000 chats ({warm_small} at 200): \
         it must stat unchanged transcripts, not read them"
    );
    // One append: the transcript's new bytes and fixed-size heads; slack for a long transcript
    // hit by the stride, never a whole-corpus file.
    for (what, small, big) in
        [("claude", claude_small, claude_big), ("codex", codex_small, codex_big)]
    {
        assert!(
            big <= small + 16 * 1024,
            "one {what} append read {big} bytes at 2,000 chats, {small} at 200: it grew with the \
             corpus"
        );
    }
}

/// Degenerate corpora: no roots at all, empty roots, one huge transcript, a transcript with no
/// trailing newline, duplicate titles. Each scans, rescans to no change, and pages.
#[test]
fn degenerate_corpora_scan_and_page() {
    let home = tempfile::tempdir().unwrap();
    let mut empty = ChatIndex::new(Vec::new());
    assert!(empty.rescan_all().is_empty());
    assert!(first_page(&empty).is_empty());

    // Roots that exist with nothing in them.
    std::fs::create_dir_all(home.path().join(".claude/projects")).unwrap();
    std::fs::create_dir_all(home.path().join(".codex/sessions")).unwrap();
    let corpus = Corpus {
        projects: home.path().join(".claude/projects"),
        codex: home.path().join(".codex"),
        claude: 0,
        codex_chats: 0,
    };
    let mut index = ChatIndex::new(corpus.roots());
    assert!(index.rescan_all().is_empty());
    assert!(first_page(&index).is_empty());

    // One huge transcript (8 MB) and one whose last line is still being written.
    let dir = corpus.projects.join("-work-huge");
    std::fs::create_dir_all(&dir).unwrap();
    let huge = dir.join(format!("{}.jsonl", claude_id(1)));
    let mut body = claude_line(1, "user", "the huge one ✓");
    body.push('\n');
    let filler = claude_line(1, "assistant", &"y".repeat(8_000));
    for _ in 0..1_000 {
        body += &filler;
        body.push('\n');
    }
    std::fs::write(&huge, body).unwrap();
    let partial = dir.join(format!("{}.jsonl", claude_id(2)));
    std::fs::write(&partial, format!("{}\n{{\"type\":\"assi", claude_line(2, "user", "dup")))
        .unwrap();
    let dup = dir.join(format!("{}.jsonl", claude_id(3)));
    std::fs::write(&dup, format!("{}\n", claude_line(3, "user", "dup"))).unwrap();

    assert_eq!(index.rescan_all().len(), 3);
    assert!(index.rescan_all().is_empty(), "a second rescan finds nothing new");
    let rows = first_page(&index);
    assert_eq!(rows.len(), 3);
    let huge_row = rows.iter().find(|row| row.entry.session_id == claude_id(1)).unwrap();
    assert_eq!(huge_row.entry.message_count, Some(1_001));
    assert_eq!(huge_row.entry.title.as_deref(), Some("the huge one ✓"));
    let titled_dup = rows.iter().filter(|row| row.entry.title.as_deref() == Some("dup")).count();
    assert_eq!(titled_dup, 2, "duplicate titles are two chats");
    // The partial line completes: counted once, on the update.
    let mut f = std::fs::OpenOptions::new().append(true).open(&partial).unwrap();
    writeln!(f, "stant\",\"message\":{{\"role\":\"assistant\",\"content\":\"ok\"}}}}").unwrap();
    drop(f);
    let changes = index.paths_changed(&[partial]);
    assert_eq!(changes.len(), 1);
    let row = index.newest_first().find(|row| row.entry.session_id == claude_id(2)).unwrap();
    assert_eq!(row.entry.message_count, Some(2));
}

/// A rescan takes an unchanged transcript's kept read, but not past a change it depends on: a
/// Claude Code title sidecar written beside it, a Codex name added to the session index, or a
/// cache saved before reads were kept.
#[test]
fn kept_reads_follow_a_sidecar_title_a_session_index_name_and_an_old_cache() {
    let home = tempfile::tempdir().unwrap();
    let corpus = Corpus::build(home.path(), 10);
    let mut index = ChatIndex::new(corpus.roots());
    index.rescan_all();
    let title = |index: &ChatIndex, id: &str| {
        index.newest_first().find(|row| row.entry.session_id == id).unwrap().entry.title.clone()
    };
    assert_eq!(title(&index, &claude_id(1)).as_deref(), Some("Title 1"));
    assert_eq!(title(&index, &codex_id(1)).as_deref(), Some("codex chat 1"));

    // Claude Code: the sidecar renames the chat; its event is a store change (a rescan).
    let sidecar = claude_file(&corpus.projects, 1).with_extension("").join("custom-title.json");
    std::fs::create_dir_all(sidecar.parent().unwrap()).unwrap();
    std::fs::write(&sidecar, r#"{"customTitle":"Renamed ✓"}"#).unwrap();
    index.paths_changed(std::slice::from_ref(&sidecar));
    assert_eq!(title(&index, &claude_id(1)).as_deref(), Some("Renamed ✓"));

    // Codex: a new name line in the session index, its rollout untouched.
    let names = corpus.codex.join("session_index.jsonl");
    let mut f = std::fs::OpenOptions::new().append(true).open(&names).unwrap();
    writeln!(f, "{}", json!({"id": codex_id(1), "thread_name": "codex renamed"})).unwrap();
    drop(f);
    index.paths_changed(std::slice::from_ref(&names));
    assert_eq!(title(&index, &codex_id(1)).as_deref(), Some("codex renamed"));

    // A cache without kept reads (an older daemon's) reads each file once, then keeps it.
    let cache = home.path().join("cache.json");
    index.save(&cache).unwrap();
    let mut saved: Value = serde_json::from_slice(&std::fs::read(&cache).unwrap()).unwrap();
    for root in saved["roots"].as_array_mut().unwrap() {
        for file in root[1]["files"].as_array_mut().unwrap() {
            assert!(file[1].get("kept").is_some(), "each read state keeps its read");
            file[1].as_object_mut().unwrap().remove("kept");
        }
    }
    std::fs::write(&cache, serde_json::to_vec(&saved).unwrap()).unwrap();
    let mut loaded = ChatIndex::load(&cache, corpus.roots());
    assert!(loaded.rescan_all().is_empty(), "the same chats");
    assert_eq!(title(&loaded, &claude_id(1)).as_deref(), Some("Renamed ✓"));
    #[cfg(target_os = "linux")]
    assert!(bytes_read(|| assert!(loaded.rescan_all().is_empty())) < 16 * 1024);
}
