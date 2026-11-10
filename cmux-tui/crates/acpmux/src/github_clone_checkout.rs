//! Part of `github_clone.rs`: what a clone checks out (Codex review round 4, F2, on #40513).
//!
//! The remote sandbox never lets the agent write a path that a later session outside it would
//! read and act on (`sandbox/remote-chain.sb`: agent instructions, Claude Code, Codex and editor
//! settings, git and tool hooks, `.envrc`, `.mcp.json`, a `HEAD` outside `.git`). A clone is
//! written by the daemon, outside the sandbox, so it holds to the same list itself ([`kept_out`]):
//! git clones with no checkout, and the checkout leaves every such path of the repository out
//! with a sparse checkout that names each one (`.git/info/sparse-checkout`, `core.sparseCheckout`),
//! so git marks them skip-worktree and sees no change. Before the clone moves into the chat's
//! folder, its work tree is walked once more, and one such path still there fails the clone.
//! The list is matched without regard to case (a case-insensitive volume opens `claude.md` for
//! `CLAUDE.md`).

use crate::rpc::RpcError;
use std::path::Path;

/// Folder names the sandbox forbids anywhere in a path (`/\.(claude|...)(/|$)`, `/\.git$`).
const FOLDERS: &[&str] = &[
    ".git",
    ".claude",
    ".codex",
    ".vscode",
    ".zed",
    ".idea",
    ".husky",
    ".githooks",
    ".cursor",
    ".windsurf",
];

/// File names the sandbox forbids anywhere.
const FILES: &[&str] = &[
    ".mcp.json",
    ".envrc",
    ".pre-commit-config.yaml",
    "lefthook.yml",
    ".tool-versions",
    "mise.toml",
    ".mise.toml",
    "mise.local.toml",
    ".mise.local.toml",
    ".cursorrules",
    "claude.md",
    "agents.md",
    "claude.local.md",
    "agents.override.md",
    "gemini.md",
    "head",
];

/// The last two parts of a path the sandbox forbids.
const ENDS: &[(&str, &str)] = &[
    ("mise", "config.toml"),
    (".mise", "config.toml"),
    (".hg", "hgrc"),
    (".github", "copilot-instructions.md"),
];

/// Whether a clone leaves out `path` (relative to the clone's top folder, `/`-separated): the
/// remote sandbox forbids the agent to write it (module docs).
pub(crate) fn kept_out(path: &[u8]) -> bool {
    let lower = path.to_ascii_lowercase();
    let parts: Vec<&[u8]> = lower.split(|&b| b == b'/').filter(|p| !p.is_empty()).collect();
    let Some(&last) = parts.last() else { return false };
    if parts.iter().any(|p| FOLDERS.iter().any(|f| f.as_bytes() == *p)) {
        return true;
    }
    if parts.windows(2).any(|w| w[0] == b".config" && w[1] == b"mise") {
        return true;
    }
    if FILES.iter().any(|f| f.as_bytes() == last) {
        return true;
    }
    parts.len() >= 2
        && ENDS.iter().any(|(a, b)| parts[parts.len() - 2] == a.as_bytes() && last == b.as_bytes())
}

/// The sparse-checkout patterns (non-cone) that check out everything but `out`, each path named
/// exactly; `None` when a path cannot be named in one (a line break in it).
pub(crate) fn sparse_patterns(out: &[&[u8]]) -> Option<Vec<u8>> {
    let mut patterns = b"/*\n".to_vec();
    for path in out {
        if path.iter().any(|&b| b == b'\n' || b == b'\r') {
            return None;
        }
        patterns.extend_from_slice(b"!/");
        let end = path.iter().rposition(|&b| b != b' ').map_or(0, |i| i + 1);
        for (i, &b) in path.iter().enumerate() {
            // Glob characters are literal; a trailing space is kept.
            if matches!(b, b'\\' | b'*' | b'?' | b'[') || (b == b' ' && i >= end) {
                patterns.push(b'\\');
            }
            patterns.push(b);
        }
        patterns.push(b'\n');
    }
    Some(patterns)
}

/// The first path under the clone's top folder `top` (not its own `.git`) that a clone leaves
/// out, if one is there (module docs). Links are not followed.
pub(crate) fn first_left_in(top: &Path) -> Result<Option<String>, RpcError> {
    use std::os::unix::ffi::OsStrExt as _;
    let failed = |e: std::io::Error| RpcError::internal(format!("could not check the clone: {e}"));
    let mut folders = vec![(top.to_path_buf(), Vec::<u8>::new())];
    while let Some((folder, rel)) = folders.pop() {
        for entry in std::fs::read_dir(&folder).map_err(failed)? {
            let entry = entry.map_err(failed)?;
            let name = entry.file_name();
            if rel.is_empty() && name.as_bytes() == b".git" {
                continue;
            }
            let mut path = rel.clone();
            if !path.is_empty() {
                path.push(b'/');
            }
            path.extend_from_slice(name.as_bytes());
            if kept_out(&path) {
                return Ok(Some(String::from_utf8_lossy(&path).into_owned()));
            }
            if entry.file_type().map_err(failed)?.is_dir() {
                folders.push((entry.path(), path));
            }
        }
    }
    Ok(None)
}

/// The reply's line naming what a clone left out (at most 50 paths).
pub(crate) fn left_out_line(out: &[String]) -> String {
    if out.is_empty() {
        return String::new();
    }
    let shown: Vec<&str> = out.iter().take(50).map(String::as_str).collect();
    let more = out.len().saturating_sub(shown.len());
    let more = if more > 0 { format!(" and {more} more") } else { String::new() };
    format!(
        "Left out of the checkout, because a chat on this machine may not write them and a later session outside its sandbox would read them (git marks them skip-worktree): {}{more}\n",
        shown.join(", ")
    )
}
