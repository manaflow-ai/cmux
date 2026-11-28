//! The chat text's resident heap after a restart reads its saved copy back (goal ram-baseline):
//! about 15 MB of chat text, saved by one process, then loaded by a fresh one, which prints its
//! anonymous (heap) resident bytes before and after `load` and after a search over every chat.
//! Linux only (`RssAnon` in `/proc/self/status`). Run:
//! `cargo test -p acpmux --test chat_text_memory -- --ignored --nocapture`.

use std::path::PathBuf;

use acpmux::chats::search::Needle;
use acpmux::chats::text::ChatText;
use cmux_chat_index::transcript::Turn;
use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};

const CHATS: usize = 600;
const CHAT_TEXT: usize = 25 * 1024;
const LOAD_ENV: &str = "CHAT_TEXT_MEMORY_LOAD";

fn chat(n: usize) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness: AdapterKind::Codex,
            session_id: format!("c{n:04}"),
            title: Some(format!("chat {n}")),
            title_source: None,
            cwd: None,
            created_ms: None,
            updated_ms: 1_000_000 - n as i64,
            message_count: None,
            source_path: PathBuf::from(format!("/nonexistent/c{n:04}.jsonl")),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

/// About `CHAT_TEXT` bytes of words, different per chat.
fn turns(n: usize) -> Vec<Turn> {
    let mut seed = n as u64 + 1;
    let mut text = String::with_capacity(CHAT_TEXT + 16);
    while text.len() < CHAT_TEXT / 2 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        text.push_str(&format!("word{} ", seed >> 50));
    }
    let answer = format!("{text} marker{n}");
    vec![Turn { prompt: text, answer, prompt_at: None, answer_at: None }]
}

fn rss_anon_kb() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").expect("status");
    status
        .lines()
        .find_map(|l| l.strip_prefix("RssAnon:"))
        .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        .expect("RssAnon")
}

#[test]
#[ignore = "memory bench: run with --ignored --nocapture"]
fn chat_text_load_memory() {
    if let Ok(path) = std::env::var(LOAD_ENV) {
        let before = rss_anon_kb();
        let text = ChatText::new(PathBuf::from(path));
        text.load();
        let loaded = rss_anon_kb();
        let found = text.search(&Needle::parse("marker17").unwrap()).len();
        let searched = rss_anon_kb();
        let (chats, bytes) = text.held();
        println!(
            "LOAD chats={chats} text_bytes={bytes} found={found} rss_anon_kb before={before} \
             after_load={loaded} after_search={searched} load_delta_kb={}",
            loaded.saturating_sub(before)
        );
        return;
    }
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("text.saved");
    let all: Vec<IndexedChat> = (0..CHATS).map(chat).collect();
    let text = ChatText::new(path.clone());
    text.update(&all, &|entry| {
        let n: usize = entry.session_id[1..].parse().ok()?;
        Some(turns(n))
    });
    let (chats, bytes) = text.held();
    let size = std::fs::metadata(&path).expect("saved").len();
    println!("FILL chats={chats} text_bytes={bytes} saved_bytes={size}");
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "chat_text_load_memory", "--ignored", "--nocapture"])
        .env(LOAD_ENV, &path)
        .output()
        .expect("child");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout.lines().find(|l| l.starts_with("LOAD")).expect("child's LOAD line");
    println!("{line}");
    assert!(out.status.success());
}
