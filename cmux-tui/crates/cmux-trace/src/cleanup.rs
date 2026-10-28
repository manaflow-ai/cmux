//! Deletes the black-box rings of processes that ended, the rule of plans/cmux-next/trace.md
//! ("Sizes by role") that Swift's `TraceRingCleanup` follows for the app: a black box whose
//! process has been dead for more than [`MAX_AGE`] goes, then the longest-dead ones go until the
//! dead processes' black boxes take at most [`DEAD_BYTE_CAP`] bytes. A live process's ring is never
//! deleted, and recording rings are not touched (they are under the `trace.start` cap). The
//! daemon runs it once at start (task 095), no timer, as Chrome cleans its metrics upload
//! directory by age and size once per launch (components/metrics/file_metrics_provider.cc).
//!
//! The age counts from the first cleanup that found the process dead, not from the ring's start or
//! its mtime: records go through a `MAP_SHARED` mapping, which does not reliably move the mtime, so
//! a session that ran for days and then crashed must not read as days old. That cleanup creates
//! `<ring>.dead` with its own wall clock as the mtime.
//!
//! A process is live when `kill(pid, 0)` finds it and its kernel start time is the header's
//! `process_start_unix_us`, so a reused pid does not keep an old ring. Linux reads no other
//! process's start time (no `/proc/<pid>` reads), so there a reused pid keeps the ring until it
//! ends too.
//!
//! Blocking file work: run it off any thread a person waits on.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::time::Duration;

use crate::layout::{HEADER_BYTES, MAGIC, off};

/// A black box whose process has been dead for longer than this is deleted.
pub const MAX_AGE: Duration = Duration::from_secs(3 * 24 * 3600);
/// The most bytes the dead processes' black boxes keep after the age rule.
pub const DEAD_BYTE_CAP: u64 = 16 * 1024 * 1024;

/// The file name suffix of a black-box ring ([`crate::blackbox_file_name`]).
const BLACKBOX_SUFFIX: &str = ".blackbox.cmxtrace";
/// The suffix of a spare file the app is still building (Swift `TraceRingFile.prepareSpare`).
const BUILDING_SUFFIX: &str = ".tmp";
/// The infix of a spare being built, `<role>.spare.cmxtrace.<pid>.tmp`.
const SPARE_INFIX: &str = ".spare.cmxtrace.";
/// The suffix of the marker whose mtime is when a cleanup first found a black box's process dead.
const DEAD_MARK_SUFFIX: &str = ".dead";

/// What one cleanup kept and deleted (file names).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Black boxes of live processes.
    pub live: Vec<String>,
    /// Black boxes of dead processes that stayed (dead for less than [`MAX_AGE`], under the cap).
    pub kept_dead: Vec<String>,
    /// Files deleted: long-dead or over-cap black boxes and abandoned spare builds (not markers).
    pub deleted: Vec<String>,
}

/// Cleans `dir` once with the system's process table and wall clock.
pub fn run(dir: &Path) -> Report {
    run_with(dir, process_is_alive, crate::clock::unix_ns())
}

/// [`run`] with the process table (`is_alive(pid, process_start_unix_us)`, a start of 0 being
/// unknown) and the wall clock (ns since 1970) given.
pub fn run_with(dir: &Path, is_alive: impl Fn(u32, u64) -> bool, now_unix_ns: u64) -> Report {
    let mut report = Report::default();
    let max_age_ns = u64::try_from(MAX_AGE.as_nanos()).unwrap_or(u64::MAX);
    let names = file_names(dir);
    let mut dead: Vec<Ring> = Vec::new();
    for name in &names {
        if name.ends_with(BUILDING_SUFFIX) {
            if builder_pid(name).is_some_and(|pid| !is_alive(pid, 0)) && remove(dir, name) {
                report.deleted.push(name.clone());
            }
            continue;
        }
        if !name.ends_with(BLACKBOX_SUFFIX) {
            continue;
        }
        let Some(mut ring) = read_ring(dir, name) else { continue };
        let marker = format!("{name}{DEAD_MARK_SUFFIX}");
        if is_alive(ring.pid, ring.start_us) {
            // A marker left by an earlier process with this pid would date this one's death early.
            if names.contains(&marker) {
                remove(dir, &marker);
            }
            report.live.push(ring.name);
            continue;
        }
        ring.dead_since_ns = dead_since(&dir.join(&marker), now_unix_ns);
        if now_unix_ns > ring.dead_since_ns && now_unix_ns - ring.dead_since_ns > max_age_ns {
            if delete(dir, name) {
                report.deleted.push(ring.name);
            }
        } else {
            dead.push(ring);
        }
    }
    // A marker whose ring is gone (deleted above, or by hand).
    let marker_suffix = format!("{BLACKBOX_SUFFIX}{DEAD_MARK_SUFFIX}");
    for marker in names.iter().filter(|name| name.ends_with(&marker_suffix)) {
        let ring = &marker[..marker.len() - DEAD_MARK_SUFFIX.len()];
        if !names.iter().any(|name| name == ring) {
            remove(dir, marker);
        }
    }
    // The cap: the longest-dead rings go first.
    dead.sort_by(|a, b| {
        (a.dead_since_ns, a.start_unix_ns, &a.name).cmp(&(
            b.dead_since_ns,
            b.start_unix_ns,
            &b.name,
        ))
    });
    let mut bytes: u64 = dead.iter().map(|ring| ring.bytes).sum();
    for ring in dead {
        if bytes > DEAD_BYTE_CAP && delete(dir, &ring.name) {
            bytes -= ring.bytes;
            report.deleted.push(ring.name);
        } else {
            report.kept_dead.push(ring.name);
        }
    }
    report
}

/// Whether process `pid`, started at `start_us` (us since 1970; 0: unknown), still runs:
/// `kill(pid, 0)` finds it (EPERM: it runs as another user), and when `start_us` is known, the
/// process with that pid started then. A start time that cannot be read counts as a match.
#[cfg(unix)]
pub fn process_is_alive(pid: u32, start_us: u64) -> bool {
    let Ok(raw) = libc::pid_t::try_from(pid) else { return false };
    if raw <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists and may be signalled.
    let found = unsafe { libc::kill(raw, 0) } == 0
        || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    if !found || start_us == 0 {
        return found;
    }
    let current = crate::identity::process_start_unix_us_of(pid);
    current == 0 || current == start_us
}

/// No process table to ask: every process counts as live, so nothing is deleted.
#[cfg(not(unix))]
pub fn process_is_alive(_pid: u32, _start_us: u64) -> bool {
    true
}

/// A black-box file: its process (from the header, else the name), its start and its size.
struct Ring {
    name: String,
    pid: u32,
    start_us: u64,
    /// The header's `start_unix_ns` (the mtime for a file that is not a v1 ring): the cap's
    /// tie-break only, never its age.
    start_unix_ns: u64,
    bytes: u64,
    /// When a cleanup first found its process dead ([`dead_since`]).
    dead_since_ns: u64,
}

fn file_names(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()).collect()
}

/// The ring's header fields, read from its first [`HEADER_BYTES`]; a file that is not a v1 ring
/// takes its pid from its name and its start from the file system.
fn read_ring(dir: &Path, name: &str) -> Option<Ring> {
    let mut file = open_no_follow(&dir.join(name)).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() {
        return None;
    }
    let modified = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
    let mut header = [0u8; HEADER_BYTES];
    if file.read_exact(&mut header).is_ok() && header[..MAGIC.len()] == MAGIC {
        let word = |at: usize| u64::from_le_bytes(header[at..at + 8].try_into().unwrap_or([0; 8]));
        let pid = u32::from_le_bytes(header[off::PID..off::PID + 4].try_into().unwrap_or([0; 4]));
        return Some(Ring {
            name: name.to_owned(),
            pid,
            start_us: word(off::PROCESS_START_UNIX_US),
            start_unix_ns: word(off::START_UNIX_NS),
            bytes: meta.len(),
            dead_since_ns: 0,
        });
    }
    Some(Ring {
        name: name.to_owned(),
        pid: name_pid(name)?,
        start_us: 0,
        start_unix_ns: modified,
        bytes: meta.len(),
        dead_since_ns: 0,
    })
}

#[cfg(unix)]
fn open_no_follow(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)
}

#[cfg(not(unix))]
fn open_no_follow(path: &Path) -> io::Result<File> {
    if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "a symlink is not a ring"));
    }
    File::open(path)
}

/// When a cleanup first found the process of a black box dead: its marker's mtime, or `now` once
/// this call made the marker with that mtime. When no marker can be made the answer is `now`, so
/// the ring stays until a later cleanup marks it.
fn dead_since(marker: &Path, now_unix_ns: u64) -> u64 {
    if let Ok(meta) = std::fs::symlink_metadata(marker) {
        let since = meta
            .is_file()
            .then(|| meta.modified().ok())
            .flatten()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok());
        return since
            .map_or(now_unix_ns, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
    }
    let created = std::fs::OpenOptions::new().write(true).create_new(true).open(marker);
    if let Ok(file) = created {
        let stamp = std::time::UNIX_EPOCH + Duration::from_nanos(now_unix_ns);
        let _ = file.set_times(std::fs::FileTimes::new().set_modified(stamp).set_accessed(stamp));
    }
    now_unix_ns
}

/// Deletes black box `name` and its dead marker; true when the ring went.
fn delete(dir: &Path, name: &str) -> bool {
    if !remove(dir, name) {
        return false;
    }
    remove(dir, &format!("{name}{DEAD_MARK_SUFFIX}"));
    true
}

fn remove(dir: &Path, name: &str) -> bool {
    std::fs::remove_file(dir.join(name)).is_ok()
}

/// The pid of `<role>-<pid>.blackbox.cmxtrace`.
fn name_pid(name: &str) -> Option<u32> {
    let stem = name.strip_suffix(BLACKBOX_SUFFIX)?;
    stem[stem.rfind('-')? + 1..].parse().ok()
}

/// The pid of a spare being built, `<role>.spare.cmxtrace.<pid>.tmp`.
fn builder_pid(name: &str) -> Option<u32> {
    let stem = name.strip_suffix(BUILDING_SUFFIX)?;
    if !stem.contains(SPARE_INFIX) {
        return None;
    }
    stem[stem.rfind('.')? + 1..].parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_give_their_pids() {
        assert_eq!(name_pid("terminal-host-42.blackbox.cmxtrace"), Some(42));
        assert_eq!(name_pid("daemon-x.blackbox.cmxtrace"), None);
        assert_eq!(name_pid("daemon-42.recording.cmxtrace"), None);
        assert_eq!(builder_pid("app.spare.cmxtrace.77.tmp"), Some(77));
        assert_eq!(builder_pid("other.77.tmp"), None);
    }
}
