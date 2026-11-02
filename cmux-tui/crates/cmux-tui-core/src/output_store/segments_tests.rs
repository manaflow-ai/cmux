//! Full-mode segment flushes (port of #31643's flood test; this line has no
//! other segment tests).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::super::{LogState, PersistencePolicy, TerminalLog};
use super::{decode_frames, flush_logs};
use crate::resource::TerminalPublicId;

fn store_directory(name: &str) -> PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-output-segments-{name}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&directory).unwrap();
    directory
}

fn terminal() -> TerminalPublicId {
    TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap()
}

/// A log of generation `g1` whose `bytes` (offsets 0..) wait for a flush.
fn pending_log(bytes: &[u8]) -> Arc<TerminalLog> {
    Arc::new(TerminalLog {
        terminal_id: terminal(),
        state: std::sync::Mutex::new(LogState {
            tail: std::collections::VecDeque::from(bytes.to_vec()),
            pending: bytes.to_vec(),
            ..LogState::new(Arc::from("g1"), 0)
        }),
    })
}

/// Every segment file under `directory`.
fn segment_files(directory: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in fs::read_dir(directory).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(segment_files(&path));
        } else if path.extension().is_some_and(|extension| extension == "seg") {
            found.push(path);
        }
    }
    found
}

/// A flood's flush writes frames no larger than the wake threshold and
/// leaves the rest dirty for an immediate next pass, so a frame never grows
/// past what a reader accepts and a flood never waits out the flush
/// interval in RAM (review of #31643 at 77a38ad8a31).
#[test]
fn a_flood_flush_writes_bounded_frames_and_asks_for_the_next_pass_at_once() {
    let directory = store_directory("flood");
    let threshold = super::super::FULL_PENDING_WAKE_BYTES;
    let bytes = vec![b'x'; threshold * 2 + 1024];
    let log = pending_log(&bytes);
    let policy = PersistencePolicy::resolve(Some("full"), None, None, 0);
    let outcome = flush_logs(&directory, &[(log.clone(), Some(1))], policy, false);
    let (pending, dirty) = {
        let state = log.state.lock().unwrap();
        (state.pending.len(), state.dirty)
    };
    let frames = segment_files(&directory)
        .iter()
        .flat_map(|file| decode_frames(&fs::read(file).unwrap()))
        .map(|(_, raw)| raw.len())
        .collect::<Vec<_>>();
    fs::remove_dir_all(&directory).unwrap();
    assert!(!frames.is_empty(), "the flush wrote no frame");
    assert!(
        frames.iter().all(|raw| *raw <= threshold),
        "a frame of {frames:?} raw bytes is over the {threshold} threshold"
    );
    assert!(
        pending >= threshold,
        "{pending} bytes left: the flush wrote more than one frame's worth"
    );
    assert!(dirty && outcome.flooded, "the bytes left wait for a pass without being marked dirty");
}
