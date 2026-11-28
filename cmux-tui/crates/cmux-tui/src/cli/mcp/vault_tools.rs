//! `vault_status`, `vault_list`, `vault_import`, `vault_remove` and `vault_sync`: the end-to-end encrypted cmux
//! vault (`cmux vault`, cli/vault.rs) for agents, by name only. No tool takes or returns a value: `vault_import`
//! reads the values from a `.env` file in this process and seals them, so they never enter a tool call, a result or
//! the transcript. A single value is kept with `<command that prints it> | cmux vault set NAME`.

use serde_json::{Map, Value, json};

use super::super::vault::{self as cli_vault, Opts, Verb};
use super::{Backend, Server, envelope, success, tool_error, v2_tools};

pub(super) const STATUS: &str = "vault_status";
pub(super) const LIST: &str = "vault_list";
pub(super) const IMPORT: &str = "vault_import";
pub(super) const REMOVE: &str = "vault_remove";
pub(super) const SYNC: &str = "vault_sync";

pub(super) fn owns(name: &str) -> bool {
    [STATUS, LIST, IMPORT, REMOVE, SYNC].contains(&name)
}

fn scope_props() -> Value {
    json!({
        "repo": {"type": "string", "description": "OWNER/NAME: only machines set up from this repo"},
        "machine": {"type": "string", "pattern": "^vm_[a-z0-9]{20}$", "description": "only this machine"},
        "team": {"type": "string", "pattern": "^team_[A-Za-z0-9_-]{1,64}$", "description": "the team vault instead of the personal one"},
    })
}

pub(super) fn descriptors() -> Vec<Value> {
    let read = json!({"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true});
    // skew: strict vault scope: unknown scope keys could silently target the wrong encrypted store.
    let team_only = json!({"type": "object", "additionalProperties": false, "properties": {"team": scope_props()["team"]}});
    let mut import_props = scope_props().as_object().cloned().unwrap_or_default();
    import_props.insert(
        "file".into(),
        json!({"type": "string", "minLength": 1, "description": "the .env file's path"}),
    );
    import_props.insert(
        "names".into(),
        json!({"type": "array", "items": {"type": "string"}, "maxItems": 512, "description": "the names to keep; omit to preview the file's names without keeping any"}),
    );
    let mut remove_props = scope_props().as_object().cloned().unwrap_or_default();
    remove_props.insert(
        "name".into(),
        json!({"type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]{0,127}$"}),
    );
    vec![
        json!({
            "name": STATUS,
            "title": "cmux vault status",
            "description": "Whether the person's end-to-end encrypted cmux vault is on for this device, its devices (with their 8-digit safety codes) and the names it keeps, each value masked. The vault is opt-in: the person turns it on with `cmux vault on` or Settings > Cloud > Vault.",
            "inputSchema": team_only,
            "annotations": read,
        }),
        json!({
            "name": LIST,
            "title": "List vault names",
            "description": "The names the cmux vault keeps and where each goes (every machine, a repo's machines, one machine). Never a value.",
            "inputSchema": team_only,
            "annotations": read,
        }),
        json!({
            "name": IMPORT,
            "title": "Import names from a .env into the vault",
            "description": "Read a .env file and keep the named entries in the cmux vault, sealed on this device, then seal them to the person's Cloud machines. Without names it only lists the file's names (masked). Values never appear in the call or its answer. Only for names the person asked to keep.",
            // skew: strict vault import: reject misspelled paths or names instead of importing a different set.
            "inputSchema": {"type": "object", "additionalProperties": false, "required": ["file"], "properties": import_props},
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
        json!({
            "name": REMOVE,
            "title": "Remove a vault name",
            "description": "Remove a name from the cmux vault (from one scope with repo or machine, else from every scope); machines lose it at their next pull.",
            // skew: strict vault removal: reject unknown keys so a deletion cannot use an unintended scope.
            "inputSchema": {"type": "object", "additionalProperties": false, "required": ["name"], "properties": remove_props},
            "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": true},
        }),
        json!({
            "name": SYNC,
            "title": "Seal the vault to the person's machines",
            "description": "Seal what each of the person's Cloud machines (spares included) should hold, for every machine whose delivery is behind. Answers one row per machine, names only.",
            "inputSchema": team_only,
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
    ]
}

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

/// The CLI's words for `arguments`, so the tools parse exactly as `cmux vault` does.
fn words(verb: &str, arguments: &Map<String, Value>) -> Result<Vec<String>, Value> {
    let mut out = vec![verb.to_owned()];
    let text = |key: &str| arguments.get(key).and_then(Value::as_str).map(str::to_owned);
    match verb {
        "import" => out.push(text("file").ok_or_else(|| invalid("file is the .env file's path"))?),
        "rm" => out.push(text("name").ok_or_else(|| invalid("name is the name to remove"))?),
        _ => {}
    }
    for key in ["repo", "machine", "team"] {
        if let Some(value) = text(key) {
            out.extend([format!("--{key}"), value]);
        }
    }
    if verb == "import"
        && let Some(names) = arguments.get("names").and_then(Value::as_array)
    {
        let names: Vec<&str> = names.iter().filter_map(Value::as_str).collect();
        if !names.is_empty() {
            out.extend(["--only".to_owned(), names.join(",")]);
        }
    }
    Ok(out)
}

impl<B: Backend> Server<B> {
    pub(super) fn call_vault(&mut self, name: &str, arguments: &Map<String, Value>) -> Value {
        let verb = match name {
            STATUS => "status",
            LIST => "ls",
            IMPORT => "import",
            REMOVE => "rm",
            _ => "sync",
        };
        let words = match words(verb, arguments) {
            Ok(words) => words,
            Err(error) => return error,
        };
        let (verb, opts): (Verb, Opts) = match cli_vault::parse(&words) {
            Ok(parsed) => parsed,
            Err(error) => return invalid(error.0),
        };
        match cli_vault::perform(verb, &opts, true) {
            Ok((value, _)) => success(value, name != STATUS && name != LIST),
            Err(failure) => tool_error(envelope(
                json!({"code": failure.code, "message": failure.message}),
                "not_run",
                None,
            )),
        }
    }
}
