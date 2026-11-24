//! A sealed segment's copy of the records a log load reads (`store/kind_index.rs`).

use super::*;
use serde_json::json;
use std::io::Write;

fn rec(seq: u64, kind: &str) -> EventRecord {
    let dir = if kind == "tool_call_update" { "in" } else { "mux" };
    let msg = json!({"promptId": format!("p{seq}"), "pad": "x".repeat(2000)});
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

/// The second scan for the log load's kinds reads each segment's copy, not the segment: a segment
/// whose bytes are gone (the same file and length, other bytes) still yields its records. Every
/// record of those kinds comes back once, in order, as the first scan read them.
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
        // Only the indexed records, as written.
        let text = std::fs::read_to_string(&copy).unwrap();
        assert!(text.lines().skip(1).all(|l| !l.contains("tool_call_update")), "segment {index}");
        // The same file and length, other bytes: only the copy still holds the records.
        let len = std::fs::metadata(path).unwrap().len();
        std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .write_all(" ".repeat(len as usize).as_bytes())
            .unwrap();
    }
    assert_eq!(scanned(&store, &kinds), expected, "the copies hold every record");
    // A scan for any other kind reads the segments themselves.
    assert!(scanned(&store, &["tool_call_update"]).is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

/// A copy of a file no longer at its segment's path (a retention rewrite renames a new one over
/// it, a move brings another log) is read past: the scan reads the segment and copies it again.
/// A segment that grew past its copy is read past it.
#[test]
fn a_copy_that_no_longer_matches_its_segment_is_made_again() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 8);
    let kinds = ["queued"];
    scanned(&store, &kinds);
    // Rewrite the first segment without its first record, renamed over it.
    let (_, first) = store.segments("c").unwrap()[0].clone();
    let text = std::fs::read_to_string(&first).unwrap();
    let dropped: u64 =
        serde_json::from_str::<EventRecord>(text.lines().next().unwrap()).unwrap().seq;
    let rest: String = text.lines().skip(1).map(|l| format!("{l}\n")).collect();
    let tmp = first.with_extension("rewrite");
    std::fs::write(&tmp, rest).unwrap();
    std::fs::rename(&tmp, &first).unwrap();
    log.retain(|r| r.seq != dropped);
    // More turns: the newest segment is sealed.
    let mut seq = log.last().unwrap().seq;
    for _ in 0..60 {
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
    let hub = crate::hub::Hub::QUEUE_KINDS.iter().chain(crate::hub::Hub::INBOX_KINDS);
    for kind in hub.chain(crate::hub::Hub::TRANSFER_KINDS).chain(&[
        "turn_started",
        "turn_result",
        "forked",
        "_acpmux/message",
    ]) {
        assert!(INDEXED_KINDS.contains(kind), "{kind}");
    }
}

/// A damaged copy (cut short, or its header's coverage changed) is read past: the scan reads the
/// segment, as without a copy.
#[test]
fn a_damaged_copy_is_read_past() {
    let root = root();
    let (store, log) = store_with_log(&root, 6);
    let kinds = ["queued", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    scanned(&store, &kinds);
    let copies = root.join("c").join(kind_index::DIR);
    for (n, entry) in std::fs::read_dir(&copies).unwrap().enumerate() {
        let path = entry.unwrap().path();
        let text = std::fs::read_to_string(&path).unwrap();
        let (header, lines) = text.split_once('\n').unwrap();
        let damaged = if n % 2 == 0 {
            // Its last copied line lost.
            let cut = lines.trim_end_matches('\n').rsplit_once('\n').map_or("", |(a, _)| a);
            format!("{header}\n{cut}\n")
        } else {
            // It claims to cover nothing of the segment.
            let mut h: serde_json::Value = serde_json::from_str(header).unwrap();
            h["len"] = json!(0);
            format!("{h}\n{lines}")
        };
        std::fs::write(&path, damaged).unwrap();
    }
    assert_eq!(scanned(&store, &kinds), expected);
    let _ = std::fs::remove_dir_all(&root);
}

/// A copy made for another list of kinds (an older daemon's, before a kind the log load reads was
/// added) holds no line of the added kinds, so it is read past.
#[test]
fn a_copy_made_for_other_kinds_is_read_past() {
    let root = root();
    let (store, log) = store_with_log(&root, 6);
    let kinds = ["queued", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    scanned(&store, &kinds);
    let copies = root.join("c").join(kind_index::DIR);
    let mut stripped = Vec::new();
    for (index, path) in store.segments("c").unwrap() {
        let copy = copies.join(format!("{index:06}.ndjson"));
        let Ok(text) = std::fs::read_to_string(&copy) else { continue };
        let (header, lines) = text.split_once('\n').unwrap();
        let header: serde_json::Value = serde_json::from_str(header).unwrap();
        // The copy an older list without `turn_result` made: none of its lines.
        let older: String =
            lines.split_inclusive('\n').filter(|l| !l.contains("\"turn_result\"")).collect();
        let meta = kind_index::Stamp::of(&std::fs::File::open(&path).unwrap()).unwrap();
        let len = header["len"].as_u64().unwrap();
        store.write_kind_index("c", index, &meta, len, true, older.as_bytes()).unwrap();
        stripped.push(copy);
    }
    assert!(!stripped.is_empty());
    let queued: Vec<EventRecord> =
        expected.iter().filter(|r| r.kind == "queued").cloned().collect();
    assert_eq!(scanned(&store, &kinds), queued, "a copy for these kinds is read");
    for copy in &stripped {
        let text = std::fs::read_to_string(copy).unwrap();
        let (header, lines) = text.split_once('\n').unwrap();
        let mut h: serde_json::Value = serde_json::from_str(header).unwrap();
        h["kinds"] = json!(h["kinds"].as_u64().unwrap() ^ 1);
        std::fs::write(copy, format!("{h}\n{lines}")).unwrap();
    }
    assert_eq!(scanned(&store, &kinds), expected);
    let _ = std::fs::remove_dir_all(&root);
}

/// A strict scan fails on a line that does not read, as one of the whole log does, whether it
/// reads the segment or a copy: the copy a lenient scan made says the line did not read.
#[test]
fn a_strict_scan_fails_on_an_unreadable_line_through_a_copy_too() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 3);
    let (_, newest) = store.segments("c").unwrap().last().unwrap().clone();
    let mut file = std::fs::OpenOptions::new().append(true).open(&newest).unwrap();
    file.write_all(b"{\"seq\": not json}\n").unwrap();
    let next = rec(log.last().unwrap().seq + 1, "queued");
    file.write_all((serde_json::to_string(&next).unwrap() + "\n").as_bytes()).unwrap();
    log.push(next);
    let queued: Vec<EventRecord> = log.iter().filter(|r| r.kind == "queued").cloned().collect();
    let strict = |store: &LocalStore| store.scan_kinds_strict("c", &["queued"], &mut |_| true);
    assert!(strict(&store).is_err(), "from the segment");
    assert_eq!(scanned(&store, &["queued"]), queued, "a lenient scan skips it");
    assert_eq!(scanned(&store, &["queued"]), queued, "from the copies");
    assert!(strict(&store).is_err(), "from the copy");
    let _ = std::fs::remove_dir_all(&root);
}

/// A strict scan of a log whose lines all read takes the copies, as a lenient one does.
#[test]
fn a_strict_scan_reads_the_copies_of_a_whole_log() {
    let root = root();
    let (store, log) = store_with_log(&root, 6);
    let kinds = ["transfer_out", "queued"];
    let expected: Vec<EventRecord> = log.iter().filter(|r| r.kind == "queued").cloned().collect();
    let strict = |store: &LocalStore| {
        let mut out = Vec::new();
        store
            .scan_kinds_strict("c", &kinds, &mut |r| {
                out.push(r);
                true
            })
            .unwrap();
        out
    };
    assert_eq!(strict(&store), expected);
    PARSED_LINES.with(|n| n.set(0));
    assert_eq!(strict(&store), expected, "from the copies");
    let parsed = PARSED_LINES.with(|n| n.get());
    assert_eq!(parsed as usize, expected.len(), "parsed only the copies' wanted lines");
    let _ = std::fs::remove_dir_all(&root);
}

/// A line still being written at the end of the newest segment is no part of a copy: once it is
/// whole, a scan returns it.
#[test]
fn a_line_being_written_is_read_once_whole() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 3);
    let (_, newest) = store.segments("c").unwrap().last().unwrap().clone();
    let next = rec(log.last().unwrap().seq + 1, "queued");
    let line = serde_json::to_string(&next).unwrap() + "\n";
    let (head, tail) = line.split_at(line.len() / 2);
    let mut file = std::fs::OpenOptions::new().append(true).open(&newest).unwrap();
    file.write_all(head.as_bytes()).unwrap();
    let before: Vec<EventRecord> = log.iter().filter(|r| r.kind == "queued").cloned().collect();
    assert_eq!(scanned(&store, &["queued"]), before);
    file.write_all(tail.as_bytes()).unwrap();
    log.push(next);
    let after: Vec<EventRecord> = log.iter().filter(|r| r.kind == "queued").cloned().collect();
    assert_eq!(scanned(&store, &["queued"]), after);
    assert_eq!(scanned(&store, &["queued"]), after, "from the copy");
    let _ = std::fs::remove_dir_all(&root);
}

/// A scan never makes a deleted chat's folder again.
#[test]
fn a_scan_writes_no_copy_for_a_deleted_chat() {
    let root = root();
    let (store, _) = store_with_log(&root, 3);
    let (index, path) = store.segments("c").unwrap()[0].clone();
    let meta = kind_index::Stamp::of(&std::fs::File::open(&path).unwrap()).unwrap();
    std::fs::remove_dir_all(root.join("c")).unwrap();
    assert!(store.write_kind_index("c", index, &meta, 0, true, b"").is_err());
    assert!(!root.join("c").exists());
    let _ = std::fs::remove_dir_all(&root);
}

/// Linux keeps a birth time and the copies need it, on musl too: Rust's `Metadata::created` fails
/// on every musl build (the static daemon), so no copy was ever written or read there. The birth
/// time comes from `statx` on the open file, the same value glibc's `created` reads.
#[cfg(target_os = "linux")]
#[test]
fn a_segments_birth_time_is_read_on_linux() {
    let root = root();
    let (store, _) = store_with_log(&root, 3);
    let (_, path) = store.segments("c").unwrap()[0].clone();
    let file = std::fs::File::open(&path).unwrap();
    let born = kind_index::birth_ns(&file);
    let created = std::fs::metadata(&path).unwrap().created().ok();
    let created = created.map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
    if cfg!(target_env = "gnu") {
        assert_eq!(born.map(u128::from), created, "glibc's created() reads the same statx field");
    } else {
        assert!(born.is_some_and(|ns| ns > 0), "statx read no birth time: {born:?}");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// The copies' folder is owner-only whatever the umask: under 002 (a lane VM's) it was made
/// group-writable, `private_state_dir` refused it, and no copy was ever written. The umask is the
/// process's, so the scan runs in a child process of this test binary that runs this test alone.
#[cfg(unix)]
#[test]
fn a_copy_is_written_under_a_group_writable_umask() {
    use std::os::unix::fs::PermissionsExt;
    const CHILD: &str = "ACPMUX_TEST_KIND_INDEX_UMASK_CHILD";
    let name = "store::kind_index::tests::a_copy_is_written_under_a_group_writable_umask";
    if std::env::var_os(CHILD).is_none() {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([name, "--exact", "--nocapture", "--test-threads=1"])
            .env(CHILD, "1")
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success() && text.contains("1 passed"), "{text}");
        return;
    }
    // SAFETY: umask has no preconditions; this process runs this test only.
    unsafe { libc::umask(0o002) };
    let root = root();
    let (store, log) = store_with_log(&root, 3);
    let first = scanned(&store, &["queued"]);
    assert_eq!(first.len(), log.iter().filter(|r| r.kind == "queued").count());
    let dir = root.join("c").join(kind_index::DIR);
    let mode = std::fs::metadata(&dir).expect("the copies' folder").permissions().mode();
    assert_eq!(mode & 0o777, 0o700);
    assert!(std::fs::read_dir(&dir).unwrap().next().is_some(), "a copy was written");
    let _ = std::fs::remove_dir_all(&root);
}

/// A scan that read [`kind_index::COPY_AFTER`] bytes past a copy adds only those lines to it: the
/// copy's earlier bytes are not written again, so the bytes written per scan stay bounded by what
/// the log grew, not by the copy's size (cmuxterm-hq#9263). Every record still comes back once, in
/// order, and a later scan reads the grown copy.
#[test]
fn a_scan_adds_to_a_copy_and_never_writes_its_lines_again() {
    let root = root();
    // One segment, so every scan reads the same copy.
    let store = LocalStore::new(root.clone(), 1 << 30).unwrap();
    let big = |seq: u64, kind: &str| {
        let msg = json!({"promptId": format!("p{seq}"), "text": "x".repeat(64 * 1024)});
        EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
    };
    let kinds = ["user_message"];
    let mut log = Vec::new();
    let mut seq = 0;
    let mut grow = |log: &mut Vec<EventRecord>, n: u64| {
        for _ in 0..n {
            seq += 1;
            let r = big(seq, if seq % 2 == 0 { "user_message" } else { "tool_call_update" });
            store.append("c", &r).unwrap();
            log.push(r);
        }
        store.flush().unwrap();
    };
    let mut sizes = Vec::new();
    for _ in 0..6 {
        // Past COPY_AFTER (1 MiB) each round: 20 records of 64 KiB.
        grow(&mut log, 20);
        let index = store.segments("c").unwrap()[0].0;
        let copy = root.join("c").join(kind_index::DIR).join(format!("{index:06}.ndjson"));
        let before = std::fs::metadata(&copy).ok().map(|m| (m.len(), inode(&copy)));
        let expected: Vec<EventRecord> =
            log.iter().filter(|r| r.kind == "user_message").cloned().collect();
        assert_eq!(scanned(&store, &kinds), expected);
        let after = (std::fs::metadata(&copy).unwrap().len(), inode(&copy));
        if let Some((len, ino)) = before {
            assert_eq!(ino, after.1, "the copy was added to, not replaced");
            assert!(after.0 > len, "the copy grew");
        }
        sizes.push(after.0);
        assert_eq!(scanned(&store, &kinds), expected, "from the grown copy");
    }
    assert!(sizes.windows(2).all(|w| w[1] > w[0]), "{sizes:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// An addition a crash cut before its header (lines past the ones the header covers) is read
/// past; a torn header fails the seal and the copy is made again. Neither is ever read wrong.
#[test]
fn a_cut_addition_or_a_torn_header_is_read_past() {
    let root = root();
    let (store, log) = store_with_log(&root, 6);
    let kinds = ["queued", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    scanned(&store, &kinds);
    let copies = root.join("c").join(kind_index::DIR);
    for (n, entry) in std::fs::read_dir(&copies).unwrap().enumerate() {
        let path = entry.unwrap().path();
        let mut bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes[kind_index::HEADER_WIDTH - 1], b'\n', "a fixed-width header");
        if n % 2 == 0 {
            // A line the header does not cover.
            bytes.extend_from_slice(b"{\"seq\":999999,\"kind\":\"queued\"}\n");
        } else {
            // A header half written: one digit of it changed.
            let at = bytes.iter().position(|b| b.is_ascii_digit()).unwrap();
            bytes[at] = if bytes[at] == b'9' { b'8' } else { bytes[at] + 1 };
        }
        std::fs::write(&path, bytes).unwrap();
    }
    assert_eq!(scanned(&store, &kinds), expected);
    assert_eq!(scanned(&store, &kinds), expected);
    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(unix)]
fn inode(path: &Path) -> u64 {
    std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(path).unwrap())
}

#[cfg(not(unix))]
fn inode(_: &Path) -> u64 {
    0
}

/// The checked copy is rebuildable. Its atomic replacement needs no durability work.
#[test]
fn a_kind_index_write_does_not_sync() {
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    std::fs::create_dir(store.dir("c")).unwrap();
    let copy = store.kind_index_path("c", 1);
    let syncs = crate::config::startup_seams::Count::syncs(home.path());
    // An explicit stamp makes this independent of filesystem birth-time support.
    let stamp = Stamp { id: (1, 2, 3), len: 0 };
    store.write_kind_index("c", 1, &stamp, 0, true, b"").unwrap();
    let first = std::fs::read(&copy).unwrap();
    assert_eq!(first.len(), HEADER_WIDTH);
    store.write_kind_index("c", 1, &stamp, 0, false, b"").unwrap();
    assert_ne!(std::fs::read(&copy).unwrap(), first, "the copy was replaced");
    assert_eq!(syncs.get(), 0, "a derived kind index performed durability work");
}

/// The kinds a resend's prompt state reads (`hub/prompt_ledger.rs` `PROMPT_STATE_KINDS`).
const PROMPT_KINDS: &[&str] = &[
    "turn_stop_requested",
    "queued",
    "user_message",
    "turn_started",
    "turn_result",
    "prompt_refused",
    "queue_declined",
    "queue_removed",
    "dequeued",
];

/// `scan_kinds_keyed` of chat "c" for the records naming `prompt`.
fn keyed(store: &LocalStore, prompt: &str) -> Vec<EventRecord> {
    let mut out = Vec::new();
    store
        .scan_kinds_keyed("c", PROMPT_KINDS, &mut |h| h.prompt_id == Some(prompt), &mut |r| {
            out.push(r);
            true
        })
        .unwrap();
    out
}

/// The records of `log` a resend's prompt state reads for `prompt`.
fn naming(log: &[EventRecord], prompt: &str) -> Vec<EventRecord> {
    log.iter()
        .filter(|r| PROMPT_KINDS.contains(&r.kind.as_str()) && r.msg["promptId"] == prompt)
        .cloned()
        .collect()
}

/// A restart's resume pass asks each chat's prompt state per retry and per queued prompt, and
/// each ask scanned its indexed kinds whole (NIGHTLY sample 2026-11-15: 2947 of 4269 samples
/// under `scan_kinds`, each call reading, hashing and parsing the chat's whole copy again). A
/// keyed scan of a log a scan already read parses only the records whose head it keeps, however
/// many times it is asked; a record appended after is seen.
#[test]
fn a_keyed_scan_parses_only_the_records_it_keeps_and_sees_what_was_appended() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 12);
    let prompts = ["p2", "p25", "p288"];
    for prompt in prompts {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt));
    }
    PARSED_LINES.with(|n| n.set(0));
    for _ in 0..20 {
        for prompt in prompts {
            assert_eq!(keyed(&store, prompt), naming(&log, prompt));
        }
    }
    let parsed = PARSED_LINES.with(|n| n.get());
    assert!(
        parsed <= 60,
        "60 keyed scans of an unchanged log, one record each, parsed {parsed} lines"
    );
    let mut seq = log.last().unwrap().seq;
    for kind in ["queued", "tool_call_update", "user_message", "turn_result"] {
        seq += 1;
        let r = rec(seq, kind);
        store.append("c", &r).unwrap();
        log.push(r);
    }
    store.flush().unwrap();
    for prompt in ["p2", "p289", "p291", "p292"] {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt), "{prompt} after the appends");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// A segment replaced by a rename (a retention rewrite) after a keyed scan read it is read again:
/// the scan returns the new file's records, not the old file's heads.
#[test]
fn a_segment_replaced_after_a_keyed_scan_is_read_again() {
    let root = root();
    let (store, log) = store_with_log(&root, 4);
    let queued: Vec<String> = log
        .iter()
        .filter(|r| r.kind == "queued")
        .map(|r| r.msg["promptId"].as_str().unwrap().to_owned())
        .collect();
    for prompt in &queued {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt));
    }
    for (_, path) in store.segments("c").unwrap() {
        let text = std::fs::read_to_string(&path).unwrap();
        let kept: String = text
            .lines()
            .filter(|l| !l.contains("\"kind\":\"queued\""))
            .map(|l| format!("{l}\n"))
            .collect();
        let tmp = path.with_extension("rewrite");
        std::fs::write(&tmp, kept).unwrap();
        std::fs::rename(&tmp, &path).unwrap();
    }
    for prompt in &queued {
        assert_eq!(keyed(&store, prompt), Vec::new(), "{prompt}'s queued record is gone");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// The resume pass's cost, timed: `ACPMUX_LEDGER_BENCH=1 ACPMUX_LEDGER_BENCH_CHATS=64 cargo test
/// --release -p acpmux --lib ledger_scan_resume_pass_bench -- --ignored --nocapture`. Chats of
/// 300 turns each (a 4 KiB prompt and 20 agent updates a turn), each asked the state of 4 of its
/// prompts a pass, as `logged_prompt_state` asks it (a keyed scan of its kinds).
#[test]
#[ignore = "a timing harness, run by hand"]
fn ledger_scan_resume_pass_bench() {
    let root = root();
    let store = LocalStore::new(root.clone(), 8 << 20).unwrap();
    let chats: u64 =
        std::env::var("ACPMUX_LEDGER_BENCH_CHATS").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
    let turns = 300u64;
    let per_turn = 24u64;
    for chat in 0..chats {
        let id = format!("c{chat}");
        let mut seq = 0;
        for turn in 0..turns {
            for kind in ["queued", "user_message", "turn_started"]
                .into_iter()
                .chain(std::iter::repeat_n("tool_call_update", 20))
                .chain(["turn_result"])
            {
                seq += 1;
                let pad = if kind == "user_message" { 4096 } else { 512 };
                let msg = json!({"promptId": format!("p{turn}"), "turnId": format!("t{turn}"), "text": "x".repeat(pad)});
                let dir = if kind == "tool_call_update" { "in" } else { "mux" };
                let r = EventRecord {
                    seq,
                    at: seq,
                    dir: dir.into(),
                    kind: kind.into(),
                    msg,
                    host_seq: None,
                };
                store.append(&id, &r).unwrap();
            }
        }
        assert_eq!(seq, turns * per_turn);
    }
    store.flush().unwrap();
    let pass = |store: &LocalStore| {
        let started = std::time::Instant::now();
        let mut seen = 0u64;
        for chat in 0..chats {
            for ask in 0..4u64 {
                let prompt = format!("p{}", (chat * 7 + ask * 71) % turns);
                let turn = format!("t{}", (chat * 7 + ask * 71) % turns);
                store
                    .scan_kinds_keyed(
                        &format!("c{chat}"),
                        PROMPT_KINDS,
                        &mut |h| h.prompt_id == Some(&prompt) || h.turn_id == Some(&turn),
                        &mut |_| {
                            seen += 1;
                            true
                        },
                    )
                    .unwrap();
            }
        }
        (started.elapsed(), seen)
    };
    let (first, seen) = pass(&store);
    let mut later = Vec::new();
    for _ in 0..5 {
        later.push(pass(&store).0);
    }
    later.sort();
    println!(
        "LEDGER_BENCH chats={chats} turns={turns} scans_per_pass={} records_per_pass={seen} first_pass_ms={:.1} median_later_pass_ms={:.1}",
        chats * 4,
        first.as_secs_f64() * 1e3,
        later[later.len() / 2].as_secs_f64() * 1e3,
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Waits past the clock tick of the last folder change, then trusts folders at once
/// (`kind_heads.rs` `SETTLED`): a test's changes come milliseconds apart, a daemon's seconds.
#[cfg(unix)]
fn settle() {
    std::thread::sleep(std::time::Duration::from_millis(30));
    kind_heads::SETTLED_FOR.with(|s| s.set(Some(std::time::Duration::ZERO)));
}

/// Detector for a resend that opens every segment of its chat (cmux NEXT nightly
/// 1.0.0-nightly.4424316677601, 2026-11-18: three keyed scans a resend, each listing, opening and
/// stat-ing all of a chat's segments, held Leo's daemon at 60-130% CPU while he typed). Once a
/// chat's folders are settled, a keyed scan opens only its last segment, however many segments
/// the log has, and still sees an append, a new segment, and a sealed segment replaced by a
/// rename.
#[cfg(unix)]
#[test]
fn a_keyed_scan_of_a_settled_log_opens_its_last_segment_only() {
    let root = root();
    let (store, mut log) = store_with_log(&root, 40);
    let segments = store.segments("c").unwrap().len() as u64;
    assert!(segments >= 20, "a log of many segments ({segments})");
    settle();
    let prompts = ["p2", "p25", "p288", "p900"];
    for prompt in prompts {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt));
    }
    kind_heads::SEGMENT_OPENS.with(|n| n.set(0));
    for _ in 0..20 {
        for prompt in prompts {
            assert_eq!(keyed(&store, prompt), naming(&log, prompt));
        }
    }
    let opens = kind_heads::SEGMENT_OPENS.with(|n| n.get());
    assert_eq!(opens, 80, "80 keyed scans of a {segments}-segment log opened {opens} segments");
    // Appends, past a new segment or two: seen.
    let mut seq = log.last().unwrap().seq;
    for kind in ["queued", "user_message", "tool_call_update", "turn_result"] {
        seq += 1;
        let r = rec(seq, kind);
        store.append("c", &r).unwrap();
        log.push(r);
    }
    store.flush().unwrap();
    settle();
    for prompt in ["p2", "p961", "p962", "p964"] {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt), "{prompt} after the appends");
    }
    // A sealed segment replaced by a rename: its records are the new file's.
    let (_, first) = store.segments("c").unwrap()[0].clone();
    let text = std::fs::read_to_string(&first).unwrap();
    let gone: Vec<String> = text
        .lines()
        .filter(|l| l.contains("\"kind\":\"queued\""))
        .map(|l| {
            serde_json::from_str::<serde_json::Value>(l).unwrap()["msg"]["promptId"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    assert!(!gone.is_empty(), "the first segment holds a queued record");
    let kept: String = text
        .lines()
        .filter(|l| !l.contains("\"kind\":\"queued\""))
        .map(|l| format!("{l}\n"))
        .collect();
    let tmp = first.with_extension("rewrite");
    std::fs::write(&tmp, kept).unwrap();
    std::fs::rename(&tmp, &first).unwrap();
    log.retain(|r| !(r.kind == "queued" && gone.iter().any(|g| r.msg["promptId"] == g.as_str())));
    settle();
    for prompt in &gone {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt), "{prompt} after the rewrite");
    }
    kind_heads::SETTLED_FOR.with(|s| s.set(None));
    let _ = std::fs::remove_dir_all(&root);
}

/// A folder changed within `SETTLED` is not trusted: every segment is checked, as before.
#[test]
fn a_keyed_scan_of_a_log_just_written_checks_every_segment() {
    let root = root();
    let (store, log) = store_with_log(&root, 8);
    let segments = store.segments("c").unwrap().len() as u64;
    for prompt in ["p2", "p25"] {
        assert_eq!(keyed(&store, prompt), naming(&log, prompt));
    }
    kind_heads::SEGMENT_OPENS.with(|n| n.set(0));
    assert_eq!(keyed(&store, "p2"), naming(&log, "p2"));
    assert_eq!(kind_heads::SEGMENT_OPENS.with(|n| n.get()), segments);
    let _ = std::fs::remove_dir_all(&root);
}

/// The keyed scans a resend makes of its chat (`hub/turns.rs`: `logged_inbox_answer`, then
/// `logged_prompt_past_inbox`), with their keeps (`hub/inbox.rs`, `hub/prompt_ledger.rs`
/// `keep_prompt`, which joins by a turn or a list too; here by the prompt, its turn and a list).
/// Returns the records read whole.
#[cfg(unix)]
fn resend_reads(store: &LocalStore, id: &str, prompt: &str) -> u64 {
    const INBOX: &[&str] = &["inbox", "inbox_noticed", "inbox_answered", "inbox_removed"];
    let turn = prompt.replacen('p', "t", 1);
    let mut seen = 0u64;
    let mut count = |_: EventRecord| {
        seen += 1;
        true
    };
    let inbox =
        &mut |h: &KindHead<'_>| h.unread || h.prompt_id == Some(prompt) || h.names(|p| p == prompt);
    store.scan_kinds_keyed(id, INBOX, inbox, &mut count).unwrap();
    let state = &mut |h: &KindHead<'_>| {
        h.unread
            || h.prompt_id == Some(prompt)
            || h.turn_id == Some(&turn)
            || h.kind == "turn_stop_requested"
            || h.names(|p| p == prompt)
    };
    store.scan_kinds_keyed(id, PROMPT_KINDS, state, &mut count).unwrap();
    seen
}

/// A resend's log reads at Leo's scale, timed (one harness, before and after):
/// `ACPMUX_RESEND_BENCH=1 cargo test --release -p acpmux --lib resend_scale_bench -- --ignored
/// --nocapture`. One coordinator chat of `ACPMUX_RESEND_BENCH_TURNS` turns (default 11,000:
/// about 470,000 records in 41 segments of 8 MiB, 40,000 indexed heads, a list of prompts in one
/// head of six, as his `claude-sr2-coord` holds: 484,969 records, 41 segments, 23,349 heads,
/// 3,213 with a list) beside `ACPMUX_RESEND_BENCH_CHATS` small chats (default 10,000), each asked
/// once first (their heads held as a running daemon holds them). Times a resend's reads of the
/// coordinator ([`resend_reads`]) and their CPU, after the folders settled.
#[cfg(unix)]
#[test]
#[ignore = "a timing harness, run by hand"]
fn resend_scale_bench() {
    let root = root();
    let store = LocalStore::new(root.clone(), 8 << 20).unwrap();
    let env = |k: &str, d: u64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    let chats = env("ACPMUX_RESEND_BENCH_CHATS", 10_000);
    let turns = env("ACPMUX_RESEND_BENCH_TURNS", 11_000);
    let append = |id: &str, seq: &mut u64, turn: u64| {
        let mut kinds = vec!["queued", "user_message", "turn_started"];
        if turn.is_multiple_of(3) {
            kinds.extend(["inbox", "inbox_noticed"]);
        }
        kinds.extend(std::iter::repeat_n("tool_call_update", 38));
        kinds.push("turn_result");
        for kind in kinds {
            *seq += 1;
            let pad = match kind {
                "user_message" => 4096,
                "tool_call_update" => 640,
                _ => 200,
            };
            let msg = match kind {
                "inbox" => json!({"promptId": format!("m{turn}"), "text": "x".repeat(pad)}),
                "inbox_noticed" => {
                    json!({"promptIds": [format!("m{turn}")], "turnId": format!("t{turn}")})
                }
                _ => {
                    json!({"promptId": format!("p{turn}"), "turnId": format!("t{turn}"), "text": "x".repeat(pad)})
                }
            };
            let dir = if kind == "tool_call_update" { "in" } else { "mux" };
            let r = EventRecord {
                seq: *seq,
                at: *seq,
                dir: dir.into(),
                kind: kind.into(),
                msg,
                host_seq: None,
            };
            store.append(id, &r).unwrap();
        }
    };
    let mut seq = 0;
    for turn in 0..turns {
        append("coord", &mut seq, turn);
    }
    for chat in 0..chats {
        append(&format!("c{chat}"), &mut 0, 0);
    }
    store.flush().unwrap();
    let segments = store.segments("coord").unwrap().len();
    // First asks: every chat's heads read once (copies made), as a running daemon has them.
    resend_reads(&store, "coord", "p0");
    for chat in 0..chats {
        resend_reads(&store, &format!("c{chat}"), "p0");
    }
    // The folders settle, as a daemon's do between segments.
    std::thread::sleep(std::time::Duration::from_secs(4));
    resend_reads(&store, "coord", "p1");
    let cpu = || {
        // SAFETY: getrusage fills a zeroed struct this closure owns.
        let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
        unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
        let ms = |v: libc::timeval| v.tv_sec as f64 * 1e3 + v.tv_usec as f64 / 1e3;
        ms(usage.ru_utime) + ms(usage.ru_stime)
    };
    let calls = 500u64;
    let (started, cpu0) = (std::time::Instant::now(), cpu());
    let mut seen = 0;
    for call in 0..calls {
        seen += resend_reads(&store, "coord", &format!("p{}", (call * 7919) % turns));
    }
    let (wall, cpu_ms) = (started.elapsed().as_secs_f64() * 1e3, cpu() - cpu0);
    let small = std::time::Instant::now();
    for chat in 0..chats {
        resend_reads(&store, &format!("c{chat}"), "p0");
    }
    let small_us = small.elapsed().as_secs_f64() * 1e6 / chats.max(1) as f64;
    println!(
        "RESEND_BENCH chats={chats} coord_turns={turns} coord_segments={segments} resends={calls} \
         records_read={seen} coord_wall_ms_per_resend={:.3} coord_cpu_ms_per_resend={:.3} \
         small_chat_us_per_resend={small_us:.1}",
        wall / calls as f64,
        cpu_ms / calls as f64,
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Bytes this thread has read (Linux `rchar`): other tests' reads are not counted.
fn thread_read_bytes() -> u64 {
    std::fs::read_to_string("/proc/thread-self/io")
        .ok()
        .and_then(|io| {
            io.lines().find(|l| l.starts_with("rchar:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

/// A chat that ran on after its log load has segments with no copy: a page of its last 16 prompts
/// (every open and attach asks for one) read each of them whole, back from its end, every time
/// (cmuxterm-hq#13733: 26 MB per page of a busy chat). The first indexed read back makes their
/// copies by the lines' heads, parsing none; the next reads the copies.
#[test]
fn an_indexed_read_back_makes_the_copies_a_chat_that_ran_on_lacks() {
    if !cfg!(target_os = "linux") {
        return; // A thread's reads are counted on Linux only.
    }
    let root = root();
    let store = LocalStore::new(root.clone(), 2 << 20).unwrap();
    let mut seq = 0;
    // 40 turns of 200 updates each: 16 prompts span most of a 16 MB log.
    for _ in 0..40 {
        for kind in ["user_message"].into_iter().chain(std::iter::repeat_n("tool_call_update", 200))
        {
            seq += 1;
            store.append("c", &rec(seq, kind)).unwrap();
        }
    }
    store.flush().unwrap();
    let segments = store.segments("c").unwrap();
    assert!(segments.len() >= 4, "{} segments", segments.len());
    // The appends copied each segment they filled (`store/segment_writer.rs`); a chat written
    // before that has none.
    std::fs::remove_dir_all(root.join("c").join(DIR)).unwrap();
    let log_bytes: u64 = segments.iter().map(|(_, p)| std::fs::metadata(p).unwrap().len()).sum();

    let page = |store: &LocalStore| {
        let mut prompts = Vec::new();
        store
            .scan_back_indexed("c", 0, u64::MAX, &|_, kind| kind != b"user_message", &mut |r| {
                if r.kind == "user_message" {
                    prompts.push(r.seq);
                }
                prompts.len() < 16
            })
            .unwrap();
        prompts
    };
    // Fewer than 16 prompts past the newest segment's start: the page reads into older segments.
    let first = page(&store);
    assert_eq!(first.len(), 16);
    let before = thread_read_bytes();
    let parsed_before = PARSED_LINES.with(std::cell::Cell::get);
    let again = page(&store);
    let read = thread_read_bytes() - before;
    assert_eq!(again, first);
    assert!(read * 10 < log_bytes, "the second page read {read} bytes of a {log_bytes}-byte log");
    assert!(
        PARSED_LINES.with(std::cell::Cell::get) - parsed_before <= 64,
        "the page parses its own records, not the log's"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Bytes this thread has read (Linux `rchar`): other tests' reads are not counted.
fn read_bytes() -> u64 {
    std::fs::read_to_string("/proc/thread-self/io")
        .ok()
        .and_then(|io| {
            io.lines().find(|l| l.starts_with("rchar:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

/// A scan for the indexed kinds past `after` (a restore point's seq, `hub/restore_point.rs`)
/// reads the copies of the segments from the one that holds `after + 1` on, not every copy: each
/// fold of a restored chat's log load (its transfer authority, its open turn, its queue, its
/// message copies) read every segment's copy from the log's first, so a load from a restore point
/// still cost the chat's whole history in opens and copies (infinite chats, Leo 2026-11-19).
#[test]
fn a_kind_scan_past_a_seq_reads_only_the_copies_past_it() {
    if !cfg!(target_os = "linux") {
        return; // A thread's reads are counted on Linux only.
    }
    let root = root();
    let (store, log) = store_with_log(&root, 200);
    let kinds = ["queued", "turn_started", "turn_result"];
    // The copies, as a log load makes them.
    let all = scanned(&store, &kinds);
    let segments = store.segments("c").unwrap().len();
    assert!(segments > 40, "{segments} segments");
    let whole = read_bytes();
    assert_eq!(scanned(&store, &kinds), all);
    let whole = read_bytes() - whole;
    let after = log[log.len() - 48].seq;
    let expected: Vec<EventRecord> = all.iter().filter(|r| r.seq > after).cloned().collect();
    for strict in [false, true] {
        let mut got = Vec::new();
        let tail = read_bytes();
        let mut visit = |r: EventRecord| {
            got.push(r);
            true
        };
        if strict {
            store.scan_kinds_after_strict("c", after, &kinds, &mut visit).unwrap();
        } else {
            store.scan_kinds_after("c", after, &kinds, &mut visit).unwrap();
        }
        let tail = read_bytes() - tail;
        eprintln!(
            "kind scan past {after} (strict {strict}): read {tail} bytes; whole scan {whole}"
        );
        assert_eq!(got, expected, "strict: {strict}");
        assert!(
            tail * 10 < whole,
            "strict {strict}: past {after} read {tail} bytes, the whole {whole}"
        );
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// A scan past `after` (a log load past its restore point) reads no segment before the one that
/// holds `after + 1`, neither its copy nor its bytes: a strict one past a damaged first segment
/// reads, where one of the whole log fails, and both return exactly the records past `after`
/// (goal infinite-chats: a 514 MB chat's restart read every segment's copy from the start).
#[test]
fn a_scan_past_a_seq_reads_no_segment_before_it() {
    let root = root();
    let (store, log) = store_with_log(&root, 12);
    let segments = store.segments("c").unwrap();
    assert!(segments.len() > 4, "the log spans many segments: {}", segments.len());
    let (_, first) = segments[0].clone();
    // The first record of the third segment: everything before it is at or before `after`.
    let third = crate::store::log_line::first_seq(&segments[2].1).unwrap().unwrap();
    let after = third - 1;
    let mut file = std::fs::OpenOptions::new().append(true).open(&first).unwrap();
    file.write_all(b"{\"seq\": not json}\n").unwrap();
    drop(file);
    let kinds = ["queued", "turn_result"];
    let past: Vec<EventRecord> =
        log.iter().filter(|r| r.seq > after && kinds.contains(&r.kind.as_str())).cloned().collect();
    let read_past = |strict: bool| {
        let mut out = Vec::new();
        let mut visit = |r: EventRecord| {
            out.push(r);
            true
        };
        let result = if strict {
            store.scan_kinds_after_strict("c", after, &kinds, &mut visit)
        } else {
            store.scan_kinds_after("c", after, &kinds, &mut visit)
        };
        result.map(|()| out)
    };
    assert!(
        store.scan_kinds_after_strict("c", 0, &kinds, &mut |_| true).is_err(),
        "a strict scan of the whole log reads the damaged first segment"
    );
    assert_eq!(read_past(true).unwrap(), past, "strict, past the damaged segment");
    assert_eq!(read_past(false).unwrap(), past, "lenient");
    assert_eq!(read_past(true).unwrap(), past, "strict again, from the copies");
    let _ = std::fs::remove_dir_all(&root);
}

/// A segment copied to another file (a staged prefix moved across file systems) takes the copy
/// its source had, carried (`carry_copy`): a scan of the copied segment reads that copy, not the
/// segment, and a copy carried onto a file with other bytes than it covers is not taken.
#[test]
fn a_copy_carried_to_a_copied_segment_is_read_and_one_of_other_bytes_is_not() {
    let (from_root, to_root) = (root(), root());
    let (store, log) = store_with_log(&from_root, 12);
    let kinds = ["queued", "turn_started", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    assert_eq!(scanned(&store, &kinds), expected);
    let to = LocalStore::new(to_root.clone(), 4096).unwrap();
    let (events, copies) =
        (to_root.join("c").join("events"), to_root.join("c").join(kind_index::DIR));
    crate::config::private_state_dir(&events).unwrap();
    crate::config::private_state_dir(&copies).unwrap();
    for (index, path) in store.segments("c").unwrap() {
        let name = format!("{index:06}.ndjson");
        std::fs::copy(&path, events.join(&name)).unwrap();
        let carried = carry_copy(
            &from_root.join("c").join(kind_index::DIR).join(&name),
            &events.join(&name),
            &copies.join(&name),
        )
        .unwrap();
        assert!(carried, "segment {index}");
        // Only the copy holds the records now: the copied segment's bytes are blanked.
        let len = std::fs::metadata(events.join(&name)).unwrap().len();
        std::fs::OpenOptions::new()
            .write(true)
            .open(events.join(&name))
            .unwrap()
            .write_all(" ".repeat(len as usize).as_bytes())
            .unwrap();
    }
    assert_eq!(scanned(&to, &kinds), expected, "the carried copies hold every record");
    // Carried onto a shorter file than it covers: not taken.
    let (first, _) = store.segments("c").unwrap()[0].clone();
    let name = format!("{first:06}.ndjson");
    std::fs::write(events.join(&name), b"").unwrap();
    let short = carry_copy(
        &from_root.join("c").join(kind_index::DIR).join(&name),
        &events.join(&name),
        &copies.join(&name),
    )
    .unwrap();
    assert!(!short, "a copy of more bytes than the file holds is not carried");
    let _ = std::fs::remove_dir_all(&from_root);
    let _ = std::fs::remove_dir_all(&to_root);
}

/// A chat written but never scanned (a new or seeded chat, one moved in) has a copy of every
/// segment its appends filled, made at the rotation (`store/segment_writer.rs`), each saying all
/// its lines read: its first strict scan, a first start's transfer authority, reads the copies
/// and the open segment, not the history (a seeded 1 GB chat read 1.18 GB at its first start).
#[test]
fn a_chat_never_scanned_has_a_copy_of_every_filled_segment() {
    let root = root();
    let (store, log) = store_with_log(&root, 40);
    let segments = store.segments("c").unwrap();
    assert!(segments.len() > 8, "{} segments", segments.len());
    let (open, filled) = segments.split_last().unwrap();
    for (index, path) in filled {
        let stamp = kind_index::Stamp::of(&std::fs::File::open(path).unwrap()).unwrap();
        if stamp.id.2 == 0 {
            return; // No birth time on this file system: no copies kept.
        }
        let (_, len, parsed) = store.read_kind_index("c", *index, &stamp).expect("a copy");
        assert_eq!(len, stamp.len, "segment {index}: the copy covers it whole");
        assert!(parsed, "segment {index}: the copy says every line read");
    }
    assert!(!root.join("c").join(DIR).join(format!("{:06}.ndjson", open.0)).exists());
    let kinds = ["queued", "turn_result"];
    let expected: Vec<EventRecord> =
        log.iter().filter(|r| kinds.contains(&r.kind.as_str())).cloned().collect();
    let log_bytes: u64 = segments.iter().map(|(_, p)| std::fs::metadata(p).unwrap().len()).sum();
    let before = read_bytes();
    let mut got = Vec::new();
    store
        .scan_kinds_strict("c", &kinds, &mut |r| {
            got.push(r);
            true
        })
        .unwrap();
    let read = read_bytes() - before;
    assert_eq!(got, expected);
    if cfg!(target_os = "linux") {
        assert!(read * 2 < log_bytes, "the first strict scan read {read} of {log_bytes} bytes");
    }
    let _ = std::fs::remove_dir_all(&root);
}
