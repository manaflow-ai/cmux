//! A closed chat's log compressed in place (`store/log_zst.rs`), and read back through every
//! reader of the store (`store/segment_file.rs`).

use super::*;
use serde_json::json;

struct Home(PathBuf);

impl Home {
    fn new(segment_bytes: u64) -> (Self, LocalStore) {
        let path = std::env::temp_dir().join(format!("acpmux-log-zst-{}", uuid::Uuid::now_v7()));
        let store = LocalStore::new(path.join("sessions"), segment_bytes).unwrap();
        (Self(path), store)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn record(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord {
        seq,
        at: 1_700_000_000_000 + seq,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

/// A closed chat of `turns` prompts, tool calls and answers, over several segments.
fn chat(store: &LocalStore, id: &str, turns: u64) {
    let meta = json!({
        "schema": META_SCHEMA, "id": id, "name": "closed chat", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let mut seq = 0;
    let mut push = |kind: &str, msg: Value| {
        seq += 1;
        store.append(id, &record(seq, kind, msg)).unwrap();
    };
    for turn in 0..turns {
        push(
            "user_message",
            json!({"text": format!("turn {turn}: {}", "fix it ".repeat(30)), "promptId": format!("p{turn}")}),
        );
        push("turn_started", json!({"promptId": format!("p{turn}")}));
        push(
            "tool_call",
            json!({"toolCallId": format!("t{turn}"), "title": "Run tests", "rawOutput": "ok ".repeat(200)}),
        );
        push(
            "agent_message_chunk",
            json!({"messageId": format!("m{turn}"), "content": {"type": "text", "text": format!("done with turn {turn}")}}),
        );
        push("turn_result", json!({"promptId": format!("p{turn}"), "stopReason": "end_turn"}));
    }
    store.close_log(id);
}

fn events_dir(store: &LocalStore, id: &str) -> PathBuf {
    store.dir(id).join("events")
}

/// The log's files by name.
fn files(store: &LocalStore, id: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(events_dir(store, id))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// Each segment's plain bytes, by index.
fn plain_bytes(store: &LocalStore, id: &str) -> BTreeMap<u32, Vec<u8>> {
    let mut out = BTreeMap::new();
    for (index, path) in store.segment_files(id).unwrap() {
        let bytes = std::fs::read(&path).unwrap();
        let bytes =
            if segment_file::is_zst(&path) { zstd::decode_all(&bytes[..]).unwrap() } else { bytes };
        out.insert(index, bytes);
    }
    out
}

/// What every reader of the store answers for chat `id`.
fn reads(store: &LocalStore, id: &str) -> Value {
    let all = store.events(id, 0, usize::MAX).unwrap();
    let mut back = Vec::new();
    store
        .scan_back(id, 0, u64::MAX, &|_, _| false, &mut |rec| {
            back.push(rec.seq);
            back.len() < 400
        })
        .unwrap();
    let mut indexed = Vec::new();
    store
        .scan_back_indexed(id, 0, u64::MAX, &|_, kind| kind != b"user_message", &mut |rec| {
            indexed.push(rec.seq);
            true
        })
        .unwrap();
    let mut kinds = Vec::new();
    store
        .scan_kinds(id, &["user_message", "turn_result"], &mut |rec| {
            kinds.push(rec.seq);
            true
        })
        .unwrap();
    let mut heads = Vec::new();
    store
        .scan_heads(id, &mut |head| {
            heads.push(head.seq);
            true
        })
        .unwrap();
    let mut texts = Vec::new();
    store.text_entries(id, &mut |entry| texts.push(serde_json::to_value(entry).unwrap())).unwrap();
    // A page reader's chunks, from the start and from a seq in the middle.
    let mut chunks = Vec::new();
    for from in [1, 333] {
        let mut marks = LogMarks::default();
        let mut next = from;
        let mut out = Vec::new();
        loop {
            let chunk = store.read_log(id, next, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
            chunks.push(String::from_utf8(out.clone()).unwrap());
            if chunk.at_end || chunk.next == next {
                break;
            }
            next = chunk.next;
        }
    }
    let part = {
        let mut marks = LogMarks::default();
        let mut out = Vec::new();
        store.read_log_part(id, 250, 10, 64, 0, &mut marks, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    };
    json!({
        "all": serde_json::to_value(&all).unwrap(),
        "after": serde_json::to_value(store.events(id, 777, 50).unwrap()).unwrap(),
        "tail": store.tail_after(id, 900).unwrap(),
        "back": back, "indexed": indexed, "kinds": kinds, "heads": heads, "texts": texts,
        "chunks": chunks, "part": part,
    })
}

fn never() -> bool {
    false
}

#[test]
fn a_closed_log_compresses_in_place_and_reads_the_same() {
    let (_home, store) = Home::new(64 * 1024);
    chat(&store, "c", 300);
    let before = reads(&store, "c");
    let bytes = plain_bytes(&store, "c");
    assert!(bytes.len() >= 4, "several segments: {}", bytes.len());

    let done = store.compress_log("c", &never).unwrap();
    assert_eq!(done.segments, bytes.len() as u64);
    assert!(!done.stopped);
    assert!(done.bytes_after * 4 < done.bytes_before, "{done:?}");
    // Every segment is compressed, no plain file or temporary file is left, and each decodes to
    // the plain bytes it replaced.
    let names = files(&store, "c");
    assert!(names.iter().all(|n| n.ends_with(".ndjson.zst")), "{names:?}");
    assert_eq!(names.len(), bytes.len());
    assert_eq!(plain_bytes(&store, "c"), bytes);
    // Each frame says its size, as plain `zstd FILE` writes it, and has a checksum.
    for (index, path) in store.segment_files("c").unwrap() {
        let file = std::fs::File::open(&path).unwrap();
        assert_eq!(segment_file::frames_len(&file).unwrap(), Some(bytes[&index].len() as u64));
    }
    segment_file::forget_scratch();
    assert_eq!(reads(&store, "c"), before);
    // A second pass has nothing to do.
    assert_eq!(store.compress_log("c", &never).unwrap(), LogCompression::default());
}

#[test]
fn a_crash_before_the_rename_leaves_the_plain_log_and_the_next_pass_finishes() {
    let (_home, store) = Home::new(64 * 1024);
    chat(&store, "c1", 120);
    let before = reads(&store, "c1");
    let bytes = plain_bytes(&store, "c1");
    crash_once("c1", CrashAt::BeforeRename);
    assert!(store.compress_log("c1", &never).is_err());
    // The plain segments, and a temporary file no reader opens.
    let names = files(&store, "c1");
    assert!(names.iter().any(|n| n.contains(TMP_MARK)), "{names:?}");
    assert!(!names.iter().any(|n| n.ends_with(".ndjson.zst")), "{names:?}");
    assert_eq!(plain_bytes(&store, "c1"), bytes);
    assert_eq!(reads(&store, "c1"), before);
    // The next pass removes it and compresses every segment.
    store.compress_log("c1", &never).unwrap();
    let names = files(&store, "c1");
    assert!(names.iter().all(|n| n.ends_with(".ndjson.zst")), "{names:?}");
    assert_eq!(plain_bytes(&store, "c1"), bytes);
    assert_eq!(reads(&store, "c1"), before);
}

#[test]
fn a_crash_before_the_removal_reads_the_plain_segment_and_the_next_pass_finishes() {
    let (_home, store) = Home::new(64 * 1024);
    chat(&store, "c2", 120);
    let before = reads(&store, "c2");
    let bytes = plain_bytes(&store, "c2");
    crash_once("c2", CrashAt::BeforeRemove);
    assert!(store.compress_log("c2", &never).is_err());
    // Both files of the first segment: the plain one is read.
    let names = files(&store, "c2");
    assert!(names.contains(&"000001.ndjson".to_owned()), "{names:?}");
    assert!(names.contains(&"000001.ndjson.zst".to_owned()), "{names:?}");
    let listed = store.segment_files("c2").unwrap();
    assert_eq!(listed.len(), bytes.len(), "each segment listed once: {listed:?}");
    assert!(!segment_file::is_zst(&listed[0].1));
    assert_eq!(reads(&store, "c2"), before);
    store.compress_log("c2", &never).unwrap();
    let names = files(&store, "c2");
    assert!(names.iter().all(|n| n.ends_with(".ndjson.zst")), "{names:?}");
    assert_eq!(plain_bytes(&store, "c2"), bytes);
    assert_eq!(reads(&store, "c2"), before);
}

#[test]
fn a_reopened_chat_appends_to_a_new_plain_segment() {
    let (_home, store) = Home::new(64 * 1024);
    chat(&store, "r", 120);
    store.compress_log("r", &never).unwrap();
    let compressed = store.segment_files("r").unwrap();
    let last = compressed.last().unwrap().0;
    let mut all = store.events("r", 0, usize::MAX).unwrap();
    let next = record(all.len() as u64 + 1, "reopened", json!({}));
    store.append("r", &next).unwrap();
    all.push(next);
    let listed = store.segment_files("r").unwrap();
    assert_eq!(listed.len(), compressed.len() + 1);
    let (index, path) = listed.last().unwrap();
    assert_eq!(*index, last + 1);
    assert!(!segment_file::is_zst(path), "{}", path.display());
    // The compressed segments are as they were.
    assert_eq!(&listed[..compressed.len()], &compressed[..]);
    assert_eq!(store.events("r", 0, usize::MAX).unwrap(), all);
    store.close_log("r");
    store.compress_log("r", &never).unwrap();
    assert!(files(&store, "r").iter().all(|n| n.ends_with(".ndjson.zst")));
    assert_eq!(store.events("r", 0, usize::MAX).unwrap(), all);
}

#[test]
fn a_log_with_an_open_writer_or_a_stop_is_left_as_it_is() {
    let (_home, store) = Home::new(64 * 1024);
    chat(&store, "w", 60);
    let bytes = plain_bytes(&store, "w");
    // An append opens the log's writer: the pass changes nothing.
    let n = store.events("w", 0, usize::MAX).unwrap().len() as u64;
    store.append("w", &record(n + 1, "status", json!({"status": "ready"}))).unwrap();
    let done = store.compress_log("w", &never).unwrap();
    assert!(done.stopped && done.segments == 0, "{done:?}");
    assert!(files(&store, "w").iter().all(|n| n.ends_with(".ndjson")));
    store.close_log("w");
    // A stop asked before the first segment.
    let done = store.compress_log("w", &|| true).unwrap();
    assert!(done.stopped && done.segments == 0, "{done:?}");
    assert!(files(&store, "w").iter().all(|n| n.ends_with(".ndjson")));
    assert_eq!(plain_bytes(&store, "w").len(), bytes.len());
}

#[test]
fn an_empty_segment_stays_plain_so_a_purged_chat_reads_as_one() {
    let (_home, store) = Home::new(64 * 1024);
    let events = store.dir("e").join("events");
    crate::config::private_state_dir(&store.dir("e")).unwrap();
    crate::config::private_state_dir(&events).unwrap();
    open_private_append(&events.join("000001.ndjson")).unwrap();
    store.compress_log("e", &never).unwrap();
    assert_eq!(files(&store, "e"), vec!["000001.ndjson".to_owned()]);
    assert!(!store.has_records("e").unwrap());
}

/// VmRSS of this process in KB (Linux), else 0.
fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(0)
}

#[test]
fn a_large_compressed_log_is_read_streamed() {
    // One segment of 256 MB: a read that inflated it in memory would hold all of it.
    const LINES: u64 = 64 * 1024;
    let (_home, store) = Home::new(1 << 30);
    let filler = "the agent's output repeats a lot ".repeat(120);
    for seq in 1..=LINES {
        store
            .append("big", &record(seq, "tool_call", json!({"n": seq, "rawOutput": filler})))
            .unwrap();
    }
    store.close_log("big");
    let plain = std::fs::metadata(events_dir(&store, "big").join("000001.ndjson")).unwrap().len();
    assert!(plain > 250 << 20, "{plain}");
    let done = store.compress_log("big", &never).unwrap();
    assert_eq!(done.segments, 1);
    segment_file::forget_scratch();
    let decoded_before = segment_file::decoded_count();
    let start = rss_kb();
    let mut peak = start;
    let mut count = 0u64;
    store
        .scan("big", 0, &mut |rec| {
            count += 1;
            assert_eq!(rec.seq, count);
            if count % 4096 == 0 {
                peak = peak.max(rss_kb());
            }
            true
        })
        .unwrap();
    assert_eq!(count, LINES);
    let grew_mb = peak.saturating_sub(start) / 1024;
    eprintln!(
        "read {LINES} records, {} MB plain from {} MB compressed: RSS {} MB at the start, peak {} MB (+{grew_mb} MB)",
        plain >> 20,
        done.bytes_after >> 20,
        start / 1024,
        peak / 1024
    );
    // The scan decoded as it read: no scratch copy was made, and memory did not grow by the
    // segment's size (other tests run beside this one, so the bound is loose).
    assert_eq!(segment_file::decoded_count(), decoded_before, "a scan from the start streams");
    if start > 0 {
        assert!(grew_mb < 160, "RSS grew {grew_mb} MB reading a {} MB log", plain >> 20);
    }
    // A read at an offset of the segment's end (a page's newest records) decodes it once to a
    // scratch file, never into memory.
    let newest = store.events("big", LINES - 3, 10).unwrap();
    assert_eq!(newest.iter().map(|r| r.seq).collect::<Vec<_>>(), vec![LINES - 2, LINES - 1, LINES]);
}
