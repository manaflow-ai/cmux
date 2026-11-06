//! The `automation_*` tools (docs/automations-teleport-teams.md, section 5).
//!
//! Each tool is one `cmux automation …` verb: its arguments become the verb's
//! words and the backend runs the CLI's own code in this process
//! (`automation::run_json`), so a tool and the CLI never differ. Option values
//! go as `--flag=value`, and a positional that starts with `-` is refused, so
//! an argument can never become another option.

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

struct AutomationTool {
    name: &'static str,
    verb: &'static str,
    description: &'static str,
    mutation: bool,
    destructive: bool,
}

const TOOLS: &[AutomationTool] = &[
    AutomationTool {
        name: "automation_list",
        verb: "list",
        description: "List automations (scheduled prompts and commands) on this Mac (target local, default) or on cmux Cloud (target cloud), with their next run; on this Mac also the ones that moved away (moved).",
        mutation: false,
        destructive: false,
    },
    AutomationTool {
        name: "automation_get",
        verb: "show",
        description: "Read one automation by id, unique id prefix or name.",
        mutation: false,
        destructive: false,
    },
    AutomationTool {
        name: "automation_create",
        verb: "create",
        description: "Make an automation: name, one body (prompt: an agent runs it; command: a shell runs it, this Mac only) and one schedule (hourly, daily HH:MM, weekdays HH:MM, weekly \"fri 17:00\", every 30m, at, in, cron, manual; webhook on Cloud only). target cloud runs a prompt in the Cloud Chief with this Mac asleep; private and editors set team sharing there.",
        mutation: true,
        destructive: false,
    },
    AutomationTool {
        name: "automation_run",
        verb: "run",
        description: "Run an automation now. The same idempotency_key starts one run.",
        mutation: true,
        destructive: false,
    },
    AutomationTool {
        name: "automation_pause",
        verb: "pause",
        description: "Pause an automation: it stops running on schedule.",
        mutation: true,
        destructive: false,
    },
    AutomationTool {
        name: "automation_resume",
        verb: "resume",
        description: "Resume a paused automation. Times missed while it was paused are not run.",
        mutation: true,
        destructive: false,
    },
    AutomationTool {
        name: "automation_delete",
        verb: "delete",
        description: "Delete an automation; its run history is kept. Only when the person asked for it.",
        mutation: true,
        destructive: true,
    },
    AutomationTool {
        name: "automation_runs",
        verb: "history",
        description: "List an automation's runs, newest first (every scheduled time has a row: run, skipped with a reason, or caught up).",
        mutation: false,
        destructive: false,
    },
    AutomationTool {
        name: "automation_teleport",
        verb: "teleport",
        description: "Move an automation to another place: to cloud (cmux Cloud), home (this Mac, from Cloud) or ssh:HOST[:DIR] (another machine). Exactly one place runs it at any time; a move that did not finish resumes when called again, abort cancels it. A shell command cannot move to Cloud.",
        mutation: true,
        destructive: false,
    },
    AutomationTool {
        name: "automation_audit",
        verb: "audit",
        description: "Read the Cloud audit log of automation changes (who created, changed, ran, moved or deleted what), for one automation or the team.",
        mutation: false,
        destructive: false,
    },
];

/// Options each verb takes, as `(argument, cli flag, kind)`.
const STRING: u8 = 0;
const BOOL: u8 = 1;
const INT: u8 = 2;
const LIST: u8 = 3;

const CREATE_OPTIONS: &[(&str, &str, u8)] = &[
    ("prompt", "prompt", STRING),
    ("command", "command", STRING),
    ("hourly", "hourly", BOOL),
    ("daily", "daily", STRING),
    ("weekdays", "weekdays", STRING),
    ("weekly", "weekly", STRING),
    ("every", "every", STRING),
    ("at", "at", STRING),
    ("in", "in", STRING),
    ("cron", "cron", STRING),
    ("manual", "manual", BOOL),
    ("webhook", "webhook", BOOL),
    ("tz", "tz", STRING),
    ("folder", "folder", STRING),
    ("model", "model", STRING),
    ("timeout", "timeout", STRING),
    ("catch_up", "catch-up", STRING),
    ("paused", "paused", BOOL),
    ("private", "private", BOOL),
    ("editors", "editor", LIST),
];

fn options(verb: &str) -> &'static [(&'static str, &'static str, u8)] {
    match verb {
        "create" => CREATE_OPTIONS,
        "run" => &[("wait", "wait", BOOL)],
        "history" => &[("limit", "limit", INT), ("state", "state", STRING)],
        "teleport" => &[("to", "to", STRING), ("abort", "abort", BOOL)],
        "audit" => &[("limit", "limit", INT)],
        _ => &[],
    }
}

/// The positional argument a verb takes, and whether it is required.
fn positional(verb: &str) -> Option<(&'static str, bool)> {
    match verb {
        "list" => None,
        "create" => Some(("name", true)),
        "history" | "audit" => Some(("automation", false)),
        _ => Some(("automation", true)),
    }
}

pub(super) fn descriptors() -> Vec<Value> {
    TOOLS.iter().map(descriptor).collect()
}

fn descriptor(tool: &AutomationTool) -> Value {
    let mut properties = Map::new();
    let target = if tool.verb == "audit" { "cloud" } else { "local" };
    properties.insert(
        "target".into(),
        json!({"type": "string", "enum": ["local", "cloud"], "default": target,
               "description": "local: this Mac's automations; cloud: cmux Cloud's."}),
    );
    let mut required = Vec::new();
    if let Some((name, needed)) = positional(tool.verb) {
        let what = if name == "name" {
            "The new automation's name."
        } else {
            "An automation id, unique id prefix, or name."
        };
        properties
            .insert(name.into(), json!({"type": "string", "minLength": 1, "description": what}));
        if needed {
            required.push(name);
        }
    }
    for (arg, _, kind) in options(tool.verb) {
        let schema = match *kind {
            BOOL => json!({"type": "boolean"}),
            INT => json!({"type": "integer", "minimum": 1, "maximum": 1000}),
            LIST => json!({"type": "array", "items": {"type": "string", "minLength": 1}}),
            _ => json!({"type": "string", "minLength": 1}),
        };
        properties.insert((*arg).into(), schema);
    }
    if tool.verb == "teleport" {
        properties.insert(
            "to".into(),
            json!({"type": "string", "minLength": 1, "description": "cloud, home or ssh:HOST[:DIR]."}),
        );
    }
    if tool.mutation {
        properties.insert(
            "idempotency_key".into(),
            json!({"type": "string", "minLength": 1, "maxLength": 128}),
        );
    }
    json!({
        "name": tool.name, "description": tool.description,
        "inputSchema": {"type": "object", "properties": properties, "required": required,
            "additionalProperties": false},
        "annotations": {"readOnlyHint": !tool.mutation, "destructiveHint": tool.destructive,
            "idempotentHint": true, "openWorldHint": true}
    })
}

/// The CLI words for one call, and the idempotency key a mutation carries
/// (the caller's, else a fresh one).
fn words(
    tool: &AutomationTool,
    arguments: &Map<String, Value>,
) -> Result<(Vec<String>, Option<String>), String> {
    let opts = options(tool.verb);
    let pos = positional(tool.verb);
    for name in arguments.keys() {
        let known = name == "target"
            || (tool.mutation && name == "idempotency_key")
            || pos.is_some_and(|(p, _)| p == name.as_str())
            || opts.iter().any(|(arg, _, _)| *arg == name.as_str());
        if !known {
            return Err(format!("{} has no argument {name:?}", tool.name));
        }
    }
    let text = |name: &str| -> Result<Option<String>, String> {
        match arguments.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if !s.is_empty() => Ok(Some(s.clone())),
            Some(_) => Err(format!("{name} must be a nonempty string")),
        }
    };
    let mut out = vec![tool.verb.to_string()];
    let default_target = if tool.verb == "audit" { "cloud" } else { "local" };
    match text("target")?.as_deref().unwrap_or(default_target) {
        "local" => {}
        "cloud" => out.extend(["--target".to_string(), "cloud".to_string()]),
        other => return Err(format!("target is local or cloud, not {other:?}")),
    }
    if let Some((name, needed)) = pos {
        match text(name)? {
            Some(v) if v.starts_with('-') => {
                return Err(format!("{name} must not start with \"-\""));
            }
            Some(v) => out.push(v),
            None if needed => return Err(format!("{name} is required")),
            None => {}
        }
    }
    for (arg, flag, kind) in opts {
        let Some(value) = arguments.get(*arg) else { continue };
        match (*kind, value) {
            (BOOL, Value::Bool(true)) => out.push(format!("--{flag}")),
            (BOOL, Value::Bool(false)) => {}
            (INT, v) if v.as_u64().is_some_and(|n| (1..=1000).contains(&n)) => {
                out.push(format!("--{flag}={}", v.as_u64().unwrap_or(1)));
            }
            (LIST, Value::Array(items)) => {
                for item in items {
                    match item.as_str().filter(|s| !s.is_empty()) {
                        Some(s) => out.push(format!("--{flag}={s}")),
                        None => return Err(format!("{arg} holds nonempty strings")),
                    }
                }
            }
            (STRING, Value::String(s)) if !s.is_empty() => out.push(format!("--{flag}={s}")),
            _ => return Err(format!("{arg} has the wrong type")),
        }
    }
    let key = if tool.mutation {
        let key = match text("idempotency_key")? {
            Some(k) => k,
            None => fresh_key(tool.verb),
        };
        cmux_tui_core::resource::validate_idempotency_key(&key).map_err(|e| e.message)?;
        if tool.verb == "run" && !out.iter().any(|w| w == "--target") {
            out.push(format!("--key={key}"));
        }
        Some(key)
    } else {
        None
    };
    Ok((out, key))
}

fn fresh_key(verb: &str) -> String {
    let mut bytes = [0u8; 12];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read as _;
        let _ = f.read_exact(&mut bytes);
    }
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("mcp-automation-{verb}-{hex}")
}

/// The tool result of `name`, or `None` when it is not an automation tool.
pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    let tool = TOOLS.iter().find(|t| t.name == name)?;
    Some(match words(tool, arguments) {
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
        Ok((words, key)) => match backend.automation(&words, key.as_deref()) {
            Ok(value) => success(value, tool.mutation),
            Err(failure) => failure_result(failure),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(name: &str, args: Value) -> Result<(Vec<String>, Option<String>), String> {
        let tool = TOOLS.iter().find(|t| t.name == name).unwrap();
        words(tool, args.as_object().unwrap())
    }

    #[test]
    fn teleport_mcp_tool_arguments_become_the_cli_words() {
        let (create, key) = w(
            "automation_create",
            json!({"name": "Brief", "target": "cloud", "prompt": "--sum up", "weekdays": "09:00",
                   "private": true, "editors": ["user_a", "user_b"], "catch_up": "none",
                   "idempotency_key": "k-1"}),
        )
        .unwrap();
        assert_eq!(
            create,
            [
                "create",
                "--target",
                "cloud",
                "Brief",
                "--prompt=--sum up",
                "--weekdays=09:00",
                "--catch-up=none",
                "--private",
                "--editor=user_a",
                "--editor=user_b"
            ]
        );
        assert_eq!(key.as_deref(), Some("k-1"));
        let (run, key) = w("automation_run", json!({"automation": "Brief"})).unwrap();
        let key = key.unwrap();
        assert!(key.starts_with("mcp-automation-run-"));
        assert_eq!(run, ["run".to_string(), "Brief".into(), format!("--key={key}")]);
        assert_eq!(
            w("automation_teleport", json!({"automation": "Brief", "to": "ssh:mini"})).unwrap().0,
            ["teleport", "Brief", "--to=ssh:mini"]
        );
        assert_eq!(w("automation_audit", json!({})).unwrap().0, ["audit", "--target", "cloud"]);
        assert_eq!(w("automation_list", json!({})).unwrap(), (vec!["list".to_string()], None));
        assert_eq!(
            w("automation_runs", json!({"automation": "Brief", "limit": 5})).unwrap().0,
            ["history", "Brief", "--limit=5"]
        );
        for bad in [
            json!({"automation": "--all"}),
            json!({"automation": "x", "target": "mars"}),
            json!({"automation": "x", "extra": 1}),
        ] {
            assert!(w("automation_pause", bad.clone()).is_err(), "{bad}");
        }
        assert!(w("automation_get", json!({})).is_err(), "automation is required");
        let names: Vec<_> =
            descriptors().iter().map(|d| d["name"].as_str().unwrap().to_string()).collect();
        assert_eq!(names.len(), 10);
        assert!(names.iter().all(|n| n.starts_with("automation_")));
    }
}
