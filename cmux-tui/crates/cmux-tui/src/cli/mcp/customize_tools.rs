//! The `customize_*` tools: customize cmux by asking, from an agent
//! (cmuxterm-hq `plans/cmux-next/customize-by-asking/DESIGN.md`).
//!
//! Each tool is one `cmux customize …` verb, run by the CLI's own code in
//! this process (`customize::run_json`), so a tool, the CLI and the GUI never
//! differ. `customize_ask` starts no second agent: it opens the draft and
//! returns the brief, and the calling agent makes the edits itself, live in
//! the person's window.

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

struct CustomizeTool {
    name: &'static str,
    verb: &'static str,
    description: &'static str,
    /// The one argument, when the verb takes one: `(name, required, kind, what it is)`.
    argument: Option<(&'static str, bool, Kind, &'static str)>,
    /// A second, optional free-text argument (a note).
    note: Option<&'static str>,
    mutation: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Text,
    Generation,
}

const TOOLS: &[CustomizeTool] = &[
    CustomizeTool {
        name: "customize_ask",
        verb: "brief",
        description: "Start here when the person wants cmux itself changed (look, layout, sidebar, theme, shortcuts, their own views or widgets, automations). Opens a draft for what they asked and returns the brief: which files to edit and the rules. You make the edits yourself; each save shows live in their cmux window as a preview, with no restart. Call it again with the next wish to refine the same draft.",
        argument: Some(("wish", true, Kind::Text, "What the person asked for, in their words.")),
        note: None,
        mutation: true,
    },
    CustomizeTool {
        name: "customize_check",
        verb: "check",
        description: "After your edits: validate what is live and mark your turn done. Returns the changes and `problems` (file, line, message); fix every problem and check again. `can_apply` is true when there are none.",
        argument: None,
        note: None,
        mutation: true,
    },
    CustomizeTool {
        name: "customize_status",
        verb: "status",
        description: "What is previewing and not yet applied, which files the person edited by hand since your last turn (`by_hand`: read those again before writing), the problems, and the generation that is applied. Reads only.",
        argument: None,
        note: None,
        mutation: false,
    },
    CustomizeTool {
        name: "customize_diff",
        verb: "diff",
        description: "The preview as text: a unified diff of every file that differs from the applied generation.",
        argument: None,
        note: None,
        mutation: false,
    },
    CustomizeTool {
        name: "customize_apply",
        verb: "apply",
        description: "Keep the preview: it becomes the next numbered generation. Refused with the problems when the live files do not validate. Only when the person said to apply or keep it.",
        argument: None,
        note: Some("A short label for the generation; the wish is used when absent."),
        mutation: true,
    },
    CustomizeTool {
        name: "customize_discard",
        verb: "discard",
        description: "Put the applied generation back on screen. The discarded draft is kept as a numbered generation (`kept_as`), so it can be brought back with customize_rollback. Only when the person said to discard or undo the preview.",
        argument: None,
        note: None,
        mutation: true,
    },
    CustomizeTool {
        name: "customize_rollback",
        verb: "rollback",
        description: "Make an earlier generation live and current: the one before the current one, or `generation`. Unapplied changes are kept as their own generation first. Going forward again is the same call with the newer number.",
        argument: Some((
            "generation",
            false,
            Kind::Generation,
            "A generation number from customize_generations.",
        )),
        note: None,
        mutation: true,
    },
    CustomizeTool {
        name: "customize_generations",
        verb: "generations",
        description: "The history, newest first: every applied, discarded and autosaved generation with its number, label, who made it and how many files it changed; `current` is the live one.",
        argument: None,
        note: None,
        mutation: false,
    },
    CustomizeTool {
        name: "customize_show",
        verb: "show",
        description: "What one generation changed from the one before it, as unified diffs.",
        argument: Some((
            "generation",
            true,
            Kind::Generation,
            "A generation number from customize_generations.",
        )),
        note: None,
        mutation: false,
    },
    CustomizeTool {
        name: "customize_save",
        verb: "save",
        description: "Save what is live as a named profile: one portable file to keep or share. Private settings and anything that looks like a secret never go in; `left_out` says what was left out.",
        argument: Some((
            "name",
            true,
            Kind::Text,
            "Lowercase letters, digits, '-' and '_', like compact-night.",
        )),
        note: Some("One line about the profile."),
        mutation: true,
    },
    CustomizeTool {
        name: "customize_use",
        verb: "use",
        description: "Preview a saved profile (by name) or a profile file (by path) as a draft: checked whole before anything is written, then live. The person applies or discards it.",
        argument: Some((
            "profile",
            true,
            Kind::Text,
            "A saved profile's name, or the path of a profile file.",
        )),
        note: None,
        mutation: true,
    },
    CustomizeTool {
        name: "customize_profiles",
        verb: "profiles",
        description: "The saved profiles: name, description, how many settings and files each holds.",
        argument: None,
        note: None,
        mutation: false,
    },
];

pub(super) fn descriptors() -> Vec<Value> {
    TOOLS.iter().map(descriptor).collect()
}

fn descriptor(tool: &CustomizeTool) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();
    if let Some((name, needed, kind, what)) = tool.argument {
        let schema = match kind {
            Kind::Text => json!({"type": "string", "minLength": 1, "description": what}),
            Kind::Generation => json!({"type": "integer", "minimum": 1, "description": what}),
        };
        properties.insert(name.into(), schema);
        if needed {
            required.push(name);
        }
    }
    if let Some(what) = tool.note {
        properties.insert("note".into(), json!({"type": "string", "description": what}));
    }
    json!({
        "name": tool.name, "description": tool.description,
        "inputSchema": {"type": "object", "properties": properties, "required": required,
            "additionalProperties": false},
        "annotations": {"readOnlyHint": !tool.mutation, "destructiveHint": false,
            "idempotentHint": !tool.mutation, "openWorldHint": false}
    })
}

/// The CLI words for one call. A text argument is one word after `--`, so
/// it can never become an option.
fn words(tool: &CustomizeTool, arguments: &Map<String, Value>) -> Result<Vec<String>, String> {
    for name in arguments.keys() {
        let known = tool.argument.is_some_and(|(argument, ..)| argument == name.as_str())
            || (tool.note.is_some() && name == "note");
        if !known {
            return Err(format!("{} has no argument {name:?}", tool.name));
        }
    }
    let mut out = vec![tool.verb.to_owned()];
    let plain = |name: &str, value: &str| -> Result<String, String> {
        if value.trim().is_empty() {
            return Err(format!("{name} must be a nonempty string"));
        }
        if tool.verb != "brief" && value.starts_with('-') {
            return Err(format!("{name} must not start with \"-\""));
        }
        Ok(value.to_owned())
    };
    if let Some((name, needed, kind, _)) = tool.argument {
        match (arguments.get(name), kind) {
            (None | Some(Value::Null), _) if needed => return Err(format!("{name} is required")),
            (None | Some(Value::Null), _) => {}
            (Some(Value::String(text)), Kind::Text) => {
                if tool.verb == "brief" {
                    out.push("--".to_owned());
                }
                out.push(plain(name, text)?);
            }
            (Some(value), Kind::Generation) => match value.as_u64().filter(|n| *n >= 1) {
                Some(n) => out.push(n.to_string()),
                None => return Err(format!("{name} is a generation number")),
            },
            (Some(_), Kind::Text) => return Err(format!("{name} must be a string")),
        }
    }
    match arguments.get("note") {
        None | Some(Value::Null) => {}
        Some(Value::String(note)) if note.trim().is_empty() => {}
        Some(Value::String(note)) => out.push(plain("note", note)?),
        Some(_) => return Err("note must be a string".to_owned()),
    }
    Ok(out)
}

/// The tool result of `name`, or `None` when it is not a customize tool.
pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    let tool = TOOLS.iter().find(|tool| tool.name == name)?;
    Some(match words(tool, arguments) {
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
        Ok(words) => match backend.customize(&words) {
            Ok(value) => success(value, tool.mutation),
            Err(failure) => failure_result(failure),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(name: &str, args: Value) -> Result<Vec<String>, String> {
        let tool = TOOLS.iter().find(|tool| tool.name == name).unwrap();
        words(tool, args.as_object().unwrap())
    }

    #[test]
    fn customize_tool_arguments_become_the_cli_words() {
        assert_eq!(
            w("customize_ask", json!({"wish": "--compact sidebar, please"})).unwrap(),
            ["brief", "--", "--compact sidebar, please"]
        );
        assert_eq!(w("customize_check", json!({})).unwrap(), ["check"]);
        assert_eq!(w("customize_apply", json!({"note": "compact"})).unwrap(), ["apply", "compact"]);
        assert_eq!(w("customize_apply", json!({})).unwrap(), ["apply"]);
        assert_eq!(w("customize_rollback", json!({})).unwrap(), ["rollback"]);
        assert_eq!(w("customize_rollback", json!({"generation": 3})).unwrap(), ["rollback", "3"]);
        assert_eq!(w("customize_show", json!({"generation": 2})).unwrap(), ["show", "2"]);
        assert_eq!(
            w("customize_save", json!({"name": "compact-night", "note": "small and dark"}))
                .unwrap(),
            ["save", "compact-night", "small and dark"]
        );
        assert_eq!(
            w("customize_use", json!({"profile": "compact-night"})).unwrap(),
            ["use", "compact-night"]
        );
        for (name, bad) in [
            ("customize_ask", json!({})),
            ("customize_ask", json!({"wish": " "})),
            ("customize_show", json!({})),
            ("customize_show", json!({"generation": "2"})),
            ("customize_rollback", json!({"generation": 0})),
            ("customize_save", json!({"name": "--help"})),
            ("customize_use", json!({"profile": "-x"})),
            ("customize_status", json!({"extra": 1})),
            ("customize_discard", json!({"note": "x"})),
        ] {
            assert!(w(name, bad.clone()).is_err(), "{name} {bad}");
        }
        let names: Vec<String> = descriptors()
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_owned))
            .collect();
        assert_eq!(names.len(), 12);
        assert!(names.iter().all(|name| name.starts_with("customize_")));
    }
}
