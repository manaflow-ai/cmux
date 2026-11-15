//! `keys_list`, `keys_write` and `keys_fill`: an agent's stored keys (`cmux keys`,
//! `key_broker/local.rs`) by name, never by value. `keys_fill` types a key into a cmux browser
//! tab's field, or into a desktop app through Computer Use (`cua_type_text` / `cua_set_value`):
//! this server reads the value and hands it to the app or the Computer Use helper itself, so the
//! value is never in a tool call, a tool result or the transcript. A key is stored with
//! `cmux keys put NAME` (value on stdin) or asked of the person with `cmux keys request`.

use serde_json::{Map, Value, json};

use super::super::key_broker::{self, local};
use super::{Backend, Server, envelope, success, tool_error, v2_tools};

pub(super) const LIST: &str = "keys_list";
pub(super) const WRITE: &str = "keys_write";
pub(super) const FILL: &str = "keys_fill";

pub(super) fn owns(name: &str) -> bool {
    [LIST, WRITE, FILL].contains(&name)
}

pub(super) fn descriptors() -> Vec<Value> {
    vec![
        json!({
            "name": LIST,
            "title": "List stored keys",
            "description": "The keys cmux keeps for agents on this machine (cmux keys): each key's name, purpose, the hosts it is for, who stored it and who asked, expiry, state (live, expired, revoked), where copies were written and where it was entered. Never a value. Store a key with `<command that prints it> | cmux keys put NAME --purpose TEXT`, make one with `cmux keys generate NAME`, or ask the person with `cmux keys request NAME --purpose TEXT` (they paste it in the cmux app, never in chat).",
            "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
        json!({
            "name": WRITE,
            "title": "Write a stored key somewhere",
            "description": "Copy a stored key into where it is needed, by name: a GitHub secret (gh-secret:OWNER/REPO[@ENV]:SECRET), this Mac's cloud secrets (keychain:[OWNER/REPO:]SECRET), the machine vault (vault:VAR), a 0600 file (file:PATH), a JSON or TOML field (json:PATH#a.b, toml:PATH#a.b) or an env file (env-file:PATH#VAR). Answers where it wrote, never the value. To run a command with a key in its env, run `cmux keys use NAME=VAR -- CMD` instead.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["name", "to"],
                "properties": {
                    "name": {"type": "string", "pattern": "^[A-Z_][A-Z0-9_]{0,79}$"},
                    "to": {"type": "array", "minItems": 1, "maxItems": 16, "items": {"type": "string", "minLength": 3}},
                },
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": true},
        }),
        json!({
            "name": FILL,
            "title": "Type a stored key into a field",
            "description": "Enter a stored key into a field by name, never by value. target browser: a cmux browser tab's field (tab: a tab id, default the browser nearest this chat; selector: CSS or a snapshot ref like e3; type: true types key by key). A key stored with hosts fills only pages on those hosts. target app: a desktop app's field through Computer Use: tool is type_text (types into the focused field) or set_value (sets an element's value), and arguments are that cua_ tool's own arguments without its text or value, which this server adds. Answers what was filled, never the value.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["name", "target"],
                "properties": {
                    "name": {"type": "string", "pattern": "^[A-Z_][A-Z0-9_]{0,79}$"},
                    "target": {"type": "string", "enum": ["browser", "app"]},
                    "tab": {"type": "string", "minLength": 1},
                    "selector": {"type": "string", "minLength": 1},
                    "type": {"type": "boolean"},
                    "tool": {"type": "string", "enum": ["type_text", "set_value"]},
                    "arguments": {"type": "object"},
                },
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
        }),
    ]
}

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

fn failed(message: String) -> Value {
    tool_error(envelope(json!({"code": "keys.failed", "message": message}), "not_run", None))
}

fn name_of(arguments: &Map<String, Value>) -> Result<String, Value> {
    arguments
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| local::valid_name(name))
        .map(str::to_owned)
        .ok_or_else(|| invalid("name is a stored key's name: upper case letters, digits and _"))
}

impl<B: Backend> Server<B> {
    pub(super) fn call_keys(&mut self, name: &str, arguments: &Map<String, Value>) -> Value {
        let paths = match key_broker::Paths::home() {
            Ok(paths) => paths,
            Err(message) => return failed(message),
        };
        match name {
            LIST => match key_broker::list(&paths) {
                Ok(list) => success(list, false),
                Err(message) => failed(message),
            },
            WRITE => {
                let key = match name_of(arguments) {
                    Ok(key) => key,
                    Err(error) => return error,
                };
                let specs: Vec<&str> = arguments
                    .get("to")
                    .and_then(Value::as_array)
                    .map(|to| to.iter().filter_map(Value::as_str).collect())
                    .unwrap_or_default();
                let mut args = vec![key.clone()];
                for spec in specs {
                    args.extend(["--to".to_owned(), spec.to_owned()]);
                }
                let targets = match local::parse("write", &args) {
                    Some(Ok(local::Local::Write { targets, .. })) => targets,
                    Some(Err(error)) => return invalid(error.0),
                    _ => return invalid("to: one or more targets"),
                };
                match local::write(&paths, &local::OsVault, &key_broker::LiveSinks, &key, &targets)
                {
                    Ok(written) => success(written, true),
                    Err(message) => failed(message),
                }
            }
            _ => self.call_keys_fill(&paths, arguments),
        }
    }

    fn call_keys_fill(
        &mut self,
        paths: &key_broker::Paths,
        arguments: &Map<String, Value>,
    ) -> Value {
        let key = match name_of(arguments) {
            Ok(key) => key,
            Err(error) => return error,
        };
        match arguments.get("target").and_then(Value::as_str) {
            Some("browser") => {
                let Some(selector) = arguments.get("selector").and_then(Value::as_str) else {
                    return invalid("target browser needs selector");
                };
                let fill = local::Fill {
                    name: key,
                    tab: arguments.get("tab").and_then(Value::as_str).map(str::to_owned),
                    selector: selector.to_owned(),
                    typing: arguments.get("type").and_then(Value::as_bool).unwrap_or(false),
                };
                let global = crate::cli::GlobalArgs::default();
                match local::fill(paths, &local::OsVault, &local::LiveApp(&global), &fill) {
                    Ok(filled) => success(filled, true),
                    Err(message) => failed(message),
                }
            }
            Some("app") => {
                let tool = arguments.get("tool").and_then(Value::as_str).unwrap_or("type_text");
                let field = match tool {
                    "type_text" => "text",
                    "set_value" => "value",
                    _ => return invalid("tool is type_text or set_value"),
                };
                let mut cua = match arguments.get("arguments") {
                    None | Some(Value::Null) => Map::new(),
                    Some(Value::Object(given)) => given.clone(),
                    Some(_) => return invalid("arguments is an object"),
                };
                if cua.contains_key(field) {
                    return invalid(format!("arguments has no {field}: this server adds the key"));
                }
                let (record, value) = match local::value_of(paths, &local::OsVault, &key) {
                    Ok(found) => found,
                    Err(message) => return failed(message),
                };
                let hosts = local::hosts_of(&record);
                if !hosts.is_empty() {
                    // An app shows no host to check: a key scoped to hosts fills only web pages.
                    return failed(format!(
                        "key {key} is for web hosts only ({}): fill it with target browser",
                        hosts.join(", ")
                    ));
                }
                cua.insert(field.to_owned(), json!(value.as_str()));
                let tool_name = format!("cua_{tool}");
                let Some(job) = self.proxied_tool(&tool_name, &cua) else {
                    return failed(format!(
                        "Computer Use is not available here ({tool_name}): set it up in cmux, or fill a browser tab"
                    ));
                };
                let answered = job.run(self.call_cap);
                drop(cua);
                let masked = local::mask_json(&answered, &[&value]);
                if !local::field(&masked, "isError").as_bool().unwrap_or(false) {
                    let place = format!("app:{tool}");
                    if let Err(message) = local::record(paths, &key, &place, false) {
                        return failed(message);
                    }
                }
                masked
            }
            _ => invalid("target is browser or app"),
        }
    }
}
