//! A chat's large, rarely-changing metadata (its agent's slash commands, `availableCommands`, and
//! its tool rows, `tools.rows`) kept beside `session.json` in `session.parts.json`, written only
//! when that content changes. Every other metadata change (a composer draft keystroke, a status, a
//! title, `updatedAt`) writes `session.json` and its journal record without them, so a save costs
//! the same for a chat whose agent lists 700 KB of commands and 250 KB of tools as for one with
//! none. Before, each such save wrote the whole metadata: ~1.09 MB per draft edit on a chat with
//! many skills and MCP servers, 93% of it these two fields (disk-write reports of
//! `Hub::set_composer_draft` -> `meta_save`, 8.6 GB in a day).
//!
//! Format. A `session.json` the store writes without them says so with `metaParts` (the parts'
//! fingerprint); a reader then takes them from `session.parts.json`. A `session.json` without
//! `metaParts` (an older build's, an import's, a bundle's) is read as it is, its inline fields and
//! all, and the next save moves them out. The store's own copies elsewhere (a bundle, an export,
//! the protocol) are serialized whole: only the store's writes split.
//!
//! An older daemon reading a split `session.json` sees no commands and no tool rows (both
//! default to empty, `tools.off` and `tools.mutable` stay in `session.json`): it lists the chat,
//! and shows its slash commands and tool rows again once the agent reports them at its next
//! start. Both are caches of what the agent reports, so a crash that keeps an older parts file
//! than its `session.json` shows the older list until the agent's next report, never loses a
//! person's setting.

use super::{SessionMeta, ToolInventory, ToolRow};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cell::Cell;
use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;

/// The parts file in a chat's folder.
pub const PARTS_FILE: &str = "session.parts.json";

thread_local! {
    /// Set while the store serializes a chat's metadata for its own files: the large fields are
    /// left out (`skip_commands`, `skip_tools`, `tools_without_rows`).
    static SPLITTING: Cell<bool> = const { Cell::new(false) };
}

#[cfg(test)]
thread_local! {
    /// Tests: the metadata bytes this thread's saves wrote (parts files, `session.json` by
    /// `LocalStore::save`, journal `meta` records), for the before and after of a save's cost.
    pub(crate) static WRITTEN: Cell<u64> = const { Cell::new(0) };
}

/// Counts `n` bytes in [`WRITTEN`] (no-op outside tests).
#[inline]
pub(crate) fn note_written(_n: usize) {
    #[cfg(test)]
    WRITTEN.with(|w| w.set(w.get().saturating_add(_n as u64)));
}

fn splitting() -> bool {
    SPLITTING.with(Cell::get)
}

/// Runs `f` with the large fields left out of every `SessionMeta` it serializes on this thread.
fn split<T>(f: impl FnOnce() -> T) -> T {
    struct Reset(bool);
    impl Drop for Reset {
        fn drop(&mut self) {
            SPLITTING.with(|s| s.set(self.0));
        }
    }
    let _reset = Reset(SPLITTING.with(|s| s.replace(true)));
    f()
}

/// `SessionMeta::available_commands`' `skip_serializing_if`.
pub(crate) fn skip_commands(commands: &Option<Value>) -> bool {
    commands.is_none() || splitting()
}

/// `SessionMeta::tools`' `skip_serializing_if`: split, only `mutable` and `off` stay.
pub(crate) fn skip_tools(tools: &ToolInventory) -> bool {
    if splitting() { !tools.mutable && tools.off.is_empty() } else { tools.is_empty() }
}

/// `SessionMeta::tools`' `serialize_with`: split, without its rows.
pub(crate) fn tools_without_rows<S: serde::Serializer>(
    tools: &ToolInventory,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    if splitting() {
        #[derive(Serialize)]
        struct Small<'a> {
            mutable: bool,
            #[serde(skip_serializing_if = "none_of")]
            off: &'a [String],
        }
        Small { mutable: tools.mutable, off: &tools.off }.serialize(serializer)
    } else {
        tools.serialize(serializer)
    }
}

/// The parts as the parts file holds them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PartsOut<'a> {
    fingerprint: &'a str,
    #[serde(skip_serializing_if = "no_value")]
    available_commands: &'a Option<Value>,
    #[serde(skip_serializing_if = "none_of")]
    tool_rows: &'a [ToolRow],
}

fn no_value(value: &&Option<Value>) -> bool {
    value.is_none()
}

fn none_of<T>(items: &&[T]) -> bool {
    items.is_empty()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartsIn {
    #[serde(default)]
    fingerprint: String,
    #[serde(default)]
    available_commands: Option<Value>,
    #[serde(default)]
    tool_rows: Vec<ToolRow>,
}

/// The fields hashed, in one order.
#[derive(Serialize)]
struct Hashed<'a> {
    commands: &'a Option<Value>,
    rows: &'a [ToolRow],
}

/// FNV-1a 64 over the bytes written, with their count: stable across builds, so a parts file
/// another run wrote is recognized.
struct Fnv(u64, u64);

impl Write for Fnv {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        for &b in bytes {
            self.0 ^= u64::from(b);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
        self.1 = self.1.wrapping_add(bytes.len() as u64);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The parts' fingerprint: hashed as they serialize, nothing allocated, nothing written.
pub(super) fn fingerprint(meta: &SessionMeta) -> String {
    let mut hash = Fnv(0xcbf2_9ce4_8422_2325, 0);
    let hashed = Hashed { commands: &meta.available_commands, rows: &meta.tools.rows };
    // A writer that never fails: an error here is a value that does not serialize, which the
    // metadata's own write reports.
    let _ = serde_json::to_writer(&mut hash, &hashed);
    format!("{:016x}{:x}", hash.0, hash.1)
}

fn has_parts(meta: &SessionMeta) -> bool {
    meta.available_commands.is_some() || !meta.tools.rows.is_empty()
}

/// A file's identity and size: a write by rename gives it a new id.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    ino: u64,
    len: u64,
    modified_ns: u128,
}

fn stamp(path: &Path) -> Option<Stamp> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    #[cfg(unix)]
    let ino = std::os::unix::fs::MetadataExt::ino(&meta);
    #[cfg(not(unix))]
    let ino = 0;
    let modified_ns = meta
        .modified()
        .ok()
        .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos());
    Some(Stamp { ino, len: meta.len(), modified_ns })
}

/// What the store last wrote or read of each chat's parts file: its fingerprint and the file's
/// stamp then. A save whose parts have that fingerprint, with that same file there, writes none.
#[derive(Default)]
pub struct PartsMemo {
    seen: Mutex<HashMap<String, (String, Option<Stamp>)>>,
}

impl PartsMemo {
    fn get(&self, id: &str) -> Option<(String, Option<Stamp>)> {
        self.seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(id).cloned()
    }

    fn set(&self, id: &str, fingerprint: String, stamp: Option<Stamp>) {
        self.seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id.to_owned(), (fingerprint, stamp));
    }

    /// Forgets `id` (a store that wrote nothing it can vouch for).
    pub fn forget(&self, id: &str) {
        self.seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(id);
    }

    /// Writes `dir`'s parts file for `meta` unless it holds these parts already; the fingerprint
    /// for the split `session.json`. One `lstat` when nothing changed.
    pub fn write(&self, dir: &Path, meta: &SessionMeta) -> Result<String> {
        let fingerprint = fingerprint(meta);
        let path = dir.join(PARTS_FILE);
        let now = stamp(&path);
        if let Some((seen, at)) = self.get(&meta.id)
            && seen == fingerprint
            && at == now
        {
            return Ok(fingerprint);
        }
        if !has_parts(meta) && now.is_none() {
            self.set(&meta.id, fingerprint.clone(), None);
            return Ok(fingerprint);
        }
        let out = PartsOut {
            fingerprint: &fingerprint,
            available_commands: &meta.available_commands,
            tool_rows: &meta.tools.rows,
        };
        let bytes = serde_json::to_vec(&out)?;
        crate::config::write_atomic(&path, &bytes)?;
        note_written(bytes.len());
        self.set(&meta.id, fingerprint.clone(), stamp(&path));
        Ok(fingerprint)
    }

    /// For a `session.json` written from an image no save of this run split (one replayed from
    /// an older build's journal holds its parts inline): writes the parts file unless this run
    /// wrote or read this chat's already, which a newer save then owns. The mark's fingerprint.
    pub fn ensure(&self, dir: &Path, meta: &SessionMeta) -> Result<String> {
        match self.get(&meta.id) {
            Some((fingerprint, _)) => Ok(fingerprint),
            None => self.write(dir, meta),
        }
    }

    /// `meta` as read from `text` (a `session.json` or journal image) in `dir`: a split one gets
    /// its parts from the parts file, and the memo learns them. One that is not split is as read.
    pub fn merge(&self, dir: &Path, text: &[u8], meta: &mut SessionMeta) {
        #[derive(Deserialize)]
        struct Mark {
            #[serde(default, rename = "metaParts")]
            parts: Option<String>,
        }
        let Ok(Mark { parts: Some(_) }) = serde_json::from_slice::<Mark>(text) else {
            // Written whole (an older build, an import): its next save writes the parts file.
            self.forget(&meta.id);
            return;
        };
        let path = dir.join(PARTS_FILE);
        let at = stamp(&path);
        // Read as `session.json` is: owner-only, never through a link.
        let read = || -> Option<Vec<u8>> {
            let mut bytes = Vec::new();
            std::io::Read::read_to_end(
                &mut crate::config::private_state_file(&path).ok()?,
                &mut bytes,
            )
            .ok()?;
            Some(bytes)
        };
        let Some(bytes) = at.and_then(|_| read()) else {
            self.forget(&meta.id);
            return;
        };
        let Ok(parts) = serde_json::from_slice::<PartsIn>(&bytes) else {
            tracing::warn!(session = %meta.id, "{} does not read", path.display());
            self.forget(&meta.id);
            return;
        };
        meta.available_commands = parts.available_commands;
        meta.tools.rows = parts.tool_rows;
        self.set(&meta.id, parts.fingerprint, at);
    }
}

/// `meta` as compact JSON for the store's own files: without its parts, with their fingerprint.
pub fn to_vec(meta: &SessionMeta, fingerprint: &str) -> serde_json::Result<Vec<u8>> {
    split(|| serde_json::to_vec(&Marked { meta, mark: fingerprint }))
}

/// `to_vec`, pretty (`session.json`).
pub fn to_string_pretty(meta: &SessionMeta, fingerprint: &str) -> serde_json::Result<String> {
    split(|| serde_json::to_string_pretty(&Marked { meta, mark: fingerprint }))
}

/// A split `session.json` (or journal image): the metadata, and the parts' fingerprint under
/// `metaParts`.
#[derive(Serialize)]
struct Marked<'a> {
    #[serde(flatten)]
    meta: &'a SessionMeta,
    #[serde(rename = "metaParts")]
    mark: &'a str,
}

#[cfg(test)]
#[path = "meta_parts_tests.rs"]
mod tests;
