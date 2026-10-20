//! `workspace create`: the new workspace's first terminal may start in a
//! folder (`--cwd`) and run a command (`--shell <script>` or exact argv after
//! `--`), as classic `cmux new-workspace --cwd --command` did.

use super::*;

pub(super) fn workspace_create(
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    // Creating a workspace never moves focus (socket focus policy); agents
    // still pass `--no-focus`, so it is accepted and does nothing.
    let _ = flags.boolean("no-focus");
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
