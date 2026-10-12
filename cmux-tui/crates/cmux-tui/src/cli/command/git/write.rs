//! `git commit` and `git push`: the session host commits and pushes as the
//! user would in a terminal, with their hooks and credentials, and never
//! waits for input.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::super::{CommandPlan, Flags, Selectors, UsageError, WireOperation, request};

/// `git commit --message <text> [--all [--include-untracked]] [--amend]
/// [--no-verify] [--expected-head <commit>] [<path>...]`.
pub(super) fn commit(
    paths: &[&str],
    flags: &mut Flags,
    selectors: &Selectors,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    params.insert("message".into(), Value::String(flags.required("message")?));
    let all = flags.boolean("all");
    let include_untracked = flags.boolean("include-untracked");
    if all && !paths.is_empty() {
        return Err(UsageError::new("give --all or paths, not both"));
    }
    if include_untracked && !all {
        return Err(UsageError::new("--include-untracked needs --all"));
    }
    if !paths.is_empty() {
        let paths = paths.iter().map(|path| Value::String((*path).to_string()));
        params.insert("paths".into(), Value::Array(paths.collect()));
    }
    for (set, field) in [
        (all, "all"),
        (include_untracked, "include_untracked"),
        (flags.boolean("amend"), "amend"),
        (flags.boolean("no-verify"), "no_verify"),
    ] {
        if set {
            params.insert(field.into(), Value::Bool(true));
        }
    }
    expected_head(flags, &mut params);
    request(Op::GitCommit, selectors, flags, params)
}

/// `git push [--remote <name>] [--branch <name>] [--set-upstream |
/// --no-set-upstream] [--expected-head <commit>]`.
pub(super) fn push(
    flags: &mut Flags,
    selectors: &Selectors,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    for field in ["remote", "branch"] {
        if let Some(value) = flags.take(field) {
            params.insert(field.into(), Value::String(value));
        }
    }
    match (flags.boolean("set-upstream"), flags.boolean("no-set-upstream")) {
        (true, true) => {
            return Err(UsageError::new("give --set-upstream or --no-set-upstream, not both"));
        }
        (true, false) => {
            params.insert("set_upstream".into(), Value::Bool(true));
        }
        (false, true) => {
            params.insert("set_upstream".into(), Value::Bool(false));
        }
        (false, false) => {}
    }
    expected_head(flags, &mut params);
    request(Op::GitPush, selectors, flags, params)
}

/// `git worktree create [--name <name>] [--base <revision>]`.
pub(super) fn worktree_create(
    flags: &mut Flags,
    selectors: &Selectors,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    for field in ["name", "base"] {
        if let Some(value) = flags.take(field) {
            params.insert(field.into(), Value::String(value));
        }
    }
    request(Op::GitWorktreeCreate, selectors, flags, params)
}

/// `git worktree apply`: the worktree's work, onto its main checkout.
pub(super) fn worktree_apply(
    flags: &mut Flags,
    selectors: &Selectors,
    params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    request(Op::GitWorktreeApply, selectors, flags, params)
}

/// `git worktree remove [--discard]`: the worktree and its branch.
pub(super) fn worktree_remove(
    flags: &mut Flags,
    selectors: &Selectors,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    if flags.boolean("discard") {
        params.insert("discard".into(), Value::Bool(true));
    }
    request(Op::GitWorktreeRemove, selectors, flags, params)
}

fn expected_head(flags: &mut Flags, params: &mut Map<String, Value>) {
    if let Some(head) = flags.take("expected-head") {
        params.insert("expected_head".into(), Value::String(head));
    }
}

/// Commits, pushes and worktrees run only on this machine's daemon (`machine` is
/// `current`): a commit or push on another machine is refused (coordinator
/// decision, remote git writes stay refused). Commit paths name files from
/// where `cmux` runs, so they are joined with the current directory. Call
/// after the global route is applied.
pub(in crate::cli) fn localize_commit_paths(
    operation: &WireOperation,
    params: &mut Value,
) -> Result<(), String> {
    let write = matches!(
        operation,
        WireOperation::Typed(
            Op::GitCommit
                | Op::GitPush
                | Op::GitWorktreeCreate
                | Op::GitWorktreeApply
                | Op::GitWorktreeRemove,
        )
    );
    if !write {
        return Ok(());
    }
    if params.get("machine").and_then(Value::as_str) != Some("current") {
        return Err("git commit, git push and git worktree run only on this machine".into());
    }
    if !matches!(operation, WireOperation::Typed(Op::GitCommit)) {
        return Ok(());
    }
    let Some(paths) = params.get_mut("paths").and_then(Value::as_array_mut) else {
        return Ok(());
    };
    let current = std::env::current_dir().map_err(|error| format!("current directory: {error}"))?;
    for path in paths.iter_mut() {
        let Some(text) = path.as_str() else { continue };
        let mut joined = current.join(text).to_string_lossy().into_owned();
        if text.ends_with('/') && !joined.ends_with('/') {
            joined.push('/');
        }
        *path = Value::String(joined);
    }
    Ok(())
}
