//! `customize_components` and `customize_tokens`: what an agent customizing cmux can build with
//! (cmuxterm-hq RFD `docs/rfd/drafts/component-libraries.md`, adoption 6; Leo, 2026-11-25:
//! "have good docs for agents and good copy-paste prompts for agents"). The kit's components
//! with their props, variants and one example each, and the design tokens with today's values,
//! read from the sources compiled into this build (`cmux_customize::kit`). Both only read.

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const COMPONENTS: &str = "customize_components";
pub(super) const TOKENS: &str = "customize_tokens";

const READ_ONLY: &str = r#"{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}"#;

fn read_only() -> Value {
    serde_json::from_str(READ_ONLY).unwrap_or(Value::Null)
}

pub(super) fn descriptors() -> Vec<Value> {
    vec![
        json!({
            "name": COMPONENTS,
            "title": "List the cmux kit's components",
            "description": "The components a customization page, plugin or web page composes, from webviews/src/kit/index.ts (import from there only): each with its file, status (ready|experimental), summary, props {name, type, optional, default, values, doc}, variants (the props whose type is a union of strings, with every value), the gallery entries that show it, and one JSX example. Also the kit's rules: color only from tokens, no restyling .kit-*/.ui-* classes, text from the caller. Give name for one component (case-insensitive).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "minLength": 1, "description": "One component, e.g. Pill or Button. Omit for all."}
                }
            },
            "annotations": read_only(),
        }),
        json!({
            "name": TOKENS,
            "title": "List cmux's design tokens",
            "description": "The design tokens with today's values and the CSS variable for each: radius, spacing, controls, icons, type, motion, color (theme roles, never literals), elevation, glass, roles (tier-2 --role-* variables), instrument (Instrument's token table, today vs. named) and look (the properties a look's agent-pane/theme.css may set). Give group for one.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "group": {"type": "string", "enum": cmux_customize::kit::TOKEN_GROUPS, "description": "One token group. Omit for all."}
                }
            },
            "annotations": read_only(),
        }),
    ]
}

/// The one optional string argument `key`, or why the arguments are wrong.
fn string_arg(arguments: &Map<String, Value>, key: &str) -> Result<Option<String>, String> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.trim().is_empty() => Ok(Some(s.trim().to_owned())),
        Some(_) => Err(format!("{key} must be a non-empty string")),
    }
}

/// Answers a kit tool; `None` for any other tool name.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    let answer = match name {
        COMPONENTS => string_arg(arguments, "name")
            .and_then(|n| cmux_customize::kit::components(n.as_deref())),
        TOKENS => {
            string_arg(arguments, "group").and_then(|g| cmux_customize::kit::tokens(g.as_deref()))
        }
        _ => return None,
    };
    Some(match answer {
        Ok(value) => success(value, false),
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
    })
}

#[cfg(test)]
#[path = "customize_kit_tools_tests.rs"]
mod tests;
