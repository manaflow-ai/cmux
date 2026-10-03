//! Fidelity corpus (plans/cmux-next/ghostty-next.md section 12).
//!
//! For each case in `schemas/terminal-corpus/manifest.json`, feed its bytes to
//! a libghostty-vt terminal of the manifest size with the session host's
//! default scrollback, the frontend's default colors and the cross check's
//! cell size, encode the READY and COMPLETE GHOSTSNP snapshots, and check
//! their per-record digests against
//! `schemas/terminal-corpus/host-snapshots-<os>-<arch>.txt`.
//! The GhosttyNextKit cross check (crosscheck/run.sh, a Mac build host with no
//! cargo) compares the surface's snapshots with the same file.
//! `CMUX_TERMINAL_CORPUS_UPDATE=1` rewrites the file. The snapshots are also
//! written to `$CARGO_TARGET_TMPDIR/terminal-corpus` (or
//! `$CMUX_TERMINAL_CORPUS_OUT`).
//!
//! Digest of one record: FNV-1a 64 over its `u16` tag, `u32` payload length
//! and payload (CRC excluded), with two documented TERMINAL normalizations:
//! pixel size (payload bytes 4..12) and mouse shape (byte 37, presentation
//! state the surface sets for its pointer).

use std::path::PathBuf;

use ghostty_vt::{
    Callbacks, Rgb, SnapshotPhase, Terminal, reencode_ready, snapshot_envelope_version,
    snapshot_ready_len, snapshot_records, snapshot_tag, snapshot_version,
};

/// The session host's default scrollback budget (cmux-tui-core
/// `DEFAULT_SCROLLBACK_LIMIT_BYTES`).
const HOST_SCROLLBACK_BYTES: usize = 50_000_000;
/// Default colors the frontend sends the session host (`set-default-colors`)
/// for Ghostty's default theme. The cross check configures the surface with
/// the same values (crosscheck/run.sh).
const HOST_DEFAULT_FOREGROUND: Rgb = Rgb { r: 0xff, g: 0xff, b: 0xff };
const HOST_DEFAULT_BACKGROUND: Rgb = Rgb { r: 0x28, g: 0x2c, b: 0x34 };

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

/// The cross check's surface cell size (its default font at scale 1);
/// crosscheck/run.sh fails when the surface reports another size. Kitty
/// placements size in cells from it. `CMUX_TERMINAL_CORPUS_CELL_PX=WxH`
/// overrides it.
const CROSSCHECK_CELL_PX: (u32, u32) = (8, 17);

fn cell_pixels() -> (u32, u32) {
    std::env::var("CMUX_TERMINAL_CORPUS_CELL_PX")
        .ok()
        .and_then(|value| {
            let (width, height) = value.split_once('x')?;
            Some((width.trim().parse().ok()?, height.trim().parse().ok()?))
        })
        .unwrap_or(CROSSCHECK_CELL_PX)
}

fn fnv1a64(bytes: impl IntoIterator<Item = u8>) -> u64 {
    bytes.into_iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// `<case> <phase> <index> <tag> <digest>` lines for one snapshot.
fn digest_lines(case: &str, phase: &str, snapshot: &[u8]) -> Vec<String> {
    snapshot_records(snapshot)
        .enumerate()
        .map(|(index, record)| {
            let mut payload = record.payload().to_vec();
            if record.tag == snapshot_tag::TERMINAL && payload.len() > 37 {
                payload[4..12].fill(0);
                payload[37] = 0;
            }
            let header = record.tag.to_le_bytes().into_iter().chain((payload.len() as u32).to_le_bytes());
            let digest = fnv1a64(header.chain(payload.iter().copied()));
            format!("{case} {phase} {index} {} {digest:016x}", record.tag)
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
    let mut digests = vec![format!(
        "# ghostty-vt tests/terminal_corpus.rs (CMUX_TERMINAL_CORPUS_UPDATE=1); GHOSTSNP {}, cell {}x{}",
        snapshot_version(),
        cell_pixels().0,
        cell_pixels().1
    )];
    for case in cases {
        let bytes = std::fs::read(corpus_dir().join(&case.file)).unwrap();
        assert_eq!(bytes.len(), case.bytes, "{}: manifest byte count", case.name);
        let mut term =
            Terminal::new(case.cols, case.rows, HOST_SCROLLBACK_BYTES, Callbacks::default())
                .unwrap();
        term.set_default_colors(Some(HOST_DEFAULT_FOREGROUND), Some(HOST_DEFAULT_BACKGROUND), None);
        let (width, height) = cell_pixels();
        term.resize(case.cols, case.rows, width, height).unwrap();
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
        digests.extend(digest_lines(&case.name, "ready", &ready));
        digests.extend(digest_lines(&case.name, "complete", &complete));
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
    // Page records split at the OS page size (16 KiB on Apple arm64, 4 KiB on
    // Linux x86_64), so the digests are per platform.
    let platform = format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH);
    let expected_path = corpus_dir().join(format!("host-snapshots-{platform}.txt"));
    let actual = digests.join("\n") + "\n";
    if std::env::var_os("CMUX_TERMINAL_CORPUS_UPDATE").is_some() {
        std::fs::write(&expected_path, &actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&expected_path).ok();
    if expected.as_deref() != Some(actual.as_str()) {
        // Direct stderr bypasses libtest capture, so CI logs carry the file.
        let _ = std::io::Write::write_all(
            &mut std::io::stderr(),
            format!("host-snapshots BEGIN\n{actual}host-snapshots END\n").as_bytes(),
        );
        // A platform with no committed file only reports its digests.
        assert!(expected.is_none(), "host snapshots differ from {}", expected_path.display());
    }
}
