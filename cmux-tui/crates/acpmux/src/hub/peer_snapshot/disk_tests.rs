//! `disk.rs`: what a scan reads back (a cut line, a leftover temporary file, a session without
//! its `meta.json`, a symlink), and segment writes that add nothing twice and stay in bound.

use super::*;
use serde_json::json;

fn rec(seq: u64) -> Value {
    json!({"sessionId": "m1", "seq": seq, "kind": "agent_message_chunk", "msg": {"text": format!("line {seq}")}})
}

fn line(seq: u64) -> String {
    format!("{}\n", rec(seq))
}

fn names(dir: &Path) -> Vec<String> {
    let names = std::fs::read_dir(dir).into_iter().flatten().flatten();
    let names: BTreeSet<String> = names.filter_map(|e| e.file_name().into_string().ok()).collect();
    names.into_iter().collect()
}

#[test]
fn a_scan_skips_a_cut_line_a_temporary_file_and_a_session_without_its_meta() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pd");
    let session = dir.path().join("huge-blue/m1");
    std::fs::create_dir_all(&session).unwrap();
    let body = format!("{}{}{{\"seq\": 3, \"kind\": \"cut", line(1), line(2));
    std::fs::write(session.join("seg-0.ndjson"), body).unwrap();
    std::fs::write(session.join("seg-1.tmp-99-0"), "{\"seq\": 4").unwrap();
    std::fs::write(session.join("meta.json"), r#"{"generation": 7, "lastSeq": 2}"#).unwrap();
    let orphan = dir.path().join("huge-blue/m9");
    std::fs::create_dir_all(&orphan).unwrap();
    std::fs::write(orphan.join("seg-0.ndjson"), line(1)).unwrap();

    let (kept, stray) = scan(dir.path());
    assert_eq!(stray, [orphan], "no meta.json: not a copy");
    let [(key, mut k)] = <[_; 1]>::try_from(kept).unwrap();
    assert_eq!((key.0.as_str(), key.1.as_str(), k.meta.generation), ("huge-blue", "m1", Some(7)));
    assert_eq!(names(&session), ["meta.json", "seg-0.ndjson"], "the temporary file went");
    load(&mut k.segments).unwrap();
    let seg = &k.segments[0];
    assert_eq!((seg.seqs.iter().copied().collect::<Vec<_>>(), seg.sealed), (vec![1, 2], true));
    // Nothing is written after a cut line: the next record opens a new segment.
    assert_eq!(open_segment(&k.segments, &session, 10).n, 1);
}

#[cfg(unix)]
#[test]
fn a_scan_follows_no_symlink() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pd");
    let outside = dir.path().join("elsewhere");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("meta.json"), r#"{"lastSeq": 1}"#).unwrap();
    std::fs::write(outside.join("seg-0.ndjson"), line(1)).unwrap();
    let peer = dir.path().join("huge-blue");
    std::fs::create_dir_all(&peer).unwrap();
    std::os::unix::fs::symlink(&outside, peer.join("m1")).unwrap();
    let real = peer.join("m2");
    std::fs::create_dir_all(&real).unwrap();
    std::fs::write(real.join("meta.json"), "{}").unwrap();
    std::os::unix::fs::symlink(outside.join("seg-0.ndjson"), real.join("seg-0.ndjson")).unwrap();
    std::os::unix::fs::symlink(outside.join("meta.json"), dir.path().join("x.json")).unwrap();

    let (kept, stray) = scan(dir.path());
    let keys: Vec<_> = kept.iter().map(|(k, _)| k.1.clone()).collect();
    assert!(!keys.contains(&"m1".to_owned()), "{keys:?}");
    assert!(stray.contains(&real), "a segment through a symlink is not one: {stray:?}");
    assert!(outside.join("meta.json").exists());
}

#[test]
fn a_segment_write_adds_each_seq_once_and_a_record_that_does_not_fit_opens_the_next() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pd");
    let session = dir.path().join("huge-blue/m1");
    let seg = open_segment(&[], &session, 10);
    let write = crate::config::write_atomic;
    let (bytes, seqs) = write_segment(write, &session, &seg, &[rec(1), rec(2)]).unwrap();
    let seg = Segment { bytes, seqs, ..seg };
    // A retry with records the segment already holds (its meta.json failed) adds only the new one.
    let (bytes, seqs) = write_segment(write, &session, &seg, &[rec(2), rec(3)]).unwrap();
    let text = std::fs::read_to_string(&seg.path).unwrap();
    assert_eq!(text, format!("{}{}{}", line(1), line(2), line(3)));
    assert_eq!((bytes, seqs.len()), (text.len() as u64, 3));
    let seg = Segment { bytes, seqs, ..seg };

    let big = json!({"seq": 4, "msg": "x".repeat(SEGMENT_BYTES as usize - 40)});
    let next = open_segment(std::slice::from_ref(&seg), &session, record_bytes(&big));
    assert_eq!(next.n, 1, "the open segment has no room for it");
    let records = [big, rec(5)];
    let batch = batch(&next, records.iter());
    assert_eq!(batch.len(), 1, "what does not fit waits for the next segment");
    let (bytes, _) = write_segment(write, &session, &next, &batch).unwrap();
    assert!(bytes <= SEGMENT_BYTES, "{bytes}");
}

#[test]
fn a_removal_takes_meta_json_first_and_a_scan_bounds_a_session() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pd");
    let session = dir.path().join("huge-blue/m1");
    std::fs::create_dir_all(&session).unwrap();
    std::fs::write(session.join("meta.json"), "{}").unwrap();
    // More segments than a session ever holds: not a copy this daemon left.
    for n in 0..9 {
        std::fs::write(session.join(format!("seg-{n}.ndjson")), line(n + 1)).unwrap();
    }
    let (kept, stray) = scan(dir.path());
    assert!(kept.is_empty());
    assert_eq!(stray, std::slice::from_ref(&session));
    remove(&dir.path().join("huge-blue")).unwrap();
    assert!(!dir.path().join("huge-blue").exists());
    remove(&dir.path().join("huge-blue")).unwrap();
}
