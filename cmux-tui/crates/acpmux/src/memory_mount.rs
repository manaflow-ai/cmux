//! The fleet's memory as a folder on every machine (Leo: "memory lives outside of any one
//! individual machine as an ebbing and flowing accessible fs type thing").
//!
//! `~/.cmux/memory/private` (this person's) and `~/.cmux/memory/team` (the team's) mirror the
//! memory store on cmux-platform (`/v1/memory/{scope}/...`). A pass pulls what changed since the
//! last sequence number it saw, then pushes what changed here; the daemon runs one on every local
//! change (after 300 ms of quiet), every remote change (a 25 s long-poll), and every 5 minutes.
//!
//! No change is dropped: a version both sides changed is three-way merged against the base kept
//! in the state folder ([`merge`]); a merge that does not settle keeps theirs under the name and
//! ours beside it as `NAME.conflict-HOST-UNIX.EXT`, and both are published. Writes into the
//! folder are atomic (a hidden temp beside the file, then a rename) and happen only while the
//! local file still matches the base.
//!
//! `acpmux memory link` points Claude's and Codex's own memory folders into the mount ([`link`]).
//! Prior art: `artifacts_sync.rs` (#27815) polls `/v1/artifacts` and is off by default; a root
//! linked into the mount is a symlink, which that sync already skips, so nothing syncs twice.

pub mod client;
pub mod engine;
pub mod link;
pub mod merge;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};

/// Files larger than this are never synced (the store answers 413 above it too).
pub const MAX_FILE_BYTES: u64 = 256 * 1024;

/// A memory store scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, clap::ValueEnum, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    Private,
    Team,
}

impl Scope {
    pub const ALL: [Scope; 2] = [Scope::Private, Scope::Team];

    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Private => "private",
            Scope::Team => "team",
        }
    }
}

/// `~/.cmux/memory`, or the configured `memory.dir`.
pub fn root(config: &crate::config::MemorySyncConfig) -> Option<PathBuf> {
    config.dir.clone().or_else(|| dirs::home_dir().map(|h| h.join(".cmux").join("memory")))
}

/// Where a scope's files live: `ROOT/private`, `ROOT/team`.
pub fn scope_dir(root: &Path, scope: Scope) -> PathBuf {
    root.join(scope.as_str())
}

/// Where a scope's sync state lives: `ROOT/.sync/SCOPE` (hidden, so never synced itself).
pub fn state_dir(root: &Path, scope: Scope) -> PathBuf {
    root.join(".sync").join(scope.as_str())
}

/// Whether a relative path (`/`-separated) is left out of the sync: editor swap and backup files
/// (`*.swp`, `*~`, `.#*`), `.DS_Store`, and any hidden part (our own temps are hidden).
pub fn skipped_name(rel: &str) -> bool {
    rel.split('/').any(|part| {
        part.is_empty()
            || part.starts_with('.')
            || part.ends_with('~')
            || part.ends_with(".swp")
            || part.ends_with(".swx")
            || part.ends_with(".tmp")
    })
}

/// The canonical name a project's memory goes under in the mount: the project's path relative
/// to the home, `/` as `-` (`~/Projects/cmux` -> `Projects-cmux`; the home itself -> `home`).
/// It takes a Claude project folder name (`-Users-leo-Projects-cmux`, the path with every
/// character that is not a letter or digit as `-`) and the home path, so the same project on a
/// Mac and on Linux lands in the same folder.
pub fn canonical_project(claude_slug: &str, home: &Path) -> String {
    let home_slug = claude_slugify(&home.to_string_lossy());
    if claude_slug == home_slug {
        return "home".to_owned();
    }
    if let Some(rest) = claude_slug.strip_prefix(&format!("{home_slug}-"))
        && !rest.is_empty()
    {
        return rest.trim_start_matches('-').to_owned();
    }
    // Outside the home: the absolute path's slug, without its leading `-`.
    let trimmed = claude_slug.trim_start_matches('-');
    if trimmed.is_empty() { "root".to_owned() } else { trimmed.to_owned() }
}

/// Claude Code's project folder name for a path: every character that is not an ASCII letter
/// or digit as `-`.
pub fn claude_slugify(path: &str) -> String {
    path.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// Hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(bytes);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// Seconds since the epoch.
pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Whether the memory sync runs in this daemon: `memory.sync` (on unless set false) on a
/// machine joined to cmux Cloud.
pub fn enabled(config: &crate::config::MemorySyncConfig) -> bool {
    config.sync.unwrap_or(true)
}

/// The daemon's sync loop for every scope, until `shutdown`. Returns at once when the sync is
/// off or this machine is not joined.
pub async fn run_background(config: crate::config::Config, shutdown: &tokio::sync::Notify) {
    if !enabled(&config.memory) {
        return;
    }
    let Some(root) = root(&config.memory) else {
        return;
    };
    let client = match client::Client::joined() {
        Ok(Some(client)) => client,
        Ok(None) => return,
        Err(error) => {
            tracing::warn!("memory sync: {error:#}");
            return;
        }
    };
    let host = crate::hand::pair::hostname();
    let runs = Scope::ALL.map(|scope| {
        let engine = engine::Engine::new(client.clone(), scope, &root, host.clone());
        async move {
            match engine {
                Ok(engine) => engine.run(shutdown).await,
                Err(error) => tracing::warn!("memory sync {}: {error:#}", scope.as_str()),
            }
        }
    });
    let [a, b] = runs;
    tokio::join!(a, b);
}
