//! Older transcript pages read through the log's index of its transcript records
//! (`store/transcript_index.rs`): every page is the one a read of the log gives, whatever state the
//! index is in, and a page costs its own records, not the log it skips.

use super::*;
use std::path::{Path, PathBuf};

/// The folder of a chat's transcript index, beside its `events`.
const INDEX_DIR: &str = "transcript-index";

fn index_dir(sessions: &Path) -> PathBuf {
    sessions.join("c").join(INDEX_DIR)
}

fn index_files(sessions: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(index_dir(sessions))
        .map(|rd| {
            rd.map(|e| e.unwrap().path())
                .filter(|p| p.extension().is_some_and(|e| e == "idx"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    files
}

fn segment_files(sessions: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(sessions.join("c").join("events"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "ndjson"))
        .collect();
    files.sort();
    files
}

fn mux(kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq: 0, at: 0, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn raw(kind: &str, bytes: usize) -> EventRecord {
    EventRecord {
        seq: 0,
        at: 0,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({"jsonrpc": "2.0", "method": kind, "params": {"text": "r".repeat(bytes)}}),
        host_seq: None,
    }
}

/// A Codex chat with every kind of line a long chat's log holds between its transcript records:
/// raw harness lines, load replays, bookkeeping updates, subagent updates, mux records a page
/// leaves out, preset approval cards, and a command still running at its end.
fn varied_chat() -> Vec<EventRecord> {
    let mut out = Vec::new();
    for (n, rec) in codex_chat(14, 24, 160, false).into_iter().enumerate() {
        out.push(rec);
        match n % 11 {
            0 => out.push(raw("codex.response", 3000)),
            1 => out.push(raw("claude.stream_event", 500)),
            2 => out.push(agent(0, "agent_message_chunk.replay", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "r".repeat(2000)}}))),
            3 => out.push(mux("preset_approval_request", json!({"preset": format!("p{n}"), "digest": "d"}))),
            4 => {
                let mut sub = agent(0, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("child {n}")}}));
                sub.msg["params"]["_meta"] = json!({"acpmux": {"subagent": "sub"}});
                out.push(sub);
            }
            5 => out.push(mux("turn_end", json!({}))),
            6 => out.push(agent(0, "usage_update", json!({"sessionUpdate": "usage_update", "used": n}))),
            7 => out.push(mux("preset_approval_decision", json!({"preset": format!("p{n}"), "outcome": "approved"}))),
            8 => out.push(raw("response", 800)),
            _ => {}
        }
    }
    out.extend(codex_chat(3, 6, 60, true).into_iter().map(|mut r| {
        r.seq = 0;
        r
    }));
    out
}

/// Every file of `from` (a chat's folder, one level of folders deep) copied to `to`.
fn copy_chat(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_chat(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A read of the log the old way: a copy of the chat with no index (removed before each read,
/// so nothing a read writes is ever read).
struct OldWay {
    sessions: PathBuf,
    hub: Arc<Hub>,
}

impl OldWay {
    fn of(sessions: &Path, root: &Path, segment_bytes: u64) -> Self {
        let copy = root.join("old-way");
        copy_chat(&sessions.join("c"), &copy.join("c"));
        let _ = std::fs::remove_dir_all(index_dir(&copy));
        Self { hub: deferred_hub(&copy, segment_bytes), sessions: copy }
    }

    fn page(&self, args: &PageArgs) -> (Vec<EventRecord>, bool) {
        let _ = std::fs::remove_dir_all(index_dir(&self.sessions));
        let page = args.read(&self.hub);
        let _ = std::fs::remove_dir_all(index_dir(&self.sessions));
        page
    }
}

struct PageArgs<'a> {
    before: Option<u64>,
    limit: usize,
    max_bytes: Option<usize>,
    filter: &'a EventFilter,
}

impl PageArgs<'_> {
    fn read(&self, hub: &Hub) -> (Vec<EventRecord>, bool) {
        let page = hub
            .events_page("c", 0, self.before, self.limit, self.max_bytes, true, self.filter)
            .unwrap();
        (page.events, page.has_more)
    }
}

fn page_filters() -> Vec<(&'static str, EventFilter)> {
    let presets = |omit| {
        EventFilter::parse(Some(&json!([
            "transcript",
            "preset_approval_request",
            "preset_approval_decision"
        ])))
        .unwrap()
        .omitting_superseded(omit)
    };
    vec![
        ("transcript", transcript(true)),
        ("transcript, every snapshot", transcript(false)),
        ("transcript and preset cards", presets(true)),
        ("transcript and preset cards, every snapshot", presets(false)),
        ("preset requests", EventFilter::parse(Some(&json!(["preset_approval_request"]))).unwrap()),
        ("a subagent", transcript(true).of_subagent(Some("sub"))),
    ]
}

/// Every page of `hub` over many `before`s, limits, byte bounds and filters is the old way's.
fn same_pages(state: &str, hub: &Hub, old: &OldWay, last: u64) {
    same_pages_of(state, hub, old, last, &page_filters());
}

/// [`same_pages`] for `filters`.
fn same_pages_of(
    state: &str,
    hub: &Hub,
    old: &OldWay,
    last: u64,
    filters: &[(&'static str, EventFilter)],
) {
    let mut befores = vec![None, Some(last + 5), Some(2), Some(1)];
    befores.extend((1..=13).map(|n| Some(last * n / 14 + 1)));
    for (name, filter) in filters {
        for before in &befores {
            for limit in [1usize, 6, 400] {
                for max_bytes in [Some(1500usize), Some(32 << 10), None] {
                    let args = PageArgs { before: *before, limit, max_bytes, filter };
                    let (events, more) = args.read(hub);
                    let (want, want_more) = old.page(&args);
                    let seqs = |r: &[EventRecord]| r.iter().map(|r| r.seq).collect::<Vec<_>>();
                    assert_eq!(
                        seqs(&events),
                        seqs(&want),
                        "{state}: {name} before {before:?} limit {limit} bytes {max_bytes:?}"
                    );
                    assert_eq!(
                        events, want,
                        "{state}: {name} before {before:?} limit {limit} bytes {max_bytes:?}"
                    );
                    assert_eq!(
                        more, want_more,
                        "{state}: {name} before {before:?} limit {limit} bytes {max_bytes:?}: has_more"
                    );
                }
            }
        }
    }
}

fn temp_root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("acpmux-{name}-{}", uuid::Uuid::now_v7()))
}

/// Leo, 2026-11-16: "how about speeding up the scrolling up of chats?" Pages read through the
/// index are the pages a read of the log gives: as written, and with the index missing, stale
/// (a segment a compaction replaced), another segment's, damaged, cut short or with a torn tail.
/// A read that passes a segment with no good index indexes it, and the next reads are the same.
#[test]
fn transcript_pages_through_the_index_are_the_logs_whatever_its_state() {
    let root = temp_root("transcript-index-parity");
    let sessions = root.join("sessions");
    let mut log = varied_chat();
    write_chat(&sessions, &mut log, 64 << 10);
    let last = log.last().unwrap().seq;
    assert!(segment_files(&sessions).len() > 8, "a log of many segments");
    let old = OldWay::of(&sessions, &root, 64 << 10);
    let hub = deferred_hub(&sessions, 64 << 10);
    assert_eq!(
        index_files(&sessions).len(),
        segment_files(&sessions).len(),
        "each segment is indexed as it is written"
    );
    same_pages("as written", &hub, &old, last);

    let mut states: Vec<(&str, Box<dyn Fn(&Path)>)> = Vec::new();
    states.push(("missing", Box::new(|s: &Path| std::fs::remove_dir_all(index_dir(s)).unwrap())));
    states.push((
        "damaged",
        Box::new(|s: &Path| {
            for path in index_files(s) {
                let mut bytes = std::fs::read(&path).unwrap();
                let at = bytes.len() / 2;
                bytes[at] ^= 0x5a;
                std::fs::write(&path, bytes).unwrap();
            }
        }),
    ));
    states.push((
        "cut short",
        Box::new(|s: &Path| {
            for path in index_files(s) {
                let len = std::fs::metadata(&path).unwrap().len();
                std::fs::OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .unwrap()
                    .set_len(len / 2 + 3)
                    .unwrap();
            }
        }),
    ));
    states.push((
        "a torn tail",
        Box::new(|s: &Path| {
            for path in index_files(s) {
                let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
                file.write_all(&[7u8; 13]).unwrap();
            }
        }),
    ));
    states.push((
        "another segment's",
        Box::new(|s: &Path| {
            let files = index_files(s);
            for pair in files.windows(2) {
                std::fs::copy(&pair[0], &pair[1]).unwrap();
            }
        }),
    ));
    states.push((
        "segments a compaction replaced",
        Box::new(|s: &Path| {
            // The same bytes in new files, as a retention rewrite that changed no line leaves them.
            for path in segment_files(s) {
                let tmp = path.with_extension("tmp");
                std::fs::copy(&path, &tmp).unwrap();
                std::fs::rename(&tmp, &path).unwrap();
            }
        }),
    ));
    states.push((
        "empty files",
        Box::new(|s: &Path| {
            for path in index_files(s) {
                std::fs::write(&path, b"").unwrap();
            }
        }),
    ));
    for (state, make) in &states {
        make(&sessions);
        same_pages(state, &hub, &old, last);
        same_pages(&format!("{state}, read again"), &hub, &old, last);
        // A fresh daemon over what the reads left.
        let fresh = deferred_hub(&sessions, 64 << 10);
        same_pages(&format!("{state}, a fresh daemon"), &fresh, &old, last);
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// A segment begun before the upgrade is indexed from where the writer was then: the bytes before
/// are read the old way, and every page is the log's.
#[test]
fn a_segment_begun_before_the_index_reads_its_older_part_the_old_way() {
    let root = temp_root("transcript-index-upgrade");
    let sessions = root.join("sessions");
    let mut log = varied_chat();
    for (n, rec) in log.iter_mut().enumerate() {
        rec.seq = n as u64 + 1;
    }
    let half = log.len() / 2;
    {
        let writer = LocalStore::new(sessions.clone(), 256 << 10).unwrap();
        writer.save(&meta("c")).unwrap();
        for rec in &log[..half] {
            writer.append("c", rec).unwrap();
        }
        writer.flush().unwrap();
    }
    // As a daemon before the index left it.
    let _ = std::fs::remove_dir_all(index_dir(&sessions));
    {
        let writer = LocalStore::new(sessions.clone(), 256 << 10).unwrap();
        for rec in &log[half..] {
            writer.append("c", rec).unwrap();
        }
        writer.flush().unwrap();
    }
    let last = log.last().unwrap().seq;
    let old = OldWay::of(&sessions, &root, 256 << 10);
    let hub = deferred_hub(&sessions, 256 << 10);
    same_pages("upgraded", &hub, &old, last);
    same_pages("upgraded, read again", &hub, &old, last);
    let _ = std::fs::remove_dir_all(&root);
}

/// A page over segments with no index indexes each segment it reads in, the one it stops in too
/// (its rest read by heads, once): the next page there reads only the index and its records.
#[test]
fn a_read_that_passes_a_segment_with_no_index_indexes_it() {
    let root = temp_root("transcript-index-lazy");
    let sessions = root.join("sessions");
    let payload = "x".repeat(14 << 10);
    let mut log: Vec<EventRecord> = (0..3_000u64)
        .map(|n| {
            if n % 50 == 49 {
                agent(0, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("reply {n}")}}))
            } else {
                raw("codex.response", payload.len())
            }
        })
        .collect();
    write_chat(&sessions, &mut log, 4 << 20);
    std::fs::remove_dir_all(index_dir(&sessions)).unwrap();
    let last = log.last().unwrap().seq;
    let filter = transcript(true);
    let hub = deferred_hub(&sessions, 4 << 20);
    let old = OldWay::of(&sessions, &root, 4 << 20);
    let args = PageArgs {
        before: Some(last / 2),
        limit: 2_000,
        max_bytes: Some(1 << 20),
        filter: &filter,
    };
    assert_eq!(args.read(&hub), old.page(&args));
    let segments = segment_files(&sessions).len();
    assert!(
        index_files(&sessions).len() >= segments / 2 - 1,
        "the segments the read passed are indexed"
    );
    assert!(index_files(&sessions).len() < segments, "the segment still written to is not");
    // A page in a segment the first read passed reads its index.
    let args =
        PageArgs { before: Some(last / 4), limit: 20, max_bytes: Some(1 << 20), filter: &filter };
    let r0 = read_bytes();
    let page = args.read(&hub);
    let read = read_bytes() - r0;
    assert_eq!(page, old.page(&args));
    if cfg!(target_os = "linux") {
        let page_bytes: u64 =
            page.0.iter().map(|r| serde_json::to_vec(r).unwrap().len() as u64).sum();
        let index_bytes: u64 =
            index_files(&sessions).iter().map(|p| std::fs::metadata(p).unwrap().len()).sum();
        assert!(
            read <= 64 * 1024 + 8 * page_bytes + index_bytes,
            "the page read {read} bytes for its {page_bytes} (index {index_bytes})"
        );
    }
    // A page that stops part way through a segment with no index indexes it whole: the next
    // page in it reads only its records.
    std::fs::remove_dir_all(index_dir(&sessions)).unwrap();
    let args =
        PageArgs { before: Some(last / 3), limit: 3, max_bytes: Some(1 << 20), filter: &filter };
    let first = args.read(&hub);
    assert_eq!(first, old.page(&args));
    assert!(!index_files(&sessions).is_empty(), "the segment the page stopped in is indexed");
    // Between the records the first page read: in segments it read in.
    let args = PageArgs {
        before: first.0.last().map(|r| r.seq),
        limit: 1,
        max_bytes: Some(1 << 20),
        filter: &filter,
    };
    let r0 = read_bytes();
    let page = args.read(&hub);
    let read = read_bytes() - r0;
    assert_eq!(page, old.page(&args));
    if cfg!(target_os = "linux") {
        assert!(read <= 64 * 1024, "the next page in it read {read} bytes");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// The daemon died between an index entry and its line, or a write failed part way: the entry
/// names a line that is not there, or a line of another seq. Pages stay the log's, and the next
/// appends go on indexing.
#[test]
fn an_entry_whose_line_was_never_written_is_read_past() {
    let root = temp_root("transcript-index-crash");
    let sessions = root.join("sessions");
    let mut log = varied_chat();
    for (n, rec) in log.iter_mut().enumerate() {
        rec.seq = n as u64 + 1;
    }
    let reply = |seq: u64| {
        agent(
            seq,
            "agent_message_chunk",
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("reply {seq}")}}),
        )
    };
    let mut seq = log.len() as u64;
    {
        let writer = LocalStore::new(sessions.clone(), 64 << 10).unwrap();
        writer.save(&meta("c")).unwrap();
        for rec in &log {
            writer.append("c", rec).unwrap();
        }
        // A write that fails part way (a full disk), and one whose cut back fails too.
        seq += 1;
        crate::store::test_write_fault::partial(20);
        assert!(writer.append("c", &reply(seq)).is_err());
        writer.append("c", &reply(seq)).unwrap();
        seq += 1;
        crate::store::test_write_fault::partial_and_failed_cut(30);
        assert!(writer.append("c", &reply(seq)).is_err());
        writer.append("c", &reply(seq)).unwrap();
        seq += 1;
        writer.append("c", &reply(seq)).unwrap();
        writer.flush().unwrap();
    }
    // The daemon died after the index entry of a reply and before its line: the line is gone.
    seq += 1;
    {
        let writer = LocalStore::new(sessions.clone(), 64 << 10).unwrap();
        writer.append("c", &reply(seq)).unwrap();
        writer.flush().unwrap();
    }
    let segment = segment_files(&sessions).pop().unwrap();
    let bytes = std::fs::read(&segment).unwrap();
    let end = bytes[..bytes.len() - 1].iter().rposition(|b| *b == b'\n').map_or(0, |n| n + 1);
    std::fs::OpenOptions::new().write(true).open(&segment).unwrap().set_len(end as u64).unwrap();
    // The next daemon writes other records where that line was.
    {
        let writer = LocalStore::new(sessions.clone(), 64 << 10).unwrap();
        for _ in 0..3 {
            seq += 1;
            let mut end = mux("turn_end", json!({}));
            end.seq = seq;
            writer.append("c", &end).unwrap();
            seq += 1;
            writer.append("c", &reply(seq)).unwrap();
        }
        writer.flush().unwrap();
    }
    let last = seq;
    let old = OldWay::of(&sessions, &root, 64 << 10);
    let hub = deferred_hub(&sessions, 64 << 10);
    same_pages("after a lost line", &hub, &old, last);
    let _ = std::fs::remove_dir_all(&root);
}

/// An index longer than its segment (the segment lost its last lines, the index kept their
/// entries) and an index whose segment's inode a new file took are read past.
#[test]
fn an_index_longer_than_its_segment_or_of_a_reused_inode_is_read_past() {
    let root = temp_root("transcript-index-longer");
    let sessions = root.join("sessions");
    let mut log = varied_chat();
    write_chat(&sessions, &mut log, 64 << 10);
    // Every segment loses its last quarter.
    for path in segment_files(&sessions) {
        let bytes = std::fs::read(&path).unwrap();
        let cut = bytes.len() * 3 / 4;
        let end = bytes[..cut].iter().rposition(|b| *b == b'\n').map_or(0, |n| n + 1);
        std::fs::OpenOptions::new().write(true).open(&path).unwrap().set_len(end as u64).unwrap();
    }
    let mut want = Vec::new();
    LocalStore::new(sessions.clone(), 64 << 10)
        .unwrap()
        .scan("c", 0, &mut |r| {
            want.push(r);
            true
        })
        .unwrap();
    let last = want.last().unwrap().seq;
    let old = OldWay::of(&sessions, &root, 64 << 10);
    let hub = deferred_hub(&sessions, 64 << 10);
    same_pages("segments shorter than their index", &hub, &old, last);
    // A segment removed and another file made in its place, the old index left beside it.
    let segments = segment_files(&sessions);
    let victim = &segments[segments.len() / 2];
    let bytes = std::fs::read(victim).unwrap();
    std::fs::remove_file(victim).unwrap();
    std::fs::write(victim, &bytes).unwrap();
    same_pages("a segment made again", &hub, &old, last);
    let _ = std::fs::remove_dir_all(&root);
}

/// A fresh daemon scrolls a chat written with the index back to its first record: each page reads
/// the index and its own records, never the log between them, and is the log's page.
#[test]
fn scrolling_a_chat_back_to_its_start_reads_each_page_not_the_log() {
    let root = temp_root("transcript-index-scroll");
    let sessions = root.join("sessions");
    let mut log = Vec::new();
    for (n, rec) in codex_chat(30, 30, 120, false).into_iter().enumerate() {
        log.push(rec);
        log.push(raw("codex.response", 6000 + n % 7));
        log.push(agent(0, "tool_call_update.replay", json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "content": "y".repeat(3000)})));
    }
    let log_bytes = write_chat(&sessions, &mut log, 512 << 10);
    let old = OldWay::of(&sessions, &root, 512 << 10);
    let hub = deferred_hub(&sessions, 512 << 10);
    let filter = transcript(true);
    let index_bytes: u64 =
        index_files(&sessions).iter().map(|p| std::fs::metadata(p).unwrap().len()).sum();
    let mut before = None;
    let mut pages = 0;
    loop {
        let args = PageArgs { before, limit: 60, max_bytes: Some(32 << 10), filter: &filter };
        let r0 = read_bytes();
        let (events, more) = args.read(&hub);
        let read = read_bytes() - r0;
        assert_eq!((events.clone(), more), old.page(&args), "page {pages}");
        if cfg!(target_os = "linux") {
            let page_bytes: u64 =
                events.iter().map(|r| serde_json::to_vec(r).unwrap().len() as u64).sum();
            assert!(
                read <= 64 * 1024 + 8 * page_bytes + index_bytes,
                "page {pages} read {read} bytes for its {page_bytes} (index {index_bytes}, log {log_bytes})"
            );
        }
        pages += 1;
        if !more {
            break;
        }
        before = events.first().map(|r| r.seq);
    }
    assert!(pages > 3, "{pages} pages");
    let _ = std::fs::remove_dir_all(&root);
}

/// Drops `dir`'s files from the page cache, so the next read of them is a cold one.
fn evict(dir: &Path) {
    #[cfg(target_os = "linux")]
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        if let Ok(file) = std::fs::File::open(entry.path()) {
            use std::os::fd::AsRawFd;
            // SAFETY: a valid descriptor this function holds open; advice changes no memory.
            unsafe { libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED) };
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = dir;
}

/// The web pane's older page exactly as it asks for it on a local acpmux (`direct.ts`
/// `olderPage`, `_acpmux/events` in `server/requests/events.rs`): the transcript and the preset
/// approval cards, `limit` 2,000 (`OLDER_PAGE_RECORDS`), `maxBytes` 1 MiB (`OLDER_PAGE_BYTES`,
/// which also leaves superseded tool output out), newest first before a seq.
fn pane_filter() -> EventFilter {
    EventFilter::parse(Some(&json!([
        "transcript",
        "preset_approval_request",
        "preset_approval_decision"
    ])))
    .unwrap()
    .omitting_superseded(true)
}

/// The pane's older page (`pane_filter`) of a large generated Codex-shaped log at several
/// depths: as before the index (`READ_THE_OLD_WAY`), on the first read of a log with no index
/// (which indexes the segments it reads in), on the next read, and through the index the log was
/// written with; warm, and cold (the log and its index dropped from the page cache first). Per
/// 100 records: a reply, a tool call update of 2 KB, a preset card every 1,000, and 14 KB load
/// replays and raw harness lines for the rest (about a long Codex chat's split). `cargo test -p
/// acpmux --release -- --ignored --nocapture older_page_synthetic_perf`; `SYNTH_PAGE_MB` sets the
/// log's size (default 1024). `SYNTH_TOOL_HEAVY=1` makes 60 of each 100 records snapshots of a
/// running command (`tool_call_update`s of 6 KB that carry its output so far; three calls at a
/// time, new ones every 5,000 records): a chat of long tool calls. `SYNTH_REPS=n` reads each page
/// through an index `n` times (warm: after one read to warm it; cold: each after the drop) and
/// prints the median and the slowest (`SYNTHMED`).
#[test]
#[ignore = "a measurement, not a check"]
fn older_page_synthetic_perf() {
    let mb: u64 = std::env::var("SYNTH_PAGE_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(1024);
    let root = temp_root("transcript-index-synthetic");
    let payload = "x".repeat(14 << 10);
    let heavy = std::env::var_os("SYNTH_TOOL_HEAVY").is_some_and(|v| v == "1");
    let mix = if heavy { "tool-heavy" } else { "real-shaped" };
    let records = mb * (1 << 20) / if heavy { 9 << 10 } else { 14 << 10 };
    let output = "s".repeat(6 << 10);
    let write = |sessions: &Path, indexed: bool| {
        let writer = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
        let writer = if indexed { writer } else { writer.without_transcript_index() };
        writer.save(&meta("c")).unwrap();
        for seq in 1..=records {
            let mut rec = match seq % 100 {
                0 if seq % 1000 == 0 => mux(
                    "preset_approval_request",
                    json!({"preset": format!("p{seq}"), "digest": "d"}),
                ),
                0 => agent(
                    0,
                    "agent_message_chunk",
                    json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("reply {seq} {}", "w".repeat(300))}}),
                ),
                1 => agent(
                    0,
                    "tool_call_update",
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("t{seq}"), "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "o".repeat(2000)}}]}),
                ),
                n @ 2..=61 if heavy => agent(
                    0,
                    "tool_call_update",
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("h{}-{}", seq / 5000, n % 3), "status": "in_progress", "content": [{"type": "content", "content": {"type": "text", "text": format!("{seq} {output}")}}], "_meta": {"terminal_output_delta": {"data": "d"}}}),
                ),
                n if n % 2 == 0 => raw("codex.response", payload.len()),
                _ => agent(
                    0,
                    "tool_call.replay",
                    json!({"sessionUpdate": "tool_call", "toolCallId": format!("r{seq}"), "title": payload}),
                ),
            };
            rec.seq = seq;
            writer.append("c", &rec).unwrap();
        }
        writer.flush().unwrap();
    };
    let legacy = root.join("legacy");
    let written = root.join("written");
    write(&legacy, false);
    write(&written, true);
    let log_bytes: u64 =
        segment_files(&legacy).iter().map(|p| std::fs::metadata(p).unwrap().len()).sum();
    println!(
        "synthetic log ({mix}): {records} records, {:.0} MB in {} segments",
        log_bytes as f64 / 1e6,
        segment_files(&legacy).len()
    );
    let filter = pane_filter();
    let read = |hub: &Hub, sessions: &Path, label: &str, depth: f64, cold: bool| {
        if cold {
            evict(&sessions.join("c").join("events"));
            evict(&index_dir(sessions));
        }
        let before = ((records as f64) * (1.0 - depth)).max(2.0) as u64;
        let (r0, b0, t0) =
            (read_bytes(), PARSED_BYTES.with(std::cell::Cell::get), std::time::Instant::now());
        let page =
            hub.events_page("c", 0, Some(before), 2000, Some(1 << 20), true, &filter).unwrap();
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        let own: u64 =
            page.events.iter().map(|r| serde_json::to_vec(r).unwrap().len() as u64).sum();
        println!(
            "SYNTH {mix} {label} {} depth {depth}: {ms:.1} ms, {} records ({:.2} MB, more {}), read {:.1} MB, parsed {:.2} MB",
            if cold { "cold" } else { "warm" },
            page.events.len(),
            own as f64 / 1e6,
            page.has_more,
            (read_bytes() - r0) as f64 / 1e6,
            (PARSED_BYTES.with(std::cell::Cell::get) - b0) as f64 / 1e6,
        );
        page.events
    };
    let reps: usize =
        std::env::var("SYNTH_REPS").ok().and_then(|v| v.parse().ok()).unwrap_or(1).max(1);
    // `reps` reads of one page (after one to warm it when warm): the median and the slowest.
    let repeated = |hub: &Hub, sessions: &Path, label: &str, depth: f64, cold: bool| {
        if !cold && reps > 1 {
            read(hub, sessions, &format!("{label} (warm-up)"), depth, cold);
        }
        let mut runs = Vec::new();
        let mut events = Vec::new();
        for _ in 0..reps {
            let r0 = read_bytes();
            let t0 = std::time::Instant::now();
            events = read(hub, sessions, label, depth, cold);
            runs.push((t0.elapsed().as_secs_f64() * 1000.0, (read_bytes() - r0) as f64 / 1e6));
        }
        runs.sort_by(|a, b| a.0.total_cmp(&b.0));
        let (median, slowest) = (runs[runs.len() / 2], runs[runs.len() - 1]);
        println!(
            "SYNTHMED {mix} {label} {} depth {depth}: median {:.1} ms (slowest {:.1} ms of {reps}), read {:.1} MB",
            if cold { "cold" } else { "warm" },
            median.0,
            slowest.0,
            median.1,
        );
        events
    };
    let depths = [0.02, 0.25, 0.5, 0.9];
    let hub = deferred_hub(&legacy, 8 << 20);
    let indexed_hub = deferred_hub(&written, 8 << 20);
    for cold in [false, true] {
        for depth in depths {
            super::READ_THE_OLD_WAY.with(|old| old.set(true));
            let want = read(&hub, &legacy, "no index", depth, cold);
            super::READ_THE_OLD_WAY.with(|old| old.set(false));
            let _ = std::fs::remove_dir_all(index_dir(&legacy));
            assert_eq!(read(&hub, &legacy, "first read", depth, cold), want);
            assert_eq!(repeated(&hub, &legacy, "next read", depth, cold), want);
            let got = repeated(&indexed_hub, &written, "indexed as written", depth, cold);
            assert_eq!(got, want);
        }
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// A `tool_call_update` of call `id` that carries nothing but its output so far (`bytes` of it)
/// and its increment: an update the superseded fold may leave out whole.
fn snapshot(id: &str, n: usize, bytes: usize) -> EventRecord {
    let text = format!("{n:06} {}", "s".repeat(bytes));
    agent(
        0,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress", "content": [{"type": "content", "content": {"type": "text", "text": text}}], "_meta": {"terminal_output_delta": {"data": "d"}}}),
    )
}

/// A chat of long tool calls, as a long Codex chat logs them: per prompt a few calls, their
/// snapshots interleaved (some with no content, some with no status), a subagent's call of the
/// same id, raw harness lines and replies between, and each call's end; ids used again in later
/// prompts; the last prompt's calls still running.
fn snapshot_chat(prompts: usize, steps: usize, bytes: usize) -> Vec<EventRecord> {
    let mut out = Vec::new();
    for prompt in 0..prompts {
        out.push(mux("user_message", json!({"text": format!("prompt {prompt}")})));
        let calls = ["a", "b", "c"];
        for id in calls {
            out.push(agent(0, "tool_call", json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test", "kind": "execute", "status": "in_progress"})));
        }
        for step in 0..steps {
            let id = calls[step % calls.len()];
            let mut rec = snapshot(id, step, bytes + (step * 37) % 900);
            match step % 13 {
                3 => {
                    rec.msg["params"]["update"].as_object_mut().unwrap().remove("content");
                }
                5 => {
                    rec.msg["params"]["update"].as_object_mut().unwrap().remove("status");
                }
                7 => rec.msg["params"]["_meta"] = json!({"acpmux": {"subagent": "sub"}}),
                9 => out.push(raw("codex.response", 2500)),
                11 => out.push(agent(0, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("note {step}")}}))),
                _ => {}
            }
            out.push(rec);
            if step % 17 == 16 {
                out.push(mux("turn_started", json!({})));
            }
        }
        if prompt + 1 == prompts {
            break;
        }
        for id in calls {
            out.push(agent(0, "tool_call_update", json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "rawOutput": {"exit_code": 0}, "content": [{"type": "content", "content": {"type": "text", "text": "done"}}]})));
        }
        out.push(agent(0, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {prompt}")}})));
    }
    out
}

/// The FNV-1a hash an index entry's check folds (`store/kind_index.rs` `fnv`).
fn entry_check(bytes: &[u8]) -> u32 {
    let h = bytes
        .iter()
        .fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x100_0000_01b3));
    (h ^ (h >> 32)) as u32
}

/// The entries of `path` (an index: a 96-byte header, then 48-byte entries).
fn entries_of(path: &Path) -> Vec<Vec<u8>> {
    let bytes = std::fs::read(path).unwrap();
    bytes.get(96..).unwrap_or_default().chunks_exact(48).map(<[u8]>::to_vec).collect()
}

/// How many entries of `sessions`' indexes hold an update's facts (flag 2).
fn snapshot_entries(sessions: &Path) -> usize {
    index_files(sessions)
        .iter()
        .flat_map(|p| entries_of(p))
        .filter(|e| u32::from_le_bytes(e[20..24].try_into().unwrap()) & 2 != 0)
        .count()
}

/// Every entry of `sessions`' indexes as an index written before this change left it: its flags
/// but the line's, and bytes 24..44, 0.
fn zero_snapshot_fields(sessions: &Path) {
    for path in index_files(sessions) {
        let mut bytes = std::fs::read(&path).unwrap();
        for entry in bytes[96..].chunks_exact_mut(48) {
            let flags = u32::from_le_bytes(entry[20..24].try_into().unwrap()) & 1;
            entry[20..24].copy_from_slice(&flags.to_le_bytes());
            entry[24..44].fill(0);
            let check = entry_check(&entry[..44]);
            entry[44..48].copy_from_slice(&check.to_le_bytes());
        }
        std::fs::write(&path, bytes).unwrap();
    }
}

/// The filters a page that leaves superseded updates out may read with, and with every record
/// read: the pane's, the app's, and with records stubbed or tool output cut.
fn snapshot_filters() -> Vec<(&'static str, EventFilter)> {
    let mut filters = page_filters();
    filters.push(("the pane's", pane_filter()));
    filters.push(("stubbed past 1.5 KB", transcript(true).stubbing_over(Some(1500))));
    filters.push(("tool output cut past 1 KB", transcript(true).cutting_tool_output(Some(1000))));
    filters.push((
        "only cards",
        EventFilter::parse(Some(&json!(["preset_approval_request", "preset_approval_decision"])))
            .unwrap()
            .omitting_superseded(true),
    ));
    filters
}

/// Leo, 2026-11-16: "how about speeding up the scrolling up of chats?" A page that leaves
/// superseded tool call updates out leaves them unread, and is still the log's page exactly: over
/// prompts that split calls, interleaved calls, a subagent's call of the same id, calls whose
/// snapshots straddle segments and pages, an index written before (its facts all 0), a mix of
/// both, and the index's other states.
#[test]
fn pages_that_leave_snapshots_unread_are_the_logs() {
    let root = temp_root("snapshot-skip-parity");
    let sessions = root.join("sessions");
    let mut log = snapshot_chat(4, 70, 600);
    log.extend(varied_chat());
    log.extend(snapshot_chat(2, 40, 2500));
    write_chat(&sessions, &mut log, 64 << 10);
    let last = log.last().unwrap().seq;
    assert!(segment_files(&sessions).len() > 8, "a log of many segments");
    let snapshots = snapshot_entries(&sessions);
    assert!(snapshots > 200, "{snapshots} entries hold an update's facts");
    let old = OldWay::of(&sessions, &root, 64 << 10);
    let hub = deferred_hub(&sessions, 64 << 10);
    let filters = snapshot_filters();
    same_pages_of("as written", &hub, &old, last, &filters);
    // Half the segments' indexes as written before, half as now.
    let files = index_files(&sessions);
    let saved: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();
    zero_snapshot_fields(&sessions);
    assert_eq!(snapshot_entries(&sessions), 0);
    same_pages_of("indexes written before", &hub, &old, last, &filters);
    for (n, (path, bytes)) in files.iter().zip(&saved).enumerate() {
        if n % 2 == 0 {
            std::fs::write(path, bytes).unwrap();
        }
    }
    same_pages_of("a mix", &hub, &old, last, &filters);
    // An index cut short, and one with an entry that names no line.
    for path in index_files(&sessions).iter().step_by(3) {
        let len = std::fs::metadata(path).unwrap().len();
        std::fs::OpenOptions::new().write(true).open(path).unwrap().set_len(len * 2 / 3).unwrap();
    }
    same_pages_of("cut short", &hub, &old, last, &filters);
    let fresh = deferred_hub(&sessions, 64 << 10);
    same_pages_of("a fresh daemon", &fresh, &old, last, &filters);
    let _ = std::fs::remove_dir_all(&root);
}

/// An older page of a chat with many long tool calls (hundreds of snapshots of a few calls, each
/// large) reads only the snapshots it keeps, about each call's newest, and its other records:
/// about twice the page's own bytes, beside the index (and a line head per snapshot). Before, it
/// read every snapshot back to its start.
#[test]
fn a_page_reads_each_calls_newest_snapshot_not_every_one() {
    let root = temp_root("snapshot-skip-bytes");
    let sessions = root.join("sessions");
    let mut log = snapshot_chat(3, 300, 12 << 10);
    let log_bytes = write_chat(&sessions, &mut log, 8 << 20);
    let last = log.last().unwrap().seq;
    let old = OldWay::of(&sessions, &root, 8 << 20);
    let hub = deferred_hub(&sessions, 8 << 20);
    let filter = pane_filter();
    let snapshots = snapshot_entries(&sessions) as u64;
    let index_bytes: u64 =
        index_files(&sessions).iter().map(|p| std::fs::metadata(p).unwrap().len()).sum();
    for before in [None, Some(last * 2 / 3), Some(last / 3)] {
        let args = PageArgs { before, limit: 2_000, max_bytes: Some(1 << 20), filter: &filter };
        let r0 = read_bytes();
        let page = args.read(&hub);
        let read = read_bytes() - r0;
        assert_eq!(page, old.page(&args), "before {before:?}");
        let page_bytes: u64 =
            page.0.iter().map(|r| serde_json::to_vec(r).unwrap().len() as u64).sum();
        println!(
            "before {before:?}: read {read} for a page of {page_bytes} (index {index_bytes}, log {log_bytes})"
        );
        if cfg!(target_os = "linux") {
            // The page's own records (each call's newest snapshot whole, the snapshots it keeps
            // with their content left out read without it), and a line head per snapshot left
            // unread.
            let heads = snapshots * 130;
            assert!(
                read <= 64 * 1024 + 2 * page_bytes + index_bytes + heads,
                "before {before:?}: the page read {read} bytes for its {page_bytes} (index {index_bytes}, {snapshots} snapshots, log {log_bytes})"
            );
        }
    }
    let _ = std::fs::remove_dir_all(&root);
}
