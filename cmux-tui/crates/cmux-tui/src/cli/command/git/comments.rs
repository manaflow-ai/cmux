//! `git comments list|save|delete`: the diff page's review comments
//! (`diff.comments.*`), which the session host keeps per worktree root. An
//! agent reads them, adds one, or removes those it resolved.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::super::{CommandPlan, Flags, Selectors, UsageError, parse_json_object, request, usage};

/// The most bytes of a root the session host keys comments by.
const MAX_ROOT_BYTES: usize = 4096;
/// The most comments one delete names.
const MAX_IDS: usize = 500;
/// The most bytes of one comment id.
const MAX_ID_BYTES: usize = 128;

/// `git comments list`, `git comments save --comment <json>` and
/// `git comments delete <id>... [--versions-json <json>]`, each for
/// `--root` (the current directory by default).
pub(super) fn parse(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    params.insert("root".into(), Value::String(root(flags)?));
    let operation = match words {
        ["list"] => Op::DiffCommentsList,
        ["save"] => {
            let comment = flags.required("comment")?;
            params.insert("comment".into(), parse_json_object("--comment", &comment)?);
            Op::DiffCommentsSave
        }
        ["delete", ids @ ..] if !ids.is_empty() => {
            if ids.len() > MAX_IDS {
                return Err(UsageError::new(format!("give at most {MAX_IDS} comment ids")));
            }
            let ids = ids.iter().map(|id| comment_id(id)).collect::<Result<Vec<_>, _>>()?;
            params.insert("ids".into(), Value::Array(ids));
            if let Some(versions) = flags.take("versions-json") {
                params.insert("versions".into(), versions_object(&versions)?);
            }
            Op::DiffCommentsDelete
        }
        _ => return usage("git comments action"),
    };
    request(operation, &Selectors::default(), flags, params)
}

/// `--root` made absolute against the current directory, or the current
/// directory itself, with `.`, `..` and a trailing `/` resolved in the text
/// (no symlink is followed): the session host keys comments by this text, so
/// `--root app/` and `--root ./app` must name the folder the diff page does.
fn root(flags: &mut Flags) -> Result<String, UsageError> {
    let current = std::env::current_dir()
        .map_err(|error| UsageError::new(format!("current directory: {error}")))?;
    let root = match flags.take("root") {
        Some(root) if root.is_empty() => return Err(UsageError::new("--root must not be empty")),
        Some(root) => current.join(root),
        None => current,
    };
    let root = lexical(&root).to_string_lossy().into_owned();
    if root.len() > MAX_ROOT_BYTES || root.contains('\0') {
        return Err(UsageError::new(format!(
            "--root must be at most {MAX_ROOT_BYTES} bytes, with no NUL"
        )));
    }
    Ok(root)
}

/// `path` with its `.` parts dropped and each `..` taking off the part before
/// it (never past the root), from the text alone.
fn lexical(path: &std::path::Path) -> std::path::PathBuf {
    use std::path::Component;
    let mut out = std::path::PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                if matches!(out.components().next_back(), Some(Component::Normal(_))) {
                    out.pop();
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn comment_id(id: &str) -> Result<Value, UsageError> {
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        return Err(UsageError::new(format!(
            "a comment id must contain 1 to {MAX_ID_BYTES} bytes"
        )));
    }
    Ok(Value::String(id.to_owned()))
}

/// `--versions-json`: each id's `updatedAt` as last read, so a comment
/// edited since is kept.
fn versions_object(value: &str) -> Result<Value, UsageError> {
    let versions = parse_json_object("--versions-json", value)?;
    let fits = versions
        .as_object()
        .is_some_and(|map| map.len() <= MAX_IDS && map.values().all(Value::is_string));
    if !fits {
        return Err(UsageError::new(format!(
            "--versions-json must map at most {MAX_IDS} comment ids to their updatedAt strings"
        )));
    }
    Ok(versions)
}
