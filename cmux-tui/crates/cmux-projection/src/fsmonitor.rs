//! git's fsmonitor hook answered by the projection (RFD 0007, hard case 2): every change made
//! through the mount is a path in a [`Journal`], so `git status` on a projected repo asks the
//! projection what changed since its last run instead of `lstat`ing every tracked file across the
//! link. The manifest is fixed for the life of a mount, so the journal is the whole truth.
//!
//! - git runs `core.fsmonitor` (hook protocol version 2) with its last token; the hook
//!   ([`hook`]) asks the projection over a Unix socket, and prints the new token, a NUL, and the
//!   changed paths of its worktree, each ended by a NUL. A token from another mount, or one older
//!   than what the journal still holds, is answered with `/` (everything changed): git checks
//!   every file once, as it does with no hook.
//! - A fresh mount writes the repo's index again with an `FSMN` extension ([`prime`]): the entries
//!   whose `stat` in the manifest matches what the index recorded are clean as of the journal's
//!   first token, so even the first `git status` checks only what changed since.
//! - The hook exits non-zero when it gets no answer: git then checks every file, never trusts a
//!   stale one.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read as _, Write as _};
use std::path::Path;
use std::sync::{Mutex, PoisonError};

/// The token's prefix, so a token another tool wrote is never read as one of ours.
const PREFIX: &str = "cmux-projection";
/// The most distinct paths the journal holds; past it, every older token reads as "everything
/// changed" (git checks every file once) and the journal starts over.
pub const MAX_PATHS: usize = 250_000;
/// The socket's request: `fsmonitor 2`, the token, the worktree relative to the mount, each ended
/// by a NUL.
const REQUEST: &[u8] = b"fsmonitor 2\0";

/// Changes made through the mount, by when, so git's fsmonitor hook can ask what changed since a
/// token. Off until the first token is given out: a mount nobody runs git on keeps nothing.
pub struct Journal {
    instance: u64,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    on: bool,
    seq: u64,
    /// Tokens below this read as "everything changed".
    floor: u64,
    /// The last token given out: a path noted since is already new to every token holder.
    asked: u64,
    by_seq: BTreeMap<u64, String>,
    latest: HashMap<String, u64>,
}

/// What changed since a token.
#[derive(Debug, PartialEq, Eq)]
pub enum Since {
    /// Everything (an unknown token, or one the journal no longer reaches).
    All,
    /// These paths (relative to the mount; a folder ends in `/`).
    Paths(Vec<String>),
}

impl Journal {
    /// A journal whose tokens name `instance` (unique to one overlay: a token of another mount,
    /// or of an earlier daemon, is unknown).
    #[must_use]
    pub fn new(instance: u64) -> Self {
        Self { instance, inner: Mutex::new(Inner::default()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Records that `path` (relative to the mount) changed. Cheap when nobody asked since its last
    /// change (a hot file's every write costs one map lookup).
    pub fn note(&self, path: &str) {
        let mut inner = self.lock();
        if !inner.on {
            return;
        }
        let asked = inner.asked;
        if inner.latest.get(path).is_some_and(|seq| *seq > asked) {
            return;
        }
        inner.seq += 1;
        let seq = inner.seq;
        if let Some(old) = inner.latest.insert(path.to_owned(), seq) {
            inner.by_seq.remove(&old);
        }
        inner.by_seq.insert(seq, path.to_owned());
        if inner.latest.len() > MAX_PATHS {
            inner.by_seq.clear();
            inner.latest.clear();
            inner.floor = seq;
        }
    }

    /// Records that folder `path` changed (moved, or everything under it).
    pub fn note_dir(&self, path: &str) {
        self.note(&format!("{path}/"));
    }

    /// A token for now (and the journal on from here).
    pub fn token(&self) -> String {
        let mut inner = self.lock();
        inner.on = true;
        inner.asked = inner.seq;
        format!("{PREFIX}:{:016x}:{}", self.instance, inner.seq)
    }

    /// What changed since `token`, and the token for now.
    pub fn since(&self, token: &str) -> (Since, String) {
        let mut inner = self.lock();
        let seq =
            self.parse(token).filter(|seq| inner.on && *seq >= inner.floor && *seq <= inner.seq);
        let since = match seq {
            None => Since::All,
            Some(seq) => {
                Since::Paths(inner.by_seq.range(seq + 1..).map(|(_, path)| path.clone()).collect())
            }
        };
        inner.on = true;
        inner.asked = inner.seq;
        (since, format!("{PREFIX}:{:016x}:{}", self.instance, inner.seq))
    }

    fn parse(&self, token: &str) -> Option<u64> {
        let rest = token.strip_prefix(PREFIX)?.strip_prefix(':')?;
        let (instance, seq) = rest.split_once(':')?;
        (u64::from_str_radix(instance, 16).ok()? == self.instance).then_some(())?;
        seq.parse().ok()
    }
}

/// The hook's answer for worktree `tree` (relative to the mount, `""` for its root): the new
/// token, a NUL, then each changed path of the worktree relative to it, ended by a NUL. Paths in
/// the repo's own `.git` are left out (git ignores them, and writes its index there every run).
#[must_use]
pub fn answer(since: &Since, token: &str, tree: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(token.len() + 1);
    out.extend_from_slice(token.as_bytes());
    out.push(0);
    match since {
        Since::All => out.extend_from_slice(b"/\0"),
        Since::Paths(paths) => {
            let prefix = if tree.is_empty() { String::new() } else { format!("{tree}/") };
            for path in paths {
                let Some(rel) = path.strip_prefix(prefix.as_str()) else { continue };
                if rel.is_empty() || rel == ".git" || rel.starts_with(".git/") {
                    continue;
                }
                out.extend_from_slice(rel.as_bytes());
                out.push(0);
            }
        }
    }
    out
}

/// Reads one request off `stream` and writes the answer from `journal`.
pub fn serve_one(
    journal: &Journal,
    stream: &mut (impl std::io::Read + std::io::Write),
) -> std::io::Result<()> {
    let mut request = Vec::new();
    stream.read_to_end(&mut request)?;
    let fields: Vec<&[u8]> =
        request.strip_prefix(REQUEST).unwrap_or_default().split(|b| *b == 0).collect();
    let (Some(token), Some(tree)) = (fields.first(), fields.get(1)) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "not an fsmonitor request",
        ));
    };
    let token = String::from_utf8_lossy(token);
    let tree = String::from_utf8_lossy(tree);
    let tree = tree.trim_matches('/');
    let (since, now) = journal.since(&token);
    stream.write_all(&answer(&since, &now, tree))
}

/// git's fsmonitor hook: asks the projection serving `socket` (mounted at `mount`) what changed
/// in the worktree `cwd` since `token`, and returns what the hook prints. An error means no
/// answer: the hook must exit non-zero so git checks every file.
pub fn hook(
    socket: &Path,
    mount: &Path,
    cwd: &Path,
    version: &str,
    token: &str,
) -> std::io::Result<Vec<u8>> {
    use std::os::unix::net::UnixStream;
    if version != "2" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "fsmonitor hook version 2 only",
        ));
    }
    let tree = cwd.strip_prefix(mount).map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "the worktree is not in the mount")
    })?;
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;
    let mut request = REQUEST.to_vec();
    request.extend_from_slice(token.as_bytes());
    request.push(0);
    request.extend_from_slice(tree.as_os_str().as_encoded_bytes());
    request.push(0);
    stream.write_all(&request)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut out = Vec::new();
    stream.read_to_end(&mut out)?;
    if !out.contains(&0) {
        return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no answer"));
    }
    Ok(out)
}

/// The hook as a command: `SOCKET MOUNT VERSION [TOKEN]` (git appends the last two), the answer
/// printed on stdout. An error is no answer: the caller exits non-zero.
pub fn run_hook(args: &[String]) -> std::io::Result<()> {
    let [socket, mount, version, rest @ ..] = args else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "usage: fsmonitor-hook SOCKET MOUNT VERSION [TOKEN]",
        ));
    };
    let token = rest.first().map_or("", String::as_str);
    let mount = std::fs::canonicalize(mount)?;
    let cwd = std::env::current_dir()?;
    let out = hook(Path::new(socket), &mount, &cwd, version, token)?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(&out)?;
    stdout.flush()
}

/// One entry of a git index, as [`prime`] shows it to its judge.
#[derive(Debug)]
pub struct IndexEntry<'a> {
    pub path: &'a [u8],
    pub mode: u32,
    pub mtime_s: u32,
    pub size: u32,
    /// Stage, skip-worktree or intent-to-add set: never judged clean.
    pub special: bool,
}

/// `index` (a git index file's bytes) with an `FSMN` extension naming `token`, every entry `clean`
/// judges unchanged marked so, the rest dirty. `None` when the index is one this cannot rewrite
/// (an unknown version, a split index, a bad checksum): git then checks every file, as before.
pub fn prime(
    index: &[u8],
    token: &str,
    mut clean: impl FnMut(&IndexEntry<'_>) -> bool,
) -> Option<Vec<u8>> {
    let header = index.get(..12)?;
    if header.get(..4)? != b"DIRC" {
        return None;
    }
    let version = be32(index, 4)?;
    let count = be32(index, 8)? as usize;
    if !(2..=4).contains(&version) {
        return None;
    }
    // A SHA-1 repo's object ids and trailer are 20 bytes, a SHA-256 repo's 32; a trailer of zeros
    // (`index.skipHash`) says neither, so both are tried.
    for len in [20usize, 32] {
        let body_end = index.len().checked_sub(len)?;
        let tail = index.get(body_end..)?;
        let skip_hash = tail.iter().all(|b| *b == 0);
        if !skip_hash && checksum(index.get(..body_end)?, len) != tail {
            continue;
        }
        if let Some(primed) =
            prime_with(index, version, count, len, body_end, skip_hash, token, &mut clean)
        {
            return Some(primed);
        }
    }
    None
}

#[allow(clippy::too_many_arguments)]
fn prime_with(
    index: &[u8],
    version: u32,
    count: usize,
    oid_len: usize,
    body_end: usize,
    skip_hash: bool,
    token: &str,
    clean: &mut impl FnMut(&IndexEntry<'_>) -> bool,
) -> Option<Vec<u8>> {
    let mut at = 12usize;
    let mut name: Vec<u8> = Vec::new();
    let mut dirty = vec![0u64; count.div_ceil(64)];
    for i in 0..count {
        let fixed = 40 + oid_len + 2;
        let start = at;
        let mode = be32(index, start + 24)?;
        let mtime_s = be32(index, start + 8)?;
        let size = be32(index, start + 36)?;
        let flags =
            u16::from_be_bytes(index.get(start + 40 + oid_len..start + fixed)?.try_into().ok()?);
        let mut special = flags & 0x3000 != 0;
        at = start + fixed;
        if flags & 0x4000 != 0 {
            if version < 3 {
                return None;
            }
            let extended = u16::from_be_bytes(index.get(at..at + 2)?.try_into().ok()?);
            special |= extended & 0x6000 != 0;
            at += 2;
        }
        if version == 4 {
            let (strip, used) = varint(index.get(at..)?)?;
            at += used;
            let end = at + index.get(at..)?.iter().position(|b| *b == 0)?;
            name.truncate(name.len().checked_sub(usize::try_from(strip).ok()?)?);
            name.extend_from_slice(index.get(at..end)?);
            at = end + 1;
        } else {
            let end = at + index.get(at..)?.iter().position(|b| *b == 0)?;
            name.clear();
            name.extend_from_slice(index.get(at..end)?);
            // Entries are padded with 1 to 8 NULs to a multiple of 8.
            at = start + ((end - start) + 8) / 8 * 8;
        }
        if at > body_end {
            return None;
        }
        let entry = IndexEntry { path: &name, mode, mtime_s, size, special };
        if !clean(&entry) {
            *dirty.get_mut(i / 64)? |= 1 << (i % 64);
        }
    }
    let entries_end = at;
    // Extensions: keep each but an old FSMN and the EOIE (its offsets would be wrong).
    let mut kept = Vec::new();
    while at < body_end {
        let sig = index.get(at..at + 4)?;
        let len = be32(index, at + 4)? as usize;
        let end = at.checked_add(8)?.checked_add(len)?;
        if end > body_end {
            return None;
        }
        match sig {
            b"link" => return None,
            b"FSMN" | b"EOIE" => {}
            _ => kept.extend_from_slice(index.get(at..end)?),
        }
        at = end;
    }
    if at != body_end {
        return None;
    }
    let mut out = Vec::with_capacity(body_end + 64 + dirty.len() * 8);
    out.extend_from_slice(index.get(..entries_end)?);
    out.extend_from_slice(&kept);
    out.extend_from_slice(&fsmn(token, count, &dirty));
    if skip_hash {
        out.extend(std::iter::repeat_n(0, oid_len));
    } else {
        let sum = checksum(&out, oid_len);
        out.extend_from_slice(&sum);
    }
    Some(out)
}

fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// git's offset varint (`decode_varint`).
fn varint(bytes: &[u8]) -> Option<(u64, usize)> {
    let mut used = 0;
    let mut byte = *bytes.first()?;
    used += 1;
    let mut value = u64::from(byte & 0x7f);
    while byte & 0x80 != 0 {
        byte = *bytes.get(used)?;
        used += 1;
        value = value.checked_add(1)?.checked_mul(128)? | u64::from(byte & 0x7f);
    }
    Some((value, used))
}

fn checksum(bytes: &[u8], len: usize) -> Vec<u8> {
    use sha1::Digest as _;
    if len == 20 {
        sha1::Sha1::digest(bytes).to_vec()
    } else {
        sha2::Sha256::digest(bytes).to_vec()
    }
}

/// The `FSMN` extension (version 2): `token`, and the bitmap of dirty entries, EWAH-encoded as
/// one marker word followed by every word literally.
fn fsmn(token: &str, count: usize, dirty: &[u64]) -> Vec<u8> {
    let mut ewah = Vec::with_capacity(12 + 8 + dirty.len() * 8);
    ewah.extend_from_slice(&u32::try_from(count).unwrap_or(u32::MAX).to_be_bytes());
    ewah.extend_from_slice(&u32::try_from(dirty.len() + 1).unwrap_or(u32::MAX).to_be_bytes());
    ewah.extend_from_slice(&((dirty.len() as u64) << 33).to_be_bytes());
    for word in dirty {
        ewah.extend_from_slice(&word.to_be_bytes());
    }
    ewah.extend_from_slice(&0u32.to_be_bytes());
    let mut data = Vec::with_capacity(4 + token.len() + 1 + 4 + ewah.len());
    data.extend_from_slice(&2u32.to_be_bytes());
    data.extend_from_slice(token.as_bytes());
    data.push(0);
    data.extend_from_slice(&u32::try_from(ewah.len()).unwrap_or(u32::MAX).to_be_bytes());
    data.extend_from_slice(&ewah);
    let mut out = Vec::with_capacity(8 + data.len());
    out.extend_from_slice(b"FSMN");
    out.extend_from_slice(&u32::try_from(data.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(&data);
    out
}

#[cfg(test)]
#[path = "fsmonitor_tests.rs"]
mod tests;
