//! Agent transcripts (`~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`):
//! unique data, so one goes only when all of these hold, each checked again
//! right before:
//!
//! - it is older than the family's age ([`DEFAULT_DAYS`], or
//!   `CMUX_CARE_TRANSCRIPT_DAYS`), the same at every disk pressure;
//! - no running session is its owner (the Claude Code registry names the
//!   session; a transcript is `<session>.jsonl` or lies in `<session>/`);
//! - no program has it open (one bounded `lsof +D` of the family's root,
//!   reused for [`OPEN_TTL`], not one per file);
//! - it was archived first: gzip-compressed into the archive store
//!   (`transcripts/<family>/<path>.gz`), read back and compared byte for
//!   byte, and it did not change meanwhile.
//!
//! Anything that fails keeps the file. Recent transcripts are not entries at
//! all; the family's root is one reported entry for them and never goes.
//! Nothing named `memory` (Claude Code's auto-memory) is ever an entry.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::caches::{Entry, Family, Outcome, Source};
use crate::policy::{Action, Verdict};
use crate::store::Store;

/// The default age, in days, past which a transcript may go.
pub const DEFAULT_DAYS: u64 = 90;
/// How deep below the root transcripts lie (codex: `YYYY/MM/DD/file`; claude:
/// `project/session/subagents/file`).
const DEPTH: usize = 5;
/// How many entries the walk reads before it stops listing more.
const WALK_LIMIT: usize = 500_000;
/// How long one open-file answer for a root is reused.
pub const OPEN_TTL: Duration = Duration::from_secs(15);
const LSOF_LIMIT: Duration = Duration::from_secs(60);

/// Files a program has open under a folder (recursively).
pub type OpenIn = fn(&Path) -> Result<HashSet<PathBuf>, String>;

/// How a transcript family checks open files; compared as equal always (a
/// function is not data).
#[derive(Clone, Copy)]
pub struct OpenCheck(pub OpenIn);

impl std::fmt::Debug for OpenCheck {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OpenCheck")
    }
}

impl PartialEq for OpenCheck {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}

impl Eq for OpenCheck {}

/// The age from `CMUX_CARE_TRANSCRIPT_DAYS`, or [`DEFAULT_DAYS`]; never under one day.
pub fn days() -> u64 {
    std::env::var("CMUX_CARE_TRANSCRIPT_DAYS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_DAYS)
        .max(1)
}

/// A transcript family over `root`, gone after `days`.
pub fn family(name: &'static str, root: PathBuf, days: u64) -> Family {
    let hours = Some(days.max(1) * 24);
    Family {
        name,
        root,
        per_child: false,
        idle_hours: [hours; 3],
        kind: crate::caches::Kind::Unique,
        source: Source::Transcripts { open: OpenCheck(lsof_tree) },
    }
}

fn modified_ms(meta: &std::fs::Metadata) -> Option<u64> {
    let since = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    u64::try_from(since.as_millis()).ok()
}

fn age_ms(family: &Family) -> u64 {
    family.idle_hours[0].unwrap_or(DEFAULT_DAYS * 24) * 60 * 60 * 1000
}

/// Whether `path`, below `root`, may be a transcript at all.
fn shaped(root: &Path, path: &Path) -> bool {
    let Ok(rel) = path.strip_prefix(root) else { return false };
    !rel.as_os_str().is_empty()
        && path.extension().is_some_and(|e| e == "jsonl")
        && !rel.components().any(|c| c.as_os_str() == "memory")
}

/// The root as one kept entry (its newest change), then every transcript
/// older than the family's age.
pub(crate) fn entries(index: usize, family: &Family, now_ms: u64, found: &mut Vec<Entry>) {
    let root = &family.root;
    if !std::fs::symlink_metadata(root).is_ok_and(|m| m.is_dir()) {
        return;
    }
    let cutoff = now_ms.saturating_sub(age_ms(family));
    let mut newest = std::fs::symlink_metadata(root).ok().and_then(|m| modified_ms(&m));
    let mut old = Vec::new();
    let mut seen = 0usize;
    let mut stack = vec![(root.clone(), 0usize)];
    'walk: while let Some((dir, depth)) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&dir) else { continue };
        for child in read.flatten() {
            seen += 1;
            if seen > WALK_LIMIT {
                break 'walk;
            }
            let path = child.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            if meta.is_dir() {
                if depth + 1 < DEPTH && child.file_name() != "memory" {
                    stack.push((path, depth + 1));
                }
                continue;
            }
            if !meta.is_file() || !shaped(root, &path) {
                continue;
            }
            let Some(ms) = modified_ms(&meta) else { continue };
            newest = newest.max(Some(ms));
            if ms < cutoff {
                old.push((path, ms));
            }
        }
    }
    found.push(Entry {
        family: index,
        path: root.clone(),
        guard: root.clone(),
        last_activity_ms: newest,
    });
    old.sort();
    for (path, ms) in old {
        found.push(Entry { family: index, guard: path.clone(), path, last_activity_ms: Some(ms) });
    }
}

/// The root's entry is a report: it never goes.
pub(crate) fn summary_keep(family: &Family, path: &Path) -> Option<Verdict> {
    (path == family.root).then(|| Verdict {
        action: Action::Keep,
        reason: format!(
            "transcripts younger than {} days stay",
            family.idle_hours[0].unwrap_or(0) / 24
        ),
        idle_ms: None,
    })
}

/// Bytes of the root's recent transcripts (the old ones are entries of their own).
pub(crate) fn recent_bytes(family: &Family, now_ms: u64) -> Option<u64> {
    let cutoff = now_ms.saturating_sub(age_ms(family));
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut total = 0u64;
    let mut stack = vec![(family.root.clone(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        if Instant::now() > deadline {
            return None;
        }
        let read = std::fs::read_dir(&dir).ok()?;
        for child in read.flatten() {
            let path = child.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            if meta.is_dir() && depth + 1 < DEPTH {
                stack.push((path, depth + 1));
            } else if meta.is_file() && modified_ms(&meta).is_some_and(|ms| ms >= cutoff) {
                total += meta.len();
            }
        }
    }
    Some(total)
}

fn keep(reason: impl Into<String>) -> Verdict {
    Verdict { action: Action::Keep, reason: reason.into(), idle_ms: None }
}

/// The running session that owns the transcript at `path`, if any.
fn owner<'a>(processes: &'a [crate::procs::Process], root: &Path, path: &Path) -> Option<u32> {
    let rel = path.strip_prefix(root).ok()?;
    let stem = path.file_stem()?.to_string_lossy().into_owned();
    processes.iter().find_map(|p| {
        let id = p.session_id.as_deref()?;
        let hit = stem == id
            || stem.ends_with(id)
            || rel.components().any(|c| c.as_os_str().to_string_lossy() == id);
        hit.then_some(p.pid)
    })
}

static OPEN_CACHE: Mutex<Option<HashMap<PathBuf, (Instant, HashSet<PathBuf>)>>> = Mutex::new(None);

/// The open files under `root`, from a recent answer or a fresh one.
fn open_under(check: OpenIn, root: &Path) -> Result<HashSet<PathBuf>, String> {
    if let Ok(cache) = OPEN_CACHE.lock()
        && let Some((at, set)) = cache.as_ref().and_then(|c| c.get(root))
        && at.elapsed() < OPEN_TTL
    {
        return Ok(set.clone());
    }
    let set = check(root)?;
    if let Ok(mut cache) = OPEN_CACHE.lock() {
        let map = cache.get_or_insert_with(HashMap::new);
        map.retain(|_, (at, _)| at.elapsed() < OPEN_TTL);
        map.insert(root.to_path_buf(), (Instant::now(), set.clone()));
    }
    Ok(set)
}

/// Forgets cached open-file answers (tests, and a caller that wants a fresh look).
pub fn forget_open() {
    if let Ok(mut cache) = OPEN_CACHE.lock() {
        *cache = None;
    }
}

/// Every file under `root` some other program has open (one bounded lsof).
pub fn lsof_tree(root: &Path) -> Result<HashSet<PathBuf>, String> {
    crate::procs::open_files_under(root, LSOF_LIMIT)
}

/// Gzips `path` to a new file next to `dest`, reads it back against the
/// original, and renames it into place. The archive id is `dest`'s path in
/// the store.
fn archive(store: &Store, family: &Family, path: &Path, now_ms: u64) -> Result<String, String> {
    let rel = path.strip_prefix(&family.root).map_err(|e| e.to_string())?;
    let base = store.dir.join("transcripts").join(family.name);
    let mut dest = base.join(rel);
    let mut name = dest.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".gz");
    dest.set_file_name(&name);
    if dest.exists() {
        let mut name = dest.file_name().map(|n| n.to_os_string()).unwrap_or_default();
        name.push(format!(".{now_ms}.gz"));
        dest.set_file_name(name);
    }
    let parent = dest.parent().ok_or("archive path has no folder")?;
    std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        std::process::id()
    ));
    let written = (|| -> Result<(), String> {
        let mut source =
            std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let file = std::fs::File::create(&temporary)
            .map_err(|e| format!("{}: {e}", temporary.display()))?;
        let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        std::io::copy(&mut source, &mut encoder).map_err(|e| e.to_string())?;
        let file = encoder.finish().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        verify(&temporary, path)
    })();
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    std::fs::rename(&temporary, &dest).map_err(|e| {
        let _ = std::fs::remove_file(&temporary);
        format!("{}: {e}", dest.display())
    })?;
    Ok(dest.strip_prefix(&store.dir).unwrap_or(&dest).to_string_lossy().into_owned())
}

/// Whether the gzip at `archive` holds exactly the bytes of `original`.
fn verify(archive: &Path, original: &Path) -> Result<(), String> {
    let file = std::fs::File::open(archive).map_err(|e| e.to_string())?;
    let mut decoded = flate2::read::GzDecoder::new(std::io::BufReader::new(file));
    let mut source =
        std::io::BufReader::new(std::fs::File::open(original).map_err(|e| e.to_string())?);
    let (mut a, mut b) = (vec![0u8; 64 * 1024], vec![0u8; 64 * 1024]);
    loop {
        let n = read_full(&mut decoded, &mut a)?;
        let m = read_full(&mut source, &mut b)?;
        if n != m || a[..n] != b[..m] {
            return Err("archive does not match the transcript".into());
        }
        if n == 0 {
            return Ok(());
        }
    }
}

fn read_full(reader: &mut impl Read, buf: &mut [u8]) -> Result<usize, String> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(filled)
}

/// The last-moment checks for one transcript, its archive, then its removal.
pub(crate) fn remove(
    options: &crate::caches::Options,
    family: &Family,
    path: &Path,
) -> Result<Option<Outcome>, Verdict> {
    let Source::Transcripts { open } = &family.source else { return Ok(None) };
    if let Some(glob) = options.never.holds(options.home, path) {
        return Err(keep(format!("never-delete: {glob}")));
    }
    let gone = || keep("no longer a transcript of its family");
    let Ok(meta) = std::fs::symlink_metadata(path) else { return Err(gone()) };
    if !meta.is_file() || !shaped(&family.root, path) || !path.starts_with(options.home) {
        return Err(gone());
    }
    let now = crate::inventory::now_ms();
    let before = (meta.len(), modified_ms(&meta));
    let Some(modified) = before.1 else { return Err(keep("its last change could not be read")) };
    let age = now.saturating_sub(modified);
    if age < age_ms(family) {
        return Err(keep(format!("changed in the last {} days", age_ms(family) / 86_400_000)));
    }
    match (options.uses)() {
        Ok(processes) => {
            if let Some(pid) = owner(&processes, &family.root, path) {
                return Err(keep(format!("its session runs (pid {pid})")));
            }
        }
        Err(error) => return Err(keep(format!("could not check live sessions: {error}"))),
    }
    match open_under(open.0, &family.root) {
        Ok(set) => {
            let real = crate::store::resolved(path);
            if set.contains(path) || set.contains(&real) {
                return Err(keep("open in a running program"));
            }
        }
        Err(error) => return Err(keep(format!("could not check open files: {error}"))),
    }
    let Some(store) = options.store else {
        return Err(keep("no archive store: unique data stays"));
    };
    let id = archive(store, family, path, now).map_err(|e| keep(format!("not archived: {e}")))?;
    let after = std::fs::symlink_metadata(path).map_err(|_| gone())?;
    if (after.len(), modified_ms(&after)) != before {
        return Err(keep("changed while it was archived"));
    }
    Ok(Some(match std::fs::remove_file(path) {
        Ok(()) => Outcome { ok: true, freed: before.0, archive: Some(id), error: None },
        Err(e) => Outcome { ok: false, freed: 0, archive: Some(id), error: Some(e.to_string()) },
    }))
}

#[cfg(test)]
#[path = "transcripts_tests.rs"]
mod tests;
