//! `git commit` and `git push`: the session host commits and pushes as the
//! user would in a terminal, with their hooks and credentials, and never
//! waits for input.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::super::{CommandPlan, Flags, Selectors, UsageError, request};

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

fn expected_head(flags: &mut Flags, params: &mut Map<String, Value>) {
    if let Some(head) = flags.take("expected-head") {
        params.insert("expected_head".into(), Value::String(head));
    }
}
