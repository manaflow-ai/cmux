use super::*;
use serde_json::{Value, json};

fn reply(seq: u64, text: &str) -> EventRecord {
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}),
        host_seq: None,
    }
}

fn raw(seq: u64, bytes: usize) -> EventRecord {
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "codex.response".into(),
        msg: json!({"jsonrpc": "2.0", "method": "codex.response", "params": {"text": "r".repeat(bytes)}}),
        host_seq: None,
    }
}

/// Record `seq` of a chat where one line in three is a reply and the rest raw harness lines.
fn record(seq: u64) -> EventRecord {
    if seq.is_multiple_of(3) { reply(seq, &format!("reply {seq}")) } else { raw(seq, 1500) }
}

/// Every record `scan_back_transcript` and `scan_back` give for a transcript page's `skip`, at
/// `before`, newest first, up to `limit`.
fn both(store: &LocalStore, before: u64, limit: usize) -> (Vec<u64>, Vec<u64>) {
    let skip = |dir: &[u8], kind: &[u8]| !holds(dir, kind);
    let read = |indexed: bool| {
        let mut out = Vec::new();
        // What a page keeps of them: no raw harness line is an agent update.
        let mut visit = |rec: EventRecord| {
            let update = rec.msg.get("method").and_then(Value::as_str) == Some("session/update");
            if rec.dir == "in" && !update {
                return true;
            }
            out.push(rec.seq);
            out.len() < limit
        };
        if indexed {
            store.scan_back_transcript_in("c", 0, before, &skip, &mut visit).unwrap();
        } else {
            store.scan_back_in("c", 0, before, &skip, &mut visit, false).unwrap();
        }
        out
    };
    (read(true), read(false))
}

fn same_reads(store: &LocalStore, last: u64, state: &str) {
    for before in (1..=last + 2).step_by(7).chain([u64::MAX]) {
        for limit in [1, 5, 1000] {
            let (indexed, old) = both(store, before, limit);
            assert_eq!(indexed, old, "{state}: before {before} limit {limit}");
        }
    }
}

#[test]
fn an_entry_and_a_header_read_back_as_written_and_zeros_are_damage() {
    let entry = Entry { seq: 9, offset: 1234, len: 77, flags: 0 };
    assert_eq!(Entry::decode(&entry.encode()), Some(entry));
    assert_eq!(Entry::decode(&[0u8; WIDTH as usize]), None, "a zeroed entry is damage");
    let header = Header {
        file: (1, 2, 3),
        from: 10,
        boot: 4,
        durable: 20,
        durable_count: 1,
        count: 2,
        covered: 30,
    };
    assert_eq!(Header::decode(&header.encode()), Some(header));
    let mut torn = header.encode();
    torn[70] ^= 1;
    assert_eq!(Header::decode(&torn), None, "a torn header is read past");
}

/// What a transcript page may want gets an entry; load replays, raw harness lines, replies and
/// bookkeeping updates do not.
#[test]
fn the_index_holds_what_a_transcript_page_may_want() {
    for (dir, kind) in [
        ("in", "agent_message_chunk"),
        ("in", "tool_call_update"),
        ("mux", "user_message"),
        ("mux", "turn_started"),
        ("mux", "turn_result"),
        ("mux", "preset_approval_request"),
        ("mux", "preset_approval_decision"),
    ] {
        assert!(holds(dir.as_bytes(), kind.as_bytes()), "{dir} {kind}");
    }
    for (dir, kind) in [
        ("in", "agent_message_chunk.replay"),
        ("in", "claude.stream_event"),
        ("in", "response"),
        ("in", "usage_update"),
        ("out", "session/prompt"),
        ("mux", "turn_end"),
    ] {
        assert!(!holds(dir.as_bytes(), kind.as_bytes()), "{dir} {kind}");
    }
    // A raw harness line whose kind does not say so is known by its message.
    let line = |rec: &EventRecord| serde_json::to_vec(rec).unwrap();
    assert!(!holds_line(&line(&raw(1, 10))), "a raw codex line");
    assert!(holds_line(&line(&reply(2, "hi"))), "a reply");
    let mut odd = reply(3, "hi");
    odd.msg = json!({"result": {"method": "codex.response"}});
    assert!(holds_line(&line(&odd)), "a line that does not say plainly is held");
}

/// A machine that stopped without writing back its page cache may keep a segment's lines and
/// lose the entries written since the index's last sync: a later boot trusts only the synced
/// part, reads the rest of the segment the old way, and its writer indexes those lines again.
#[test]
fn an_index_from_another_boot_is_trusted_as_far_as_its_last_sync() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let mut seq = 0;
    as_if_booted(Some(11));
    {
        // One segment: the unsynced entries are its last ones.
        let store = LocalStore::new(root.clone(), 8 << 20).unwrap();
        for _ in 0..200 {
            seq += 1;
            store.append("c", &record(seq)).unwrap();
        }
        store.flush().unwrap();
        // Written after the last sync.
        for _ in 0..30 {
            seq += 1;
            store.append("c", &record(seq)).unwrap();
        }
    }
    let index = root.join("c").join(DIR);
    let mut files: Vec<_> = std::fs::read_dir(&index).unwrap().map(|e| e.unwrap().path()).collect();
    files.sort();
    let newest = files.last().unwrap().clone();
    // The machine lost the entries past the last sync: the last few.
    let len = std::fs::metadata(&newest).unwrap().len();
    std::fs::OpenOptions::new()
        .write(true)
        .open(&newest)
        .unwrap()
        .set_len(len - 4 * WIDTH)
        .unwrap();
    as_if_booted(Some(12));
    let store = LocalStore::new(root.clone(), 8 << 20).unwrap();
    same_reads(&store, seq, "another boot");
    // Its writer indexes the unsynced lines again and goes on.
    for _ in 0..40 {
        seq += 1;
        store.append("c", &record(seq)).unwrap();
    }
    same_reads(&store, seq, "after the writer went on");
    store.flush().unwrap();
    drop(store);
    as_if_booted(Some(13));
    let store = LocalStore::new(root, 8 << 20).unwrap();
    same_reads(&store, seq, "a third boot");
    as_if_booted(None);
}

/// A daemon without the index (a build swapped back and forth) appends lines with no entries: a
/// reader reads them the old way, and the next writer with the index indexes them.
#[test]
fn lines_a_daemon_without_the_index_appended_are_read() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let mut seq = 0;
    for indexed in [true, false, true, false] {
        let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
        let store = if indexed { store } else { store.without_transcript_index() };
        for _ in 0..90 {
            seq += 1;
            store.append("c", &record(seq)).unwrap();
        }
        drop(store);
        let reader = LocalStore::new(root.clone(), 64 << 10).unwrap();
        same_reads(&reader, seq, &format!("after a daemon with the index {indexed}"));
    }
}

/// A failed write cut back takes its entry back; the records after it are indexed and read.
#[test]
fn a_write_that_failed_part_way_takes_its_entry_back() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
    for seq in 1..=20 {
        store.append("c", &record(seq)).unwrap();
    }
    // 21 is a reply: its entry is written, then its line fails part way.
    let mut seq = 21;
    super::test_write_fault::partial(25);
    assert!(store.append("c", &record(seq)).is_err());
    store.append("c", &record(seq)).unwrap();
    for _ in 0..10 {
        seq += 1;
        store.append("c", &record(seq)).unwrap();
    }
    same_reads(&store, seq, "after a failed write");
    let path = store.transcript_index_path("c", 1);
    let header = Header::decode(&std::fs::read(&path).unwrap()).unwrap();
    let len = std::fs::metadata(&path).unwrap().len();
    assert_eq!(len, HEADER + header.count * WIDTH, "no entry of the failed write is left");
    assert_eq!(header.count, seq / 3, "one entry a reply");
}

/// What an append costs with the index and without: `cargo test -p acpmux --release -- --ignored
/// --nocapture transcript_index_append_cost`. One line in three is a reply (an entry), the rest
/// raw harness lines of 1.5 KB (none).
#[test]
#[ignore = "a measurement, not a check"]
fn transcript_index_append_cost() {
    let n: u64 =
        std::env::var("APPEND_RECORDS").ok().and_then(|v| v.parse().ok()).unwrap_or(30_000);
    let lines: Vec<(EventRecord, bool)> = (1..=n)
        .map(|seq| {
            let rec =
                if seq.is_multiple_of(3) { reply(seq, &"w".repeat(120)) } else { raw(seq, 1500) };
            let held = seq.is_multiple_of(3);
            (rec, held)
        })
        .collect();
    for round in 0..3 {
        for indexed in [false, true] {
            let home = tempfile::tempdir().unwrap();
            let store = LocalStore::new(home.path().join("sessions"), 8 << 20).unwrap();
            let store = if indexed { store } else { store.without_transcript_index() };
            let started = std::time::Instant::now();
            for (rec, _) in &lines {
                store.append("c", rec).unwrap();
            }
            let all = started.elapsed().as_nanos() as f64 / n as f64;
            // The replies alone, the lines that get an entry.
            let home2 = tempfile::tempdir().unwrap();
            let store2 = LocalStore::new(home2.path().join("sessions"), 8 << 20).unwrap();
            let store2 = if indexed { store2 } else { store2.without_transcript_index() };
            let held: Vec<&EventRecord> =
                lines.iter().filter(|(_, h)| *h).map(|(r, _)| r).collect();
            let started = std::time::Instant::now();
            for rec in &held {
                store2.append("c", rec).unwrap();
            }
            let replies = started.elapsed().as_nanos() as f64 / held.len() as f64;
            println!(
                "append round {round}, index {}: {all:.0} ns a record (mixed), {replies:.0} ns a reply",
                if indexed { "on" } else { "off" }
            );
        }
    }
}
