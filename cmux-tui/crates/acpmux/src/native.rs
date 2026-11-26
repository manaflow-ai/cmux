//! Locate and copy the adapter's own session files so a bundle can resume
//! at the "exact" level on another machine.

use crate::store::SessionMeta;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Returns `(label, path)` pairs of native files that belong to the session.
pub fn locate(meta: &SessionMeta) -> Vec<(String, PathBuf)> {
    match dirs::home_dir() {
        Some(home) => locate_in(meta, &home),
        None => vec![],
    }
}

/// [`locate`] under the home folder `home`.
pub fn locate_in(meta: &SessionMeta, home: &Path) -> Vec<(String, PathBuf)> {
    let Some(sid) = meta.agent_session_id.as_deref() else {
        return vec![];
    };
    let mut out = Vec::new();
    match store_kind(meta) {
        "codex" => {
            // ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
            let root = home.join(".codex").join("sessions");
            for p in walk(&root, 4) {
                let name =
                    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                if is_codex_rollout(&name, sid) {
                    out.push(("codex-rollout".to_owned(), p));
                }
            }
        }
        "claude" => {
            // ~/.claude/projects/<cwd-with-dashes>/<session-id>.jsonl
            let root = home.join(".claude").join("projects");
            // The file under the chat's own folder's name is the one its agent reads and
            // writes: when it is there it is the chat's, and no other folder's copy of the
            // id (one the chat left behind in a folder it ran in before) goes with it. It
            // also spares a snapshot the walk of every project.
            let own = root.join(claude_project_dir(&meta.cwd)).join(format!("{sid}.jsonl"));
            if std::fs::symlink_metadata(&own).is_ok_and(|m| m.file_type().is_file()) {
                return vec![("claude-project".to_owned(), own)];
            }
            for p in walk(&root, 2) {
                let name =
                    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                if name == format!("{sid}.jsonl") {
                    // Its `Task` children's transcripts: `<session-id>/subagents/*.jsonl`
                    // beside it, which Claude reads back for the subagents it ran.
                    let children = p.with_extension("").join(CLAUDE_SUBAGENTS);
                    out.push(("claude-project".to_owned(), p));
                    for child in walk(&children, 0) {
                        if child.extension().is_some_and(|e| e == "jsonl") {
                            out.push((CLAUDE_SUBAGENT_LABEL.to_owned(), child));
                        }
                    }
                }
            }
        }
        "pi" => {
            // ~/.pi/agent/sessions/--<cwd-with-dashes>--/<ts>_<session-id>.jsonl
            let root = home.join(PI_SESSIONS);
            for p in walk(&root, 1) {
                let name =
                    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                if name.ends_with(&format!("_{sid}.jsonl")) {
                    out.push((PI_LABEL.to_owned(), p));
                }
            }
        }
        _ => {}
    }
    out
}

/// Whether the file named `name` is the Codex rollout of the session `sid`:
/// `rollout-<time>-<sid>.jsonl`. The id is the name's whole end after a dash, so a word that is
/// merely somewhere in a name (`rollout`, a date, the start of another id) names no file.
fn is_codex_rollout(name: &str, sid: &str) -> bool {
    name.starts_with("rollout-") && name.ends_with(&format!("-{sid}.jsonl"))
}

/// The folder beside a Claude transcript (`<session-id>/subagents`) that holds its subagents'.
const CLAUDE_SUBAGENTS: &str = "subagents";
/// The bundle label of a Claude subagent's transcript (`<session-id>/subagents/*.jsonl`).
pub const CLAUDE_SUBAGENT_LABEL: &str = "claude-subagent";

/// Where a bundled Claude subagent transcript goes: `rel` must be
/// `.claude/projects/<dir>/<sid>/subagents/<name>.jsonl`, and it lands under the target cwd's
/// project directory, beside the session's own transcript.
fn claude_subagent_target(meta: &SessionMeta, sid: &str, rel: &Path) -> Option<PathBuf> {
    let parts: Vec<&str> = rel.iter().map(|p| p.to_str()).collect::<Option<_>>()?;
    match parts.as_slice() {
        [".claude", "projects", dir, s, CLAUDE_SUBAGENTS, name]
            if !dir.is_empty()
                && *s == sid
                && name.len() > ".jsonl".len()
                && name.ends_with(".jsonl") =>
        {
            Some(
                PathBuf::from(".claude/projects")
                    .join(claude_project_dir(&meta.cwd))
                    .join(sid)
                    .join(CLAUDE_SUBAGENTS)
                    .join(name),
            )
        }
        _ => None,
    }
}

/// pi's session folder under the home folder.
const PI_SESSIONS: &str = ".pi/agent/sessions";
/// The bundle label of a pi session file.
const PI_LABEL: &str = "pi-session";
/// The bundle label of OpenCode's export of a session (`opencode export ID`): OpenCode keeps
/// its sessions in a SQLite database, so the session travels as its export and is imported on
/// the target ([`import_opencode`]), never copied as a file of the home folder.
pub const OPENCODE_EXPORT: &str = "opencode-export";

/// The agent store the chat's agent keeps: its family when it is one this file knows, since a
/// profile such as `codex-acp`, `claude-sr` or `opencode-v2` runs the same agent with the same
/// store; else its profile. `cmux-harness` keeps its own state (`hub/transfer.rs`).
fn store_kind(meta: &SessionMeta) -> &str {
    const KNOWN: [&str; 4] = ["claude", "codex", "pi", "opencode"];
    if meta.harness == "cmux-harness" {
        return "cmux-harness";
    }
    [meta.family.as_deref(), Some(meta.harness.as_str())]
        .into_iter()
        .flatten()
        .find(|k| KNOWN.contains(k))
        .unwrap_or(meta.harness.as_str())
}

/// pi's session folder name for a cwd: `--<cwd without its leading slash, each / \\ or : a
/// dash>--`, as pi names it.
fn pi_session_dir(cwd: &Path) -> String {
    let cwd = cwd.to_string_lossy();
    let trimmed = cwd.strip_prefix(['/', '\\']).unwrap_or(&cwd);
    format!("--{}--", trimmed.replace(['/', '\\', ':'], "-"))
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
    copy_into_from(src, dest, label, &dirs::home_dir().unwrap_or_default())
}

/// [`copy_into`] for a file of the home folder `home`.
pub fn copy_into_from(src: &Path, dest: &Path, label: &str, home: &Path) -> Result<String> {
    let rel = src.strip_prefix(home).unwrap_or(src);
    let target = dest.join(label).join(rel);
    if let Some(parent) = target.parent() {
        crate::home_fs::create_dirs(parent)?;
    }
    crate::home_fs::copy(src, &target)?;
    if target.extension().is_some_and(|e| e == "jsonl") {
        complete_lines(&target)?;
    }
    Ok(target.strip_prefix(dest).unwrap_or(&target).to_string_lossy().into_owned())
}

/// [`copy_into_from`] from `prepared`, the folder an earlier [`copy_into_from`] of `src` filled:
/// its copy moves to `dest` and only what `src` grew by since is read and appended, so the cost
/// is the growth, not the file. None when there is no earlier copy or `src` is not that copy
/// grown at its end (shorter, or other bytes in the [`GROWN_WINDOW`] before the copy's end):
/// the caller copies it whole.
pub fn grow_into_from(
    src: &Path,
    prepared: &Path,
    dest: &Path,
    label: &str,
    home: &Path,
) -> Result<Option<String>> {
    use std::io::{Read, Seek, SeekFrom, Write};
    let rel = src.strip_prefix(home).unwrap_or(src);
    let (earlier, target) = (prepared.join(label).join(rel), dest.join(label).join(rel));
    let Ok(had) = std::fs::metadata(&earlier).map(|m| m.len()) else { return Ok(None) };
    let mut from = std::fs::File::open(src)?;
    let now = from.metadata()?.len();
    if now < had {
        return Ok(None);
    }
    let window = had.min(GROWN_WINDOW);
    let tail = |file: &mut std::fs::File| -> std::io::Result<Vec<u8>> {
        let mut bytes = vec![0; window as usize];
        file.seek(SeekFrom::Start(had - window))?;
        file.read_exact(&mut bytes)?;
        Ok(bytes)
    };
    if tail(&mut from)? != tail(&mut std::fs::File::open(&earlier)?)? {
        return Ok(None);
    }
    if let Some(parent) = target.parent() {
        crate::home_fs::create_dirs(parent)?;
    }
    crate::home_fs::rename(&earlier, &target)?;
    let mut out = crate::home_fs::OpenOptions::new().append(true).open(&target)?;
    from.seek(SeekFrom::Start(had))?;
    std::io::copy(&mut (&mut from).take(now - had), &mut out)?;
    out.flush()?;
    drop(out);
    if target.extension().is_some_and(|e| e == "jsonl") {
        complete_lines_after(&target, had)?;
    }
    Ok(Some(target.strip_prefix(dest).unwrap_or(&target).to_string_lossy().into_owned()))
}

/// The bytes before an earlier copy's end that [`grow_into_from`] compares with the file now.
pub const GROWN_WINDOW: u64 = 64 << 10;

/// [`complete_lines`] of a file whose first `start` bytes end at a line's end: only the bytes
/// past `start` are read.
fn complete_lines_after(path: &Path, start: u64) -> Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = crate::home_fs::OpenOptions::new().read(true).write(true).open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut grown = Vec::new();
    file.read_to_end(&mut grown)?;
    if grown.last().is_some_and(|b| *b != b'\n') {
        let keep = grown.iter().rposition(|b| *b == b'\n').map(|i| i + 1).unwrap_or(0);
        file.set_len(start + keep as u64)?;
    }
    Ok(())
}

/// The adapters append their JSONL while a turn runs, so a copy can end in a
/// half-written line. Cut it back to the last complete line: an append-only
/// log's prefix is a consistent snapshot that resumes cleanly.
fn complete_lines(path: &Path) -> Result<()> {
    let bytes = std::fs::read(path)?;
    if bytes.last().is_some_and(|b| *b != b'\n') {
        let keep = bytes.iter().rposition(|b| *b == b'\n').map(|i| i + 1).unwrap_or(0);
        crate::home_fs::OpenOptions::new().write(true).open(path)?.set_len(keep as u64)?;
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
    match (store_kind(meta), label) {
        ("claude", "claude-project")
            if rel.starts_with(".claude/projects") && name == format!("{sid}.jsonl") =>
        {
            // Claude finds the session through the cwd's project directory;
            // the destination cwd may differ from the exporting machine's.
            Some(PathBuf::from(".claude/projects").join(claude_project_dir(&meta.cwd)).join(name))
        }
        ("claude", CLAUDE_SUBAGENT_LABEL) => claude_subagent_target(meta, sid, rel),
        ("codex", "codex-rollout")
            if rel.starts_with(".codex/sessions") && is_codex_rollout(&name, sid) =>
        {
            Some(rel.to_path_buf())
        }
        ("pi", PI_LABEL)
            if rel.starts_with(PI_SESSIONS) && name.ends_with(&format!("_{sid}.jsonl")) =>
        {
            // pi finds a session by the id in its file's first line, in any folder; the
            // target's own cwd folder keeps `pi --continue` there working too.
            Some(Path::new(PI_SESSIONS).join(pi_session_dir(&meta.cwd)).join(name))
        }
        _ => None,
    }
}

/// Put native files from a bundle back under the home directory. An existing
/// file is overwritten only when it is a shorter start of the bundled one (the
/// chat ran here before and its log grew elsewhere); any other is kept.
/// Returns the number of files restored.
pub fn restore(bundle: &Path, meta: &SessionMeta) -> Result<usize> {
    restore_in(bundle, meta, &dirs::home_dir().unwrap_or_default())
}

/// [`restore`] of a bundle nothing reads after it: a file the home folder does not hold yet
/// becomes another name of the bundle's (one link, not a copy of a transcript that can be
/// gigabytes), falling back to a copy where the link fails.
pub fn restore_linked(bundle: &Path, meta: &SessionMeta) -> Result<usize> {
    restore_in_with(bundle, meta, &dirs::home_dir().unwrap_or_default(), true)
}

/// [`restore`] under the home folder `home`.
pub fn restore_in(bundle: &Path, meta: &SessionMeta, home: &Path) -> Result<usize> {
    restore_in_with(bundle, meta, home, false)
}

/// [`restore`] of a copy that is the chat (Auto mode's Cloud copy, `hub/auto_import.rs`): a
/// file here that holds other bytes is replaced, whatever it holds, since the chat's log here
/// was replaced the same way. The file that was here stays beside it under
/// [`REPLACED_SUFFIX`].
pub fn restore_replacing(bundle: &Path, meta: &SessionMeta) -> Result<usize> {
    restore_replacing_in(bundle, meta, &dirs::home_dir().unwrap_or_default())
}

/// [`restore_replacing`] under the home folder `home`.
pub fn restore_replacing_in(bundle: &Path, meta: &SessionMeta, home: &Path) -> Result<usize> {
    restore_as(bundle, meta, home, Placing::Replace)
}

/// The name a replaced agent file is kept under, after its own: no agent reads a file of this
/// ending as a session.
pub const REPLACED_SUFFIX: &str = ".before-cloud-copy";

/// What a restore does with a file the home folder holds already, and how it puts a new one.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Placing {
    /// Overwritten only when it is a shorter start of the bundled one; a new file is copied.
    Copy,
    /// [`Placing::Copy`], and a new file is a link to the bundle's.
    Link,
    /// Overwritten unless it holds the same bytes.
    Replace,
}

/// [`restore_in`]; `link`: [`restore_linked`].
pub fn restore_in_with(
    bundle: &Path,
    meta: &SessionMeta,
    home: &Path,
    link: bool,
) -> Result<usize> {
    restore_as(bundle, meta, home, if link { Placing::Link } else { Placing::Copy })
}

fn restore_as(bundle: &Path, meta: &SessionMeta, home: &Path, placing: Placing) -> Result<usize> {
    let link = placing == Placing::Link;
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
        if label_name == OPENCODE_EXPORT {
            // Imported by `import_opencode`, not a file of the home folder.
            continue;
        }
        for file in walk(&label.path(), 8) {
            let rel = file.strip_prefix(label.path()).unwrap_or(&file);
            let Some(target) = restore_target(meta, &label_name, rel) else {
                tracing::warn!("bundle file {} is not this session's; skipped", rel.display());
                continue;
            };
            let target = home.join(target);
            if target.exists() {
                // A chat back on a machine it ran on: this machine's copy is the start of the
                // log the chat kept writing elsewhere. Any other copy is left as it is, unless
                // the bundle is the chat (`Placing::Replace`).
                if !is_strict_prefix(&target, &file)? {
                    if placing != Placing::Replace || same_bytes(&target, &file)? {
                        continue;
                    }
                    keep_replaced(&target)?;
                }
                replace_with(&file, &target)?;
                n += 1;
                continue;
            }
            if let Some(parent) = target.parent() {
                crate::home_fs::create_dirs(parent)?;
            }
            if !(link && crate::home_fs::hard_link(&file, &target).is_ok()) {
                crate::home_fs::copy(&file, &target)?;
            }
            n += 1;
        }
    }
    Ok(n)
}

/// The bundle's agent files a restore did not place: each `<label>/<path>` under the bundle's
/// `native` folder (the source's manifest of what the chat owns) whose file is not at its place
/// under the home folder, or that has no place for this chat here. A file kept as it was (the
/// home folder held other bytes there) counts as placed. Empty when every entry landed.
pub fn unacked(bundle: &Path, meta: &SessionMeta) -> Vec<String> {
    unacked_in(bundle, meta, &dirs::home_dir().unwrap_or_default())
}

/// [`unacked`] under the home folder `home`.
pub fn unacked_in(bundle: &Path, meta: &SessionMeta, home: &Path) -> Vec<String> {
    let Ok(labels) = std::fs::read_dir(bundle.join("native")) else {
        return vec![];
    };
    let mut out = Vec::new();
    for label in labels.flatten() {
        let label_name = label.file_name().to_string_lossy().into_owned();
        if label_name == OPENCODE_EXPORT {
            continue;
        }
        for file in walk(&label.path(), 8) {
            let rel = file.strip_prefix(label.path()).unwrap_or(&file);
            let entry = format!("{label_name}/{}", rel.display());
            match restore_target(meta, &label_name, rel) {
                None => out.push(format!("{entry}: no place for this chat")),
                Some(target) if !home.join(&target).is_file() => {
                    out.push(format!("{entry}: not at {}", target.display()))
                }
                Some(_) => {}
            }
        }
    }
    out.sort();
    out
}

/// Whether `old` holds fewer bytes than `new` and they are the first bytes of `new`: an
/// append-only agent log that grew since `old` was copied.
fn is_strict_prefix(old: &Path, new: &Path) -> Result<bool> {
    let (old_len, new_len) = (std::fs::metadata(old)?.len(), std::fs::metadata(new)?.len());
    if old_len >= new_len {
        return Ok(false);
    }
    let (a, b) = (std::fs::read(old)?, std::fs::read(new)?);
    Ok(b.starts_with(&a))
}

/// Whether two files hold the same bytes.
fn same_bytes(a: &Path, b: &Path) -> Result<bool> {
    if std::fs::metadata(a)?.len() != std::fs::metadata(b)?.len() {
        return Ok(false);
    }
    Ok(std::fs::read(a)? == std::fs::read(b)?)
}

/// Keeps the file at `target` beside itself under [`REPLACED_SUFFIX`], in place of any kept
/// before: what this machine's agent wrote after the chat's last copy left.
fn keep_replaced(target: &Path) -> Result<()> {
    let mut name = target.file_name().unwrap_or_default().to_os_string();
    name.push(REPLACED_SUFFIX);
    replace_with(target, &target.with_file_name(name))
}

/// Puts a copy of `src` at `target` in one rename, so the agent never reads a half-written file.
fn replace_with(src: &Path, target: &Path) -> Result<()> {
    let parent = target.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = parent.join(format!(".{name}.{}.part", uuid::Uuid::now_v7()));
    let placed =
        crate::home_fs::copy(src, &part).and_then(|_| crate::home_fs::rename(&part, target));
    if placed.is_err() {
        let _ = crate::home_fs::remove_file(&part);
    }
    Ok(placed?)
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
        if label_name == OPENCODE_EXPORT {
            // Not a home file: `import_opencode` imports it. Only this chat's own export.
            for file in walk(&label.path(), 0) {
                let own = store_kind(meta) == "opencode"
                    && sid.is_some_and(|sid| {
                        file.file_name() == Some(opencode_export_name(sid).as_ref())
                    });
                if !own {
                    return Err(format!(
                        "{label_name}/{} is not this chat's agent file",
                        file.display()
                    ));
                }
            }
            continue;
        }
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
    match (store_kind(meta), label) {
        ("claude", "claude-project")
            if rel.starts_with(".claude/projects")
                && rel.components().count() == 4
                && name == format!("{sid}.jsonl") =>
        {
            Some(PathBuf::from(".claude/projects").join(claude_project_dir(&meta.cwd)).join(name))
        }
        ("claude", CLAUDE_SUBAGENT_LABEL) => claude_subagent_target(meta, sid, rel),
        ("codex", "codex-rollout")
            if rel.starts_with(".codex/sessions") && is_codex_rollout(name, sid) =>
        {
            Some(rel.to_path_buf())
        }
        ("pi", PI_LABEL)
            if rel.starts_with(PI_SESSIONS)
                && rel.components().count() == 5
                && name.ends_with(&format!("_{sid}.jsonl")) =>
        {
            Some(Path::new(PI_SESSIONS).join(pi_session_dir(&meta.cwd)).join(name))
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
    crate::home_fs::create_dirs(parent)?;
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = parent.join(format!(".{name}.{}.part", uuid::Uuid::now_v7()));
    let placed = write_without_mode(src, &part).and_then(|()| {
        if replace {
            crate::home_fs::rename(&part, target)?;
        } else {
            crate::home_fs::hard_link(&part, target)?;
            crate::home_fs::remove_file(&part)?;
        }
        Ok(())
    });
    if placed.is_err() {
        let _ = crate::home_fs::remove_file(&part);
    }
    placed
}

fn write_without_mode(src: &Path, dest: &Path) -> Result<()> {
    use std::io::Write;
    let text = std::fs::read(src)?;
    // The owner's only, as the agent's own store is: a transcript holds the whole conversation.
    let file =
        crate::home_fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(dest)?;
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

/// The file name of a session's OpenCode export in a bundle.
fn opencode_export_name(sid: &str) -> String {
    format!("{sid}.json")
}

/// An agent session id plain enough to pass to a CLI and to name a file.
fn plain_sid(meta: &SessionMeta) -> Option<&str> {
    meta.agent_session_id.as_deref().filter(|s| {
        (8..=128).contains(&s.len())
            && !s.starts_with('-')
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

/// How long an `opencode export` or `import` may take.
const OPENCODE_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

/// The `opencode` CLI on this machine: on the PATH, else where its installers put it.
fn opencode_cli() -> Option<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain([".bun/bin", ".opencode/bin", ".local/bin"].map(|d| home.join(d)))
        .chain([PathBuf::from("/opt/homebrew/bin"), PathBuf::from("/usr/local/bin")])
        .map(|d| d.join("opencode"))
        .find(|p| p.is_file())
}

/// Runs `cmd` with its stdout captured and its stderr dropped (it may echo transcript text),
/// for at most [`OPENCODE_WAIT`]; answers its stdout once it exits 0.
fn run_cli(mut cmd: std::process::Command) -> Result<Vec<u8>> {
    use std::io::Read as _;
    use std::process::Stdio;
    let mut child =
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        stdout.read_to_end(&mut out).map(|_| out)
    });
    let deadline = std::time::Instant::now() + OPENCODE_WAIT;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!("timed out after {}s", OPENCODE_WAIT.as_secs());
        }
        // A child process has no async exit signal in this synchronous export path; a short
        // bounded wait between checks, ended by the deadline above.
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    let out = reader.join().map_err(|_| anyhow::anyhow!("stdout reader panicked"))??;
    if !status.success() {
        anyhow::bail!("exited with {status}");
    }
    Ok(out)
}

/// An OpenCode export's JSON: its bytes from the first `{` on (the CLI may print a line before
/// it). None when there is no `{`.
fn opencode_export_json(bytes: &[u8]) -> Option<&[u8]> {
    let start = bytes.iter().position(|b| *b == b'{')?;
    bytes.get(start..)
}

/// The session id an OpenCode export holds (`info.id`).
fn opencode_export_id(bytes: &[u8]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(opencode_export_json(bytes)?).ok()?;
    v.pointer("/info/id").and_then(serde_json::Value::as_str).map(str::to_owned)
}

/// [`export_opencode_with`] with this machine's `opencode`, for an OpenCode chat; None for any
/// other chat, or when OpenCode is not installed here.
pub fn export_opencode(meta: &SessionMeta, native_dir: &Path) -> Result<Option<String>> {
    if store_kind(meta) != "opencode" {
        return Ok(None);
    }
    match opencode_cli() {
        Some(cli) => export_opencode_with(&cli, meta, native_dir),
        None => Ok(None),
    }
}

/// Writes OpenCode's export of the chat's session (`cli export ID`) under `native_dir` as
/// `opencode-export/<id>.json` (0600: it is the whole transcript); answers that path. An export
/// of another session, or a failed one, is an error and writes nothing.
pub fn export_opencode_with(
    cli: &Path,
    meta: &SessionMeta,
    native_dir: &Path,
) -> Result<Option<String>> {
    let Some(sid) = plain_sid(meta) else {
        return Ok(None);
    };
    let mut cmd = std::process::Command::new(cli);
    cmd.arg("export").arg(sid);
    cmd.current_dir(if meta.cwd.is_dir() { meta.cwd.clone() } else { std::env::temp_dir() });
    let out = run_cli(cmd).map_err(|e| anyhow::anyhow!("opencode export: {e}"))?;
    let json = match opencode_export_json(&out) {
        Some(json) if opencode_export_id(json).as_deref() == Some(sid) => json,
        _ => anyhow::bail!("opencode export did not answer session {sid}"),
    };
    let dir = native_dir.join(OPENCODE_EXPORT);
    crate::home_fs::create_dirs(&dir)?;
    let name = opencode_export_name(sid);
    crate::agent_login::write_private(&dir.join(&name), json)?;
    Ok(Some(format!("{OPENCODE_EXPORT}/{name}")))
}

/// [`import_opencode_with`] with this machine's `opencode`. A bundle with an export and no
/// OpenCode here is an error: the chat then resumes from acpmux's history only.
pub fn import_opencode(bundle: &Path, meta: &SessionMeta) -> Result<bool> {
    let has = plain_sid(meta).is_some_and(|sid| {
        bundle.join("native").join(OPENCODE_EXPORT).join(opencode_export_name(sid)).is_file()
    });
    if store_kind(meta) != "opencode" || !has {
        return Ok(false);
    }
    let cli = opencode_cli().ok_or_else(|| anyhow::anyhow!("opencode is not installed here"))?;
    import_opencode_with(&cli, bundle, meta)
}

/// Imports the bundle's OpenCode export of the chat's session with `cli import FILE`, run in the
/// chat's folder: OpenCode keeps the session id and files it under the folder it runs in.
/// Answers false when the bundle has no export for this session.
pub fn import_opencode_with(cli: &Path, bundle: &Path, meta: &SessionMeta) -> Result<bool> {
    let Some(sid) = plain_sid(meta) else {
        return Ok(false);
    };
    let file = bundle.join("native").join(OPENCODE_EXPORT).join(opencode_export_name(sid));
    if !file.is_file() {
        return Ok(false);
    }
    if opencode_export_id(&std::fs::read(&file)?).as_deref() != Some(sid) {
        anyhow::bail!("the bundle's OpenCode export is not session {sid}");
    }
    if !meta.cwd.is_dir() {
        anyhow::bail!("{} is not a folder here", meta.cwd.display());
    }
    let mut cmd = std::process::Command::new(cli);
    cmd.arg("import").arg(&file).current_dir(&meta.cwd);
    run_cli(cmd).map_err(|e| anyhow::anyhow!("opencode import: {e}"))?;
    Ok(true)
}

#[cfg(all(test, unix))]
mod private_copy_tests {
    /// A restored transcript is the owner's only, whatever the umask (review F2 on #41462).
    #[test]
    fn a_restored_transcript_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("acpmux-restore-mode-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("src.jsonl");
        std::fs::write(&src, "{\"type\":\"user\"}\n").unwrap();
        let dest = dir.join("dest.jsonl");
        super::write_without_mode(&src, &dest).unwrap();
        let mode = std::fs::metadata(&dest).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "mode {mode:o}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
