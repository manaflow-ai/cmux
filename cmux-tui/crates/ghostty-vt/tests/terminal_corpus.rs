//! Fidelity corpus (plans/cmux-next/ghostty-next.md section 12).
//!
//! For each case in `schemas/terminal-corpus/manifest.json`, feed its bytes to
//! a libghostty-vt terminal of the manifest size with the session host's
//! default scrollback, encode the READY and COMPLETE GHOSTSNP snapshots, and
//! write them to `$CARGO_TARGET_TMPDIR/terminal-corpus/<case>.{ready,complete}.ghostsnp`
//! (or `$CMUX_TERMINAL_CORPUS_OUT` when set) for the cross check against
//! GhosttyNextKit's `ghostty_surface_encode_snapshot`.

use std::path::PathBuf;

use ghostty_vt::{
    Callbacks, SnapshotPhase, Terminal, reencode_ready, snapshot_envelope_version,
    snapshot_ready_len, snapshot_records, snapshot_tag, snapshot_version,
};

/// The session host's default scrollback budget (cmux-tui-core
/// `DEFAULT_SCROLLBACK_LIMIT_BYTES`).
const HOST_SCROLLBACK_BYTES: usize = 50_000_000;

struct Case {
    name: String,
    file: String,
    cols: u16,
    rows: u16,
    bytes: usize,
}

fn corpus_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/terminal-corpus")
}

fn field<'a>(object: &'a str, key: &str) -> &'a str {
    let start = object.find(&format!("\"{key}\"")).unwrap_or_else(|| panic!("missing {key}"));
    let rest = &object[start + key.len() + 2..];
    let rest = rest[rest.find(':').unwrap() + 1..].trim_start();
    let end = rest.find([',', '\n', '}']).unwrap();
    rest[..end].trim().trim_matches('"')
}

/// The manifest is flat: one object per case under `cases`.
fn cases() -> Vec<Case> {
    let manifest = std::fs::read_to_string(corpus_dir().join("manifest.json")).unwrap();
    let cases = &manifest[manifest.find("\"cases\"").unwrap()..];
    cases
        .split("\"name\"")
        .skip(1)
        .map(|chunk| {
            let object = format!("\"name\"{}", &chunk[..chunk.find('}').unwrap()]);
            Case {
                name: field(&object, "name").to_string(),
                file: field(&object, "file").to_string(),
                cols: field(&object, "cols").parse().unwrap(),
                rows: field(&object, "rows").parse().unwrap(),
                bytes: field(&object, "bytes").parse().unwrap(),
            }
        })
        .collect()
}

fn out_dir() -> PathBuf {
    let dir = std::env::var_os("CMUX_TERMINAL_CORPUS_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("terminal-corpus"));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn terminal_corpus_snapshots_encode_ready_and_complete() {
    let cases = cases();
    assert!(cases.len() >= 7, "manifest lists {} cases", cases.len());
    let out = out_dir();
    let mut mismatches = Vec::new();
    let mut report = Vec::new();
    for case in cases {
        let bytes = std::fs::read(corpus_dir().join(&case.file)).unwrap();
        assert_eq!(bytes.len(), case.bytes, "{}: manifest byte count", case.name);
        let mut term =
            Terminal::new(case.cols, case.rows, HOST_SCROLLBACK_BYTES, Callbacks::default())
                .unwrap();
        term.vt_write(&bytes);
        let ready = term.encode_snapshot(SnapshotPhase::Ready).unwrap();
        let complete = term.encode_snapshot(SnapshotPhase::Complete).unwrap();
        assert_eq!(snapshot_envelope_version(&ready), Some(snapshot_version()), "{}", case.name);
        assert_eq!(snapshot_ready_len(&complete), Some(ready.len()), "{}", case.name);
        assert_eq!(&complete[..ready.len()], &ready[..], "{}: READY is a prefix", case.name);
        assert_eq!(
            snapshot_records(&complete).last().map(|record| record.tag),
            Some(snapshot_tag::FINISH),
            "{}",
            case.name
        );
        // Deterministic: encoding the same state again gives the same bytes.
        assert_eq!(term.encode_snapshot(SnapshotPhase::Complete).unwrap(), complete);
        // Viewer side: a terminal restored from COMPLETE encodes the same READY.
        let viewer = reencode_ready(&complete).unwrap();
        if viewer != ready {
            mismatches.push(case.name.clone());
        }
        std::fs::write(out.join(format!("{}.ready.ghostsnp", case.name)), &ready).unwrap();
        std::fs::write(out.join(format!("{}.complete.ghostsnp", case.name)), &complete).unwrap();
        let line = format!(
            "corpus {}: {}x{} input {} B, READY {} B, COMPLETE {} B, version {}, restore {}",
            case.name,
            case.cols,
            case.rows,
            bytes.len(),
            ready.len(),
            complete.len(),
            snapshot_version(),
            if mismatches.contains(&case.name) { "differs" } else { "equal" },
        );
        // Direct stderr writes bypass libtest capture, so CI logs keep them.
        let _ = std::io::Write::write_all(&mut std::io::stderr(), format!("{line}\n").as_bytes());
        report.push(line);
    }
    if let Some(summary) = std::env::var_os("GITHUB_STEP_SUMMARY") {
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new().append(true).open(summary).unwrap();
        for line in &report {
            writeln!(file, "- {line}").unwrap();
        }
    }
    assert!(mismatches.is_empty(), "READY restore round trip differs for {mismatches:?}");
}
