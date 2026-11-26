//! Part of `Hub`; see `hub/mod.rs`. What an agent's hooks keep of one session beside its
//! transcript, carried with a moved chat: each `~/.cache/<tool>/sessions/<agent-session-id>.json`.
//!
//! A hook that remembers what it already put in a session's context keys that memory by the
//! agent's session id (the `session_id` of Claude Code's hook payload). The notes-first hook keeps
//! the rulebook pages and Decided lines it inlined there; a chat that moved without it got every
//! page and line it already held sent again (gcp-agent-lane-2, 2026-11-21 to 11-24: 62 moved-in
//! sessions, 42 whole pages and 945 Decided lines, 347 KB; cmuxterm-hq
//! `docs/findings/2026-11-24-moved-session-notes-state.md`). So a move's bundle carries each such
//! file under `hook-state/<tool>/<agent-session-id>.json` ([`BUNDLE_DIR`]), and the import puts
//! it back under the same name here, unless this machine already holds one (the hook's own,
//! newer than nothing).
//!
//! Only regular files of that exact shape go, each at most [`MAX_FILE`] bytes and at most
//! [`MAX_FILES`] of them; a guarded receive (Move to Cloud) takes the bundle but restores none.

use std::path::{Component, Path, PathBuf};

/// The bundle folder the files go under: `hook-state/<tool>/<agent-session-id>.json`.
pub(crate) const BUNDLE_DIR: &str = "hook-state";
/// The largest state file a move carries (notes-first's run to a few KB).
pub(crate) const MAX_FILE: u64 = 1 << 20;
/// The most state files a move carries.
pub(crate) const MAX_FILES: usize = 16;
/// The folder a tool's per-session files sit in, under `~/.cache/<tool>/`.
const SESSIONS: &str = "sessions";

/// A tool folder or file name a move carries: one plain name, no dot first.
fn plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 120
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// The file name a hook keys a session by: the agent's session id, as notes-first writes it.
fn state_name(sid: &str) -> Option<String> {
    (plain_name(sid) && super::transfer_guard::plain_agent_session(sid))
        .then(|| format!("{sid}.json"))
}

/// Each `(tool, path)` of the session `sid`'s state files under `cache` (`~/.cache`).
pub(crate) fn locate_in(cache: &Path, sid: &str) -> Vec<(String, PathBuf)> {
    let Some(name) = state_name(sid) else { return vec![] };
    let Ok(tools) = std::fs::read_dir(cache) else { return vec![] };
    let mut out = Vec::new();
    for tool in tools.flatten() {
        let Some(tool_name) = tool.file_name().to_str().map(str::to_owned) else { continue };
        // `DirEntry::file_type` does not follow symlinks: a linked folder carries nothing.
        if !plain_name(&tool_name) || !tool.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let path = tool.path().join(SESSIONS).join(&name);
        let regular = std::fs::symlink_metadata(&path)
            .is_ok_and(|m| m.file_type().is_file() && m.len() <= MAX_FILE);
        if regular {
            out.push((tool_name, path));
        }
        if out.len() >= MAX_FILES {
            break;
        }
    }
    out.sort();
    out
}

/// Copies the session `sid`'s state files under `cache` into the bundle folder `dir`; answers
/// how many went. One that cannot be read is left out: the hook seeds itself from the
/// transcript instead.
pub(crate) fn bundle(cache: &Path, sid: Option<&str>, dir: &Path) -> std::io::Result<usize> {
    let Some(sid) = sid else { return Ok(0) };
    let mut copied = 0;
    for (tool, src) in locate_in(cache, sid) {
        let Ok(bytes) = std::fs::read(&src) else { continue };
        let to = dir.join(BUNDLE_DIR).join(&tool);
        crate::home_fs::create_dirs(&to)?;
        crate::home_fs::write(to.join(src.file_name().unwrap_or_default()), bytes)?;
        copied += 1;
    }
    Ok(copied)
}

/// Whether `path` (under a bundle) is one of the files [`bundle`] writes: `hook-state/<tool>/<f>`.
pub(crate) fn is_bundle_path(path: &str) -> bool {
    let parts: Vec<&str> = Path::new(path)
        .components()
        .map(|c| match c {
            Component::Normal(p) => p.to_str().unwrap_or(""),
            _ => "",
        })
        .collect();
    matches!(parts.as_slice(), [d, tool, f]
        if *d == BUNDLE_DIR && plain_name(tool) && plain_name(f) && f.ends_with(".json"))
}

/// Puts the bundle's state files of the session `sid` back under `cache`; answers how many it
/// placed. A file this machine already holds is kept; a file not named for `sid`, not a regular
/// file, or past [`MAX_FILE`] is skipped. Each is written owner-only beside its place and
/// renamed in.
pub(crate) fn restore(bundle: &Path, cache: &Path, sid: Option<&str>) -> std::io::Result<usize> {
    let Some(name) = sid.and_then(state_name) else { return Ok(0) };
    let Ok(tools) = std::fs::read_dir(bundle.join(BUNDLE_DIR)) else { return Ok(0) };
    let mut placed = 0;
    for tool in tools.flatten() {
        if placed >= MAX_FILES {
            break;
        }
        let Some(tool_name) = tool.file_name().to_str().map(str::to_owned) else { continue };
        if !plain_name(&tool_name) {
            continue;
        }
        let src = tool.path().join(&name);
        let regular = std::fs::symlink_metadata(&src)
            .is_ok_and(|m| m.file_type().is_file() && m.len() <= MAX_FILE);
        if !regular {
            continue;
        }
        let dest = cache.join(&tool_name).join(SESSIONS).join(&name);
        if crate::home_fs::exists_nofollow(&dest) {
            continue;
        }
        let bytes = std::fs::read(&src)?;
        crate::home_fs::write_json_private(&dest, &bytes)?;
        placed += 1;
    }
    Ok(placed)
}

/// `~/.cache`, where the hooks keep their state: `$XDG_CACHE_HOME` is not read, since the hooks
/// write under the home's own `.cache`.
pub(crate) fn cache_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".cache"))
}

#[cfg(test)]
#[path = "hook_state_tests.rs"]
mod tests;
