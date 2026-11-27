//! A projection's upper layer and whiteouts as Bring Back carries them from the machine to the
//! Mac ([`crate::way_back`] plans what they do there). The machine sends the listing first
//! ([`Layer`], no bytes), then only the files the Mac asks for ([`send_files`]), so build output
//! the Mac's rules keep out never crosses the link.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::manifest::Kind;
use crate::way_back::Upper;

/// The most paths a listing holds (a decode refuses more).
const MAX_PATHS: usize = 20_000_000;
/// The most bytes a listing decodes to.
const MAX_DECODED_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// The length a missing file is sent with.
const MISSING: u64 = u64::MAX;

/// What the agent changed: the upper layer's paths (folders before what they hold) and the
/// whiteouts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Layer {
    pub upper: Vec<Upper>,
    pub whiteouts: Vec<String>,
}

fn mtime_of(meta: &fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
}

/// Whether `path` is relative, `/`-separated plain names.
fn plain(path: &str) -> bool {
    !path.is_empty()
        && path.split('/').all(|name| !matches!(name, "" | "." | "..") && !name.contains('\0'))
}

impl Layer {
    /// The layer kept in the projection's state folder `state` (its `upper/` and `whiteouts`);
    /// empty when the projection never wrote anything. Expands the owned git swap link;
    /// preserves every other symlink as a link. Skips what is not a
    /// file, folder or link, and names that are not UTF-8.
    pub fn collect(state: &Path) -> anyhow::Result<Self> {
        let root = state.join("upper");
        let swapped_git = crate::git_swap::swapped_repository(state)?;
        let mut upper = Vec::new();
        let mut stack: Vec<(PathBuf, String)> = Vec::new();
        if fs::symlink_metadata(&root).is_ok_and(|meta| meta.is_dir()) {
            stack.push((root, String::new()));
        }
        while let Some((dir, relative)) = stack.pop() {
            let mut names: Vec<_> = fs::read_dir(&dir)?
                .filter_map(Result::ok)
                .filter_map(|entry| entry.file_name().into_string().ok())
                .collect();
            names.sort();
            let mut below = Vec::new();
            for name in names {
                let path = if relative.is_empty() && name == ".git" {
                    swapped_git.clone().unwrap_or_else(|| dir.join(&name))
                } else {
                    dir.join(&name)
                };
                let Ok(meta) = fs::symlink_metadata(&path) else { continue };
                let child = if relative.is_empty() { name } else { format!("{relative}/{name}") };
                let kind = if meta.is_dir() {
                    Kind::Dir
                } else if meta.file_type().is_symlink() {
                    Kind::Link
                } else if meta.is_file() {
                    Kind::File
                } else {
                    continue;
                };
                let link = match kind {
                    Kind::Link => match fs::read_link(&path)?.into_os_string().into_string() {
                        Ok(text) => Some(text),
                        Err(_) => continue,
                    },
                    _ => None,
                };
                upper.push(Upper {
                    path: child.clone(),
                    kind,
                    size: if kind == Kind::Dir { 0 } else { meta.len() },
                    mode: meta.mode() & 0o7777,
                    mtime_ns: mtime_of(&meta),
                    link,
                });
                if kind == Kind::Dir {
                    below.push((path, child));
                }
            }
            // Depth first, in name order.
            stack.extend(below.into_iter().rev());
        }
        upper.sort_by(|a, b| a.path.cmp(&b.path));
        let whiteouts = fs::read_to_string(state.join("whiteouts"))
            .map(|text| {
                // NUL-ended, as the overlay writes them; an older file of lines still reads.
                let ends = if text.contains('\0') { '\0' } else { '\n' };
                text.split(ends).filter(|path| plain(path)).map(str::to_owned).collect()
            })
            .unwrap_or_default();
        Ok(Self { upper, whiteouts })
    }

    /// The listing as the wire carries it (bincode, then zstd).
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        Ok(zstd::encode_all(bincode::serialize(self)?.as_slice(), 3)?)
    }

    /// A listing from [`Layer::encode`]'s bytes: every path plain, no more than the limits.
    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        let mut raw = Vec::new();
        zstd::Decoder::new(bytes)?.take(MAX_DECODED_BYTES + 1).read_to_end(&mut raw)?;
        anyhow::ensure!(raw.len() as u64 <= MAX_DECODED_BYTES, "the listing is too large");
        let layer: Self = bincode::deserialize(&raw)?;
        anyhow::ensure!(layer.upper.len() + layer.whiteouts.len() <= MAX_PATHS, "too many paths");
        for path in layer.upper.iter().map(|entry| &entry.path).chain(&layer.whiteouts) {
            anyhow::ensure!(plain(path), "bad path {path:?}");
        }
        Ok(layer)
    }
}

/// Writes each of `paths` (files of the upper layer in `state`) to `out` as its length (u64,
/// little-endian) then its bytes; a path that is gone, or is no longer a regular file, as
/// [`MISSING`]. Opens nothing through a symlink at the last name. The bytes sent.
pub fn send_files(state: &Path, paths: &[String], out: &mut impl Write) -> anyhow::Result<u64> {
    let root = state.join("upper");
    let mut sent = 0u64;
    for path in paths {
        anyhow::ensure!(plain(path), "bad path {path:?}");
        let opened = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(root.join(path))
            .ok()
            .filter(|file| file.metadata().is_ok_and(|meta| meta.is_file()));
        let Some(mut file) = opened else {
            out.write_all(&MISSING.to_le_bytes())?;
            continue;
        };
        let len = file.metadata()?.len();
        out.write_all(&len.to_le_bytes())?;
        let copied = std::io::copy(&mut (&mut file).take(len), out)?;
        anyhow::ensure!(copied == len, "{path} shrank while it was sent");
        sent += len;
    }
    out.flush()?;
    Ok(sent)
}

/// Reads [`send_files`]'s stream for `paths` into `into` (each at its relative path, folders made,
/// owner-only), stopping a file at `limit` bytes. Which paths arrived.
pub fn receive_files(
    input: &mut impl Read,
    paths: &[String],
    into: &Path,
    limit: u64,
) -> anyhow::Result<Vec<bool>> {
    let mut arrived = Vec::with_capacity(paths.len());
    for path in paths {
        anyhow::ensure!(plain(path), "bad path {path:?}");
        let mut len = [0u8; 8];
        input.read_exact(&mut len)?;
        let len = u64::from_le_bytes(len);
        if len == MISSING {
            arrived.push(false);
            continue;
        }
        anyhow::ensure!(len <= limit, "{path} is larger than {limit} bytes");
        let target = into.join(path);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&target)?;
        let copied = std::io::copy(&mut input.take(len), &mut file)?;
        anyhow::ensure!(copied == len, "the stream ended inside {path}");
        arrived.push(true);
    }
    Ok(arrived)
}

#[cfg(test)]
#[path = "layer_tests.rs"]
mod tests;
