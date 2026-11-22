//! `~/.claude.json` read while Claude Code rewrites it in place: the read must not take a torn
//! file (truncated, or an empty one between truncate and write) as "no trust answer".

use super::*;

/// Trust files in a scratch folder (canonical), with a work folder `work/` in it.
fn scratch(tag: &str) -> (PathBuf, Paths, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "acpmux-trust-torn-{tag}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(root.join("work")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let paths = Paths {
        claude_json: root.join("claude.json"),
        codex_config: root.join("config.toml"),
        record: root.join("trust.json"),
        agent_home: None,
        cmux_worktrees: None,
        peer_scratch: None,
    };
    let work = root.join("work");
    (root, paths, work)
}

/// A `~/.claude.json` that trusts `folder`, padded the way a real one is (other projects).
fn trusting(folder: &Path) -> String {
    let mut projects = serde_json::Map::new();
    for n in 0..64 {
        projects.insert(format!("/elsewhere/{n}"), json!({"hasTrustDialogAccepted": false}));
    }
    projects.insert(folder.display().to_string(), json!({"hasTrustDialogAccepted": true}));
    serde_json::to_string_pretty(&json!({"numStartups": 7, "projects": projects})).unwrap()
}

/// Claude Code's level for `work` read while a writer finishes an in-place rewrite of the file:
/// `torn` is on disk when the read starts, the full file lands 30 ms later.
fn claude_during_rewrite(tag: &str, torn: impl Fn(&str) -> String) -> Value {
    let (root, paths, work) = scratch(tag);
    let full = trusting(&work);
    std::fs::write(&paths.claude_json, torn(&full)).unwrap();
    let file = paths.claude_json.clone();
    let writer = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(30));
        std::fs::write(file, full).unwrap();
    });
    let reply = get_at(&paths, &work.to_string_lossy(), None).unwrap();
    writer.join().unwrap();
    let _ = std::fs::remove_dir_all(&root);
    reply["harnesses"]["claude"].clone()
}

#[test]
fn trust_read_waits_out_an_empty_claude_json_mid_rewrite() {
    let level = claude_during_rewrite("empty", |_| String::new());
    assert_eq!(level, "trusted");
}

#[test]
fn trust_read_waits_out_a_truncated_claude_json_mid_rewrite() {
    let level = claude_during_rewrite("prefix", |full| full[..full.len() / 2].to_owned());
    assert_eq!(level, "trusted");
}

#[test]
fn trust_read_absent_or_unlisted_claude_json_stays_unknown() {
    let (root, paths, work) = scratch("unlisted");
    let cwd = work.to_string_lossy().into_owned();
    let started = std::time::Instant::now();
    // No file: no answer, at once.
    assert_eq!(get_at(&paths, &cwd, None).unwrap()["harnesses"]["claude"], "unknown");
    // A whole file with no entry for the folder: no answer, at once.
    std::fs::write(&paths.claude_json, trusting(&root.join("other"))).unwrap();
    assert_eq!(get_at(&paths, &cwd, None).unwrap()["harnesses"]["claude"], "unknown");
    assert!(started.elapsed() < std::time::Duration::from_millis(100), "{:?}", started.elapsed());
    let _ = std::fs::remove_dir_all(&root);
}

/// `read_settled` over a scripted sequence of reads: what it parsed, how many reads, its waits.
fn settle(reads: &[std::io::Result<&str>]) -> (Option<Value>, usize, Vec<u64>) {
    let mut next = reads.iter();
    let mut count = 0;
    let mut waits = Vec::new();
    let parsed = read_settled(
        || {
            count += 1;
            match next.next().expect("read past the script") {
                Ok(text) => Ok((*text).to_owned()),
                Err(e) => Err(std::io::Error::from(e.kind())),
            }
        },
        |text| serde_json::from_str::<Value>(text).ok(),
        |wait| waits.push(wait.as_millis() as u64),
    );
    (parsed, count, waits)
}

#[test]
fn trust_read_settles_on_the_first_whole_read() {
    let (parsed, reads, waits) = settle(&[Ok(""), Ok(r#"{"projects": {"#), Ok(r#"{"a": 1}"#)]);
    assert_eq!(parsed, Some(json!({"a": 1})));
    assert_eq!((reads, waits), (3, vec![10, 20]));
}

#[test]
fn trust_read_gives_up_on_a_file_that_never_parses_within_its_bound() {
    let (parsed, reads, waits) = settle(&[Ok("{"), Ok("{"), Ok("{"), Ok("{"), Ok("{")]);
    assert_eq!(parsed, None);
    assert_eq!(reads, 5);
    assert_eq!(waits.iter().sum::<u64>(), 150, "{waits:?}");
}

#[test]
fn trust_read_takes_no_file_at_once() {
    let (parsed, reads, waits) = settle(&[Err(std::io::ErrorKind::NotFound.into())]);
    assert_eq!(parsed, None);
    assert_eq!((reads, waits), (1, vec![]));
}
