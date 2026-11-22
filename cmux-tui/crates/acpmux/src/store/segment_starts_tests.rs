//! A forward read past `after` opens only the segments it reads (`store/segment_starts.rs`): the
//! regression for an attach whose cost grew with the chat's segment count (Leo's daemon,
//! 2026-11-18: 711 segments opened per open of one chat).

use super::super::*;
use serde_json::json;
use std::sync::atomic::Ordering;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A store of 64 KiB segments (its least) holding chat `id` with `records` records of ~2 KB each.
fn chat(id: &str, records: u64) -> (Home, LocalStore) {
    let path = std::env::temp_dir().join(format!("acpmux-segment-starts-{}", uuid::Uuid::now_v7()));
    let store = LocalStore::new(path.join("sessions"), 64 * 1024).unwrap();
    let meta = json!({
        "schema": META_SCHEMA, "id": id, "name": "long chat", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let text = "x".repeat(2000);
    for seq in 1..=records {
        let rec = EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "session/update".into(),
            msg: json!({"n": seq, "text": text}),
            host_seq: None,
        };
        store.append(id, &rec).unwrap();
    }
    store.flush_session(id).unwrap();
    (Home(path), store)
}

fn seqs_after(store: &LocalStore, id: &str, after: u64) -> Vec<u64> {
    let mut out = Vec::new();
    Store::scan_matching(store, id, after, &|_| true, &mut |rec| {
        out.push(rec.seq);
        true
    })
    .unwrap();
    out
}

fn head_reads(store: &LocalStore) -> u64 {
    store.segment_starts.reads.load(Ordering::Relaxed)
}

#[test]
fn a_page_past_after_reads_the_heads_of_log_n_segments_once_then_none() {
    let (_home, store) = chat("long", 7000);
    let segments = store.segments("long").unwrap().len();
    assert!(segments >= 200, "the chat spans {segments} segments");
    let before = head_reads(&store);
    assert_eq!(seqs_after(&store, "long", 6990), (6991..=7000).collect::<Vec<_>>());
    let cold = head_reads(&store) - before;
    // A binary search: about log2(segments) heads, never one per segment.
    let bound = u64::from(usize::BITS - segments.leading_zeros()) + 1;
    assert!(cold <= bound, "{cold} segment heads read for {segments} segments (bound {bound})");
    // Read again, and for other cursors: the kept seqs answer, no segment head is opened.
    let warm = head_reads(&store);
    assert_eq!(seqs_after(&store, "long", 6990), (6991..=7000).collect::<Vec<_>>());
    assert_eq!(head_reads(&store), warm, "a second page read no segment head");
}

#[test]
fn an_old_reverse_page_does_not_open_every_newer_segment() {
    let (_home, store) = chat("reverse", 7000);
    let segments = store.segments("reverse").unwrap().len();
    let read = || {
        let mut seqs = Vec::new();
        store
            .scan_back("reverse", 0, 20, &|_, _| false, &mut |record| {
                seqs.push(record.seq);
                seqs.len() < 5
            })
            .unwrap();
        assert_eq!(seqs, vec![19, 18, 17, 16, 15]);
    };
    let copies = segment_table::PATH_COPIES.with(std::cell::Cell::get);
    let before = head_reads(&store);
    read();
    let copied = segment_table::PATH_COPIES.with(std::cell::Cell::get) - copies;
    let cold = head_reads(&store) - before;
    eprintln!(
        "reverse segment table: {segments} segments, {cold} heads read, {copied} paths copied"
    );
    assert!(copied <= 2, "a five-record old page copied {copied} segment paths");
    let bound = u64::from(usize::BITS - segments.leading_zeros()) + 2;
    assert!(cold <= bound, "{cold} heads read for an old page in {segments} segments");
    let before = head_reads(&store);
    read();
    assert_eq!(head_reads(&store), before);
}

#[test]
fn the_cost_of_a_page_does_not_grow_with_the_log() {
    // Ten times the segments, the same page: at most a few more heads (log n), never 10x.
    let (_small_home, small) = chat("small", 700);
    let (_large_home, large) = chat("large", 7000);
    let reads = |store: &LocalStore, id: &str, last: u64| {
        let before = head_reads(store);
        assert_eq!(seqs_after(store, id, last - 5).len(), 5);
        head_reads(store) - before
    };
    let small_reads = reads(&small, "small", 700);
    let large_reads = reads(&large, "large", 7000);
    assert!(
        large_reads <= small_reads + 5,
        "a page of 5 records read {small_reads} heads of a 700-record log, {large_reads} of a 7000-record one"
    );
}

#[test]
fn every_cursor_reads_exactly_the_records_past_it() {
    let (_home, store) = chat("c", 600);
    for after in [0, 1, 2, 7, 8, 9, 10, 99, 100, 101, 333, 598, 599, 600, 700] {
        let want: Vec<u64> = (after + 1..=600).collect();
        assert_eq!(seqs_after(&store, "c", after), want, "after {after}");
    }
}

#[test]
fn a_rewritten_segment_is_read_again() {
    let (_home, store) = chat("r", 200);
    assert_eq!(seqs_after(&store, "r", 150), (151..=200).collect::<Vec<_>>());
    // Segment files replaced with others (a compaction's rename): new inodes, read again.
    let segments = store.segments("r").unwrap();
    let (_, path) = &segments[segments.len() / 2];
    let bytes = std::fs::read(path).unwrap();
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &bytes).unwrap();
    std::fs::rename(&tmp, path).unwrap();
    assert_eq!(seqs_after(&store, "r", 150), (151..=200).collect::<Vec<_>>());
    assert_eq!(seqs_after(&store, "r", 0), (1..=200).collect::<Vec<_>>());
}
