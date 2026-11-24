//! Git LFS files in a seed (RFD 0066 piece 13): which tracked files are LFS pointers, and for
//! each, whether the Mac holds the real content (`.git/lfs/objects/aa/bb/<oid>`) or only the
//! pointer because the object was never fetched.
//!
//! The work commit stores what git's clean filter produced: a pointer file of a few lines. The
//! bundle carries pointers, never content, and the machine can pull content only for objects
//! GitHub has. So content only this Mac has is named ([`skipped`]) and can be staged for
//! upload ([`stage_objects`], which checks every object's SHA-256 first). Off unless
//! `CMUX_SEED_LFS` is `1`: [`enabled`].

use std::io::{Read as _, Seek as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use sha2::{Digest as _, Sha256};

use super::git;
use super::plan::Skipped;

/// A pointer file is a few short lines; git-lfs itself stops reading at this size.
const POINTER_MAX: usize = 1024;
const VERSION: &str = "version https://git-lfs.github.com/spec/v1";

/// What a pointer file names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pointer {
    /// Lowercase hex SHA-256 of the content.
    pub oid: String,
    pub size: u64,
}

/// One LFS-tracked file of the work commit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LfsFile {
    pub path: String,
    pub oid: String,
    pub size: u64,
    /// The Mac holds the whole content in its LFS store.
    pub present: bool,
}

/// Whether the seed looks at LFS files at all (`CMUX_SEED_LFS=1`).
pub fn enabled() -> bool {
    std::env::var("CMUX_SEED_LFS").is_ok_and(|value| value == "1")
}

/// The pointer a file's bytes spell, or None when they are anything else (real content that
/// was committed without the filter, a text file, a look-alike).
pub fn parse_pointer(bytes: &[u8]) -> Option<Pointer> {
    if bytes.len() > POINTER_MAX {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.lines();
    if lines.next()? != VERSION {
        return None;
    }
    let (mut oid, mut size) = (None, None);
    for line in lines {
        if let Some(rest) = line.strip_prefix("oid sha256:") {
            let valid =
                rest.len() == 64 && rest.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
            if !valid || oid.replace(rest.to_owned()).is_some() {
                return None;
            }
        } else if let Some(rest) = line.strip_prefix("size ") {
            if size.replace(rest.parse::<u64>().ok()?).is_some() {
                return None;
            }
        }
    }
    Some(Pointer { oid: oid?, size: size? })
}

/// Where the LFS store keeps an object under `lfs_dir` (`.git/lfs`).
pub fn object_path(lfs_dir: &Path, oid: &str) -> PathBuf {
    lfs_dir.join("objects").join(&oid[0..2]).join(&oid[2..4]).join(oid)
}

fn holds(lfs_dir: &Path, pointer: &Pointer) -> bool {
    std::fs::metadata(object_path(lfs_dir, &pointer.oid))
        .is_ok_and(|meta| meta.is_file() && meta.len() == pointer.size)
}

/// Every LFS pointer in `commit`'s tree, sorted by path, with whether its content is in
/// `lfs_dir`. Empty when git cannot say.
pub(super) fn scan(top: &Path, lfs_dir: &Path, commit: &str) -> Vec<LfsFile> {
    scan_inner(top, lfs_dir, commit).unwrap_or_default()
}

fn scan_inner(top: &Path, lfs_dir: &Path, commit: &str) -> Result<Vec<LfsFile>, String> {
    let listing = git::output(git::at(top).args(["ls-tree", "-r", "-l", "-z", commit]))?;
    // `<mode> blob <oid> <size>\t<path>` per NUL-terminated entry.
    let mut candidates: Vec<(String, String)> = Vec::new();
    for entry in listing.split(|b| *b == 0).filter(|entry| !entry.is_empty()) {
        let Some(tab) = entry.iter().position(|b| *b == b'\t') else { continue };
        let meta = String::from_utf8_lossy(&entry[..tab]);
        let fields: Vec<&str> = meta.split_whitespace().collect();
        let [mode, kind, oid, size] = fields[..] else { continue };
        if kind != "blob" || mode == "120000" {
            continue;
        }
        if size.parse::<usize>().is_ok_and(|size| size <= POINTER_MAX) {
            candidates
                .push((oid.to_owned(), String::from_utf8_lossy(&entry[tab + 1..]).into_owned()));
        }
    }
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    // The oids go in through a file, so a full pipe cannot stall git.
    let mut input = tempfile::tempfile().map_err(|error| error.to_string())?;
    for (oid, _) in &candidates {
        writeln!(input, "{oid}").map_err(|error| error.to_string())?;
    }
    input.rewind().map_err(|error| error.to_string())?;
    let mut command = git::at(top);
    command.args(["cat-file", "--batch"]).stdin(Stdio::from(input)).stdout(Stdio::piped());
    let mut child = command.spawn().map_err(|error| format!("cannot run git: {error}"))?;
    let mut out = Vec::new();
    child.stdout.take().ok_or("no stdout")?.read_to_end(&mut out).map_err(|e| e.to_string())?;
    let status = child.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err(format!("git cat-file exited with {status}"));
    }
    let mut files = Vec::new();
    let mut at = 0;
    for (_, path) in candidates {
        let Some(nl) = out[at..].iter().position(|b| *b == b'\n') else { break };
        let header = String::from_utf8_lossy(&out[at..at + nl]).into_owned();
        at += nl + 1;
        let Some(len) = header.split(' ').nth(2).and_then(|len| len.parse::<usize>().ok()) else {
            continue; // `<oid> missing`: no body follows
        };
        let body = out.get(at..at + len).ok_or("short cat-file answer")?;
        at += len + 1;
        if let Some(pointer) = parse_pointer(body) {
            let present = holds(lfs_dir, &pointer);
            files.push(LfsFile { path, oid: pointer.oid, size: pointer.size, present });
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// The files whose pointer the bundle carries but whose content the Mac does not hold, named
/// the way the plan names what it left out.
pub fn skipped(files: &[LfsFile]) -> Vec<Skipped> {
    files
        .iter()
        .filter(|file| !file.present)
        .map(|file| Skipped {
            path: file.path.clone(),
            why: format!(
                "LFS file not fetched on this Mac ({} bytes); only its pointer goes",
                file.size
            ),
            raw: file.path.as_bytes().to_vec(),
        })
        .collect()
}

/// Copies the content of every present file into `dest/objects/aa/bb/<oid>` (the layout of
/// `.git/lfs`), once per object, after checking its SHA-256 against the pointer. Returns the
/// bytes staged. A mismatch is an error naming the file: nothing corrupt is sent.
pub fn stage_objects(files: &[LfsFile], lfs_dir: &Path, dest: &Path) -> Result<u64, String> {
    let mut total = 0;
    let mut seen = std::collections::BTreeSet::new();
    for file in files.iter().filter(|file| file.present) {
        if !seen.insert(file.oid.as_str()) {
            continue;
        }
        let from = object_path(lfs_dir, &file.oid);
        let bytes = std::fs::read(&from).map_err(|error| format!("{}: {error}", file.path))?;
        let digest: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        if digest != file.oid {
            return Err(format!("{}: LFS object does not match its pointer", file.path));
        }
        let to = object_path(dest, &file.oid);
        std::fs::create_dir_all(to.parent().ok_or("no parent")?).map_err(|e| e.to_string())?;
        std::fs::write(&to, &bytes).map_err(|error| format!("{}: {error}", file.path))?;
        total += file.size;
    }
    Ok(total)
}
