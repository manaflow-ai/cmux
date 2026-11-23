//! `project actions [PATH]`: the actions of the project a folder is in
//! (`<project>/.cmux/actions.json`, merged with the global `actions`), from
//! the session host's `project.actions.list`. The folder is PATH, `--path`,
//! the working directory of the terminal a `--workspace`, `--screen`,
//! `--pane`, `--tab` or `--terminal` selector names, or the current one.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::{CommandPlan, Flags, UsageError, request, usage};

pub(super) fn parse_project(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let path = match words {
        ["actions"] => None,
        ["actions", path] => Some(*path),
        _ => return usage("project action"),
    };
    if let Some(path) = path {
        if flags.take("path").is_some() {
            return Err(UsageError::new("give the folder once: PATH or --path"));
        }
        flags.values.insert("path".into(), Some(path.to_string()));
    }
    let mut params = Map::new();
    let selectors = super::git::target(flags, &mut params)?;
    if flags.boolean("no-global") {
        params.insert("include_global".into(), Value::Bool(false));
    }
    request(Op::ProjectActionsList, &selectors, flags, params)
}
