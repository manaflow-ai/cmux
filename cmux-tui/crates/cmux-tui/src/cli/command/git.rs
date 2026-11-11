//! `git status|diff|branches|files|list|checkpoint|commit|push|worktree create|apply|remove|setup`: the session host's git operations, and `git comments` (the diff page's review comments, `comments.rs`). The repository
//! is the one `--path` is in, or the working directory of the terminal a
//! `--workspace`, `--screen`, `--pane`, `--tab` or `--terminal` selector
//! names; with none of them, the current directory's.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::{
    CommandPlan, Flags, Selectors, UsageError, insert_bounded_u32, insert_decimal, request, usage,
    validate_one_of,
};

const SCOPES: &[&str] = &["uncommitted", "unstaged", "staged", "committed", "branch", "commits"];
const TARGETS: &[(&str, &str)] = &[
    ("workspace", "ws"),
    ("screen", "screen"),
    ("pane", "pane"),
    ("tab", "tab"),
    ("terminal", "term"),
];

/// `git status`, `git diff [<path>...]`, `git branches`, `git files <query>...` and
/// `git list`.
pub(super) fn parse_git(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    // Comments are keyed by a worktree root, not a repository target.
    if let ["comments", action @ ..] = words {
        return comments::parse(action, flags);
    }
    let mut params = Map::new();
    let selectors = target(flags, &mut params)?;
    let operation = match words {
        ["checkpoint", action @ ..] => return checkpoint::parse(action, flags, &selectors, params),
        ["commit", paths @ ..] => return write::commit(paths, flags, &selectors, params),
        ["push"] => return write::push(flags, &selectors, params),
        ["worktree", "create"] => return write::worktree_create(flags, &selectors, params),
        ["worktree", "apply"] => return write::worktree_apply(flags, &selectors, params),
        ["worktree", "remove"] => return write::worktree_remove(flags, &selectors, params),
        ["worktree", "setup"] => {
            if let Some(value) = flags.take("since") {
                insert_decimal(&mut params, "since", "--since", value)?;
            }
            Op::GitWorktreeSetup
        }
        ["status"] => Op::GitStatus,
        ["branches"] => {
            if let Some(value) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", value, 1, 1000)?;
            }
            Op::GitBranches
        }
        ["diff", paths @ ..] => {
            let scope = flags.take("scope").unwrap_or_else(|| "uncommitted".to_string());
            validate_one_of("--scope", &scope, SCOPES)?;
            commit_range(flags, &mut params, scope == "commits")?;
            params.insert("scope".into(), Value::String(scope));
            if flags.boolean("patch") {
                params.insert("include_patch".into(), Value::Bool(true));
            }
            if let Some(value) = flags.take("max-patch-bytes") {
                let field = "max_patch_bytes";
                insert_bounded_u32(&mut params, field, "--max-patch-bytes", value, 1, 4_194_304)?;
            }
            if let Some(value) = flags.take("max-files") {
                insert_bounded_u32(&mut params, "max_files", "--max-files", value, 1, 5000)?;
            }
            if let Some(value) = flags.take("context-lines") {
                let field = "context_lines";
                insert_bounded_u32(&mut params, field, "--context-lines", value, 0, 1_000_000)?;
            }
            diff_pages(flags, &mut params)?;
            if !paths.is_empty() {
                let paths = paths.iter().map(|path| Value::String((*path).to_string()));
                params.insert("paths".into(), Value::Array(paths.collect()));
            }
            Op::GitDiff
        }
        ["files", query @ ..] if !query.is_empty() => {
            params.insert("query".into(), Value::String(query.join(" ")));
            if let Some(value) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", value, 1, 200)?;
            }
            Op::GitFilesSearch
        }
        ["list"] => {
            if let Some(value) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", value, 1, 5000)?;
            }
            Op::GitFilesList
        }
        _ => return usage("git action"),
    };
    request(operation, &selectors, flags, params)
}

/// `--base` and `--head` of `git diff --scope commits` (a pull request's change): the full
/// commit ids of the branch it goes into and of the change, both required there and
/// refused with any other scope.
fn commit_range(
    flags: &mut Flags,
    params: &mut Map<String, Value>,
    commits: bool,
) -> Result<(), UsageError> {
    for name in ["base", "head"] {
        match (flags.take(name), commits) {
            (Some(id), true) => {
                // The session host reads only a full SHA-1 or SHA-256 id in
                // lowercase (`cmux-git` `diff::commits`).
                let id = id.to_ascii_lowercase();
                if !matches!(id.len(), 40 | 64) || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err(UsageError::new(format!(
                        "--{name} must be a full commit id (40 or 64 hex digits)"
                    )));
                }
                params.insert(name.into(), Value::String(id));
            }
            (None, true) => {
                return Err(UsageError::new(format!("--scope commits needs --{name}")));
            }
            (Some(_), false) => {
                return Err(UsageError::new(format!("--{name} is only for --scope commits")));
            }
            (None, false) => {}
        }
    }
    Ok(())
}

/// The paging flags `git diff` and `git checkpoint diff` share: `--after-path`
/// continues a long file listing from the previous reply's `next_path`;
/// `--patch-offset` and `--patch-revision` read one file's raw patch in
/// bounded pages (`patch_page`), the revision from the first page.
fn diff_pages(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    if let Some(path) = flags.take("after-path") {
        if path.is_empty() {
            return Err(UsageError::new("--after-path must not be empty"));
        }
        params.insert("after_path".into(), Value::String(path));
    }
    if let Some(offset) = flags.take("patch-offset") {
        insert_decimal(params, "patch_offset", "--patch-offset", offset)?;
    }
    if let Some(revision) = flags.take("patch-revision") {
        if revision.len() != 64 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(UsageError::new(
                "--patch-revision must be the 64 hex digits of a patch_page revision",
            ));
        }
        params.insert("patch_revision".into(), Value::String(revision));
    }
    Ok(())
}

/// The repository to read: one selector, `--path`, or the current directory.
fn target(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<Selectors, UsageError> {
    let mut selectors = Selectors::default();
    let mut chosen = 0;
    for &(scope, prefix) in TARGETS {
        if let Some(value) = flags.take(scope) {
            selectors.insert(scope, prefix, &value)?;
            chosen += 1;
        }
    }
    let path = flags.take("path");
    if chosen + usize::from(path.is_some()) > 1 {
        return Err(UsageError::new(
            "give at most one of --path, --workspace, --screen, --pane, --tab and --terminal",
        ));
    }
    if chosen == 0 {
        let current = typed_current_dir()
            .map_err(|error| UsageError::new(format!("current directory: {error}")))?;
        let path = match path {
            Some(path) => current.join(path),
            None => current,
        };
        params.insert("path".into(), Value::String(path.to_string_lossy().into_owned()));
    }
    Ok(selectors)
}

/// The current folder as the shell typed it: `PWD` when it names the same
/// folder as the process's directory (which has its links resolved), so cmux
/// prints `/tmp/x`, not `/private/tmp/x`; else the process's directory.
fn typed_current_dir() -> std::io::Result<std::path::PathBuf> {
    let current = std::env::current_dir()?;
    match std::env::var_os("PWD").map(std::path::PathBuf::from) {
        Some(pwd) if pwd.is_absolute() && cmux_git::worktree::same_folder(&pwd, &current) => {
            Ok(pwd)
        }
        _ => Ok(current),
    }
}

/// `relative` (or the current folder) as an absolute folder in the spelling
/// the person typed: against [`typed_current_dir`], with `.` and `..` taken
/// as a shell takes them; the resolved folder when that spelling names
/// another folder (a `..` out of a link).
pub(in crate::cli) fn typed_folder(relative: Option<&str>) -> std::io::Result<std::path::PathBuf> {
    let current = typed_current_dir()?;
    let joined = match relative {
        Some(relative) => current.join(relative),
        None => return Ok(current),
    };
    let typed = comments::lexical(&joined);
    let real = std::fs::canonicalize(&joined).unwrap_or_else(|_| joined.clone());
    Ok(if cmux_git::worktree::same_folder(&typed, &real) { typed } else { real })
}

mod checkpoint;
mod comments;
#[cfg(test)]
mod tests;
mod write;
pub(in crate::cli) use write::localize_commit_paths;
