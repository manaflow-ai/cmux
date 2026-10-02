//! `git status|diff`: the session host's read-only git reads. The repository
//! is the one `--path` is in, or the working directory of the terminal a
//! `--workspace`, `--screen`, `--pane`, `--tab` or `--terminal` selector
//! names; with none of them, the current directory's.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::{
    CommandPlan, Flags, Selectors, UsageError, insert_bounded_u32, request, usage, validate_one_of,
};

const SCOPES: &[&str] = &["uncommitted", "unstaged", "staged", "committed", "branch"];
const TARGETS: &[(&str, &str)] = &[
    ("workspace", "ws"),
    ("screen", "screen"),
    ("pane", "pane"),
    ("tab", "tab"),
    ("terminal", "term"),
];

/// `git status` and `git diff [<path>...]`.
pub(super) fn parse_git(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    let selectors = target(flags, &mut params)?;
    let operation = match words {
        ["status"] => Op::GitStatus,
        ["diff", paths @ ..] => {
            let scope = flags.take("scope").unwrap_or_else(|| "uncommitted".to_string());
            validate_one_of("--scope", &scope, SCOPES)?;
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
            if !paths.is_empty() {
                let paths = paths.iter().map(|path| Value::String((*path).to_string()));
                params.insert("paths".into(), Value::Array(paths.collect()));
            }
            Op::GitDiff
        }
        _ => return usage("git action"),
    };
    request(operation, &selectors, flags, params)
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
        let current = std::env::current_dir()
            .map_err(|error| UsageError::new(format!("current directory: {error}")))?;
        let path = match path {
            Some(path) => current.join(path),
            None => current,
        };
        params.insert("path".into(), Value::String(path.to_string_lossy().into_owned()));
    }
    Ok(selectors)
}

#[cfg(test)]
mod tests;
