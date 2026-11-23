//! A pack reads back every byte, an appended log repacks to the same chunks as a fresh pack, and
//! a move to a store with an older copy ships only what was sealed since.

use cmux_session_pack::{Manifest, Pack, Params, RangeId, Store, pack, ship};
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
    assert!(ship::unbundle(&there, &mut &bad[..]).is_err());
    assert_ne!(Manifest::load(&there, "s").unwrap().unwrap(), grown);
    assert_eq!(ship::unbundle(&there, &mut &bundle[..]).unwrap(), grown);
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
