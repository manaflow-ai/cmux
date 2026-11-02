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
