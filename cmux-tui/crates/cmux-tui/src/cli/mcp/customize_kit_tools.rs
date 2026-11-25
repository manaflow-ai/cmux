//! `customize_tokens` and `customize_components`: the component kit read by
//! an agent (cmuxterm-hq `docs/rfd/drafts/component-libraries.md`, item 6).
//! Each runs `cmux customize tokens|components …` in this process, as the
//! other `customize_*` tools do, and reads only: no file is written and
//! nothing the app draws changes.

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

const TOKENS: &str = "customize_tokens";
const COMPONENTS: &str = "customize_components";
const ACTIONS: &[&str] = &["list", "show", "test"];

pub(super) fn descriptors() -> Vec<Value> {
    let read_only = json!({"readOnlyHint": true, "destructiveHint": false,
        "idempotentHint": true, "openWorldHint": false});
    vec![
        json!({
            "name": TOKENS,
            "description": "The design tokens cmux draws with, so a customization or view names a token instead of a raw number. `list` returns Instrument's tokens (name, group, the value drawn today, Instrument's value where it differs and what it waits on, the `--instrument-*` CSS property) and the app's scales: spacing, radius, type, control, icon, motion; `group` narrows to one token group (ink, corner, type…) or one scale. `show` returns one token (by name or CSS property) or one scale. `test` says whether a value is a step of a scale (`family`, or every length scale; a value ending in ms is motion) and, when it is not, the nearest step to use; a token name tests whether that token exists.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ACTIONS},
                    "group": {"type": "string", "minLength": 1, "description": "list: a token group or a scale family."},
                    "name": {"type": "string", "minLength": 1, "description": "show: a token name (corner.card), its CSS property (--instrument-corner-card) or a scale family."},
                    "value": {"description": "test: a length (14, \"14px\"), a duration (\"180ms\") or a token name.", "oneOf": [{"type": "number"}, {"type": "string", "minLength": 1}]},
                    "family": {"type": "string", "enum": cmux_customize::kit::FAMILIES, "description": "test: the scale to test against."}
                },
                "required": ["action"],
                "additionalProperties": false
            },
            "annotations": read_only.clone()
        }),
        json!({
            "name": COMPONENTS,
            "description": "The web component kit (webviews/src/ui), from its generated manifest, so an agent uses a component and props that exist instead of inventing them. `list` returns every component (name, tier ui or kit, status, summary, its doc page); `filter` keeps one tier or status. `show` returns one component whole: its props with types and docs, what it extends, its data attributes and its gallery entries. `test` checks a props object against the component's declared props and names each unknown prop and each missing required one, with the fix. With no manifest in this checkout the answer says how to make it (available: false).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ACTIONS},
                    "filter": {"type": "string", "minLength": 1, "description": "list: a tier (ui, kit) or a status."},
                    "name": {"type": "string", "minLength": 1, "description": "show, test: the component's name."},
                    "props": {"type": "object", "description": "test: the props you would pass."}
                },
                "required": ["action"],
                "additionalProperties": false
            },
            "annotations": read_only
        }),
    ]
}

/// The CLI words for one call of `tool`.
fn words(tool: &str, arguments: &Map<String, Value>) -> Result<Vec<String>, String> {
    let text = |name: &str| -> Result<Option<String>, String> {
        match arguments.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(value)) if value.trim().is_empty() => {
                Err(format!("{name} must be nonempty"))
            }
            Some(Value::String(value)) => Ok(Some(value.clone())),
            Some(Value::Number(value)) if name == "value" => Ok(Some(value.to_string())),
            Some(_) => Err(format!("{name} must be a string")),
        }
    };
    let action = match arguments.get("action") {
        Some(Value::String(action)) if ACTIONS.contains(&action.as_str()) => action.clone(),
        _ => return Err(format!("action is one of {}", ACTIONS.join(", "))),
    };
    let tokens = tool == TOKENS;
    let allowed: &[&str] = match (tokens, action.as_str()) {
        (true, "list") => &["group"],
        (true, "show") => &["name"],
        (true, _) => &["value", "family"],
        (false, "list") => &["filter"],
        (false, "show") => &["name"],
        (false, _) => &["name", "props"],
    };
    for name in arguments.keys() {
        if name != "action" && !allowed.contains(&name.as_str()) {
            return Err(format!("{tool} {action} takes no {name:?}"));
        }
    }
    let mut out = vec![if tokens { "tokens" } else { "components" }.to_owned(), action.clone()];
    match (tokens, action.as_str()) {
        (true, "list") => out.extend(text("group")?),
        (false, "list") => out.extend(text("filter")?),
        (_, "show") => out.push(text("name")?.ok_or("name is required")?),
        (true, _) => {
            out.push(text("value")?.ok_or("value is required")?);
            if let Some(family) = text("family")? {
                out.extend(["--as".to_owned(), family]);
            }
        }
        (false, _) => {
            out.push(text("name")?.ok_or("name is required")?);
            match arguments.get("props") {
                None | Some(Value::Null) => {}
                Some(props @ Value::Object(_)) => out.push(props.to_string()),
                Some(_) => return Err("props must be an object".to_owned()),
            }
        }
    }
    Ok(out)
}

/// The tool result, or `None` when `name` is another tool.
pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    if name != TOKENS && name != COMPONENTS {
        return None;
    }
    Some(match words(name, arguments) {
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
        Ok(words) => match backend.customize(&words) {
            Ok(value) => success(value, false),
            Err(failure) => failure_result(failure),
        },
    })
}

#[cfg(test)]
#[path = "customize_kit_tools_tests.rs"]
mod tests;
