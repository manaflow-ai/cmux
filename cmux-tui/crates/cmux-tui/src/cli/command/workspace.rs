//! `workspace create`: the new workspace's first terminal may start in a
//! folder (`--cwd`) and run a command (`--shell <script>` or exact argv after
//! `--`), as classic `cmux new-workspace --cwd --command` did. It opens in
//! the background unless `--focus` is given, and goes where
//! `workspaces.newPlacement` puts it unless `--top` puts it first; run from a
//! cmux terminal, below that terminal's workspace.

use super::*;

pub(super) fn workspace_create(
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    // Creating a workspace does not move focus (socket focus policy) unless
    // `--focus` asks; agents still pass `--no-focus`, which is the default.
    let _ = flags.boolean("no-focus");
    if flags.boolean("focus") {
        params.insert("focus".into(), Value::Bool(true));
    }
    if let Some(name) = flags.take("name") {
        params.insert("name".into(), Value::String(name));
    }
    params.insert(
        "initial_content".into(),
        Value::String(if flags.boolean("empty") { "empty" } else { "terminal" }.into()),
    );
    if flags.boolean("ephemeral") {
        params.insert("ephemeral".into(), Value::Bool(true));
    }
    // First in the sidebar (below Home) for this create, whatever
    // `workspaces.newPlacement` says: an agent's workspace on top (#29875).
    if flags.boolean("top") {
        params.insert("placement".into(), Value::String("top".into()));
    } else if let Some(key) = std::env::var("CMUX_WORKSPACE_ID").ok().filter(|key| !key.is_empty())
    {
        // Run from a cmux terminal: the new workspace goes below the one
        // the script runs in, not next to the person's selection
        // (ask-48544d7525). A place hint only; an older daemon gets the
        // request without it (wire/workspace_created_by.rs).
        params.insert("created_by".into(), json!({"kind": "script", "workspace": key}));
    }
    // The daemon refuses these with --empty: there is no terminal to launch.
    if let Some(cwd) = flags.take("cwd") {
        params.insert("cwd".into(), Value::String(cwd));
    }
    match (argv, flags.take("shell")) {
        (None, None) => {}
        (Some(argv), None) if argv.first().is_some_and(|program| !program.is_empty()) => {
            params.insert("argv".into(), json!(argv));
        }
        (None, Some(script)) if !script.is_empty() => {
            params.insert("shell".into(), Value::String(script));
        }
        _ => return Err(UsageError::new("give exact argv after -- or one --shell script")),
    }
    request(ResourceOperation::WorkspaceCreate, selectors, flags, params)
}
