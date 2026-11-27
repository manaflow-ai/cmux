//! `git.commit`'s arguments: the message, what to stage and the guards.
//! Paths are relative to the repository root, or absolute inside it (the
//! CLI sends them joined with its working directory); either way they end
//! up root-relative, with no `.`, `..` or `.git` component (in any case), and
//! are always taken literally.

use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value};

use crate::resource::ResourceError;

const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_PATHS: usize = 5000;

pub(super) struct Arguments {
    pub message: String,
    pub paths: Vec<String>,
    pub all: bool,
    pub include_untracked: bool,
    pub amend: bool,
    pub no_verify: bool,
    pub expected_head: Option<String>,
}

/// The arguments, with paths made relative to `root`.
pub(super) fn parse(fields: &Map<String, Value>, root: &Path) -> Result<Arguments, ResourceError> {
    let message = fields.get("message").and_then(Value::as_str).unwrap_or_default();
    if message.trim().is_empty() || message.len() > MAX_MESSAGE_BYTES || message.contains('\0') {
        return Err(ResourceError::validation_invalid(
            Some("message"),
            "a commit message has text, at most 64 KiB and no NUL",
        ));
    }
    let flag = |name: &str| fields.get(name).and_then(Value::as_bool).unwrap_or(false);
    let (all, include_untracked) = (flag("all"), flag("include_untracked"));
    let paths = match fields.get("paths") {
        Some(value) => root_relative(value, root)?,
        None => Vec::new(),
    };
    if all && !paths.is_empty() {
        return Err(ResourceError::validation_invalid(Some("all"), "give paths or all, not both"));
    }
    if include_untracked && !all {
        return Err(ResourceError::validation_invalid(
            Some("include_untracked"),
            "include_untracked needs all",
        ));
    }
    Ok(Arguments {
        message: message.to_string(),
        paths,
        all,
        include_untracked,
        amend: flag("amend"),
        no_verify: flag("no_verify"),
        expected_head: fields.get("expected_head").and_then(Value::as_str).map(str::to_string),
    })
}

fn root_relative(value: &Value, root: &Path) -> Result<Vec<String>, ResourceError> {
    let given = value.as_array().map(Vec::as_slice).unwrap_or_default();
    if given.is_empty() || given.len() > MAX_PATHS {
        return Err(ResourceError::validation_invalid(
            Some("paths"),
            format!("paths names 1 to {MAX_PATHS} files"),
        ));
    }
    given
        .iter()
        .map(|path| {
            let text = path.as_str().unwrap_or_default();
            relative(text, root).ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("paths"),
                    format!("{path} is not a path inside the repository"),
                )
            })
        })
        .collect()
}

/// `path` relative to `root`, or `None` when it is outside it or names a
/// component a commit path never has.
pub(super) fn relative(path: &str, root: &Path) -> Option<String> {
    if path.contains('\0') {
        return None;
    }
    let trimmed = path.strip_suffix('/').unwrap_or(path);
    let relative = if Path::new(trimmed).is_absolute() {
        inside(Path::new(trimmed), root)?
    } else {
        trimmed.to_string()
    };
    let valid = !relative.is_empty()
        && relative.split('/').all(|part| !matches!(part, "" | "." | ".."))
        && Path::new(&relative).components().all(|part| match part {
            Component::Normal(name) => !name.eq_ignore_ascii_case(".git"),
            _ => false,
        });
    valid.then_some(relative)
}

/// An absolute path's part below `root`. The longest existing ancestor is
/// resolved first, so a path through a symbolic link to the repository (or
/// to a file that no longer exists) still counts.
fn inside(path: &Path, root: &Path) -> Option<String> {
    if let Ok(rest) = path.strip_prefix(root) {
        return rest.to_str().map(str::to_string);
    }
    let mut existing = path.to_path_buf();
    let mut missing: Vec<std::ffi::OsString> = Vec::new();
    let resolved: PathBuf = loop {
        if let Ok(real) = std::fs::canonicalize(&existing) {
            break real;
        }
        missing.push(existing.file_name()?.to_os_string());
        existing = existing.parent()?.to_path_buf();
    };
    let full = missing.iter().rev().fold(resolved, |path, part| path.join(part));
    full.strip_prefix(root).ok()?.to_str().map(str::to_string)
}
