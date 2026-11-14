//! `apps-cli {name, words}`: the short app command `cmux <cli.name> <path…>`
//! (plans/cmux-next/app-commands-codemode.md section 1). The CLI sends the
//! first word it does not know and the words after it; the supervisor finds
//! the installed app whose manifest `cli.name` is that word and the catalog
//! op whose `cli.path` is the longest run of the next words, and answers
//! what the CLI needs to build the op's arguments and run it with
//! `apps-run` (which checks install, enable, hidden access and grants again).
//!
//! Answers:
//! - an op: `{app, name, op, path, consumed, input, positional, docs, commands}`;
//!   `consumed` is how many of `words` the path took.
//! - no words, or `help`/`--help`/`-h` first: `{app, name, commands}`, the
//!   app's command list for its help.
//! - `apps.cli.unknown`: no installed app has the name (the CLI goes on to
//!   its usage error).
//! - `apps.cli.conflict`: two installed apps claim it; details name each
//!   app's qualified form (`cmux apps run <id> …`), which always works.
//! - `apps.disabled`: the app is installed but turned off.
//! - `apps.cli.path_unknown`: the app has no command for the words;
//!   details hold its command list.

use serde_json::{Value, json};

use super::catalog::Package;
use super::mirror::Record;
use super::supervisor::{ApiError, Supervisor};
use crate::panic_free::RecoverPoison as _;

/// The help words that list an app's commands.
const HELP: &[&str] = &["help", "--help", "-h"];

impl Supervisor {
    /// `apps-cli`: resolves `cmux <name> <words…>` to one app op.
    pub fn cli_resolve(&self, name: &str, words: &[String]) -> Result<Value, ApiError> {
        let inner = self.inner.lock().recover_poison();
        let claims: Vec<(&Package, &Record)> = inner
            .catalog
            .packages
            .values()
            .filter(|package| cli_name(package) == Some(name))
            .filter_map(|package| {
                let record = inner.mirror.apps.get(&package.id).filter(|r| r.installed)?;
                Some((package, record))
            })
            .collect();
        resolve(name, words, &claims)
    }
}

fn cli_name(package: &Package) -> Option<&str> {
    package.manifest.pointer("/cli/name").and_then(Value::as_str)
}

/// The pure part of [`Supervisor::cli_resolve`]: `claims` are the installed
/// apps whose `cli.name` is `name`.
fn resolve(
    name: &str,
    words: &[String],
    claims: &[(&Package, &Record)],
) -> Result<Value, ApiError> {
    let (package, record) = match claims {
        [] => {
            return Err(ApiError::new(
                "apps.cli.unknown",
                format!("no installed app has the command {name}"),
            ));
        }
        [one] => *one,
        many => {
            let forms: Vec<String> =
                many.iter().map(|(p, _)| format!("cmux apps run {} <op>", p.id)).collect();
            let mut error = ApiError::new(
                "apps.cli.conflict",
                format!(
                    "more than one installed app is called {name}; run one with {}",
                    forms.join(" or ")
                ),
            );
            error.details = Some(
                json!({ "apps": many.iter().map(|(p, _)| &p.id).collect::<Vec<_>>(), "forms": forms }),
            );
            return Err(error);
        }
    };
    if !record.enabled {
        return Err(ApiError::new(
            "apps.disabled",
            format!("{} is turned off; turn it on in the App Store to run cmux {name}", package.id),
        ));
    }
    let ops = package.catalog_ops();
    let commands: Vec<Value> = ops
        .iter()
        .filter_map(|(op, entry)| {
            let path = entry.pointer("/cli/path")?.as_str()?;
            let visible = entry.pointer("/cli/visible").and_then(Value::as_bool) != Some(false);
            visible.then(|| json!({ "path": path, "op": op, "docs": entry["docs"] }))
        })
        .collect();
    let app_name = package.manifest["name"].clone();
    if words.first().is_none_or(|word| HELP.contains(&word.as_str())) {
        return Ok(json!({ "app": package.id, "name": app_name, "commands": commands }));
    }
    // The longest path that the words start with (paths are one to three words).
    let found = ops
        .iter()
        .filter_map(|(op, entry)| {
            let path = entry.pointer("/cli/path")?.as_str()?;
            let parts: Vec<&str> = path.split(' ').collect();
            let matches = parts.len() <= words.len()
                && parts.iter().zip(words).all(|(part, word)| *part == word.as_str());
            matches.then_some((parts.len(), op, entry, path))
        })
        .max_by_key(|(len, ..)| *len);
    let Some((consumed, op, entry, path)) = found else {
        let mut error = ApiError::new(
            "apps.cli.path_unknown",
            format!("{} has no command {}", package.id, words[0]),
        );
        error.details = Some(json!({ "app": package.id, "commands": commands }));
        return Err(error);
    };
    Ok(json!({
        "app": package.id,
        "name": app_name,
        "op": op,
        "path": path,
        "consumed": consumed,
        "input": entry.get("input").cloned().unwrap_or_else(|| json!({ "type": "object" })),
        "positional": entry.pointer("/cli/positional").cloned().unwrap_or_else(|| json!([])),
        "docs": entry["docs"],
        "commands": commands,
    }))
}

#[cfg(test)]
#[path = "cli_commands_tests.rs"]
mod tests;
