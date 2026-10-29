//! `for_each_line_rev` and the tail read built on it (`tail_after`) over a real file
//! (`store.rs`).

use super::*;
use std::os::unix::fs::PermissionsExt;

/// Lines come newest first, whole, whatever blocks they span; blank lines are skipped.
#[test]
fn lines_across_blocks_come_back_whole_newest_first() {
    let path = std::env::temp_dir().join(format!(
        "acpmux-line-rev-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let lines =
        ["a".to_owned(), "x".repeat(200_000), String::new(), "b".repeat(65_535), "c".into()];
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut seen = Vec::new();
    for_each_line_rev(&path, &mut |line| {
        seen.push(String::from_utf8(line.to_vec()).unwrap());
        true
    })
    .unwrap();
    let _ = std::fs::remove_file(&path);
    let want: Vec<String> = lines.iter().rev().filter(|l| !l.is_empty()).cloned().collect();
    assert_eq!(seen.len(), want.len());
    assert!(seen == want, "lines came back changed or out of order");
}

/// `tail_after` reads the tail past `after` in one pass from the end: it counts those records,
/// names the last, hands the records of the asked kinds oldest first, and does not count a last
/// line a crash tore (its header reads, its record does not), as when every line was parsed.
#[test]
fn tail_after_hands_the_meta_replay_kinds_oldest_first_and_counts_the_tail() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-tail-after-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let events = root.join("s").join("events");
    std::fs::create_dir_all(&events).unwrap();
    let line = |seq: u64, kind: &str| {
        let msg = serde_json::json!({"n": seq});
        let rec =
            EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None };
        serde_json::to_string(&rec).unwrap()
    };
    let kinds = [(1, "renamed"), (2, "agent"), (3, "renamed"), (4, "agent"), (5, "policy")];
    let mut text: String = kinds.iter().map(|(seq, kind)| line(*seq, *kind) + "\n").collect();
    let torn = line(6, "agent");
    text.push_str(&torn[..torn.find("\"msg\"").unwrap() + 4]);
    let segment = events.join("000001.ndjson");
    std::fs::write(&segment, text).unwrap();
    std::fs::set_permissions(&segment, std::fs::Permissions::from_mode(0o600)).unwrap();
    let store = LocalStore::new(root.clone(), 64 * 1024, &crate::supervised::embedded()).unwrap();
    let mut seen = Vec::new();
    let tail = store.tail_after("s", 2, &["renamed", "policy"], &mut |rec| {
        seen.push((rec.seq, rec.kind));
    });
    let _ = std::fs::remove_dir_all(&root);
    assert_eq!(tail.unwrap(), (3, 5), "three records past seq 2, the last is 5");
    assert_eq!(seen, [(3, "renamed".to_owned()), (5, "policy".to_owned())]);
}
