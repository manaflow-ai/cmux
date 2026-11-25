//! The agent harnesses' executables read back into the page cache right after a resume, so the first agent turn on a
//! claimed spare does not page its harness in from disk.
//!
//! Before a pause the platform drops the guest's clean page cache ([`super::page_cache`]); a file read after the resume
//! comes from disk, as on a fresh boot. The Claude Code executable is one 400 MB file, and its first run after a long
//! pause pays for it: the first `session/new` on a claimed spare took p50 938 ms / p90 3012 ms on spares under 2 min
//! old and p50 2979 ms / p90 9007 ms on spares over an hour old (the app chat probes, 2026-11-22 to 11-24), the
//! largest step of a CLI or app start. The read here starts the moment cmux-host sees the resume, seconds before the
//! claim's connect and approvals are done and the first chat starts its harness.
//!
//! A sequential `read` (not `posix_fadvise(WILLNEED)`): a resumed snapshot's memory can itself come back lazily, and
//! only touching the pages brings them in on every provider. The read runs on its own thread, at most one at a time,
//! and stops at [`MAX_BYTES`] or [`DEADLINE`]; it reads only, so a missing or unreadable file is skipped.

use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The harness executables under a user's home: Claude Code's native installer link and a Codex link beside it.
pub const HOME_HARNESSES: &[&str] = &[".local/bin/claude", ".local/bin/codex"];
/// The system-wide installs (an npm global Claude Code or Codex, and the Node that runs them).
pub const SYSTEM_HARNESSES: &[&str] =
    &["/usr/local/bin/claude", "/usr/local/bin/codex", "/usr/local/bin/node", "/usr/bin/node"];
/// The most one resume reads: Claude Code and Codex together are well under it.
pub const MAX_BYTES: u64 = 1 << 30;
/// The longest one resume's read runs.
pub const DEADLINE: Duration = Duration::from_secs(20);

/// The canonical regular files the names resolve to under `homes` and among `system`, each once, in order.
pub fn targets(homes: &[PathBuf], system: &[&str]) -> Vec<PathBuf> {
    let names = homes
        .iter()
        .flat_map(|home| HOME_HARNESSES.iter().map(move |name| home.join(name)))
        .chain(system.iter().map(PathBuf::from));
    let mut out: Vec<PathBuf> = Vec::new();
    for name in names {
        let Ok(path) = std::fs::canonicalize(&name) else { continue };
        if path.is_file() && !out.contains(&path) {
            out.push(path);
        }
    }
    out
}

/// What one read did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Paged {
    pub files: usize,
    pub bytes: u64,
    /// False when the byte cap or the deadline stopped it.
    pub whole: bool,
}

/// Reads `files` front to back, stopping at `max_bytes` in all or at `deadline`.
pub fn page_in(files: &[PathBuf], max_bytes: u64, deadline: Instant) -> Paged {
    let mut buf = vec![0_u8; 1 << 20];
    let mut paged = Paged { files: 0, bytes: 0, whole: true };
    for path in files {
        let Ok(mut file) = std::fs::File::open(path) else { continue };
        paged.files += 1;
        loop {
            if paged.bytes >= max_bytes || Instant::now() >= deadline {
                paged.whole = false;
                return paged;
            }
            let room =
                usize::try_from(max_bytes - paged.bytes).unwrap_or(usize::MAX).min(buf.len());
            match file.read(&mut buf[..room]) {
                Ok(0) | Err(_) => break,
                Ok(n) => paged.bytes += n as u64,
            }
        }
    }
    paged
}

/// One read in flight at a time: a resume both detectors saw, or a second pause during the read, starts no other.
static RUNNING: AtomicBool = AtomicBool::new(false);

/// Starts the read of the harnesses under `homes` on its own thread, unless one runs; the journal gets one line.
pub fn spawn(homes: Vec<PathBuf>) {
    if RUNNING.swap(true, Ordering::AcqRel) {
        return;
    }
    let started = std::thread::Builder::new().name("page-in-harnesses".into()).spawn(move || {
        let start = Instant::now();
        let files = targets(&homes, SYSTEM_HARNESSES);
        let paged = page_in(&files, MAX_BYTES, start + DEADLINE);
        eprintln!(
            "cmux-host: paged in {} harness file{} ({} MiB{}) in {} ms after the resume",
            paged.files,
            if paged.files == 1 { "" } else { "s" },
            paged.bytes >> 20,
            if paged.whole { "" } else { ", stopped at its bound" },
            start.elapsed().as_millis()
        );
        RUNNING.store(false, Ordering::Release);
    });
    if let Err(e) = started {
        RUNNING.store(false, Ordering::Release);
        eprintln!("cmux-host: page-in thread: {e}");
    }
}

/// Whether a read runs now.
pub fn running() -> bool {
    RUNNING.load(Ordering::Acquire)
}
