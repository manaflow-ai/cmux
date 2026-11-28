//! Model check of the watcher path: after every random burst (appends, new transcripts,
//! deletions, copies of one chat in a second root), the index the incremental path kept equals a
//! full merge of its roots and a fresh index scanned from the files. The full merge is the old
//! implementation's shape (every entry of every root folded per event), so it is the oracle.

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use std::io::Write;
use std::path::{Path, PathBuf};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*: seeded, so a failure names its seed and replays.
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn line(i: usize, second: usize, text: &str) -> String {
    let (h, m, s) = (second / 3600 % 24, second / 60 % 60, second % 60);
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"{}","timestamp":"2026-10-01T{h:02}:{m:02}:{s:02}.000Z","message":{{"role":"user","content":"{text}"}}}}"#,
        i % 7,
        session_id(i)
    )
}

fn file_of(projects: &Path, i: usize) -> PathBuf {
    projects.join(format!("-work-p{}", i % 7)).join(format!("{}.jsonl", session_id(i)))
}

fn root(projects: &Path, account: &str) -> ChatRoot {
    std::fs::create_dir_all(projects).unwrap();
    ChatRoot {
        harness: AdapterKind::ClaudeCode,
        path: projects.to_path_buf(),
        real_path: projects.canonicalize().unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: vec![account.to_owned()],
    }
}

fn append(file: &Path, text: &str) {
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(file).unwrap();
    writeln!(f, "{text}").unwrap();
}

fn run(seed: u64, steps: usize) {
    let mut rng = Rng(seed);
    let home = tempfile::tempdir().unwrap();
    let projects = [home.path().join("a/projects"), home.path().join("b/projects")];
    let roots = || vec![root(&projects[0], "a"), root(&projects[1], "b")];
    let chats = 40;
    // Each write a later second than any before, so "newest copy wins" never ties.
    let mut clock = 0;
    for i in 0..chats / 2 {
        clock += 1;
        append(&file_of(&projects[rng.below(2)], i), &line(i, clock, &format!("chat {i}")));
    }
    let mut index = ChatIndex::new(roots());
    index.rescan_all();
    assert!(index.matches_full_merge(), "seed {seed}: after the first scan");

    for step in 0..steps {
        let mut burst = Vec::new();
        for _ in 0..1 + rng.below(3) {
            let i = rng.below(chats);
            let which = rng.below(2);
            let file = file_of(&projects[which], i);
            clock += 1;
            match rng.below(10) {
                // A deletion (the chat may live on in the other root).
                0 | 1 => {
                    let _ = std::fs::remove_file(&file);
                }
                // A copy into the other root, as sr copies a transcript before a resume.
                2 => {
                    let other = file_of(&projects[1 - which], i);
                    if file.is_file() {
                        std::fs::create_dir_all(other.parent().unwrap()).unwrap();
                        std::fs::copy(&file, &other).unwrap();
                        burst.push(other);
                    }
                }
                // A rewrite from scratch (truncated, then a new first line).
                3 => {
                    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
                    std::fs::write(&file, format!("{}\n", line(i, clock, "rewritten"))).unwrap();
                }
                // An append, or a new transcript.
                _ => append(&file, &line(i, clock, &format!("turn {step}"))),
            }
            burst.push(file);
        }
        index.paths_changed(&burst);
        assert!(index.matches_full_merge(), "seed {seed} step {step}: kept != full merge");
        let fresh = {
            let mut fresh = ChatIndex::new(roots());
            fresh.rescan_all();
            fresh
        };
        let kept: Vec<_> = index.chats().into_iter().cloned().collect();
        let scanned: Vec<_> = fresh.chats().into_iter().cloned().collect();
        assert_eq!(kept, scanned, "seed {seed} step {step}: kept != a fresh scan of the files");
    }

    // The cache round trip keeps the same chats.
    let cache = home.path().join("chat-index.json");
    index.save(&cache).unwrap();
    let mut loaded = ChatIndex::load(&cache, roots());
    assert!(loaded.matches_full_merge());
    let a: Vec<_> = index.chats().into_iter().cloned().collect();
    let b: Vec<_> = loaded.chats().into_iter().cloned().collect();
    assert_eq!(a, b, "seed {seed}: the loaded cache holds other chats");
}

#[test]
fn incremental_bursts_match_a_full_merge_and_a_fresh_scan() {
    let seeds: u64 =
        std::env::var("CMUX_ORACLE_SEEDS").ok().and_then(|v| v.parse().ok()).unwrap_or(8);
    for seed in 1..=seeds {
        run(seed * 0x9e37_79b9_7f4a_7c15, 60);
    }
}
