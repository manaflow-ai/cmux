//! The generator against its own shape, in-process: a small run's kind mix, sizes, gaps, bursts and
//! peaks within `fidelity::TOLERANCE`; the same seed makes the same bytes; every line parses as an
//! acpmux record in a segment no bigger than acpmux would write.

use super::*;
use std::collections::BTreeMap;

fn tmp(name: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("coord-sim-gen-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    p
}

fn opts(out: &Path, extra: &[&str]) -> Opts {
    let mut args: Vec<String> = vec!["--out".into(), out.display().to_string()];
    args.extend(extra.iter().map(|s| s.to_string()));
    Opts::parse(&args).unwrap()
}

fn files(dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            files(&p, out);
        } else {
            out.insert(p.strip_prefix(dir).unwrap().to_owned(), std::fs::read(&p).unwrap());
        }
    }
}

#[test]
fn a_small_run_matches_its_shape() {
    let shape = Shape::load(None).unwrap();
    let out = tmp("fidelity");
    // Two claude coordinators of 40k events each, one codex: every family's mix is in it.
    let o = opts(
        &out,
        &["--seed", "11", "--coordinators", "3", "--events", "40000", "--format", "acpmux"],
    );
    let m = generate(&shape, &o).unwrap();
    let got = fidelity::probe(&out.join("acpmux-home")).unwrap();
    let report = fidelity::compare(&shape, &got, &m).unwrap();
    eprintln!("{}", serde_json::to_string_pretty(&report).unwrap());
    assert!(report.failures.is_empty(), "{:?}", report.failures);
    assert_eq!(report.lines, m.coordinators.iter().map(|c| c.lines).sum::<u64>());
    std::fs::remove_dir_all(&out).unwrap();
}

#[test]
fn the_same_seed_makes_the_same_bytes() {
    let shape = Shape::load(None).unwrap();
    let (a, b, c) = (tmp("det-a"), tmp("det-b"), tmp("det-c"));
    let args = ["--seed", "5", "--coordinators", "2", "--events", "5000", "--scale", "2"];
    generate(&shape, &opts(&a, &args)).unwrap();
    generate(&shape, &opts(&b, &args)).unwrap();
    let mut seed6 = args;
    seed6[1] = "6";
    generate(&shape, &opts(&c, &seed6)).unwrap();
    let (mut fa, mut fb, mut fc) = (BTreeMap::new(), BTreeMap::new(), BTreeMap::new());
    files(&a, &mut fa);
    files(&b, &mut fb);
    files(&c, &mut fc);
    assert!(fa.len() > 4);
    assert!(fa == fb, "same seed, different bytes");
    assert!(fa != fc, "another seed made the same bytes");
    for d in [a, b, c] {
        std::fs::remove_dir_all(d).unwrap();
    }
}

#[test]
fn every_line_is_an_acpmux_record_and_segments_roll_like_acpmux() {
    let shape = Shape::load(None).unwrap();
    let out = tmp("records");
    let o = opts(
        &out,
        &["--seed", "3", "--coordinators", "2", "--events", "6000", "--segment-bytes", "256K"],
    );
    let m = generate(&shape, &o).unwrap();
    for c in &m.coordinators {
        let dir = out.join("acpmux-home/sessions").join(&c.id);
        let meta: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("session.json")).unwrap()).unwrap();
        assert_eq!(meta["schema"], "acpmux.session.v1");
        assert_eq!(meta["lastSeq"], c.lines);
        let mut segs: Vec<_> =
            std::fs::read_dir(dir.join("events")).unwrap().map(|e| e.unwrap().path()).collect();
        segs.sort();
        assert_eq!(segs.len() as u32, c.segments);
        assert!(segs[0].ends_with("000001.ndjson"));
        let (mut seq, mut at, mut transcript) = (0u64, 0u64, 0u64);
        for (n, seg) in segs.iter().enumerate() {
            let text = std::fs::read_to_string(seg).unwrap();
            let lines: Vec<&str> = text.lines().collect();
            // acpmux rolls before a line once the segment holds segmentBytes: all but the last line fit.
            let before_last = text.len() - lines.last().unwrap().len() - 1;
            if n + 1 < segs.len() {
                assert!(before_last < 256 * 1024, "{seg:?} rolled late");
            }
            for l in lines {
                let v: serde_json::Value =
                    serde_json::from_str(l).unwrap_or_else(|e| panic!("{e}: {l:.300}"));
                seq += 1;
                assert_eq!(v["seq"], seq);
                let t = v["at"].as_u64().unwrap();
                assert!(t >= at, "time went back at seq {seq}");
                at = t;
                assert!(["in", "out", "mux"].contains(&v["dir"].as_str().unwrap()));
                let kind = v["kind"].as_str().unwrap();
                if v["dir"] == "in" && v["msg"]["method"] == "session/update" {
                    assert!(v["msg"]["params"]["update"]["sessionUpdate"].is_string(), "{l:.300}");
                    if !kind.ends_with(".replay") && !NON_TRANSCRIPT_UPDATES.contains(&kind) {
                        transcript = seq;
                    }
                } else if v["dir"] == "mux" && TRANSCRIPT_MUX_KINDS.contains(&kind) {
                    transcript = seq;
                }
            }
        }
        assert_eq!(seq, c.lines);
        assert_eq!(meta["transcriptSeq"], transcript);
    }
    let attachments = out.join("acpmux-home/attachments");
    if let Ok(rd) = std::fs::read_dir(&attachments) {
        for e in rd {
            let p = e.unwrap().path();
            let bytes = std::fs::read(&p).unwrap();
            let mut h = sha256::Sha256::default();
            h.update(&bytes);
            assert_eq!(
                p.file_name().unwrap().to_str().unwrap(),
                h.hex(),
                "an attachment is named by its hash"
            );
        }
    }
    std::fs::remove_dir_all(&out).unwrap();
}

#[test]
fn messages_between_coordinators_pair_up() {
    let shape = Shape::load(None).unwrap();
    let out = tmp("sends");
    let o = opts(
        &out,
        &["--seed", "9", "--coordinators", "4", "--events", "30000", "--format", "script"],
    );
    generate(&shape, &o).unwrap();
    let mut sends = 0;
    for i in 0..4 {
        let text = std::fs::read_to_string(out.join(format!("coord-{i}.ndjson"))).unwrap();
        let mut at = 0;
        for l in text.lines() {
            let e: SimEvent = serde_json::from_str(l).unwrap();
            assert!(e.at_ms >= at);
            at = e.at_ms;
            if let Op::SendTo { to } = e.op {
                assert_ne!(to, i);
                assert!(to < 4);
                sends += 1;
            }
            if let Op::Event { kind } = &e.op {
                assert_ne!(kind, plan::RECEIPT, "a receipt is the sender's SendTo in a script");
            }
        }
    }
    assert!(sends > 0);
    std::fs::remove_dir_all(&out).unwrap();
}

#[test]
fn byte_limit_and_scale_make_a_bigger_chat() {
    let shape = Shape::load(None).unwrap();
    let out = tmp("bytes");
    let o = opts(
        &out,
        &[
            "--seed", "2", "--events", "1000000", "--scale", "4", "--bytes", "24M", "--format",
            "acpmux",
        ],
    );
    let m = generate(&shape, &o).unwrap();
    let c = &m.coordinators[0];
    assert!(c.bytes >= 24 << 20 && c.bytes < 64 << 20, "{}", c.bytes);
    assert!(c.segments >= 3);
    std::fs::remove_dir_all(&out).unwrap();
}

#[test]
fn target_bytes_lands_within_two_percent() {
    let shape = Shape::load(None).unwrap();
    for (target, n) in [("1MB", 1_000_000u64), ("20MB", 20_000_000), ("8MiB", 8 << 20)] {
        let out = tmp(&format!("target-{target}"));
        let o = opts(&out, &["--seed", "4", "--target-bytes", target, "--format", "acpmux"]);
        let m = generate(&shape, &o).unwrap();
        let c = &m.coordinators[0];
        let on_disk: u64 =
            std::fs::read_dir(out.join("acpmux-home/sessions").join(&c.id).join("events"))
                .unwrap()
                .map(|e| e.unwrap().metadata().unwrap().len())
                .sum();
        assert_eq!(on_disk, c.bytes);
        assert!(on_disk >= n && (on_disk as f64) <= n as f64 * 1.02, "{target}: {on_disk}");
        std::fs::remove_dir_all(&out).unwrap();
    }
}

#[test]
fn sizes_parse() {
    assert_eq!(parse_size("512").unwrap(), 512);
    assert_eq!(parse_size("8M").unwrap(), 8 << 20);
    assert_eq!(parse_size("8MiB").unwrap(), 8 << 20);
    assert_eq!(parse_size("100MB").unwrap(), 100_000_000);
    assert_eq!(parse_size("4GB").unwrap(), 4_000_000_000);
    assert_eq!(parse_size("1.5g").unwrap(), 3 << 29);
    assert!(parse_size("x").is_err());
}
