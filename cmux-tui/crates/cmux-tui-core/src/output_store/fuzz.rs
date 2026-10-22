//! Output store file decode for cmux-tui/fuzz: the
//! segment reader (`read_after`) and the snapshot readers (`read`,
//! `stream_ends`) on file contents from the fuzzer.
//!
//! The file layout (directory, names, magic) is copied from segments.rs and
//! snapshot.rs; `self_check` proves the copy still matches by reading back
//! well-formed files.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use flate2::Compression;
use flate2::write::GzEncoder;

use super::{segments, snapshot};
use crate::resource::TerminalPublicId;

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
const GENERATION: &str = "fuzz-generation";
const SNAPSHOT_MAGIC: &[u8] = b"CMUXSNAP1\n";

fn directory() -> Option<&'static Path> {
    static DIRECTORY: OnceLock<Option<PathBuf>> = OnceLock::new();
    DIRECTORY
        .get_or_init(|| {
            let directory =
                std::env::temp_dir().join(format!("cmux-fuzz-output-store-{}", std::process::id()));
            std::fs::create_dir_all(directory.join(TERMINAL)).ok()?;
            Some(directory)
        })
        .as_deref()
}

fn segment_path(directory: &Path, start: u64) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    GENERATION.hash(&mut hasher);
    directory.join(TERMINAL).join(format!("{:016x}-{start:020}.seg", hasher.finish()))
}

fn gzip(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    if encoder.write_all(bytes).is_err() {
        return Vec::new();
    }
    encoder.finish().unwrap_or_default()
}

/// Segment frames built from `data`: per frame a start offset (u8), a flag
/// byte and a body length (u8); the flag picks a gzip body with the true raw
/// length, a gzip body with a lying raw length, or the raw bytes as stored.
fn frames(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut rest = data;
    while let [start, flag, length, tail @ ..] = rest {
        let take = usize::from(*length).min(tail.len());
        let Some((body, next)) = tail.split_at_checked(take) else { break };
        rest = next;
        let (stored, raw) = match flag % 3 {
            0 => (gzip(body), body.len()),
            1 => (gzip(body), usize::from(*flag)),
            _ => (body.to_vec(), body.len()),
        };
        out.extend_from_slice(&u64::from(*start).to_le_bytes());
        out.extend_from_slice(&u32::try_from(stored.len()).unwrap_or(u32::MAX).to_le_bytes());
        out.extend_from_slice(&u32::try_from(raw).unwrap_or(u32::MAX).to_le_bytes());
        out.extend_from_slice(&stored);
    }
    out
}

fn read_back(directory: &Path, terminal: &TerminalPublicId, after: u64, budget: usize) -> bool {
    let window = segments::read_after(directory, terminal, GENERATION, after, budget);
    let snapshot = snapshot::read(directory, terminal);
    let _ = snapshot::stream_ends(directory);
    window.is_some() && snapshot.is_some()
}

pub(crate) fn files(data: &[u8]) {
    let Some(directory) = directory() else { return };
    let Ok(terminal) = TerminalPublicId::parse(TERMINAL) else { return };
    let Some((&mode, data)) = data.split_first() else { return };
    // The snapshot header line comes first, up to the first newline.
    let (header, body) = match data.iter().position(|byte| *byte == b'\n') {
        Some(newline) => data.split_at(newline),
        None => (data, &[][..]),
    };
    let body = body.get(1..).unwrap_or_default();
    let segment = if mode & 1 == 0 { frames(body) } else { body.to_vec() };
    let mut snapshot = Vec::new();
    if mode & 2 == 0 {
        snapshot.extend_from_slice(SNAPSHOT_MAGIC);
    }
    snapshot.extend_from_slice(header);
    snapshot.push(b'\n');
    if mode & 4 == 0 {
        snapshot.extend_from_slice(&gzip(body));
    } else {
        snapshot.extend_from_slice(body);
    }
    let snapshot_path = directory.join(format!("{TERMINAL}.snap"));
    if std::fs::write(segment_path(directory, 0), &segment).is_err()
        || std::fs::write(&snapshot_path, &snapshot).is_err()
    {
        return;
    }
    let after = u64::from(mode >> 4);
    let budget = usize::from(mode >> 3) * 64;
    let _ = read_back(directory, &terminal, after, budget);
}

pub(crate) fn self_check() -> bool {
    let Some(directory) = directory() else { return false };
    let Ok(terminal) = TerminalPublicId::parse(TERMINAL) else { return false };
    let segment = frames(&[0, 0, 5, b'h', b'e', b'l', b'l', b'o']);
    let mut snapshot = SNAPSHOT_MAGIC.to_vec();
    snapshot.extend_from_slice(
        br#"{"generation":"fuzz-generation","stream_end":5,"cols":80,"rows":24}"#,
    );
    snapshot.push(b'\n');
    snapshot.extend_from_slice(&gzip(b"hello"));
    std::fs::write(segment_path(directory, 0), segment).is_ok()
        && std::fs::write(directory.join(format!("{TERMINAL}.snap")), snapshot).is_ok()
        && read_back(directory, &terminal, 0, 1024)
}
