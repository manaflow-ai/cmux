use super::*;
use crate::store::care_tests::scratch;

fn row(at: u64, path: &str) -> Row {
    Row {
        at_ms: at,
        family: "npm-cache".into(),
        path: path.into(),
        bytes: 1024,
        verdict: "reclaim".into(),
        action: "removed".into(),
        archive: None,
        reason: "unused".into(),
    }
}

#[test]
fn rows_come_back_by_path_newest_first() {
    let ledger = Ledger::in_dir(&scratch("ledger"));
    ledger.append(&[row(1, "/h/a"), row(2, "/h/b"), row(3, "/h/a")]).unwrap();
    let rows = ledger.for_path(Path::new("/h/a"), 10);
    assert_eq!(rows.iter().map(|r| r.at_ms).collect::<Vec<_>>(), vec![3, 1]);
    assert_eq!(ledger.recent(2).len(), 2);
    assert!(ledger.for_path(Path::new("/h/zzz"), 10).is_empty());
    // A parent's row names everything inside it, and a child's row its parent.
    assert_eq!(ledger.for_path(Path::new("/h/a/sub"), 10).len(), 2);
    assert_eq!(ledger.for_path(Path::new("/h"), 10).len(), 3);
}

#[test]
fn a_full_file_rotates_and_both_halves_are_read() {
    let dir = scratch("ledger-rotate");
    let ledger = Ledger::in_dir(&dir);
    ledger.append(&[row(1, "/h/old")]).unwrap();
    // Fill to the limit with one big line's worth of padding rows.
    let padding = Row { reason: "x".repeat(1 << 20), ..row(2, "/h/pad") };
    for _ in 0..4 {
        ledger.append(std::slice::from_ref(&padding)).unwrap();
    }
    ledger.append(&[row(9, "/h/new")]).unwrap();
    assert!(dir.join("care-ledger.jsonl.1").exists());
    assert_eq!(ledger.for_path(Path::new("/h/old"), 5).len(), 1);
    assert_eq!(ledger.for_path(Path::new("/h/new"), 5).len(), 1);
    let size = std::fs::metadata(dir.join("care-ledger.jsonl")).unwrap().len();
    assert!(size < MAX_BYTES + (1 << 20));
}

#[test]
fn a_torn_line_is_skipped() {
    let dir = scratch("ledger-torn");
    let ledger = Ledger::in_dir(&dir);
    ledger.append(&[row(1, "/h/a")]).unwrap();
    let mut file = std::fs::OpenOptions::new().append(true).open(dir.join(FILE)).unwrap();
    writeln!(file, "{{\"atMs\": 5, \"fam").unwrap();
    ledger.append(&[row(3, "/h/a")]).unwrap();
    assert_eq!(ledger.rows().len(), 2);
}
