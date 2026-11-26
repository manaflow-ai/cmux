//! A chat whose segments a tool outside acpmux zstd'd in place lists and reads again
//! (cmuxterm-hq docs/findings/2026-11-23-acpmux-orphan-zst-chats.md).

use super::*;
use serde_json::json;

fn meta(id: &str, status: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": id,
        "name": "chat",
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": status,
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("a test meta: {e}"))
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        // Past the 64 KiB segment size: one record per segment.
        msg: json!({"text": format!("{seq}:{}", "x".repeat(70_000))}),
        host_seq: None,
    }
}

/// A closed chat with `records` records, its store dropped; the segment files, oldest first.
fn closed_chat(root: &Path, id: &str, records: u64) -> Vec<PathBuf> {
    let store = LocalStore::new(root.to_path_buf(), 64 << 10).unwrap();
    store.save(&meta(id, "closed")).unwrap();
    for seq in 1..=records {
        store.append(id, &record(seq)).unwrap();
    }
    store.close_log(id);
    let mut segments: Vec<PathBuf> = std::fs::read_dir(root.join(id).join("events"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "ndjson"))
        .collect();
    segments.sort();
    assert_eq!(segments.len() as u64, records, "one record per segment: {segments:?}");
    segments
}

/// What `zstd --rm FILE` does: `FILE.zst` beside it, then `FILE` removed.
fn zstd_in_place(path: &Path) {
    let input = std::fs::File::open(path).unwrap();
    let mut out = path.as_os_str().to_owned();
    out.push(".zst");
    let output = std::fs::File::create(PathBuf::from(out)).unwrap();
    // As the build that most likely wrote them did: level 9, long-distance matching, a 2^27 window.
    let mut encoder = zstd::stream::write::Encoder::new(output, 9).unwrap();
    encoder.long_distance_matching(true).unwrap();
    encoder.window_log(27).unwrap();
    std::io::copy(&mut std::io::BufReader::new(input), &mut encoder).unwrap();
    encoder.finish().unwrap();
    std::fs::remove_file(path).unwrap();
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn seqs(store: &LocalStore, id: &str) -> Vec<u64> {
    store.events(id, 0, 1000).unwrap().into_iter().map(|r| r.seq).collect()
}

#[test]
fn a_closed_chat_with_every_segment_zstd_in_place_lists_and_reads_again() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let segments = closed_chat(&root, "sealed", 3);
    let before = names(&root.join("sealed").join("events"));
    for segment in &segments {
        zstd_in_place(segment);
    }

    let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
    let ids: Vec<String> = store.list().unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["sealed"], "a closed chat with sealed segments read as purged");
    assert_eq!(seqs(&store, "sealed"), [1, 2, 3]);
    assert_eq!(
        names(&root.join("sealed").join("events")),
        before,
        "the first read decodes each sealed segment back to its own name and removes the copy"
    );
    // It goes on where it left off: no new `000001.ndjson` beside a sealed one.
    store.append("sealed", &record(4)).unwrap();
    assert_eq!(seqs(&store, "sealed"), [1, 2, 3, 4]);
}

#[test]
fn an_append_to_a_sealed_chat_decodes_it_first() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    for segment in closed_chat(&root, "sealed", 2) {
        zstd_in_place(&segment);
    }
    let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
    // No read first: the append's own listing finds the sealed segments.
    store.append("sealed", &record(3)).unwrap();
    assert_eq!(seqs(&store, "sealed"), [1, 2, 3]);
    assert!(names(&root.join("sealed").join("events")).iter().all(|n| !n.ends_with(".zst")));
}

#[test]
fn a_plain_segment_wins_and_an_unreadable_sealed_one_is_kept_aside() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("sessions");
    let segments = closed_chat(&root, "mixed", 3);
    let events = root.join("mixed").join("events");
    // The oldest is sealed, the middle is a sealed copy cut short, the newest stays plain.
    zstd_in_place(&segments[0]);
    let middle = segments[1].clone();
    zstd_in_place(&middle);
    let mut cut = middle.as_os_str().to_owned();
    cut.push(".zst");
    let cut = PathBuf::from(cut);
    let len = std::fs::metadata(&cut).unwrap().len();
    std::fs::OpenOptions::new().write(true).open(&cut).unwrap().set_len(len / 2).unwrap();
    // A sealed copy beside its plain segment (a crash in the middle of `zstd --rm`): left be.
    let newest = segments[2].clone();
    let mut copy = newest.as_os_str().to_owned();
    copy.push(".zst");
    std::fs::copy(&newest, PathBuf::from(&copy)).unwrap();

    let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
    assert_eq!(store.list().unwrap().len(), 1);
    assert_eq!(seqs(&store, "mixed"), [1, 3], "the chat reads with the segments that decode");
    let left = names(&events);
    let stem = |p: &Path| p.file_name().unwrap().to_string_lossy().replace(".ndjson", "");
    assert!(left.contains(&format!("{}.ndjson.zst.unreadable", stem(&middle))), "{left:?}");
    assert!(left.contains(&copy.to_string_lossy().rsplit('/').next().unwrap().to_owned()));
    // Nothing is tried again on the next read.
    assert_eq!(seqs(&store, "mixed"), [1, 3]);
}

#[test]
fn the_sealed_name_is_a_numbered_segment_only() {
    assert_eq!(plain_name("000003.ndjson.zst"), Some("000003.ndjson"));
    assert_eq!(plain_name("cold.zst"), None);
    assert_eq!(plain_name("x.ndjson.zst"), None);
    assert_eq!(plain_name(".ndjson.zst"), None);
    assert_eq!(plain_name("000003.ndjson"), None);
}
