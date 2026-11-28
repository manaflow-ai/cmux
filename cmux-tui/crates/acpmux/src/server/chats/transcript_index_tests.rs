use super::*;
use crate::adopt_replay::PastTurn;

#[test]
fn terminal_agent_history_sparse_index_skips_only_proven_misses_and_invalidates_on_append() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("log");
    std::fs::write(&path, b"synthetic transcript").unwrap();
    let mut index = Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
    let page = TranscriptPage {
        start: 4,
        end: path.metadata().unwrap().len(),
        read: 0,
        clipped_head: None,
        last_break: Some(path.metadata().unwrap().len()),
        turns: vec![PastTurn { prompt: "SHOW status".into(), ..PastTurn::default() }],
    };
    index.record(&page, &[]);
    let term = |text: &str| Needle::parse(text).unwrap();
    assert_eq!(index.skip(page.end, &term("show")), None);
    assert_eq!(index.skip(page.end, &term("xyzzy")), Some(4));
    drop(index);
    let mut reopened =
        Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
    assert_eq!(reopened.skip(page.end, &term("xyzzy")), Some(4));
    assert!(reopened.file.metadata().unwrap().len() <= SLOTS * RECORD_BYTES as u64);
    drop(reopened);
    std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"append").unwrap();
    let mut changed =
        Offsets::open(dir.path(), &path, "claude", &path.metadata().unwrap()).unwrap();
    assert_eq!(changed.skip(page.end, &term("xyzzy")), None);
}
