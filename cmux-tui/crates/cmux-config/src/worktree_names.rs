//! `worktrees.location` and `worktrees.branchPrefix`: where the shared
//! worktree folder is, and the prefix of the branch each worktree cmux makes
//! for a chat or a lane gets. Unset, they are what cmux always used:
//! `~/.cmux/worktrees/<project>/<name>` on `cmux/<name>`.
//! (`agentPane.sessionWorktrees` set to `project` keeps worktrees inside the
//! project instead; the branch prefix applies there too.)

use std::path::{Path, PathBuf};

use serde_json::Value;

/// The location setting's dotted key.
pub const LOCATION_KEY: &str = "worktrees.location";

/// The branch prefix setting's dotted key.
pub const BRANCH_PREFIX_KEY: &str = "worktrees.branchPrefix";

/// The location's default, as the setting shows it.
pub const DEFAULT_LOCATION: &str = "~/.cmux/worktrees";

/// The branch prefix's default.
pub const DEFAULT_BRANCH_PREFIX: &str = "cmux/";

/// The shared worktree folder a stored location names, or None for the
/// default `~/.cmux/worktrees` (which the caller lays out, with its
/// `.noindex` link on macOS). A leading `~` is `home`; a value that is not
/// an absolute path after that, or names the default, reads as the default.
pub fn location(value: Option<&Value>, home: &Path) -> Option<PathBuf> {
    let path = expand(value.and_then(Value::as_str)?.trim(), home)?;
    (path.is_absolute() && Some(&path) != expand(DEFAULT_LOCATION, home).as_ref()).then_some(path)
}

/// `text` with a leading `~/` (or a lone `~`) as `home`; None for `~user`
/// forms and text git could not take as a path.
fn expand(text: &str, home: &Path) -> Option<PathBuf> {
    if text.is_empty() || text.contains('\0') {
        return None;
    }
    match text.strip_prefix('~') {
        Some("") => Some(home.to_path_buf()),
        Some(rest) => {
            let rest = rest.strip_prefix('/')?.trim_end_matches('/');
            Some(if rest.is_empty() { home.to_path_buf() } else { home.join(rest) })
        }
        None => Some(PathBuf::from(text.trim_end_matches('/')).components().collect()),
    }
}

/// The prefix a stored value names, or [`DEFAULT_BRANCH_PREFIX`] for none or
/// one git would not take at the start of a branch name. An empty value is
/// no prefix: the branch is the worktree's name.
pub fn branch_prefix(value: Option<&Value>) -> String {
    match value.and_then(Value::as_str) {
        Some(prefix) if valid_prefix(prefix) => prefix.to_string(),
        _ => DEFAULT_BRANCH_PREFIX.to_string(),
    }
}

/// Whether `prefix` followed by a plain name (`fix-login`) is a branch name
/// git accepts (`git check-ref-format --branch`).
fn valid_prefix(prefix: &str) -> bool {
    if prefix.is_empty() {
        return true;
    }
    let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/');
    prefix.chars().all(allowed)
        && !prefix.starts_with(['-', '/', '.'])
        && !prefix.contains("..")
        && !prefix.contains("//")
        && !prefix.contains("/.")
        && !prefix.ends_with('.')
        && !prefix.split('/').any(|part| part.ends_with(".lock"))
}
