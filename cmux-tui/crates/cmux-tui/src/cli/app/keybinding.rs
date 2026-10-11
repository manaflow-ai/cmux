//! `cmux keybinding list|resolve|context` (R59): the app's binding table
//! read ops. They read the app and change nothing.
//!
//! - `list [--query TEXT] [--command ID] [--source default|app|user]`:
//!   every entry in precedence order (`keybinding.list`);
//! - `resolve KEYS [--window ID]`: what the keys do in a window, with every
//!   candidate's verdict (`keybinding.resolve`; KEYS in keybindings.json
//!   syntax, strokes separated by spaces: `"ctrl+k s"`);
//! - `context [--window ID]`: the window's live context keys
//!   (`context.keys`).

use serde_json::{Map, Value, json};

use super::{AppCommand, Options, READ_TIMEOUT};
use crate::cli::UsageError;

pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = crate::localization::catalog().app_control.keybinding_usage;
    let call = |method, params| AppCommand::Call {
        method,
        params,
        timeout: Some(READ_TIMEOUT),
        pick: None,
    };
    let Some((verb, tail)) = rest.split_first() else { return Err(UsageError::new(usage)) };
    match verb.as_str() {
        "list" => {
            let options = Options::parse(tail, &["query", "command", "source"], &[])?;
            let mut params = Map::new();
            for key in ["query", "command", "source"] {
                if let Some(value) = options.value(key) {
                    params.insert(key.into(), json!(value));
                }
            }
            Ok(call("keybinding.list", Value::Object(params)))
        }
        "resolve" => {
            let Some((keys, tail)) = tail.split_first().filter(|(keys, _)| !keys.starts_with('-'))
            else {
                return Err(UsageError::new(usage));
            };
            let mut params = window(tail)?;
            params.insert("keys".into(), json!(keys));
            Ok(call("keybinding.resolve", Value::Object(params)))
        }
        "context" => Ok(call("context.keys", Value::Object(window(tail)?))),
        _ => Err(UsageError::new(usage)),
    }
}

fn window(args: &[String]) -> Result<Map<String, Value>, UsageError> {
    let options = Options::parse(args, &["window"], &[])?;
    let mut params = Map::new();
    if let Some(window) = options.value("window") {
        params.insert("window".into(), json!(window));
    }
    Ok(params)
}
