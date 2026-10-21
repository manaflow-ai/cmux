//! A watcher burst that names one transcript costs that chat, not the index.
//! acpmux applies a burst each time any agent on the Mac writes a line, so a
//! full remerge of every chat (14k on a busy Mac) per line kept every idle
//! acpmux daemon at about 3% CPU.

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use std::io::Write;
use std::path::{Path, PathBuf};

const CHATS: usize = 5000;

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn line(i: usize, second: usize, text: &str) -> String {
    let (m, s) = (second / 60 % 60, second % 60);
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"{}","timestamp":"2026-10-01T01:{m:02}:{s:02}.000Z","message":{{"role":"user","content":"{text}"}}}}"#,
        i % 50,
        session_id(i)
    )
}

fn session_file(projects: &Path, i: usize) -> PathBuf {
    projects.join(format!("-work-p{}", i % 50)).join(format!("{}.jsonl", session_id(i)))
}

fn root(projects: &Path) -> ChatRoot {
    let real = projects.canonicalize().unwrap();
    ChatRoot {
        harness: AdapterKind::ClaudeCode,
        path: projects.to_path_buf(),
        real_path: real,
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    }
}

#[test]
fn one_transcript_write_merges_one_chat() {
    let home = tempfile::tempdir().unwrap();
    let projects = home.path().join("projects");
    for i in 0..CHATS {
        let file = session_file(&projects, i);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", line(i, i % 3600, &format!("chat {i}")))).unwrap();
    }
    let mut index = ChatIndex::new(vec![root(&projects)]);
    index.rescan_all();
    assert_eq!(index.chats().len(), CHATS);

    let file = session_file(&projects, 7);
    let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(f, "{}", line(7, 3599, "next prompt")).unwrap();
    drop(f);

    let changes = index.paths_changed(std::slice::from_ref(&file));
    assert_eq!(changes.len(), 1, "one chat changed: {changes:?}");
    assert!(
        index.merge_visits() <= 2,
        "one transcript write merged {} root entries ({CHATS} chats); it must merge only that chat",
        index.merge_visits()
    );
    assert_eq!(index.chats().len(), CHATS);
    assert_eq!(index.chats()[0].entry.session_id, session_id(7), "the written chat is newest");

    // A new transcript is one more chat, still merged alone.
    let new = session_file(&projects, CHATS);
    std::fs::write(&new, format!("{}\n", line(CHATS, 3599, "new chat"))).unwrap();
    let changes = index.paths_changed(&[new]);
    assert_eq!(changes.len(), 1);
    assert!(index.merge_visits() <= 2, "a new chat merged {} entries", index.merge_visits());
    assert_eq!(index.chats().len(), CHATS + 1);

    // A deleted transcript removes that chat only.
    std::fs::remove_file(&file).unwrap();
    let changes = index.paths_changed(&[file]);
    assert!(
        matches!(changes.as_slice(), [cmux_chat_index::ChatChange::Removed { .. }]),
        "{changes:?}"
    );
    assert_eq!(index.chats().len(), CHATS);
}
