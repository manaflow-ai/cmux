//! Locate and copy the adapter's own session files so a bundle can resume
//! at the "exact" level on another machine.

use crate::store::SessionMeta;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Returns `(label, path)` pairs of native files that belong to the session.
pub fn locate(meta: &SessionMeta) -> Vec<(String, PathBuf)> {
    let Some(sid) = meta.agent_session_id.as_deref() else {
        return vec![];
    };
    let Some(home) = dirs::home_dir() else {
        return vec![];
    };
    let mut out = Vec::new();
    match meta.harness.as_str() {
        "codex" => {
            // ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
            let root = home.join(".codex").join("sessions");
            for p in walk(&root, 4) {
                let name =
                    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                if name.ends_with(".jsonl") && name.contains(sid) {
                    out.push(("codex-rollout".to_owned(), p));
                }
            }
        }
        "claude" => {
            // ~/.claude/projects/<cwd-with-dashes>/<session-id>.jsonl
            let root = home.join(".claude").join("projects");
            for p in walk(&root, 2) {
                let name =
                    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                if name == format!("{sid}.jsonl") {
                    out.push(("claude-project".to_owned(), p));
                }
            }
        }
        _ => {}
    }
    out
}

/// Regular files under `root`, at most `depth` directories down. Symlinks
/// are neither followed nor returned, so a link cannot pull unrelated files
/// into a bundle or out of one.
fn walk(root: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(root) else {
        return out;
    };
    for entry in rd.flatten() {
        // `DirEntry::file_type` does not follow symlinks.
        let Ok(ft) = entry.file_type() else { continue };
        if ft.is_dir() {
            if depth > 0 {
                out.extend(walk(&entry.path(), depth - 1));
            }
        } else if ft.is_file() {
            out.push(entry.path());
        }
    }
    out
}

/// Copy `src` under `dest/<label>/<relative-to-home>` and return the relative path.
pub fn copy_into(src: &Path, dest: &Path, label: &str) -> Result<String> {
    let home = dirs::home_dir().unwrap_or_default();
    let rel = src.strip_prefix(&home).unwrap_or(src);
    let target = dest.join(label).join(rel);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(src, &target)?;
    if target.extension().is_some_and(|e| e == "jsonl") {
        complete_lines(&target)?;
    }
    Ok(target.strip_prefix(dest).unwrap_or(&target).to_string_lossy().into_owned())
}

/// The adapters append their JSONL while a turn runs, so a copy can end in a
/// half-written line. Cut it back to the last complete line: an append-only
/// log's prefix is a consistent snapshot that resumes cleanly.
fn complete_lines(path: &Path) -> Result<()> {
    let bytes = std::fs::read(path)?;
    if bytes.last().is_some_and(|b| *b != b'\n') {
        let keep = bytes.iter().rposition(|b| *b == b'\n').map(|i| i + 1).unwrap_or(0);
        std::fs::OpenOptions::new().write(true).open(path)?.set_len(keep as u64)?;
    }
    Ok(())
}

/// Claude Code's project directory name for a cwd: every character other
/// than an ASCII letter or digit becomes `-`.
fn claude_project_dir(cwd: &Path) -> String {
    cwd.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// Where a bundled native file goes under `home`, or None when it is not
/// one of this session's own files. Only the label for the session's
/// harness and the file named for its agent session are accepted, so a
/// bundle cannot plant arbitrary files in the home directory.
fn restore_target(meta: &SessionMeta, label: &str, rel: &Path) -> Option<PathBuf> {
    use std::path::Component;
    let sid = meta.agent_session_id.as_deref().filter(|s| !s.is_empty())?;
    if !rel.components().all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    let name = rel.file_name()?.to_string_lossy().into_owned();
    match (meta.harness.as_str(), label) {
        ("claude", "claude-project")
            if rel.starts_with(".claude/projects") && name == format!("{sid}.jsonl") =>
        {
            // Claude finds the session through the cwd's project directory;
            // the destination cwd may differ from the exporting machine's.
            Some(PathBuf::from(".claude/projects").join(claude_project_dir(&meta.cwd)).join(name))
        }
        ("codex", "codex-rollout")
            if rel.starts_with(".codex/sessions")
                && name.ends_with(".jsonl")
                && name.contains(sid) =>
        {
            Some(rel.to_path_buf())
        }
        _ => None,
    }
}

/// Put native files from a bundle back under the home directory. Existing
/// files are never overwritten. Returns the number of files restored.
pub fn restore(bundle: &Path, meta: &SessionMeta) -> Result<usize> {
    let home = dirs::home_dir().unwrap_or_default();
    let native = bundle.join("native");
    if !native.is_dir() {
        return Ok(0);
    }
    let mut n = 0;
    let Ok(labels) = std::fs::read_dir(&native) else {
        return Ok(0);
    };
    for label in labels.flatten() {
        let label_name = label.file_name().to_string_lossy().into_owned();
        for file in walk(&label.path(), 8) {
            let rel = file.strip_prefix(label.path()).unwrap_or(&file);
            let Some(target) = restore_target(meta, &label_name, rel) else {
                tracing::warn!("bundle file {} is not this session's; skipped", rel.display());
                continue;
            };
            let target = home.join(target);
            if target.exists() {
                continue;
            }
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(&file, &target)?;
            n += 1;
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restore_accepts_only_the_sessions_own_file() {
        let mut meta: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": "acpmux.session.v1", "id": "s1", "name": "n", "harness": "claude",
            "cwd": "/work/my.repo", "agentSessionId": "abc", "status": "idle",
            "createdAt": 0, "updatedAt": 0
        }))
        .unwrap();
        let target = |label: &str, rel: &str| restore_target(&meta, label, Path::new(rel));
        assert_eq!(
            target("claude-project", ".claude/projects/-old/abc.jsonl"),
            Some(PathBuf::from(".claude/projects/-work-my-repo/abc.jsonl"))
        );
        assert!(target("claude-project", ".ssh/authorized_keys").is_none());
        assert!(target("codex-rollout", ".codex/sessions/abc.jsonl").is_none());
        assert!(target("claude-project", ".claude/projects/x/zzz.jsonl").is_none());
        meta.harness = "codex".into();
        let rollout = ".codex/sessions/2026/01/02/rollout-1-abc.jsonl";
        assert_eq!(
            restore_target(&meta, "codex-rollout", Path::new(rollout)),
            Some(PathBuf::from(rollout))
        );
    }
}
