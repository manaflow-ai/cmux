//! Seeding a replica from a machine's working tree at pause (M20 follow-up 1, minimal).
//!
//! A pause copies the machine's folder into a folder of the daemon's own, once, while nothing
//! runs on the machine. The copy has bounds ([`SeedBounds`]): a file over the size bound, a
//! link, `.git` and anything that is not a plain file or folder are left out, and the copy stops
//! once it holds the file or byte budget. A path left out answers [`ReplicaRead::MachineOnly`];
//! a path missing from a copy that stopped early does too, because the copy cannot say it is
//! absent. Each seed has a generation of its own, so an answer names the snapshot it came from.

use super::STAGING_PREFIX;
use super::replica::{DirReplica, ReplicaRead, ReplicaSource};
use std::collections::BTreeSet;
use std::io;
use std::path::{Path, PathBuf};

/// How much one seed may copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SeedBounds {
    pub max_files: usize,
    pub max_total_bytes: u64,
    pub max_file_bytes: u64,
}

impl Default for SeedBounds {
    fn default() -> Self {
        Self {
            max_files: 20_000,
            max_total_bytes: 256 << 20,
            max_file_bytes: DirReplica::DEFAULT_MAX_FILE_BYTES,
        }
    }
}

/// What a seed copied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeedReport {
    pub generation: u64,
    pub files: usize,
    pub bytes: u64,
    /// Paths left out (links, `.git`, files over the size bound, names that are not UTF-8).
    pub left_out: usize,
    /// False when a budget ran out before the whole folder was copied.
    pub complete: bool,
}

/// A replica a seed made: the copy, and what it does not hold.
pub struct SeededReplica {
    dir: DirReplica,
    left_out: BTreeSet<String>,
    complete: bool,
}

impl SeededReplica {
    pub fn root(&self) -> &Path {
        self.dir.root()
    }

    /// Anything ran on the machine: the copy no longer answers for it.
    pub fn invalidate(&self) {
        self.dir.invalidate();
    }

    fn left_out(&self, path: &str) -> bool {
        let mut at = 0;
        loop {
            let end = path.get(at..).and_then(|rest| rest.find('/')).map(|i| at + i);
            let prefix = end.map_or(path, |e| path.get(..e).unwrap_or(path));
            if self.left_out.contains(prefix) {
                return true;
            }
            match end {
                Some(e) => at = e + 1,
                None => return false,
            }
        }
    }
}

impl ReplicaSource for SeededReplica {
    fn generation(&self) -> u64 {
        self.dir.generation()
    }

    fn is_fresh(&self) -> bool {
        self.dir.is_fresh()
    }

    fn read(&self, path: &str) -> io::Result<ReplicaRead> {
        if self.left_out(path) {
            return Ok(ReplicaRead::MachineOnly);
        }
        match self.dir.read(path)? {
            ReplicaRead::Absent if !self.complete => Ok(ReplicaRead::MachineOnly),
            read => Ok(read),
        }
    }
}

/// Copies `machine_root` into `into` (made new; anything already there is removed first, it is
/// the daemon's own) within `bounds`, as snapshot `generation`.
pub fn seed(
    machine_root: &Path,
    into: &Path,
    bounds: SeedBounds,
    generation: u64,
) -> io::Result<(SeededReplica, SeedReport)> {
    match crate::home_fs::remove_dir_all(into) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    crate::home_fs::create_dirs(into)?;
    let mut report = SeedReport { generation, files: 0, bytes: 0, left_out: 0, complete: true };
    let mut left_out = BTreeSet::new();
    // Sorted, so a seed that stops early stops at the same place every time.
    let mut stack: Vec<(PathBuf, String)> = vec![(machine_root.to_path_buf(), String::new())];
    'walk: while let Some((dir, rel)) = stack.pop() {
        let mut names: Vec<_> = std::fs::read_dir(&dir)?.collect::<io::Result<Vec<_>>>()?;
        names.sort_by_key(std::fs::DirEntry::file_name);
        let mut folders = Vec::new();
        for entry in names {
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                // Not a name a journal path can carry: the copy cannot say what is absent.
                report.complete = false;
                continue;
            };
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            let kind = entry.file_type()?;
            if name == ".git" || name.starts_with(STAGING_PREFIX) || kind.is_symlink() {
                left_out.insert(path);
                continue;
            }
            if kind.is_dir() {
                crate::home_fs::create_dirs(into.join(&path))?;
                folders.push((entry.path(), path));
                continue;
            }
            if !kind.is_file() {
                left_out.insert(path);
                continue;
            }
            let len = entry.metadata()?.len();
            if len > bounds.max_file_bytes {
                left_out.insert(path);
                continue;
            }
            if report.files >= bounds.max_files
                || report.bytes.saturating_add(len) > bounds.max_total_bytes
            {
                report.complete = false;
                break 'walk;
            }
            let bytes = std::fs::read(entry.path())?;
            crate::home_fs::write(into.join(&path), &bytes)?;
            report.files += 1;
            report.bytes = report.bytes.saturating_add(bytes.len() as u64);
        }
        // Popped in name order.
        stack.extend(folders.into_iter().rev());
    }
    report.left_out = left_out.len();
    let dir = DirReplica::with_generation(into, bounds.max_file_bytes, generation);
    Ok((SeededReplica { dir, left_out, complete: report.complete }, report))
}
