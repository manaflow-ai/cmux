//! A pack reads back every byte, an appended log repacks to the same chunks as a fresh pack, and
//! a move to a store with an older copy ships only what was sealed since.

use cmux_session_pack::{
    Manifest, Pack, Params, RangeId, SegmentCheck, Store, pack, pack_after, pack_kept, ship,
};
use std::collections::HashSet;
use std::fmt::Write as _;

fn log(lines: usize) -> Vec<u8> {
    let mut out = String::new();
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    let mut rnd = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let png = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        (0..3000).map(|i| (i * 7 % 251) as u8).collect::<Vec<u8>>(),
    );
    for i in 0..lines {
        let text: String =
            (0..(rnd() % 900)).map(|_| char::from(b'a' + (rnd() % 26) as u8)).collect();
        match i % 9 {
            0 => writeln!(out, "{{\"seq\":{i},\"at\":{},\"dir\":\"mux\",\"kind\":\"turn_started\",\"msg\":{{}}}}", 1_795_000_000_000 + i as u64 * 37),
            1 | 2 => writeln!(out, "{{\"seq\":{i},\"at\":{},\"dir\":\"in\",\"kind\":\"tool_call_update\",\"msg\":{{\"out\":\"{text}\",\"again\":\"{text}\"}}}}", 1_795_000_000_000 + i as u64 * 37),
            3 => writeln!(out, "{{\"seq\":{i},\"at\":5,\"dir\":\"in\",\"kind\":\"claude.user\",\"img\":\"{png}\",\"esc\":\"a\\\"b{text}\"}}"),
            4 => writeln!(out, "not json at all \u{1} with a control byte \u{1}\u{1} and \"an open quote {text}"),
            5 => writeln!(out, "{{\"seq\":007,\"at\":1,\"dir\":\"in\",\"kind\":\"odd\",\"t\":\"{text}\"}}"),
            6 => writeln!(out),
            _ => writeln!(out, "{{\"type\":\"assistant\",\"message\":{{\"content\":\"{text}\"}},\"uuid\":\"{:x}\"}}", rnd()),
        }
        .unwrap();
    }
    out.into_bytes()
}

fn params() -> Params {
    Params { segment_bytes: 64 << 10, level: 3, ..Params::default() }
}

#[test]
fn every_byte_reads_back_and_ranges_match() {
    let dir = tempfile::tempdir().unwrap();
    let mut bytes = log(2000);
    bytes.extend_from_slice(b"{\"seq\":9999,\"at\":1,\"dir\":\"in\",\"kind\":\"torn\",\"half");
    let file = dir.path().join("log.ndjson");
    std::fs::write(&file, &bytes).unwrap();
    let store = Store::new(dir.path().join("store"));
    let (m, stats) = pack(&store, "s1", &[file], &params(), false).unwrap();
    assert!(m.segments.len() > 5, "{} segments", m.segments.len());
    assert!(!m.final_newline);
    assert!(stats.stored_bytes * 2 < stats.raw_bytes, "{stats:?}");

    let p = Pack::open(&store, "s1").unwrap();
    let mut back = Vec::new();
    p.cat(&mut back).unwrap();
    assert!(back == bytes, "the log does not read back");

    let lines: Vec<&[u8]> = bytes.split(|b| *b == b'\n').collect();
    assert_eq!(m.lines as usize, lines.len());
    for (a, b) in [(0u64, 1u64), (17, 400), (1990, 2001), (700, 701)] {
        let got = p.read_lines(a..b).unwrap();
        assert_eq!(got.len() as u64, b - a);
        for (i, l) in got.iter().enumerate() {
            assert!(l == lines[a as usize + i], "line {}", a as usize + i);
        }
        let mut text = Vec::new();
        p.write_range(a..b, &mut text).unwrap();
        let mut want = lines[a as usize..b as usize].join(&b'\n');
        // The log's last line is torn: no newline ends it.
        if (b as usize) < lines.len() {
            want.push(b'\n');
        }
        assert!(text == want, "write_range {a}..{b}");
    }
    let (line, rec) = p.by_seq(901).unwrap().unwrap();
    assert_eq!(line, 901);
    assert!(rec == lines[901]);
    assert_eq!(m.marks().count(), 2000usize.div_ceil(9));
    let r = RangeId::parse("s1@18-26").unwrap();
    assert_eq!(r.to_string(), "s1@18-26");
    assert_eq!(m.tail_turns(2), 1989);
}

#[test]
fn an_appended_log_repacks_to_the_same_chunks_and_ships_only_the_new_ones() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = log(6000);
    let cut = bytes[..bytes.len() * 9 / 10].iter().rposition(|b| *b == b'\n').unwrap() + 1;
    let (old, whole) = (dir.path().join("old.ndjson"), dir.path().join("whole.ndjson"));
    std::fs::write(&old, &bytes[..cut]).unwrap();
    std::fs::write(&whole, &bytes).unwrap();

    // Here: packed at 90%, then again once the log grew.
    let here = Store::new(dir.path().join("here"));
    pack(&here, "s", std::slice::from_ref(&old), &params(), false).unwrap();
    let (grown, stats) = pack(&here, "s", std::slice::from_ref(&whole), &params(), false).unwrap();
    assert!(stats.kept_segments > 0 && stats.encoded_bytes < stats.raw_bytes / 4, "{stats:?}");
    // The same as packing the whole log at once.
    let fresh = Store::new(dir.path().join("fresh"));
    let (full, _) = pack(&fresh, "s", &[whole], &params(), false).unwrap();
    assert_eq!(grown, full);

    // There: holds the 90% copy.
    let there = Store::new(dir.path().join("there"));
    pack(&there, "s", &[old], &params(), false).unwrap();
    let have: HashSet<_> = there.ids().unwrap().into_iter().collect();
    let mut bundle = Vec::new();
    let shipped = ship::bundle(&here, "s", &have, &mut bundle).unwrap();
    assert!(shipped.chunks < shipped.session_chunks / 4, "{shipped:?}");
    assert!(shipped.bytes < shipped.session_bytes / 4, "{shipped:?}");

    // A damaged bundle changes nothing; the whole one brings the session over.
    let mut bad = bundle.clone();
    let last = bad.len() - 1;
    bad[last] ^= 1;
    assert!(ship::unbundle(&there, &mut &bad[..], ship::Lacking::Refuse).is_err());
    assert_ne!(Manifest::load(&there, "s").unwrap().unwrap(), grown);
    assert_eq!(
        ship::unbundle(&there, &mut &bundle[..], ship::Lacking::Refuse).unwrap(),
        Some(grown)
    );
    let mut back = Vec::new();
    Pack::open(&there, "s").unwrap().cat(&mut back).unwrap();
    assert!(back == bytes);
}

#[test]
fn a_rewritten_log_is_packed_from_the_start() {
    let dir = tempfile::tempdir().unwrap();
    let mut bytes = log(3000);
    let file = dir.path().join("log.ndjson");
    std::fs::write(&file, &bytes).unwrap();
    let store = Store::new(dir.path().join("store"));
    pack(&store, "s", std::slice::from_ref(&file), &params(), false).unwrap();
    bytes[10] = b'9';
    std::fs::write(&file, &bytes).unwrap();
    let (_, stats) = pack(&store, "s", &[file], &params(), false).unwrap();
    assert_eq!(stats.kept_segments, 0);
    let mut back = Vec::new();
    Pack::open(&store, "s").unwrap().cat(&mut back).unwrap();
    assert!(back == bytes);
}

#[test]
fn a_turn_comes_back_as_text_that_names_what_it_cut() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().join("store"));
    let long = "x".repeat(5000);
    let lines = [
        r#"{"seq":1,"at":10,"dir":"mux","kind":"turn_started","msg":{"promptLine":"fix the build"}}"#.to_string(),
        r#"{"seq":2,"at":11,"dir":"mux","kind":"user_message","msg":{"text":"fix the build"}}"#.to_string(),
        r#"{"seq":3,"at":12,"dir":"in","kind":"tool_call","msg":{"params":{"update":{"_meta":{"claude":{"tool":"Bash"}},"rawInput":{"command":"make"},"status":"in_progress","toolCallId":"t1"}}}}"#.to_string(),
        format!(r#"{{"seq":4,"at":13,"dir":"in","kind":"tool_call_update","msg":{{"params":{{"update":{{"content":[{{"content":{{"text":"{long}","type":"text"}},"type":"content"}}],"status":"completed","toolCallId":"t1"}}}}}}}}"#),
        r#"{"seq":5,"at":14,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"It builds."}}}}}"#.to_string(),
        r#"{"seq":6,"at":15,"dir":"mux","kind":"turn_started","msg":{"promptLine":"now ship it"}}"#.to_string(),
    ];
    let log = dir.path().join("log.ndjson");
    std::fs::write(&log, lines.join("\n") + "\n").unwrap();
    pack(&store, "s", &[log], &Params::default(), false).unwrap();
    let p = Pack::open(&store, "s").unwrap();

    let outline = cmux_session_pack::digest::outline(&p).unwrap();
    let rows: Vec<&str> = outline.lines().collect();
    assert_eq!(rows, ["s@0-4\t10\t5\tfix the build", "s@5-5\t15\t1\tnow ship it"]);

    let range = RangeId::parse("s@0-4").unwrap();
    let text = cmux_session_pack::digest::digest(&p, &range, Default::default()).unwrap();
    assert!(text.contains("user (seq 2): fix the build"), "{text}");
    assert!(text.contains(r#"tool Bash (seq 3): {"command":"make"}"#), "{text}");
    assert!(text.contains("result (completed, 5000 bytes): xxx"), "{text}");
    assert!(text.contains("[4400 more bytes: session-pack seq s 4]"), "{text}");
    assert!(text.contains("assistant: It builds."), "{text}");
    assert!(text.len() < 1500, "{}", text.len());
    // The whole result is one read away, by the name the text gave.
    let (line, whole) = p.by_seq(4).unwrap().unwrap();
    assert_eq!((line, whole.as_slice()), (3, lines[3].as_bytes()));
}

#[test]
fn a_session_starts_elsewhere_from_its_tail_and_fetches_older_lines_when_read() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = log(6000);
    let file = dir.path().join("log.ndjson");
    std::fs::write(&file, &bytes).unwrap();
    let here = Store::new(dir.path().join("here"));
    let (m, _) = pack(&here, "s", &[file], &params(), false).unwrap();
    let lines: Vec<&[u8]> = bytes.split(|b| *b == b'\n').collect();

    // The move carries the manifest and what the last 300 lines read: a small part of the pack.
    let tail = m.lines - 300..m.lines;
    let mut bundle = Vec::new();
    let shipped =
        ship::bundle_range(&here, "s", tail.clone(), &HashSet::new(), &mut bundle).unwrap();
    assert!(shipped.bytes < shipped.session_bytes / 4, "{shipped:?}");

    // A whole move refuses it; a move that starts from the tail takes it and reads the tail.
    let there = Store::new(dir.path().join("there"));
    assert!(ship::unbundle(&there, &mut &bundle[..], ship::Lacking::Refuse).is_err());
    assert_eq!(ship::unbundle(&there, &mut &bundle[..], ship::Lacking::Allow).unwrap(), Some(m));
    let p = Pack::open(&there, "s").unwrap();
    assert!(p.lacking(tail.clone()).unwrap().is_empty());
    let got = p.read_lines(tail.clone()).unwrap();
    assert!(
        got.iter()
            .map(Vec::as_slice)
            .eq(lines[tail.start as usize..tail.end as usize].iter().copied())
    );

    // An older range names the chunks it lacks; they arrive without a manifest, and it reads.
    let old = 100..400u64;
    let err = p.read_lines(old.clone()).unwrap_err().to_string();
    assert!(err.starts_with(cmux_session_pack::MISSING), "{err}");
    let mut rounds = 0;
    loop {
        let ids = p.lacking(old.clone()).unwrap();
        if ids.is_empty() {
            break;
        }
        rounds += 1;
        let mut chunks = Vec::new();
        ship::bundle_chunks(&here, "s", &ids, &mut chunks).unwrap();
        assert_eq!(ship::unbundle(&there, &mut &chunks[..], ship::Lacking::Allow).unwrap(), None);
    }
    assert!((1..=2).contains(&rounds), "{rounds} rounds");
    let got = p.read_lines(old.clone()).unwrap();
    assert!(
        got.iter()
            .map(Vec::as_slice)
            .eq(lines[old.start as usize..old.end as usize].iter().copied())
    );
    // Most of the log is still only on the first side.
    assert!(!ship::want(&there, &p.manifest).unwrap().is_empty());

    // A chunk of another session is not handed out under this one's name.
    assert!(ship::bundle_chunks(&here, "s", &[[7u8; 32]], &mut Vec::new()).is_err());
}

/// A pack extended from its last sealed segment with only the lines after it (what acpmux does
/// as a log grows) is the pack a whole pack of the log makes: the same manifest, the same chunks,
/// every byte back. Where the sealed segments do not end at the line given it packs nothing.
#[test]
fn a_pack_extended_from_its_sealed_end_is_the_whole_pack() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = log(3000);
    let cut = bytes.len() / 3;
    let cut = cut + bytes[cut..].iter().position(|b| *b == b'\n').unwrap() + 1;
    let head = dir.path().join("head.ndjson");
    std::fs::write(&head, &bytes[..cut]).unwrap();
    let grown = Store::new(dir.path().join("grown"));
    let (first, _) = pack(&grown, "s", &[head], &params(), false).unwrap();
    let sealed = first.segments.iter().rfind(|s| s.sealed).unwrap();
    let (after, sealed_raw) = (
        sealed.line + sealed.lines,
        first.segments.iter().filter(|s| s.sealed).map(|s| s.raw).sum::<u64>() as usize,
    );
    let tail = dir.path().join("tail.ndjson");
    std::fs::write(&tail, &bytes[sealed_raw..]).unwrap();
    assert!(
        pack_after(&grown, "s", after + 1, std::slice::from_ref(&tail), &params())
            .unwrap()
            .is_none(),
        "a line past the sealed end packs nothing"
    );
    let (m, stats) = pack_after(&grown, "s", after, &[tail], &params()).unwrap().unwrap();
    assert_eq!(stats.encoded_bytes as usize, bytes.len() - sealed_raw, "{stats:?}");

    let whole = dir.path().join("whole.ndjson");
    std::fs::write(&whole, &bytes).unwrap();
    let fresh = Store::new(dir.path().join("fresh"));
    let (want, _) = pack(&fresh, "s", &[whole], &params(), true).unwrap();
    assert_eq!(m, want, "the extended pack is the whole pack");
    let mut back = Vec::new();
    Pack::open(&grown, "s").unwrap().cat(&mut back).unwrap();
    assert!(back == bytes, "the extended pack does not read back");
}

/// A pack that keeps its first sealed segments and encodes only the lines after them (what
/// acpmux does at a compaction's outline or an export, from records, never writing the whole
/// log) is the pack a whole pack of the log makes, also through a line before the pack's sealed
/// end (it is cut back there, as a whole pack cuts it). The segments are checked as the lines
/// stream by, nothing written: a log whose bytes changed in a segment keeps the ones before it.
#[test]
fn a_pack_that_keeps_its_first_segments_is_the_whole_pack() {
    use std::io::Write as _;
    let dir = tempfile::tempdir().unwrap();
    let bytes = log(3000);
    let whole = dir.path().join("whole.ndjson");
    std::fs::write(&whole, &bytes).unwrap();
    let grown = Store::new(dir.path().join("grown"));
    let (full, _) = pack(&grown, "s", std::slice::from_ref(&whole), &params(), false).unwrap();
    let sealed: Vec<_> = full.segments.iter().filter(|s| s.sealed).collect();
    assert!(sealed.len() > 6, "{} sealed", sealed.len());

    // Every sealed segment checks against the log as it streams by, in odd-sized writes.
    let mut check = SegmentCheck::new(&sealed);
    for piece in bytes.chunks(777) {
        if check.write_all(piece).is_err() {
            break;
        }
    }
    assert_eq!(check.matched(), sealed.len());
    // A byte changed in the fourth segment: three are kept, and the check says it diverged.
    let mut changed = bytes.clone();
    let at = (sealed[..3].iter().map(|s| s.raw).sum::<u64>() + 10) as usize;
    changed[at] ^= 1;
    let mut check = SegmentCheck::new(&sealed);
    assert!(check.write_all(&changed).is_err());
    assert!(check.diverged());
    assert_eq!(check.matched(), 3);

    // Keep 4 of them and encode the rest of the log (the pack's further segments are redone).
    let keep = 4;
    let kept_raw = sealed[..keep].iter().map(|s| s.raw).sum::<u64>() as usize;
    let tail = dir.path().join("tail.ndjson");
    std::fs::write(&tail, &bytes[kept_raw..]).unwrap();
    let (m, stats) =
        pack_kept(&grown, "s", keep, std::slice::from_ref(&tail), &params()).unwrap().unwrap();
    assert_eq!(stats.kept_segments as usize, keep);
    assert_eq!(stats.encoded_bytes as usize, bytes.len() - kept_raw);
    let fresh = Store::new(dir.path().join("fresh"));
    let (want, _) = pack(&fresh, "s", std::slice::from_ref(&whole), &params(), true).unwrap();
    assert_eq!(m, want, "the pack that kept 4 segments is the whole pack");

    // Through a line before the pack's sealed end: cut back there, as a whole pack of it is.
    let short_end = sealed[..6].iter().map(|s| s.raw).sum::<u64>() as usize + 5;
    let short_end = short_end + bytes[short_end..].iter().position(|b| *b == b'\n').unwrap() + 1;
    std::fs::write(&tail, &bytes[kept_raw..short_end]).unwrap();
    let (m, _) =
        pack_kept(&grown, "s", keep, std::slice::from_ref(&tail), &params()).unwrap().unwrap();
    let short = dir.path().join("short.ndjson");
    std::fs::write(&short, &bytes[..short_end]).unwrap();
    let other = Store::new(dir.path().join("other"));
    let (want, _) = pack(&other, "s", &[short], &params(), true).unwrap();
    assert_eq!(m, want, "a pack cut back is the whole pack of the shorter log");
    let mut back = Vec::new();
    Pack::open(&grown, "s").unwrap().cat(&mut back).unwrap();
    assert!(back == bytes[..short_end], "the cut pack does not read back");

    // More than the pack has sealed, none, or other params: nothing packed.
    assert!(pack_kept(&grown, "s", 999, std::slice::from_ref(&tail), &params()).unwrap().is_none());
    assert!(pack_kept(&grown, "s", 0, std::slice::from_ref(&tail), &params()).unwrap().is_none());
    let other_params = Params { level: 4, ..params() };
    assert!(pack_kept(&grown, "s", 1, &[tail], &other_params).unwrap().is_none());
}
