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

fn walk(root: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(root) else {
        return out;
    };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.is_dir() {
            if depth > 0 {
                out.extend(walk(&p, depth - 1));
            }
        } else {
            out.push(p);
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
    Ok(target.strip_prefix(dest).unwrap_or(&target).to_string_lossy().into_owned())
}

/// Put native files from a bundle back under the home directory. Existing
/// files are never overwritten. Returns the number of files restored.
pub fn restore(bundle: &Path, _meta: &SessionMeta) -> Result<usize> {
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
        for file in walk(&label.path(), 8) {
            let rel = file.strip_prefix(label.path()).unwrap_or(&file);
            let target = home.join(rel);
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
