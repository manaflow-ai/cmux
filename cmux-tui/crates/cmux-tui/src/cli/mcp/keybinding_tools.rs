//! MCP tools for the app's binding table read ops (R59): `keybinding_list`,
//! `keybinding_resolve` and `context_keys` call the app control methods
//! `keybinding.list`, `keybinding.resolve` and `context.keys`. They read the
//! app and change nothing.

use serde_json::{Map, Value, json};

/// One read tool: its name, the app method and its argument names.
pub(super) struct KeybindingTool {
    pub name: &'static str,
    pub method: &'static str,
    description: &'static str,
    /// (argument, description, required)
    arguments: &'static [(&'static str, &'static str, bool)],
}

const WINDOW: (&str, &str, bool) = ("window", "A window id (default: the key window).", false);

pub(super) const TOOLS: &[KeybindingTool] = &[
    KeybindingTool {
        name: "keybinding_list",
        method: "keybinding.list",
        description: "List the cmux app's key bindings in precedence order (a later entry wins): keys in \
            keybindings.json syntax, command, when, args, source and conflicts. Reads the app and changes nothing.",
        arguments: &[
            ("query", "Filter by title, command id or key text.", false),
            ("command", "Only this command id.", false),
            ("source", "Only this source: default, app or user.", false),
        ],
    },
    KeybindingTool {
        name: "keybinding_resolve",
        method: "keybinding.resolve",
        description: "What a key sequence does in a cmux window: the outcome (run, armed or none) and every \
            candidate binding with its verdict (won, whenFalse, notRunnable, shadowed). Reads the app and changes nothing.",
        arguments: &[
            (
                "keys",
                "Keys in keybindings.json syntax, strokes separated by spaces: \"ctrl+k s\".",
                true,
            ),
            WINDOW,
        ],
    },
    KeybindingTool {
        name: "context_keys",
        method: "context.keys",
        description: "The live context keys of a cmux window, as `when` clauses read them. Reads the app and \
            changes nothing.",
        arguments: &[WINDOW],
    },
];

pub(super) fn find(name: &str) -> Option<&'static KeybindingTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl KeybindingTool {
    pub(super) fn descriptor_json(&self) -> Value {
        let mut properties = Map::new();
        for (name, description, _) in self.arguments {
            properties
                .insert((*name).into(), json!({ "type": "string", "description": description }));
        }
        let required: Vec<&str> = self
            .arguments
            .iter()
            .filter(|(_, _, required)| *required)
            .map(|(name, _, _)| *name)
            .collect();
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": {
                "type": "object", "properties": properties, "required": required, "additionalProperties": false,
            },
            "annotations": {
                "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
            },
        })
    }

    /// The app method's params, or the message for an argument the tool
    /// does not take or a missing required one.
    pub(super) fn params(&self, arguments: &Map<String, Value>) -> Result<Value, String> {
        let mut params = Map::new();
        for (name, value) in arguments {
            if !self.arguments.iter().any(|(argument, _, _)| argument == name) {
                return Err(format!("{} has no argument {name:?}", self.name));
            }
            let Some(text) = value.as_str() else {
                return Err(format!("{} argument {name:?} must be a string", self.name));
            };
            params.insert(name.clone(), json!(text));
        }
        if let Some((missing, _, _)) = self
            .arguments
            .iter()
            .find(|(name, _, required)| *required && !params.contains_key(*name))
        {
            return Err(format!("{} needs the argument {missing:?}", self.name));
        }
        Ok(Value::Object(params))
    }
}
