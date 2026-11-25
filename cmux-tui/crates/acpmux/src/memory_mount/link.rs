//! `acpmux memory link`: point a harness's own memory folder into the mount, so what it
//! remembers on one machine is there on every machine.
//!
//! - Claude: `~/.claude/projects/<slug>/memory` -> `private/claude/<canonical>`
//!   ([`super::canonical_project`]: `~/Projects/cmux` on a Mac and on Linux is `Projects-cmux`).
//! - Codex: `~/.codex/memories` -> `private/codex`.
//! - agent-memory: `~/.cmux/agent-memory-notes.jsonl` -> `private/agent-memory/notes.jsonl` (it
//!   appends through the link; the sync merges `.jsonl` by lines).
//!
//! A dry run (the default) says what it would do. `--apply` merges the old folder into the mount
//! (a file on both sides: the newest wins; the other is published first, so it stays in the
//! store's history), moves the old folder to `NAME.pre-mount-UNIX`, and puts a symlink in its
//! place. Nothing is deleted.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Serialize;

use super::client::Client;
use super::{Scope, now_unix, sha256_hex, skipped_name};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Harness {
    Claude,
    Codex,
    AgentMemory,
}

/// One folder (or file) to point into the mount.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Link {
    /// The harness's own path.
    pub from: PathBuf,
    /// Where it points once linked.
    pub to: PathBuf,
    /// The path inside the private scope (`claude/Projects-cmux`).
    pub rel: String,
    /// Already a symlink to `to`.
    pub linked: bool,
    /// Files it holds that the mount does not have the same of.
    pub files: Vec<String>,
}

/// What `link --harness H` would do on this machine.
pub fn plan(harness: Harness, home: &Path, private_dir: &Path) -> Result<Vec<Link>> {
    let mut out = Vec::new();
    let mut add = |from: PathBuf, rel: String| -> Result<()> {
        let to = private_dir.join(&rel);
        let linked = std::fs::read_link(&from).is_ok_and(|target| target == to);
        let files = if linked { Vec::new() } else { differing(&from, &to)? };
        out.push(Link { from, to, rel, linked, files });
        Ok(())
    };
    match harness {
        Harness::Claude => {
            let projects = home.join(".claude").join("projects");
            let Ok(entries) = std::fs::read_dir(&projects) else {
                return Ok(out);
            };
            let mut slugs: Vec<String> = entries
                .flatten()
                .filter_map(|e| e.file_name().to_str().map(str::to_owned))
                .collect();
            slugs.sort();
            for slug in slugs {
                let from = projects.join(&slug).join("memory");
                if std::fs::symlink_metadata(&from).is_err() {
                    continue;
                }
                add(from, format!("claude/{}", super::canonical_project(&slug, home)))?;
            }
        }
        Harness::Codex => {
            let from = home.join(".codex").join("memories");
            if std::fs::symlink_metadata(&from).is_ok() {
                add(from, "codex".to_owned())?;
            }
        }
        Harness::AgentMemory => {
            let from = home.join(".cmux").join("agent-memory-notes.jsonl");
            if std::fs::symlink_metadata(&from).is_ok() {
                add(from, "agent-memory/notes.jsonl".to_owned())?;
            }
        }
    }
    Ok(out)
}

/// Relative paths of the files under `from` (a folder or one file) that `to` lacks or holds
/// other bytes of.
fn differing(from: &Path, to: &Path) -> Result<Vec<String>> {
    Ok(files_under(from)?
        .into_iter()
        .filter(|rel| {
            let a = std::fs::read(join(from, rel)).ok();
            let b = std::fs::read(join(to, rel)).ok();
            a != b
        })
        .collect())
}

/// `base` itself when `rel` is empty (a single-file link), else `base/rel`.
fn join(base: &Path, rel: &str) -> PathBuf {
    if rel.is_empty() { base.to_path_buf() } else { base.join(rel) }
}

/// Regular files under `root` as relative paths (`""` when `root` is one file). Symlinks are
/// not followed.
fn files_under(root: &Path) -> Result<Vec<String>> {
    let meta = match std::fs::symlink_metadata(root) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("stat {}", root.display())),
    };
    if meta.is_file() {
        return Ok(vec![String::new()]);
    }
    if !meta.is_dir() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    let mut stack = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, prefix)) = stack.pop() {
        for entry in
            std::fs::read_dir(&dir).with_context(|| format!("read {}", dir.display()))?.flatten()
        {
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
            let rel = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
            if skipped_name(&rel) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push((entry.path(), rel));
            } else if kind.is_file() {
                out.push(rel);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// What [`apply`] did with one link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Applied {
    pub from: PathBuf,
    pub to: PathBuf,
    /// Where the old folder went (`None`: it was linked already).
    pub kept: Option<PathBuf>,
    pub copied: Vec<String>,
    /// Files both had different: the newer one is in the mount, the other is in the store's
    /// history (when published) and in `kept`.
    pub replaced: Vec<String>,
}

/// Link each of `links`: merge, move the old one aside, symlink. `client`, when given, publishes
/// the losing side of each file both had first, so it stays in the store's history.
pub async fn apply(links: &[Link], client: Option<&Client>, host: &str) -> Result<Vec<Applied>> {
    let versions = match client {
        Some(client) => match client.tree(Scope::Private, 0).await {
            Ok(tree) => tree
                .entries
                .into_iter()
                .filter(|e| !e.deleted)
                .map(|e| (e.path, e.version))
                .collect(),
            Err(e) => {
                tracing::warn!("memory link: no store tree ({e:#}); losers stay only on disk");
                std::collections::BTreeMap::new()
            }
        },
        None => std::collections::BTreeMap::new(),
    };
    let stamp = now_unix();
    let mut out = Vec::new();
    for link in links {
        if link.linked {
            out.push(Applied {
                from: link.from.clone(),
                to: link.to.clone(),
                kept: None,
                copied: vec![],
                replaced: vec![],
            });
            continue;
        }
        let single = std::fs::symlink_metadata(&link.from).is_ok_and(|m| m.is_file());
        let mut copied = Vec::new();
        let mut replaced = Vec::new();
        for rel in files_under(&link.from)? {
            let src = join(&link.from, &rel);
            let dst = join(&link.to, &rel);
            let ours = std::fs::read(&src).with_context(|| format!("read {}", src.display()))?;
            let mount = std::fs::read(&dst).ok();
            let store_rel =
                if rel.is_empty() { link.rel.clone() } else { format!("{}/{rel}", link.rel) };
            match mount {
                None => {
                    super::engine::write_atomic(&dst, &ours)?;
                    copied.push(store_rel);
                }
                Some(mount) if mount == ours => {}
                Some(mount) => {
                    let ours_newer = modified(&src) >= modified(&dst);
                    let (winner, loser) =
                        if ours_newer { (&ours, &mount) } else { (&mount, &ours) };
                    if let (Some(client), Some(&version)) = (client, versions.get(&store_rel)) {
                        publish_both(client, &store_rel, version, &mount, loser, winner, host)
                            .await;
                    }
                    if ours_newer {
                        super::engine::write_atomic(&dst, winner)?;
                    }
                    replaced.push(store_rel);
                }
            }
        }
        if !single {
            crate::home_fs::create_dirs(&link.to)
                .with_context(|| format!("create {}", link.to.display()))?;
        }
        let name =
            link.from.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let kept = link.from.with_file_name(format!("{name}.pre-mount-{stamp}"));
        crate::home_fs::rename(&link.from, &kept)
            .with_context(|| format!("move {} to {}", link.from.display(), kept.display()))?;
        symlink(&link.to, &link.from)?;
        out.push(Applied {
            from: link.from.clone(),
            to: link.to.clone(),
            kept: Some(kept),
            copied,
            replaced,
        });
    }
    Ok(out)
}

/// The store holds `mount` at `version`: publish the loser first (unless it is what the store
/// has), then the winner, so the loser is a version in the history.
async fn publish_both(
    client: &Client,
    rel: &str,
    version: u64,
    mount: &[u8],
    loser: &[u8],
    winner: &[u8],
    host: &str,
) {
    use super::client::Wrote;
    let mut at = version;
    if loser != mount {
        match client.put(Scope::Private, rel, loser.to_vec(), at, None, host).await {
            Ok(Wrote::Ok { version }) => at = version,
            other => {
                tracing::warn!("memory link: {rel}'s older side not published: {other:?}");
                return;
            }
        }
    }
    if sha256_hex(winner) != sha256_hex(mount) || loser != mount {
        let _ = client.put(Scope::Private, rel, winner.to_vec(), at, None, host).await;
    }
}

fn modified(path: &Path) -> std::time::SystemTime {
    std::fs::metadata(path).and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH)
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> Result<()> {
    crate::home_fs::symlink(target, link)
        .with_context(|| format!("link {} to {}", link.display(), target.display()))
}

#[cfg(not(unix))]
fn symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::windows::fs::symlink_dir(target, link)
        .with_context(|| format!("link {} to {}", link.display(), target.display()))
}
