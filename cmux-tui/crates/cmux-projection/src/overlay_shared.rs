//! The shared content store behind a projection's disk store (RFD 0065, piece 12): blobs by the
//! SHA-256 of their bytes, per team, so a second machine, or one a day behind, fetches from it only
//! what it does not hold. [`super::content::Content::fetch`] reads through to it; a blob the
//! overlay fetched is published to it (only when publishing is on).
//!
//! A blob over [`crate::cdc::PROJECTION_MIN_FILE`] is published as its content-defined chunks
//! (piece 13, 64 KiB average) and a recipe under the blob's own hash, so a machine holding last
//! week's version of a big file fetches only the chunks an edit changed.
//!
//! **Off by default.** Whether a person's repo contents belong in a store of ours by default is an
//! open question in RFD 0065, so nothing is read from or written to a shared store unless the
//! machine's environment says so:
//!
//! - `CMUX_PROJECTION_SHARED_STORE`: unset, empty, `0` or `off` (the default): no shared store.
//!   `dir:<absolute path>`: a folder every machine of the team mounts (a host's disk, a network
//!   file system); it costs nothing new. `bucket`: a team bucket, a stub for now (see
//!   [`BUCKET_MISSING`]).
//! - `CMUX_PROJECTION_SHARED_TEAM`: the team, one plain path segment; blobs sit under
//!   `<store>/<team>/`, so no team reads another's. Required.
//! - `CMUX_PROJECTION_SHARED_PUBLISH`: `1` to write fetched blobs to it; without it the machine
//!   only reads.
//!
//! Every byte read from a shared store is hashed against the name it was asked by before it is
//! kept or served, so the store is untrusted transport, as the blob chain's stores are.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// The switch: which shared store, if any.
pub const SWITCH: &str = "CMUX_PROJECTION_SHARED_STORE";
/// The team whose blobs a machine reads and writes.
pub const TEAM: &str = "CMUX_PROJECTION_SHARED_TEAM";
/// `1`: publish fetched blobs, not only read.
pub const PUBLISH: &str = "CMUX_PROJECTION_SHARED_PUBLISH";

/// What a team bucket still needs before `bucket` can do anything: each costs money or is a
/// decision, so none is made here.
pub const BUCKET_MISSING: &str = "a team bucket for shared projection blobs (none exists; \
     creating one is paid storage), write keys for it on agent machines, and a PUT by raw \
     SHA-256 in s3.rs (Store::push takes git object ids only)";

/// A store of blobs by key: the SHA-256 of a blob's bytes, or of a chunk's. What it answers is
/// unverified; the caller hashes it.
pub trait Shared: Send + Sync {
    fn get(&self, key: &[u8; 32]) -> Option<Vec<u8>>;
    fn has(&self, key: &[u8; 32]) -> bool;
    /// Stores `bytes` under `key`; false when it could not.
    fn put(&self, key: &[u8; 32], bytes: &[u8]) -> bool;
    /// Whether this machine publishes to it.
    fn publishes(&self) -> bool;
}

fn hex(key: &[u8; 32]) -> String {
    key.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A shared folder: `<root>/<team>/<first two hex>/<hex>`.
pub struct Dir {
    root: PathBuf,
    publish: bool,
    temp: AtomicU64,
}

impl Dir {
    /// The team's part of the folder at `root` (made when publishing).
    #[must_use]
    pub fn new(root: &Path, team: &str, publish: bool) -> Self {
        Self { root: root.join(team), publish, temp: AtomicU64::new(0) }
    }

    fn path(&self, key: &[u8; 32]) -> PathBuf {
        let name = hex(key);
        let fan = name.get(..2).unwrap_or_default().to_owned();
        self.root.join(fan).join(name)
    }
}

impl Shared for Dir {
    fn get(&self, key: &[u8; 32]) -> Option<Vec<u8>> {
        fs::read(self.path(key)).ok()
    }

    fn has(&self, key: &[u8; 32]) -> bool {
        self.path(key).is_file()
    }

    fn put(&self, key: &[u8; 32], bytes: &[u8]) -> bool {
        if !self.publish {
            return false;
        }
        let path = self.path(key);
        let Some(folder) = path.parent() else { return false };
        if fs::create_dir_all(folder).is_err() {
            return false;
        }
        // Written aside and renamed in, so a reader on another machine never sees half a blob.
        let temp = folder.join(format!(
            ".tmp-{}-{}",
            std::process::id(),
            self.temp.fetch_add(1, Ordering::Relaxed)
        ));
        if fs::write(&temp, bytes).and_then(|()| fs::rename(&temp, &path)).is_ok() {
            return true;
        }
        let _ = fs::remove_file(&temp);
        false
    }

    fn publishes(&self) -> bool {
        self.publish
    }
}

fn plain_segment(team: &str) -> bool {
    !team.is_empty()
        && team != "."
        && team != ".."
        && team
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

/// The shared store `lookup` (an environment) names: `Ok(None)` when the switch is off, `Err`
/// saying why when it is on but unusable.
pub fn from_lookup(
    lookup: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<Arc<dyn Shared>>, String> {
    let switch = lookup(SWITCH).unwrap_or_default();
    let switch = switch.trim();
    if matches!(switch, "" | "0" | "off" | "false" | "no") {
        return Ok(None);
    }
    let team = lookup(TEAM).unwrap_or_default();
    let team = team.trim();
    if !plain_segment(team) {
        return Err(format!("{TEAM} {team:?} is not one plain path segment"));
    }
    let publish =
        lookup(PUBLISH).is_some_and(|value| matches!(value.trim(), "1" | "true" | "yes" | "on"));
    if let Some(root) = switch.strip_prefix("dir:") {
        let root = Path::new(root);
        if !root.is_absolute() {
            return Err(format!("{SWITCH} dir:{} is not an absolute path", root.display()));
        }
        return Ok(Some(Arc::new(Dir::new(root, team, publish))));
    }
    if switch == "bucket" {
        return Err(format!("{SWITCH}=bucket is not built yet; missing: {BUCKET_MISSING}"));
    }
    Err(format!("{SWITCH} {switch:?} is not off, dir:<path> or bucket"))
}

/// [`from_lookup`] of the process environment; an unusable setting is logged and is no store.
#[must_use]
pub fn from_env() -> Option<Arc<dyn Shared>> {
    match from_lookup(&|name| std::env::var(name).ok()) {
        Ok(shared) => shared,
        Err(why) => {
            eprintln!("cmux-projection: shared content store off: {why}");
            None
        }
    }
}

/// What reads through to the shared store moved, for the mount's timing line and the tests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Transfer {
    /// Blobs the shared store supplied.
    pub hits: u64,
    /// Bytes fetched from it (whole blobs and chunks).
    pub fetched: u64,
    /// Bytes of chunks the disk store already held, so not fetched.
    pub reused: u64,
}

/// A recipe: a big blob's size and its chunks' hashes and lengths, in order.
pub(super) type Chunks = Vec<([u8; 32], u32)>;

pub(super) const RECIPE_MAGIC: &[u8] = b"cmux-cdc1\n";

pub(super) fn encode_recipe(size: u64, chunks: &[([u8; 32], u32)]) -> Vec<u8> {
    let mut out = Vec::with_capacity(RECIPE_MAGIC.len() + 8 + chunks.len() * 36);
    out.extend_from_slice(RECIPE_MAGIC);
    out.extend_from_slice(&size.to_le_bytes());
    for (hash, len) in chunks {
        out.extend_from_slice(hash);
        out.extend_from_slice(&len.to_le_bytes());
    }
    out
}

/// The recipe in `bytes`, or `None` when it is not one or its lengths do not add up to its size.
pub(super) fn decode_recipe(bytes: &[u8]) -> Option<(u64, Chunks)> {
    let rest = bytes.strip_prefix(RECIPE_MAGIC)?;
    let (size, rest) = rest.split_first_chunk::<8>()?;
    let size = u64::from_le_bytes(*size);
    if rest.len() % 36 != 0 {
        return None;
    }
    let chunks: Chunks = rest
        .chunks_exact(36)
        .filter_map(|record| {
            let (hash, len) = record.split_first_chunk::<32>()?;
            Some((*hash, u32::from_le_bytes(len.try_into().ok()?)))
        })
        .collect();
    let total: u64 = chunks.iter().map(|(_, len)| u64::from(*len)).sum();
    (total == size).then_some((size, chunks))
}

#[cfg(test)]
#[path = "overlay_shared_tests.rs"]
mod tests;
