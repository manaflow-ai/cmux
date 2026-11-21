//! `device_setup` and `device_start`: `cmux device setup|start` for agents (Leo, 2026-11-14:
//! "agents need to be able to help set up and propagate the app for me"). They install, keep
//! running and start cmux NIGHTLY on a Mac that is already the person's. Neither grants any
//! device access: Share This Mac and device access stay a person's click.

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const SETUP: &str = "device_setup";
pub(super) const START: &str = "device_start";

pub(super) fn descriptors() -> Vec<Value> {
    vec![
        json!({
            "name": SETUP,
            "title": "Set up cmux NIGHTLY on a Mac of yours",
            "description": "Install cmux NIGHTLY, or bring it to the newest build, on one of the person's own Macs (device) or on every one with an ssh route (all), keep it running with a login item, start it, sign it in and report its Screen Sharing grants, over ssh. It never quits or replaces a running app and grants nobody access: turning Share This Mac on and raising a device's access stay a person's click. Returns one line per step ({device, step, state: ok|changed|warn|fail|skip, detail, fix}) and a summary per device.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "device": {"type": "string", "minLength": 1, "description": "A device id, name or address from `cmux device list`."},
                    "all": {"type": "boolean", "description": "Every Mac of yours with an ssh route; phones, Cloud and pool machines are skipped."}
                }
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
        json!({
            "name": START,
            "title": "Start cmux NIGHTLY on a Mac of yours",
            "description": "Start cmux NIGHTLY on one of the person's own Macs over ssh (and add its keepalive login item when missing), so an Offline Mac comes back. It grants nobody access. Returns one line per step and a summary.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["device"],
                "properties": {
                    "device": {"type": "string", "minLength": 1, "description": "A device id, name or address from `cmux device list`."}
                }
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
    ]
}

/// The verb's words, or why the arguments are wrong.
pub(super) fn words(name: &str, arguments: &Map<String, Value>) -> Result<Vec<String>, String> {
    let device = arguments
        .get("device")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(str::to_owned);
    let all = arguments.get("all").and_then(Value::as_bool).unwrap_or(false);
    if device.as_deref().is_some_and(|d| d.starts_with('-')) {
        return Err("device must be a device id, name or address".into());
    }
    match (name, device, all) {
        (SETUP, Some(_), true) => Err("give device or all, not both".into()),
        (SETUP, Some(device), false) => Ok(vec!["setup".into(), device]),
        (SETUP, None, true) => Ok(vec!["setup".into(), "--all".into()]),
        (SETUP, None, false) => Err("device or all: true is required".into()),
        (START, Some(device), _) => Ok(vec!["start".into(), device]),
        (START, None, _) => Err("device is required".into()),
        _ => Err("unknown device tool".into()),
    }
}

/// Runs a device tool; `None` for any other tool name.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    if name != SETUP && name != START {
        return None;
    }
    let words = match words(name, arguments) {
        Ok(words) => words,
        Err(message) => {
            return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None)));
        }
    };
    let words = words.iter().map(String::as_str).collect::<Vec<_>>();
    Some(match crate::devices::setup::run_json_lines(&words) {
        Ok((ok, lines, error)) => {
            let mut value = json!({"ok": ok, "lines": lines});
            if !ok
                && !error.is_empty()
                && let Some(fields) = value.as_object_mut()
            {
                fields.insert("error".into(), json!(error));
            }
            success(value, true)
        }
        Err(error) => {
            tool_error(envelope(v2_tools::invalid(format!("{error:#}")), "not_run", None))
        }
    })
}
