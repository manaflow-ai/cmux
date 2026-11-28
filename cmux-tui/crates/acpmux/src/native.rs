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

/// The most agent store files a guarded move restores, and their total size.
pub const MAX_GUARDED_FILES: usize = 8;
pub const MAX_GUARDED_BYTES: u64 = 1 << 30;

/// A guarded move's agent store files (`hub/transfer_guard.rs`): each bundled file and where it
/// goes under the home directory. Unlike [`restore`], which skips a stray file, any file that is
/// not exactly this session's refuses the move: a Claude project file named `<sid>.jsonl`, or a
/// Codex rollout `rollout-*-<sid>.jsonl`, for the session's own harness and label only.
pub fn guarded_plan(bundle: &Path, meta: &SessionMeta) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    let native = bundle.join("native");
    let Ok(labels) = std::fs::read_dir(&native) else {
        return Ok(vec![]);
    };
    let sid = meta.agent_session_id.as_deref().filter(|s| !s.is_empty());
    let (mut plan, mut total) = (Vec::new(), 0u64);
    for label in labels.flatten() {
        let label_name = label.file_name().to_string_lossy().into_owned();
        for file in walk(&label.path(), 8) {
            let rel = file.strip_prefix(label.path()).unwrap_or(&file);
            let target = sid.and_then(|sid| guarded_target(meta, sid, &label_name, rel));
            let target = target.ok_or_else(|| {
                format!("{label_name}/{} is not this chat's agent file", rel.display())
            })?;
            total =
                total.saturating_add(std::fs::metadata(&file).map_err(|e| e.to_string())?.len());
            plan.push((file, target));
        }
    }
    if plan.len() > MAX_GUARDED_FILES || total > MAX_GUARDED_BYTES {
        return Err(format!("{} agent store files, {total} bytes", plan.len()));
    }
    Ok(plan)
}

fn guarded_target(meta: &SessionMeta, sid: &str, label: &str, rel: &Path) -> Option<PathBuf> {
    use std::path::Component;
    if !rel.components().all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    let name = rel.file_name()?.to_str()?;
    match (meta.harness.as_str(), label) {
        ("claude", "claude-project")
            if rel.starts_with(".claude/projects")
                && rel.components().count() == 4
                && name == format!("{sid}.jsonl") =>
        {
            Some(PathBuf::from(".claude/projects").join(claude_project_dir(&meta.cwd)).join(name))
        }
        ("codex", "codex-rollout")
            if rel.starts_with(".codex/sessions")
                && name.starts_with("rollout-")
                && name.ends_with(&format!("-{sid}.jsonl")) =>
        {
            Some(rel.to_path_buf())
        }
        _ => None,
    }
}

/// Copies a [`guarded_plan`] under the home directory without the records that set the agent's
/// permission mode ([`without_mode`]). Each file is written to a part file beside its target and
/// then put in place: linked, so an existing file is never overwritten, or with `replace` (the
/// chat's own moved-away copy, `hub/transfer_guard.rs`) renamed over it. Any failure removes the
/// part file and the files this call created, and is returned. Returns the number restored.
pub fn restore_guarded(plan: &[(PathBuf, PathBuf)], replace: bool) -> Result<usize> {
    let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    let mut created: Vec<PathBuf> = Vec::new();
    for (src, rel) in plan {
        let target = home.join(rel);
        if let Err(e) = restore_one(src, &target, replace) {
            if !replace {
                for done in &created {
                    let _ = std::fs::remove_file(done);
                }
            }
            return Err(e.context(format!("restore {}", rel.display())));
        }
        created.push(target);
    }
    Ok(created.len())
}

fn restore_one(src: &Path, target: &Path, replace: bool) -> Result<()> {
    let parent = target.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    std::fs::create_dir_all(parent)?;
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = parent.join(format!(".{name}.{}.part", uuid::Uuid::now_v7()));
    let placed = write_without_mode(src, &part).and_then(|()| {
        if replace {
            std::fs::rename(&part, target)?;
        } else {
            std::fs::hard_link(&part, target)?;
            std::fs::remove_file(&part)?;
        }
        Ok(())
    });
    if placed.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    placed
}

fn write_without_mode(src: &Path, dest: &Path) -> Result<()> {
    use std::io::Write;
    let text = std::fs::read(src)?;
    let file = std::fs::OpenOptions::new().write(true).create_new(true).open(dest)?;
    let mut out = std::io::BufWriter::new(file);
    for line in text.split(|b| *b == b'\n') {
        if let Some(kept) = without_mode(line) {
            out.write_all(&kept)?;
            out.write_all(b"\n")?;
        }
    }
    out.flush()?;
    Ok(())
}

/// One agent store line as a guarded move restores it. A resumed agent can take its permission
/// mode back from its own store: Claude Code restores the last `permissionMode` a transcript
/// records, and a Codex `turn_context` record carries the turn's approval and sandbox policies.
/// So a record that sets a mode (`turn_context`, a permission mode record) and a line that is
/// not a JSON object are dropped, and a `permissionMode` field is removed.
fn without_mode(line: &[u8]) -> Option<Vec<u8>> {
    if line.iter().all(u8::is_ascii_whitespace) {
        return None;
    }
    let mut v: serde_json::Value = serde_json::from_slice(line).ok()?;
    let obj = v.as_object_mut()?;
    let sets_mode = ["type", "subtype"].iter().any(|k| {
        obj.get(*k).and_then(serde_json::Value::as_str).is_some_and(|t| {
            let t = t.to_ascii_lowercase().replace(['-', '_'], "");
            t == "turncontext" || t.contains("permissionmode")
        })
    });
    if sets_mode {
        return None;
    }
    if obj.remove("permissionMode").is_none() {
        return Some(line.to_vec());
    }
    serde_json::to_vec(&v).ok()
}
