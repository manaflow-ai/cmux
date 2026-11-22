//! MCP tools for the cmux app's actions, generated from the app's own
//! registry (`action.list`): one tool per action the app marks for the CLI
//! (`cli: true`), named after its CLI name (`workspace move-to-window` is
//! `app_workspace_move_to_window`), with the action's typed arguments as
//! the input schema. Every run goes through `action.run` with the CLI's
//! contract (`wait: true`, `after: "sync"`, an idempotency key) and
//! `origin: "mcp"`, so the app changes the user's focus only for an action
//! whose purpose is focus or a call that passes `focus: true`.

use serde_json::{Map, Value, json};

use super::super::app::{ActionName, action_run_params};
use super::Exclusion;
use super::schema;
use super::v2_tools::invalid;

/// The app tool that lists windows (`snapshot.get`), for `win_` targets.
pub(super) const WINDOW_LIST: &str = "window_list";

/// Why the app keeps an action from MCP (`surfaces.mcp` in `action.list`,
/// the app's `ActionSurfacePlan`). The app decides; this only words it.
fn mcp_exemption_reason(exemption: &str) -> String {
    let why = match exemption {
        "credentials" => "credentials and sign-in stay with a person",
        "endsApp" => "it ends the app the user works in",
        "systemChange" => "it changes preferences, the system or the running app",
        "guiOnly" => "it has no purpose outside the GUI",
        "liveInput" | "focusMove" | "stepAdjust" => "it is live input or view navigation",
        "clipboard" => "it reads or writes the user's clipboard",
        _ => "the app keeps it out of MCP",
    };
    format!("The app marks it `{exemption}` for MCP in its action list: {why}.")
}

/// App control methods that are neither actions nor tools, with the reason.
pub(super) const EXCLUDED_APP_METHODS: &[(&str, &str)] = &[
    (
        "action.run",
        "Only actions the app marks for the CLI (cli: true) are tools; GUI-only actions stay in the app.",
    ),
    (
        "settings.get, settings.set, settings.unset",
        "Preferences belong to the config layer; cmux.json may hold credentials and holds mcp.enabled.",
    ),
    ("events.stream", "A stream; a bounded events read is a later phase."),
    ("history.list", "The user's browsing and command history; not an operation or a CLI action."),
    ("bookmark.list", "The user's bookmarks; not an operation or a CLI action."),
    ("accounts.list", "Provider account records; not an operation or a CLI action."),
    (
        "browser.page.*",
        "Page commands (eval, fill, click) reach pages the user is signed in to; a later phase sets their policy.",
    ),
    ("system.ping, system.identify, system.capabilities", "Diagnostics; `cmux app identify`."),
];

pub(super) struct ActionTool {
    pub name: String,
    pub id: String,
    pub cli_name: String,
    descriptor: Value,
}

/// The tools for an `action.list` result, and the CLI actions left out.
pub(super) fn from_list(list: &Value) -> (Vec<ActionTool>, Vec<Exclusion>) {
    let mut tools: Vec<ActionTool> = Vec::new();
    let mut excluded = Vec::new();
    let actions = list.get("actions").and_then(Value::as_array).map(Vec::as_slice);
    for action in actions.unwrap_or_default() {
        let surfaces = action.get(crate::app_identity::ACTION_SURFACE_PLAN);
        let surface = |name: &str| surfaces.and_then(|surfaces| surfaces[name].as_str());
        let cli = match surface("cli") {
            Some(cli) => cli == "offered",
            None => action.get("cli") == Some(&Value::Bool(true)),
        };
        if !cli {
            continue;
        }
        let id = action["id"].as_str().unwrap_or_default().to_owned();
        let cli_name = action["cli_name"].as_str().unwrap_or_default().to_owned();
        let mut exclude = |reason: &str| {
            excluded.push(Exclusion {
                kind: "action",
                name: format!("{id} ({cli_name})"),
                reason: reason.to_owned(),
            });
        };
        // Fail closed: an app that does not say whether MCP may run the
        // action does not get it run.
        match surface("mcp") {
            Some("offered") => {}
            Some(exemption) => {
                exclude(&mcp_exemption_reason(exemption));
                continue;
            }
            None => {
                exclude("The app reports no MCP decision for it; update the app.");
                continue;
            }
        }
        let Some(name) = tool_name(&cli_name) else {
            exclude("Its CLI name does not make a valid tool name.");
            continue;
        };
        if arguments(action)
            .any(|argument| matches!(argument["name"].as_str(), Some("target" | "idempotency_key")))
        {
            exclude("An argument's name collides with a tool control argument.");
            continue;
        }
        if tools.iter().any(|tool| tool.name == name) {
            exclude("Another action has the same tool name.");
            continue;
        }
        tools.push(ActionTool { name, id, cli_name, descriptor: action.clone() });
    }
    (tools, excluded)
}

/// `app_` and the CLI name's words (`app new-window` is `app_new_window`).
pub(super) fn tool_name(cli_name: &str) -> Option<String> {
    let mut words = cli_name.split_whitespace().peekable();
    if words.peek() == Some(&"app") {
        words.next();
    }
    let mut name = String::from("app");
    for word in words {
        name.push('_');
        for character in word.chars() {
            match character {
                'a'..='z' | '0'..='9' => name.push(character),
                'A'..='Z' => name.push(character.to_ascii_lowercase()),
                '-' | '_' | '.' => name.push('_'),
                _ => return None,
            }
        }
    }
    (name.len() > "app_".len() && name.len() <= 64).then_some(name)
}

fn arguments(action: &Value) -> impl Iterator<Item = &Value> {
    action.get("arguments").and_then(Value::as_array).into_iter().flatten()
}

impl ActionTool {
    fn has_argument(&self, name: &str) -> bool {
        arguments(&self.descriptor).any(|argument| argument["name"] == name)
    }

    fn targets(&self) -> Vec<&str> {
        self.descriptor["targets"]
            .as_array()
            .map(|targets| targets.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default()
    }

    pub(super) fn descriptor_json(&self) -> Value {
        json!({
            "name": self.name,
            "title": self.descriptor["title"],
            "description": self.description(),
            "inputSchema": self.input_schema(),
            "annotations": {
                "title": self.descriptor["title"],
                "readOnlyHint": false,
                "destructiveHint": self.descriptor["destructive"] == Value::Bool(true),
                "idempotentHint": false,
                "openWorldHint": false,
            },
        })
    }

    fn description(&self) -> String {
        let title = self.descriptor["title"].as_str().unwrap_or(&self.id).trim_end_matches('…');
        let mut text = format!(
            "{title}. cmux app action `{}` (CLI: `cmux {}`). Runs in the cmux app and waits \
             until its work is done.",
            self.id, self.cli_name
        );
        if self.descriptor["focuses"] == Value::Bool(true) {
            text.push_str(" Its purpose is focus: it changes the app's focus or selection.");
        } else {
            text.push_str(
                " An MCP run changes the user's focus only when focus is true or the action's \
                 purpose is focus.",
            );
        }
        if self.descriptor["destructive"] == Value::Bool(true) {
            text.push_str(" Destructive: the app runs it only with confirm: true.");
        }
        let requires = self.descriptor["requires"]
            .as_array()
            .map(|names| names.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "))
            .unwrap_or_default();
        if !requires.is_empty() {
            text.push_str(&format!(" Needs: {requires}."));
        }
        if let Some(reason) = self.descriptor["unavailable_reason"].as_str() {
            text.push_str(&format!(" Unavailable in this build: {reason}"));
        }
        text
    }

    pub(super) fn input_schema(&self) -> Value {
        let mut properties = Map::new();
        let mut required = Vec::new();
        for argument in arguments(&self.descriptor) {
            let Some(name) = argument["name"].as_str() else { continue };
            properties.insert(name.to_owned(), argument_schema(argument));
            if argument["required"] == Value::Bool(true) {
                required.push(Value::String(name.to_owned()));
            }
        }
        let targets = self.targets();
        if !targets.is_empty() {
            properties.insert(
                "target".into(),
                json!({
                    "type": "string",
                    "minLength": 1,
                    "description": format!(
                        "What to act on: a public id (or unique prefix) of a {}, or kind:id. \
                         Default: the focused one in the app.",
                        targets.join(" or ")
                    ),
                }),
            );
        }
        let focus = "Let this run change the app's focus, selection, shown workspace or key \
                     window. Default false: the user's view stays as it is.";
        let mut focus_schema = json!({ "type": "boolean", "description": focus });
        if let Some(own) = properties.get("focus") {
            focus_schema = own.clone();
            schema::describe(&mut focus_schema, focus);
        }
        properties.insert("focus".into(), focus_schema);
        properties.insert(
            "idempotency_key".into(),
            json!({
                "type": "string",
                "minLength": 1,
                "maxLength": 200,
                "description": "Names this run so a retry cannot run it twice. Generated when \
                    absent; a failed call returns it.",
            }),
        );
        json!({
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        })
    }

    /// The `action.run` params for a call, and its idempotency key.
    pub(super) fn run_params(
        &self,
        arguments: &Map<String, Value>,
    ) -> Result<(Value, Option<String>), Value> {
        let mut params = action_run_params(&self.cli_name, ActionName::Cli, "mcp");
        let mut values = Map::new();
        let mut key = None;
        for (name, value) in arguments {
            match name.as_str() {
                "target" if !self.targets().is_empty() => {
                    let target = value.as_str().filter(|target| !target.is_empty());
                    let target = target.ok_or_else(|| invalid("target must be a string"))?;
                    params.insert("target".into(), json!(target));
                }
                "focus" => {
                    let focus =
                        value.as_bool().ok_or_else(|| invalid("focus must be a boolean"))?;
                    if focus {
                        params.insert("focus".into(), json!(true));
                    }
                    if self.has_argument("focus") {
                        values.insert("focus".into(), json!(focus));
                    }
                }
                "idempotency_key" => {
                    let text = value.as_str().filter(|text| !text.is_empty() && text.len() <= 200);
                    let text = text.ok_or_else(|| {
                        invalid("idempotency_key must be a string of 1 to 200 characters")
                    })?;
                    key = Some(text.to_owned());
                }
                _ if self.has_argument(name) => {
                    values.insert(name.clone(), value.clone());
                }
                _ => return Err(invalid(format!("{} has no argument {name:?}", self.name))),
            }
        }
        if !values.is_empty() {
            params.insert("args".into(), Value::Object(values));
        }
        Ok((Value::Object(params), key))
    }
}

fn argument_schema(argument: &Value) -> Value {
    let mut schema = match argument["kind"].as_str().unwrap_or_default() {
        "int" => {
            let mut schema = json!({ "type": "integer" });
            for (from, to) in [("min", "minimum"), ("max", "maximum")] {
                if let Some(bound) = argument.get(from) {
                    schema[to] = bound.clone();
                }
            }
            schema
        }
        "bool" => json!({ "type": "boolean" }),
        "enum" => {
            let choices = argument["choices"].as_array().map(Vec::as_slice).unwrap_or_default();
            let values = choices.iter().map(|choice| choice["value"].clone()).collect::<Vec<_>>();
            let titles = choices
                .iter()
                .filter_map(|choice| {
                    Some(format!("{} ({})", choice["value"].as_str()?, choice["title"].as_str()?))
                })
                .collect::<Vec<_>>()
                .join(", ");
            let mut schema = json!({ "type": "string", "enum": values });
            if !titles.is_empty() {
                schema::describe(&mut schema, &format!("One of: {titles}."));
            }
            schema
        }
        "target" => {
            let kind = argument["target_kind"].as_str().unwrap_or("object");
            json!({
                "type": "string",
                "minLength": 1,
                "description": format!("A {kind}: its public id or a unique prefix."),
            })
        }
        _ => json!({ "type": "string" }),
    };
    if let Some(title) = argument["title"].as_str() {
        schema::describe(&mut schema, title);
    }
    schema
}

/// `window_list`: the app's windows and their `win_` ids (`snapshot.get`).
pub(super) fn window_list_tool() -> Value {
    json!({
        "name": WINDOW_LIST,
        "description": "List the cmux app's windows with their ids, for the target of window \
            actions. Reads the app and changes nothing.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
        "annotations": {
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        },
    })
}
