//! `_acpmux/hunk_summary`: one plain sentence for one diff hunk, for the diff tab's Plain
//! English view (webviews/src/diff-viewer/hunkSummaries.ts). The sentence comes from one
//! `_acpmux/complete` run (`crate::complete`): the chat's own harness when the diff belongs to a
//! chat, else the daemon's default, with no tools, session or chat entry.
//!
//! Summaries are kept by the hunk's content hash ([`key`]), one small file each under
//! `<acpmux home>/hunk-summaries` ([`Cache`]): reopening a diff reads them and runs nothing, and a
//! hunk that changed has a new hash, so only it is asked again. The folder holds at most
//! [`CACHE_CAP`] files; past that the oldest are removed ([`Cache::prune`]).
//!
//! The unix socket only, as `_acpmux/complete` (`complete::allowed`): it runs a harness CLI with
//! the user's own login. The patch is never logged.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Most summaries kept on disk (each file is one sentence, about 100 bytes: about 2 MB).
pub const CACHE_CAP: usize = 20_000;
/// A prune leaves this many.
pub const PRUNE_TO: usize = CACHE_CAP * 9 / 10;
/// The folder is listed for a prune once per this many writes (and on the first), so a write
/// costs one small file, not a listing of every summary.
const PRUNE_EVERY: usize = 256;
static PUTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// The longest path, in bytes, put into the prompt.
const MAX_PATH_BYTES: usize = 240;
/// The answer's limit for `_acpmux/complete`, in tokens (about 4 bytes each).
pub const MAX_TOKENS: u32 = 60;
/// How long one summary may take.
pub const TIMEOUT_MS: u32 = 30_000;
/// The longest sentence kept, in bytes.
const MAX_SENTENCE_BYTES: usize = 220;
/// The cache key's version: a new prompt changes it, so old sentences are not reused.
const KEY_VERSION: &str = "hunk-summary-v1";

const INSTRUCTIONS: &str = "Describe what this code change does in one plain English sentence \
of at most 18 words, for a reviewer. Start with a verb in the present tense (\"Retries the upload \
three times before giving up\"). Say what it does, not how the diff looks: no code, no file name, \
no line numbers, no quotes, no markdown. Reply with the sentence only.";

/// The cache key of the hunk `patch` in file `path`: hex SHA-256 of both, versioned.
pub fn key(path: &str, patch: &str) -> String {
    let mut hash = Sha256::new();
    for part in [KEY_VERSION, path, patch] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    hash.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// The `_acpmux/complete` prompt for one hunk, within `max_bytes`: a patch that does not fit is
/// cut on a line boundary, and the prompt says so.
pub fn prompt(path: &str, patch: &str, max_bytes: usize) -> String {
    let path = crate::complete::cut(path.trim(), MAX_PATH_BYTES);
    let head = format!("{INSTRUCTIONS}\n\nFile: {path}\n\n```diff\n");
    let tail = "\n```\n";
    let cut_note = "\n(the rest of this hunk was cut)";
    let room = max_bytes.saturating_sub(head.len() + tail.len());
    let patch = patch.trim_end_matches('\n');
    let body = if patch.len() <= room {
        patch.to_owned()
    } else {
        let kept = crate::complete::cut(patch, room.saturating_sub(cut_note.len()));
        // A whole line is kept or none of it.
        let kept = kept.rfind('\n').and_then(|at| kept.get(..at)).unwrap_or("");
        format!("{kept}{cut_note}")
    };
    format!("{head}{body}{tail}")
}

/// The model's answer as one sentence: its first non-empty line, without a list mark,
/// quotes or backticks, capitalized, with a full stop, at most [`MAX_SENTENCE_BYTES`]. None when
/// nothing is left.
pub fn sentence(answer: &str) -> Option<String> {
    let line = answer.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line.trim_start_matches(['-', '*', '•', '>', ' ']);
    let line = line.trim_matches(|c: char| matches!(c, '"' | '\'' | '`' | '“' | '”' | ' '));
    let line: String = line.chars().filter(|c| !c.is_control() && *c != '`').collect();
    let mut line = crate::complete::cut(line.trim(), MAX_SENTENCE_BYTES).trim_end().to_owned();
    if line.is_empty() {
        return None;
    }
    if let Some(first) = line.chars().next()
        && first.is_lowercase()
    {
        let upper: String = first.to_uppercase().collect();
        line.replace_range(..first.len_utf8(), &upper);
    }
    if !line.ends_with(['.', '!', '?', '…']) {
        line.push('.');
    }
    Some(line)
}

/// Whether `key` is a cache key ([`key`]): 64 lowercase hex digits, so it names a file safely.
pub fn is_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The summaries on disk: `<root>/<key>`, one sentence each.
#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
}

impl Cache {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// The daemon's own: `<acpmux home>/hunk-summaries`.
    pub fn for_daemon() -> Self {
        Self::new(crate::config::home().join("hunk-summaries"))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The sentence kept for `key`, if any.
    pub fn get(&self, key: &str) -> Option<String> {
        if !is_key(key) {
            return None;
        }
        let text = std::fs::read_to_string(self.root.join(key)).ok()?;
        let text = text.trim();
        (!text.is_empty()).then(|| text.to_owned())
    }

    /// Keeps `text` for `key`; now and then prunes the folder back under [`CACHE_CAP`]. A
    /// failed write is only a summary asked again next time.
    pub fn put(&self, key: &str, text: &str) -> std::io::Result<()> {
        if !is_key(key) {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a summary key"));
        }
        crate::agent_host::ensure_private_dir(&self.root).map_err(std::io::Error::other)?;
        crate::config::write_atomic(&self.root.join(key), text.as_bytes())
            .map_err(std::io::Error::other)?;
        if PUTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed).is_multiple_of(PRUNE_EVERY) {
            self.prune(CACHE_CAP, PRUNE_TO);
        }
        Ok(())
    }

    /// When more than `cap` summaries are kept, removes the oldest (by modification time) down
    /// to `keep`; returns how many. Under `cap` it only lists the folder.
    pub fn prune(&self, cap: usize, keep: usize) -> usize {
        let Ok(entries) = std::fs::read_dir(&self.root) else { return 0 };
        let names: Vec<_> =
            entries.flatten().filter(|e| is_key(&e.file_name().to_string_lossy())).collect();
        if names.len() <= cap {
            return 0;
        }
        let mut aged: Vec<_> = names
            .into_iter()
            .map(|e| {
                let at = e.metadata().and_then(|m| m.modified()).ok();
                (at, e.path())
            })
            .collect();
        aged.sort_by_key(|(at, _)| *at);
        let extra = aged.len().saturating_sub(keep);
        aged.into_iter().take(extra).filter(|(_, path)| std::fs::remove_file(path).is_ok()).count()
    }
}

#[cfg(test)]
#[path = "hunk_summary_tests.rs"]
mod tests;
