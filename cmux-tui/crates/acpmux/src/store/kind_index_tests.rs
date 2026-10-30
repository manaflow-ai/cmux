//! A sealed segment's copy of the records a log load reads (`store/kind_index.rs`).

use super::*;
use serde_json::json;

fn rec(seq: u64, kind: &str) -> EventRecord {
    let dir = if kind == "tool_call_update" { "in" } else { "mux" };
    let msg = json!({"promptId": format!("p{seq}"), "pad": "x".repeat(200)});
    EventRecord { seq, at: seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// A log of small segments: per turn a queued prompt, its start, many updates and its end.
fn store_with_log(root: &Path, turns: u64) -> (LocalStore, Vec<EventRecord>) {
    let store = LocalStore::new(root.to_path_buf(), 4096).unwrap();
    let mut log = Vec::new();
    let mut seq = 0;
    for _ in 0..turns {
        for kind in ["queued", "user_message", "turn_started"]
            .into_iter()
            .chain(std::iter::repeat_n("tool_call_update", 20))
            .chain(["turn_result"])
        {
            seq += 1;
            let r = rec(seq, kind);
            store.append("c", &r).unwrap();
            log.push(r);
        }
    }
    store.flush().unwrap();
    (store, log)
}

fn scanned(store: &LocalStore, kinds: &[&str]) -> Vec<EventRecord> {
    let mut out = Vec::new();
    store
        .scan_kinds("c", kinds, &mut |r| {
            out.push(r);
            true
        })
        .unwrap();
    out
}

fn root() -> PathBuf {
    std::env::temp_dir().join(format!("acpmux-kind-index-{}", uuid::Uuid::now_v7()))
}

/// The second scan for the log load's kinds reads each sealed segment's copy, not the segment:
/// a segment whose bytes are gone (the same length and time, other bytes) still yields its
/// records. Every record of those kinds comes back once, in order, as the first scan read them.
#[test]
fn a_second_scan_for_the_log_loads_kinds_reads_the_sealed_segments_copies() {
    let root = root();
    let (store, log) = store_with_log(&root, 12);
    let kinds = ["queued", "turn_started", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    assert_eq!(scanned(&store, &kinds), expected);
    let segments = store.segments("c").unwrap();
    assert!(segments.len() > 3, "{} segments", segments.len());
    let copies = root.join("c").join(kind_index::DIR);
    for (index, path) in &segments {
        let copy = copies.join(format!("{index:06}.ndjson"));
        assert_eq!(copy.exists(), *index != segments.last().unwrap().0, "segment {index}");
        if copy.exists() {
            // Only the indexed records, as written.
            let text = std::fs::read_to_string(&copy).unwrap();
            assert!(text.lines().skip(1).all(|l| !l.contains("tool_call_update")));
            // Same length and time, other bytes: only the copy still holds the records.
            let file = std::fs::OpenOptions::new().write(true).open(path).unwrap();
            let (len, modified) =
                (file.metadata().unwrap().len(), file.metadata().unwrap().modified().unwrap());
            std::fs::write(path, " ".repeat(len as usize)).unwrap();
            let file = std::fs::OpenOptions::new().write(true).open(path).unwrap();
            file.set_modified(modified).unwrap();
        }
    }
    assert_eq!(scanned(&store, &kinds), expected, "the copies hold every record");
    // A scan for any other kind reads the segments themselves.
    let newest_updates = log
        .iter()
        .filter(|r| {
            r.kind == "tool_call_update"
                && r.seq >= first_seq(&segments.last().unwrap().1).unwrap().unwrap()
        })
        .count();
    assert_eq!(scanned(&store, &["tool_call_update"]).len(), newest_updates);
    let _ = std::fs::remove_dir_all(&root);
}

/// A copy that no longer matches its segment (a retention rewrite, another log after a move) is
/// read past: the scan reads the segment and copies it again. The newest segment, once sealed by
/// more appends, gets its copy on the next scan.
#[test]
fn a_copy_that_no_longer_matches_its_segment_is_made_again() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 8);
    let kinds = ["queued"];
    scanned(&store, &kinds);
    // Rewrite the first segment without its first record.
    let (_, first) = store.segments("c").unwrap()[0].clone();
    let text = std::fs::read_to_string(&first).unwrap();
    let dropped: u64 =
        serde_json::from_str::<EventRecord>(text.lines().next().unwrap()).unwrap().seq;
    let rest: String = text.lines().skip(1).map(|l| format!("{l}\n")).collect();
    std::fs::write(&first, rest).unwrap();
    log.retain(|r| r.seq != dropped);
    // More turns: the newest segment is sealed.
    let mut seq = log.last().unwrap().seq;
    for _ in 0..30 {
        seq += 1;
        let r = rec(seq, if seq % 5 == 0 { "queued" } else { "tool_call_update" });
        store.append("c", &r).unwrap();
        log.push(r);
    }
    store.flush().unwrap();
    let expected: Vec<EventRecord> = log.iter().filter(|r| r.kind == "queued").cloned().collect();
    assert_eq!(scanned(&store, &kinds), expected);
    assert_eq!(scanned(&store, &kinds), expected, "from the copies made again");
    let _ = std::fs::remove_dir_all(&root);
}

/// The kinds the log load reads are all copied.
#[test]
fn the_log_loads_kinds_are_indexed() {
    for kind in crate::hub::Hub::QUEUE_KINDS.iter().chain(&["turn_started", "turn_result"]) {
        assert!(INDEXED_KINDS.contains(kind), "{kind}");
    }
}
