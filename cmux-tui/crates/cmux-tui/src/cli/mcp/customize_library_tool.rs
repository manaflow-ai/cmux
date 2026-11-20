//! `customize_library`: the library of everything the person applied, from
//! an agent. One tool with an `action`, each one `cmux customize library …`
//! run by the CLI's own code in this process, as the `customize_*` tools are.

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

const NAME: &str = "customize_library";

const ACTIONS: &[&str] = &["list", "on", "off", "order", "remove", "export", "import"];

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "description": "The person's customize library: every customization they applied (an ask, a profile or recipe they used, a try-on they kept) is saved by itself as a small entry they can turn on or off. Entries stack top first: where two entries that are on set the same setting or file, the higher one wins, and `conflicts` names each such key, its winner and the losers. `list` reads only. `on`, `off`, `order` and `remove` change what is live as one applied generation (customize_rollback undoes it) and are refused while a preview is open; do them only when the person asked. `export` returns the library as one collection (`file` writes it there; `link` returns a cmux-collection: link). `import` adds a collection file or link, off unless `on` is true.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ACTIONS},
                "entry": {"type": "string", "minLength": 1, "description": "The entry's name, from list (on, off, order, remove)."},
                "position": {"description": "Where order moves it: \"top\", \"bottom\" or a number, 1 being the top.", "oneOf": [{"type": "integer", "minimum": 1}, {"type": "string", "enum": ["top", "bottom"]}]},
                "source": {"type": "string", "minLength": 1, "description": "import: a collection file's path or a cmux-collection: link."},
                "file": {"type": "string", "minLength": 1, "description": "export: write the collection to this path."},
                "link": {"type": "boolean", "description": "export: return it as a cmux-collection: link."},
                "on": {"type": "boolean", "description": "export: only entries that are on. import: turn on the entries the collection marks on."},
                "name": {"type": "string", "description": "export: the collection's name."}
            },
            "required": ["action"],
            "additionalProperties": false
        },
        "annotations": {"readOnlyHint": false, "destructiveHint": false,
            "idempotentHint": false, "openWorldHint": false}
    })
}

/// The CLI words for one call.
fn words(arguments: &Map<String, Value>) -> Result<Vec<String>, String> {
    let text = |name: &str| -> Result<Option<String>, String> {
        match arguments.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(value)) if value.trim().is_empty() || value.starts_with('-') => {
                Err(format!("{name} must be nonempty and not start with \"-\""))
            }
            Some(Value::String(value)) => Ok(Some(value.clone())),
            Some(_) => Err(format!("{name} must be a string")),
        }
    };
    let flag = |name: &str| -> Result<bool, String> {
        match arguments.get(name) {
            None | Some(Value::Null) => Ok(false),
            Some(Value::Bool(value)) => Ok(*value),
            Some(_) => Err(format!("{name} must be true or false")),
        }
    };
    let action = match arguments.get("action") {
        Some(Value::String(action)) if ACTIONS.contains(&action.as_str()) => action.clone(),
        _ => return Err(format!("action is one of {}", ACTIONS.join(", "))),
    };
    let allowed: &[&str] = match action.as_str() {
        "list" => &[],
        "on" | "off" | "remove" => &["entry"],
        "order" => &["entry", "position"],
        "export" => &["file", "link", "on", "name"],
        _ => &["source", "on"],
    };
    for name in arguments.keys() {
        if name != "action" && !allowed.contains(&name.as_str()) {
            return Err(format!("{NAME} {action} takes no {name:?}"));
        }
    }
    let mut out = vec!["library".to_owned(), action.clone()];
    match action.as_str() {
        "on" | "off" | "remove" | "order" => {
            out.push(text("entry")?.ok_or("entry is required")?);
        }
        _ => {}
    }
    if action == "order" {
        match arguments.get("position") {
            Some(Value::String(position)) if position == "top" || position == "bottom" => {
                out.push(position.clone());
            }
            Some(value) if value.as_u64().is_some_and(|n| n >= 1) => {
                out.push(value.as_u64().unwrap_or(1).to_string());
            }
            _ => return Err("position is \"top\", \"bottom\" or a number from 1".to_owned()),
        }
    }
    if action == "export" {
        out.extend(text("file")?);
        if flag("link")? {
            out.push("--link".to_owned());
        }
        if let Some(name) = text("name")? {
            out.extend(["--name".to_owned(), name]);
        }
    }
    if action == "import" {
        out.push(text("source")?.ok_or("source is required")?);
    }
    if flag("on")? {
        out.push("--on".to_owned());
    }
    Ok(out)
}

/// The tool result, or `None` when `name` is another tool.
pub(super) fn call(
    backend: &impl Backend,
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    if name != NAME {
        return None;
    }
    let mutation = !matches!(arguments.get("action").and_then(Value::as_str), Some("list"));
    Some(match words(arguments) {
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
        Ok(words) => match backend.customize(&words) {
            Ok(value) => success(value, mutation),
            Err(failure) => failure_result(failure),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(args: Value) -> Result<Vec<String>, String> {
        words(args.as_object().unwrap())
    }

    #[test]
    fn library_tool_arguments_become_the_cli_words() {
        assert_eq!(w(json!({"action": "list"})).unwrap(), ["library", "list"]);
        assert_eq!(
            w(json!({"action": "on", "entry": "roomy"})).unwrap(),
            ["library", "on", "roomy"]
        );
        assert_eq!(
            w(json!({"action": "order", "entry": "roomy", "position": 2})).unwrap(),
            ["library", "order", "roomy", "2"]
        );
        assert_eq!(
            w(json!({"action": "order", "entry": "roomy", "position": "top"})).unwrap(),
            ["library", "order", "roomy", "top"]
        );
        assert_eq!(
            w(json!({"action": "export", "link": true, "on": true})).unwrap(),
            ["library", "export", "--link", "--on"]
        );
        assert_eq!(
            w(json!({"action": "import", "source": "cmux-collection:abc", "on": true})).unwrap(),
            ["library", "import", "cmux-collection:abc", "--on"]
        );
        for bad in [
            json!({}),
            json!({"action": "frob"}),
            json!({"action": "on"}),
            json!({"action": "on", "entry": "-x"}),
            json!({"action": "list", "entry": "x"}),
            json!({"action": "order", "entry": "x", "position": 0}),
            json!({"action": "import"}),
            json!({"action": "export", "link": "yes"}),
        ] {
            assert!(w(bad.clone()).is_err(), "{bad}");
        }
        assert_eq!(descriptor()["name"], NAME);
    }
}
