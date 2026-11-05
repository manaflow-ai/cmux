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
    match (store_kind(meta), label) {
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

/// [`restore`] under the home folder `home`.
pub fn restore_in(bundle: &Path, meta: &SessionMeta, home: &Path) -> Result<usize> {
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
                // log the chat kept writing elsewhere. Any other copy is left as it is.
                if !is_strict_prefix(&target, &file)? {
                    continue;
                }
                replace_with(&file, &target)?;
                n += 1;
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

/// Puts a copy of `src` at `target` in one rename, so the agent never reads a half-written file.
fn replace_with(src: &Path, target: &Path) -> Result<()> {
    let parent = target.parent().ok_or_else(|| anyhow::anyhow!("no parent folder"))?;
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let part = parent.join(format!(".{name}.{}.part", uuid::Uuid::now_v7()));
    let placed = std::fs::copy(src, &part).and_then(|_| std::fs::rename(&part, target));
    if placed.is_err() {
        let _ = std::fs::remove_file(&part);
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
        ("codex", "codex-rollout")
            if rel.starts_with(".codex/sessions")
                && name.starts_with("rollout-")
                && name.ends_with(&format!("-{sid}.jsonl")) =>
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
    std::fs::create_dir_all(&dir)?;
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
