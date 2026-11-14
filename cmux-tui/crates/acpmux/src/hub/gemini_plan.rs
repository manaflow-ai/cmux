//! Gemini CLI's plan approval, with its plan. In plan mode Gemini writes its plan as a Markdown
//! file in its own plans folder, then calls `exit_plan_mode`. Over ACP that call names the file
//! and nothing else: its `tool_call`, its `session/request_permission` and its end carry the
//! title `Requesting plan approval for: <path>` and no content (gemini-cli 0.66.0 and the
//! 0.67.0 nightly, `packages/core/src/tools/exit-plan-mode.ts` `getDescription`, and
//! `packages/cli/src/acp/acpClient.ts`, which sends a tool's display title and its confirmation's
//! content, and `exit_plan_mode`'s confirmation has none). So acpmux, which runs Gemini on the
//! same machine, reads the file and attaches it the way Grok's and Cursor's plan approvals carry
//! theirs (`xai.rs`, `cursor_ext.rs`): a text block first in the call's `content`, which the
//! transcript draws as Markdown, `rawInput.plan`, and `_meta.acpmux.plan` for the approval card.
//!
//! Only a file in Gemini's own plans folder for the chat's project is read: under
//! `<gemini home>/tmp/<project>/plans/` or `<gemini home>/tmp/<project>/<session>/plans/`, where
//! `<project>`'s `.project_root` marker (gemini-cli `config/projectRegistry.ts`) names the chat's
//! folder. The path is resolved (symlinks too) before it is judged, it must be a Markdown file,
//! the marker and the plan are opened through one handle on the project's folder, part by part
//! from the resolved `tmp` folder with no symlink followed, and the open file must be a regular
//! file of at most 256 KiB. Anything else, or a read that fails, leaves the call as Gemini sent
//! it. Only on Unix, where those handle-relative opens exist; elsewhere no plan file is read.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The title Gemini gives `exit_plan_mode`, before the plan file's path.
const TITLE: &str = "Requesting plan approval for: ";

/// The marker Gemini writes in each project's temp folder: the project's root path.
const PROJECT_ROOT_FILE: &str = ".project_root";

/// The most of a plan file acpmux reads. A plan is a page or two of Markdown; a larger file is
/// left unread, so the hook never pulls a big file into every client's log.
const MAX_PLAN_BYTES: u64 = 256 * 1024;

/// The most of a `.project_root` marker acpmux reads: one path.
const MARKER_MAX_BYTES: u64 = 16 * 1024;

/// The folder `root` (already resolved) held open, refused when it is now a symlink. Only on
/// Unix: elsewhere there is no handle-relative open here, so no plan file is read at all.
#[cfg(unix)]
fn open_folder(root: &Path) -> Option<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root)
        .ok()
}

#[cfg(not(unix))]
fn open_folder(_root: &Path) -> Option<std::fs::File> {
    None
}

/// What `parts` names under the open folder `dir`, opened one part at a time from that handle
/// with no symlink followed at any part: a folder or file swapped for a symlink after the path was
/// judged is refused, never followed out of `dir`. The last part opens as a folder when `folder`,
/// else as a file; a FIFO opens without waiting for a writer (then fails [`read_capped`]'s
/// regular-file check).
#[cfg(unix)]
fn open_at(dir: &std::fs::File, parts: &[&std::ffi::OsStr], folder: bool) -> Option<std::fs::File> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    use std::os::unix::ffi::OsStrExt as _;
    let dir_flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let file_flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    let at = |dir: &std::fs::File, name: &std::ffi::OsStr, flags: libc::c_int| {
        let name = std::ffi::CString::new(name.as_bytes()).ok()?;
        // SAFETY: `dir` is open for the call and `name` is NUL-terminated; the descriptor opened
        // is owned at once.
        let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
        (fd >= 0).then(|| std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
    };
    let (last, folders) = parts.split_last()?;
    let mut held: Option<std::fs::File> = None;
    for name in folders {
        held = Some(at(held.as_ref().unwrap_or(dir), name, dir_flags)?);
    }
    at(held.as_ref().unwrap_or(dir), last, if folder { dir_flags } else { file_flags })
}

#[cfg(not(unix))]
fn open_at(
    _dir: &std::fs::File,
    _parts: &[&std::ffi::OsStr],
    _folder: bool,
) -> Option<std::fs::File> {
    None
}

/// `file`'s text when it is a regular file of at most `max` bytes; None otherwise. Kind and size
/// come from the open file itself, and the read is bounded too, so a file that grows after the
/// stat is still never read past `max`.
fn read_capped(file: std::fs::File, max: u64) -> Option<String> {
    use std::io::Read as _;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > max {
        return None;
    }
    let mut text = String::new();
    file.take(max + 1).read_to_string(&mut text).ok()?;
    (text.len() as u64 <= max).then_some(text)
}

/// The plan file an `exit_plan_mode` tool call names, from its title.
fn named_plan(tool: &Value) -> Option<&str> {
    let path = tool.get("title")?.as_str()?.strip_prefix(TITLE)?.trim();
    (!path.is_empty()).then_some(path)
}

/// Whether `tool` (a tool call, an update to one, or a request's `toolCall`) is Gemini's
/// `exit_plan_mode` naming a plan file: a title check only, cheap on every update.
pub(super) fn names_plan(tool: &Value) -> bool {
    named_plan(tool).is_some()
}

/// The folders Gemini keeps its state in (gemini-cli `config/storage.ts`
/// `getGlobalRuntimeDir`): `$GEMINI_CLI_HOME/.gemini` or `~/.gemini`, and under macOS's
/// sandbox-exec `~/.cache/.gemini`.
pub(super) fn gemini_homes() -> Vec<PathBuf> {
    let home = std::env::var_os("GEMINI_CLI_HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir);
    let Some(home) = home else { return Vec::new() };
    vec![home.join(".gemini"), home.join(".cache").join(".gemini")]
}

/// `path` resolved the way Gemini's `path.resolve` writes it: absolute, no `.` or `..`.
fn resolved(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Whether `marker` (a `.project_root` file's text) names `cwd`, as written or resolved.
fn names_project(marker: &str, cwd: &Path) -> bool {
    let owner = resolved(Path::new(marker.trim()));
    if owner.as_os_str().is_empty() {
        return false;
    }
    owner == resolved(cwd)
        || matches!(
            (std::fs::canonicalize(&owner), std::fs::canonicalize(cwd)),
            (Ok(a), Ok(b)) if a == b
        )
}

/// The plan's Markdown, when `path` is a Markdown file in Gemini's plans folder for the project
/// at `cwd` under one of `homes`; None for any other path, or a read that fails.
pub(super) fn read_plan(path: &str, cwd: &Path, homes: &[PathBuf]) -> Option<String> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return None;
    }
    let real = std::fs::canonicalize(path).ok()?;
    if real.extension().and_then(|e| e.to_str()).is_none_or(|e| !e.eq_ignore_ascii_case("md")) {
        return None;
    }
    // Both reads go through one handle on the project's folder, opened part by part from the
    // resolved `tmp` folder: the plan read is in the very folder whose marker was checked, even if
    // a folder on the way is swapped (for a symlink or another project's folder) meanwhile.
    let text = homes.iter().find_map(|home| {
        let tmp = std::fs::canonicalize(home.join("tmp")).ok()?;
        let rest = real.strip_prefix(&tmp).ok()?;
        let parts: Vec<_> = rest.components().map(|c| c.as_os_str()).collect();
        // <project>/plans/<file...> or <project>/<session>/plans/<file...>.
        let plans = |at: usize| parts.get(at).is_some_and(|part| *part == "plans");
        if !((parts.len() >= 3 && plans(1)) || (parts.len() >= 4 && plans(2))) {
            return None;
        }
        let (project, in_project) = parts.split_first()?;
        let project = open_at(&open_folder(&tmp)?, &[*project], true)?;
        let marker = std::ffi::OsStr::new(PROJECT_ROOT_FILE);
        let marker = read_capped(open_at(&project, &[marker], false)?, MARKER_MAX_BYTES)?;
        if !names_project(&marker, cwd) {
            return None;
        }
        read_capped(open_at(&project, in_project, false)?, MAX_PLAN_BYTES)
    })?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// Puts `plan` on an `exit_plan_mode` tool call: a text block before whatever content Gemini
/// sent (its end's "Plan approved: <path>" stays after it), `rawInput.plan` (beside any input
/// Gemini sent, whose own fields stay), and `_meta.acpmux.plan`.
fn attach(tool: &mut Value, path: &str, plan: &str) {
    let Some(call) = tool.as_object_mut() else { return };
    let block = json!({"type": "content", "content": {"type": "text", "text": plan}});
    let mut content = vec![block];
    if let Some(sent) = call.get("content").and_then(Value::as_array) {
        content.extend(sent.iter().cloned());
    }
    call.insert("content".into(), Value::Array(content));
    match call.get_mut("rawInput") {
        None | Some(Value::Null) => {
            call.insert("rawInput".into(), json!({"plan": plan, "plan_path": path}));
        }
        Some(Value::Object(input)) if !input.contains_key("plan") => {
            input.insert("plan".into(), json!(plan));
            input.entry("plan_path").or_insert_with(|| json!(path));
        }
        Some(_) => {}
    }
    let meta = call.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    let Some(meta) = meta.as_object_mut() else { return };
    let acpmux = meta.entry("acpmux").or_insert_with(|| json!({}));
    if !acpmux.is_object() {
        *acpmux = json!({});
    }
    if let Some(acpmux) = acpmux.as_object_mut() {
        acpmux.insert("plan".into(), json!({"markdown": plan, "path": path}));
    }
}

/// Attaches the plan to `tool` (a tool call, an update to one, or a permission request's
/// `toolCall`) when it is Gemini's `exit_plan_mode` and its plan file passes `read_plan`.
/// True when it did.
pub(super) fn with_plan(tool: &mut Value, cwd: &Path, homes: &[PathBuf]) -> bool {
    let Some(path) = named_plan(tool).map(str::to_owned) else { return false };
    if tool.pointer("/_meta/acpmux/plan").is_some() {
        return false;
    }
    let Some(plan) = read_plan(&path, cwd, homes) else { return false };
    attach(tool, &path, &plan);
    true
}

/// [`with_plan`] on a `session/update`'s params when the update is a tool call or its update.
pub(super) fn with_plan_update(params: &mut Value, cwd: &Path, homes: &[PathBuf]) -> bool {
    let Some(update) = params.get_mut("update") else { return false };
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return false;
    }
    with_plan(update, cwd, homes)
}

// Only Unix reads a plan file (`open_folder`).
#[cfg(all(test, unix))]
#[path = "gemini_plan_tests.rs"]
mod tests;
