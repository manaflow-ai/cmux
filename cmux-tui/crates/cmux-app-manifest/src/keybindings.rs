//! `contributes.keybindings`: key bindings an app installs as typed data, in
//! keybindings.json form (`{key, command, when?, args?}`), and the
//! `onKeybinding` activation that goes with them.
//!
//! Each entry is read by the same parser as the person's keybindings.json
//! ([`cmux_config::keybindings::parse_entry`]), so a binding this accepts is
//! one the app's binding table loads. `command` is a cmux action id or an op
//! of the app's own catalog family (run with `apps-run`, as its palette row
//! is). The bindings join the app layer: above cmux's defaults, below the
//! person's keybindings.json, whose removals take them out. A removal
//! (`-id`) is refused by the schema's `command` pattern: taking out
//! someone else's binding is the person's alone.

use crate::issue::Issue;
use cmux_config::keybindings::{Problem, parse_entry};
use serde_json::Value;
use std::collections::HashSet;

/// The activation entry that starts the app's host on its first contributed
/// key press (an own-op binding runs through `apps-run`, which starts it).
pub const ON_KEYBINDING: &str = "onKeybinding";

/// One accepted entry of `contributes.keybindings`, normalized.
#[derive(Debug, Clone, PartialEq)]
pub struct AppKeybinding {
    /// Normalized strokes (`["cmd+k", "s"]`).
    pub keys: Vec<String>,
    /// The action id or own op as written.
    pub command: String,
    pub when: Option<String>,
    pub args: Option<Value>,
}

impl AppKeybinding {
    /// The strokes joined as keybindings.json writes them (`cmd+k s`).
    pub fn key(&self) -> String {
        self.keys.join(" ")
    }
}

fn rows(m: &Value) -> impl Iterator<Item = (usize, &Value)> {
    m.pointer("/contributes/keybindings")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
}

/// Whether `command` names a cmux action (or an old name of one).
pub fn is_builtin_action(command: &str) -> bool {
    cmux_action_catalog::find(command).is_some()
        || cmux_action_catalog::legacy_alias(command).is_some()
}

/// The entries of `contributes.keybindings` that parse, in order. The
/// daemon reads this; [`check`] reports the rest.
pub fn keybindings(m: &Value) -> Vec<AppKeybinding> {
    rows(m)
        .filter_map(|(_, row)| {
            let entry = parse_entry(row).ok().filter(|e| !e.removal)?;
            Some(AppKeybinding {
                keys: entry.keys,
                command: entry.command,
                when: entry.when,
                args: entry.args,
            })
        })
        .collect()
}

pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    let mut seen = HashSet::new();
    let has_catalog = m.get("catalog").is_some();
    for (i, row) in rows(m) {
        let at = format!("/contributes/keybindings/{i}");
        let entry = match parse_entry(row) {
            Ok(entry) => entry,
            Err(diagnostic) => {
                let field = match diagnostic.problem {
                    Problem::MissingCommand => "/command",
                    Problem::InvalidWhen => "/when",
                    Problem::InvalidArgs => "/args",
                    _ => "/key",
                };
                out.push(Issue::error(
                    format!("{at}{field}"),
                    "keybindings.invalid",
                    diagnostic.message,
                ));
                continue;
            }
        };
        if !seen.insert((entry.keys.clone(), entry.when.clone())) {
            out.push(Issue::warning(
                format!("{at}/key"),
                "keybindings.shortcutConflict",
                format!(
                    "{} is bound twice in this app for the same condition",
                    entry.keys.join(" ")
                ),
            ));
        }
        if is_builtin_action(&entry.command) {
            continue;
        }
        if !has_catalog {
            out.push(Issue::error(
                format!("{at}/command"),
                "keybindings.unknownCommand",
                format!(
                    "{} is not a cmux action, and the app has no catalog with ops to bind",
                    entry.command
                ),
            ));
        } else if entry.args.is_some() {
            out.push(Issue::error(
                format!("{at}/args"),
                "keybindings.opArgs",
                "an app op runs as its palette row does, with no arguments",
            ));
        }
    }
    let activation = m["activation"].as_array().into_iter().flatten();
    if let Some(i) = activation.into_iter().position(|a| a == ON_KEYBINDING)
        && rows(m).next().is_none()
    {
        out.push(Issue::error(
            format!("/activation/{i}"),
            "activation.noKeybindings",
            "onKeybinding needs contributes.keybindings",
        ));
    }
}

/// A binding that is not a cmux action names an op of the app's own catalog
/// (`validate_package`).
pub(crate) fn check_ops(m: &Value, catalog: &Value, out: &mut Vec<Issue>) {
    let family = catalog["family"].as_str().unwrap_or_default();
    let names: HashSet<&str> = catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["name"].as_str())
        .collect();
    for (i, row) in rows(m) {
        let command = row["command"].as_str().unwrap_or_default();
        if command.starts_with('-') || is_builtin_action(command) {
            continue;
        }
        let at = format!("/contributes/keybindings/{i}/command");
        if !command.starts_with(&format!("{family}.")) {
            out.push(Issue::error(
                at,
                "keybindings.unknownCommand",
                format!(
                    "{command} is neither a cmux action nor an op of the app's family {family}"
                ),
            ));
        } else if !names.contains(command) {
            out.push(Issue::error(
                at,
                "keybindings.unknownOp",
                format!("{command} is not in the app's catalog"),
            ));
        }
    }
}
