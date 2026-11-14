//! The log read by seq and its count (`store/log_bytes.rs`).

use super::*;

pub(crate) struct Home(PathBuf);

impl Home {
    /// A store of 1 MiB segments with a chat `id` of `messages` messages and about `bytes`, as
    /// the god fixture writes them (each turn's tool output padded past retention's cut).
    pub(crate) fn chat(id: &str, messages: usize, bytes: u64) -> (Self, LocalStore, u64) {
        let path = std::env::temp_dir().join(format!("acpmux-log-bytes-{}", uuid::Uuid::now_v7()));
        let store = LocalStore::new(path.join("sessions"), 1 << 20).unwrap();
        let (_, last) = crate::god_fixture::append_log(&store, id, messages, bytes).unwrap();
        (Self(path), store, last)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Every line of `id`'s log, from its segments as files, in order.
fn file_lines(store: &LocalStore, id: &str) -> Vec<Vec<u8>> {
    let mut lines = Vec::new();
    for (_, path) in store.segments(id).unwrap() {
        let bytes = std::fs::read(path).unwrap();
        lines.extend(bytes.split_inclusive(|b| *b == b'\n').map(<[u8]>::to_vec));
    }
    lines
}

/// The whole log through `read_log`, chunk by chunk from seq 1 with one set of marks.
fn read_all(store: &LocalStore, id: &str, marks: &mut LogMarks) -> (Vec<Vec<u8>>, u64, usize) {
    let stamp = store.read_stamp(id).unwrap();
    let (mut lines, mut read, mut chunks, mut from) = (Vec::new(), 0, 0, 1);
    let mut out = Vec::new();
    loop {
        let chunk = store.read_log_bytes(id, from, LogFilter::ALL, stamp, marks, &mut out).unwrap();
        assert!(out.len() <= CHUNK_BYTES || out.split_inclusive(|b| *b == b'\n').count() == 1);
        assert!(
            out.capacity() + marks.waiting() <= CHUNK_BYTES.max(out.len()),
            "one chunk held, its waiting bytes with it"
        );
        lines.extend(out.split_inclusive(|b| *b == b'\n').map(<[u8]>::to_vec));
        read += chunk.read;
        chunks += 1;
        from = chunk.next;
        if chunk.at_end {
            return (lines, read, chunks);
        }
    }
}

fn log_len(store: &LocalStore, id: &str) -> u64 {
    store.segments(id).unwrap().iter().map(|(_, p)| std::fs::metadata(p).unwrap().len()).sum()
}

#[test]
fn a_catch_up_gives_every_line_as_written_and_reads_each_byte_about_once() {
    let (_home, store, last) = Home::chat("c", 400, 6 << 20);
    assert!(store.segments("c").unwrap().len() >= 5, "the log spans segments");
    let (lines, read, chunks) = read_all(&store, "c", &mut LogMarks::default());
    assert_eq!(lines, file_lines(&store, "c"));
    assert_eq!(log_line_seqs(&lines).last().copied(), Some(last));
    let len = log_len(&store, "c");
    assert!(chunks as u64 >= len / CHUNK_BYTES as u64);
    // Each chunk after the first goes on from its mark with the bytes it left waiting: the
    // bytes read are the log's, and a segment's first bytes where a read looks at the next one.
    assert!(read * 50 <= len * 51, "read {read} of a {len} byte log");
}

fn log_line_seqs(lines: &[Vec<u8>]) -> Vec<u64> {
    lines.iter().map(|l| line_seq(l).unwrap()).collect()
}

#[test]
fn a_read_away_from_its_marks_scans_at_most_one_segment() {
    let (_home, store, last) = Home::chat("c", 400, 6 << 20);
    let mut out = Vec::new();
    for from in [1, last / 2, last - 3, last + 1, last + 50] {
        let chunk = store
            .read_log_bytes("c", from, LogFilter::ALL, 0, &mut LogMarks::default(), &mut out)
            .unwrap();
        let first = out.split(|b| *b == b'\n').next().and_then(line_seq);
        if from <= last {
            assert_eq!(first, Some(from), "a read from {from}");
        } else {
            assert!(out.is_empty() && chunk.at_end && chunk.next == from);
        }
        // One segment (1 MiB here), a chunk, and the first bytes of each segment.
        assert!(chunk.read <= (1 << 20) + 2 * CHUNK_BYTES as u64, "{from}: {}", chunk.read);
    }
}

#[test]
fn a_line_being_written_is_not_there_and_a_later_read_takes_it_whole() {
    let (_home, store, last) = Home::chat("c", 8, 4096);
    let segment = store.segments("c").unwrap().last().unwrap().1.clone();
    let line = format!(
        "{{\"seq\":{},\"at\":1,\"dir\":\"mux\",\"kind\":\"status\",\"msg\":{{}}}}\n",
        last + 1
    );
    let (head, tail) = line.as_bytes().split_at(10);
    std::fs::OpenOptions::new().append(true).open(&segment).unwrap().write_all(head).unwrap();
    let mut marks = LogMarks::default();
    let (lines, _, _) = read_all(&store, "c", &mut marks);
    assert_eq!(lines.len() as u64, last);
    let mut out = Vec::new();
    let chunk =
        store.read_log_bytes("c", last + 1, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
    assert!(out.is_empty() && chunk.at_end);
    std::fs::OpenOptions::new().append(true).open(&segment).unwrap().write_all(tail).unwrap();
    let chunk =
        store.read_log_bytes("c", last + 1, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
    assert_eq!(out, line.as_bytes());
    assert_eq!(chunk.next, last + 2);
}

#[test]
fn a_line_larger_than_a_chunk_is_one_chunk_of_its_own() {
    let path = std::env::temp_dir().join(format!("acpmux-log-bytes-{}", uuid::Uuid::now_v7()));
    let _home = Home(path.clone());
    let store = LocalStore::new(path.join("sessions"), 8 << 20).unwrap();
    let big = "x".repeat(3 * CHUNK_BYTES);
    for seq in 1..=4 {
        let text = if seq == 2 { big.clone() } else { format!("small {seq}") };
        let rec = EventRecord {
            seq,
            at: seq,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: serde_json::json!({ "text": text }),
            host_seq: None,
        };
        store.append("c", &rec).unwrap();
    }
    let mut marks = LogMarks::default();
    let mut out = Vec::new();
    let mut seen = Vec::new();
    let mut from = 1;
    loop {
        let chunk =
            store.read_log_bytes("c", from, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
        seen.push(log_line_seqs(
            &out.split_inclusive(|b| *b == b'\n').map(<[u8]>::to_vec).collect::<Vec<_>>(),
        ));
        from = chunk.next;
        if chunk.at_end {
            break;
        }
    }
    assert_eq!(seen, vec![vec![1], vec![2], vec![3, 4]]);
}

#[test]
fn compaction_and_a_restore_cut_bump_the_count_twice_and_a_cold_archive_does_not() {
    let (_home, store, last) = Home::chat("c", 200, 2 << 20);
    assert_eq!(store.read_stamp("c").unwrap(), 0);
    let staged =
        store.stage_compaction("c", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(staged.stats.trimmed > 0);
    assert!(store.commit_compaction("c", staged).unwrap());
    assert_eq!(store.read_stamp("c").unwrap(), 2);
    // A pass that changes no line leaves it.
    let staged =
        store.stage_compaction("c", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(store.commit_compaction("c", staged).unwrap());
    assert_eq!(store.read_stamp("c").unwrap(), 2);
    // A journal restore's cut.
    assert!(store.truncate_after("c", last / 2).unwrap());
    assert_eq!(store.read_stamp("c").unwrap(), 4);
    // A cold archive and its rehydrate keep every byte.
    let before = file_lines(&store, "c");
    let staged = store.stage_cold("c").unwrap().unwrap();
    assert!(store.commit_cold("c", staged).unwrap());
    assert!(store.rehydrate("c").unwrap());
    assert_eq!(file_lines(&store, "c"), before);
    assert_eq!(store.read_stamp("c").unwrap(), 4);
    // The count is on disk beside `events/`, read again by a new store.
    let again = LocalStore::new(store.root.clone(), 1 << 20).unwrap();
    assert_eq!(again.read_stamp("c").unwrap(), 4);
}

#[test]
fn a_cut_a_crash_left_halfway_bumps_the_count_when_it_is_finished() {
    let (_home, store, last) = Home::chat("c", 200, 2 << 20);
    super::between_segments_once("c", Box::new(|| panic!("a crash between two renames")));
    let staged =
        store.stage_compaction("c", CompactMode::Truncate { after: last / 2 }).unwrap().unwrap();
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        store.commit_compaction("c", staged)
    }));
    assert!(crashed.is_err());
    // The crash came after the first bump: one more when the cut is finished, before its first
    // rename, and one after its last.
    let restarted = LocalStore::new(store.root.clone(), 1 << 20).unwrap();
    assert_eq!(restarted.read_stamp("c").unwrap(), 1);
    restarted.segments("c").unwrap();
    assert_eq!(restarted.read_stamp("c").unwrap(), 3);
}

/// A read started while a change holds the writers' lock between two renames waits for the
/// change, then reads under the bumped count: never a chunk of mixed lines under the old one.
#[test]
fn a_read_started_mid_change_waits_and_reads_under_the_bumped_count() {
    let (_home, store, _) = Home::chat("c", 200, 2 << 20);
    let store = std::sync::Arc::new(store);
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let reader_store = store.clone();
    super::between_segments_once(
        "c",
        Box::new(move || {
            // The first segment is renamed and the writers' lock held: a read starts now.
            std::thread::spawn(move || {
                started_tx.send(()).unwrap();
                let before = reader_store.read_stamp("c").unwrap();
                let mut out = Vec::new();
                let mut marks = LogMarks::default();
                reader_store
                    .read_log_bytes("c", 1, LogFilter::ALL, before, &mut marks, &mut out)
                    .unwrap();
                let after = reader_store.read_stamp("c").unwrap();
                done_tx.send((before, after, out)).unwrap();
            });
            started_rx
                .recv_timeout(std::time::Duration::from_secs(30))
                .expect("the reader thread did not start in 30 s");
            std::thread::sleep(std::time::Duration::from_millis(200));
        }),
    );
    let staged =
        store.stage_compaction("c", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(done_rx.try_recv().is_err(), "nothing read yet");
    assert!(store.commit_compaction("c", staged).unwrap());
    let (before, after, out) = done_rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap();
    assert_eq!((before, after), (2, 2), "the count was read after the change, not inside it");
    let compacted = file_lines(&store, "c").concat();
    assert!(compacted.starts_with(&out), "every line of the chunk is the compacted log's");
}

#[test]
fn a_mark_from_before_a_compaction_is_not_used_after_it() {
    let (_home, store, _) = Home::chat("c", 200, 2 << 20);
    let mut marks = LogMarks::default();
    let mut out = Vec::new();
    let chunk = store.read_log_bytes("c", 1, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
    assert_eq!(marks.held(), 2);
    let staged =
        store.stage_compaction("c", CompactMode::Write { archive: None }).unwrap().unwrap();
    assert!(store.commit_compaction("c", staged).unwrap());
    let stamp = store.read_stamp("c").unwrap();
    let mut fresh = Vec::new();
    store
        .read_log_bytes(
            "c",
            chunk.next,
            LogFilter::ALL,
            stamp,
            &mut LogMarks::default(),
            &mut fresh,
        )
        .unwrap();
    store.read_log_bytes("c", chunk.next, LogFilter::ALL, stamp, &mut marks, &mut out).unwrap();
    assert_eq!(out, fresh, "the old marks' offsets name bytes of the log before");
    assert_eq!(out.split(|b| *b == b'\n').next().and_then(line_seq), Some(chunk.next));
    // A mark of the right count in a file no longer at its segment's name (a compaction's rename
    // made with no count, as a cold archive's rehydrate does) is dropped too.
    let (_home, store, _) = Home::chat("d", 200, 2 << 20);
    let mut marks = LogMarks::default();
    let chunk = store.read_log_bytes("d", 1, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
    let staged = store.stage_cold("d").unwrap().unwrap();
    assert!(store.commit_cold("d", staged).unwrap());
    store.read_log_bytes("d", chunk.next, LogFilter::ALL, 0, &mut marks, &mut out).unwrap();
    store
        .read_log_bytes("d", chunk.next, LogFilter::ALL, 0, &mut LogMarks::default(), &mut fresh)
        .unwrap();
    assert_eq!(out, fresh);
}
