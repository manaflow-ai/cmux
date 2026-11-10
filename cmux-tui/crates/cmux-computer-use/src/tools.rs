//! The tool catalog: names, descriptions and JSON schemas. acpmux serves
//! this list itself, so an agent's `tools/list` works while the worker is
//! starting or restarting, and it is identical on every platform.

use serde_json::{Value, json};

use crate::policy::Access;

/// The MCP server name agents see.
pub const SERVER_NAME: &str = "cmux-computer-use";
/// Tool names are prefixed with this in the folded `cmux` server (`cu_click`).
pub const TOOL_PREFIX: &str = "cu";

/// The acting tools' optional argument that sets the agent cursor's tag
/// (`CallContext::tag`). The bridge takes it out of the arguments and keeps it
/// for the session's later calls.
pub const CURSOR_TAG_ARG: &str = "cursor_tag";

/// An agent cursor tag fit to show the person: one line of at most
/// [`crate::engine::LABEL_MAX_CHARS`] characters, as `safe_label` makes a
/// label; None when nothing is left of it.
pub fn safe_tag(tag: &str) -> Option<String> {
    if tag.chars().all(|c| c.is_control() || c.is_whitespace()) {
        return None;
    }
    Some(crate::engine::safe_label(tag))
}

/// The acting tools whose result carries the window's state after acting.
pub const OBSERVES: &[&str] =
    &["click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action"];

/// One tool.
pub struct Tool {
    pub name: &'static str,
    pub access: Access,
    pub description: &'static str,
    schema: fn() -> Value,
}

impl Tool {
    pub fn schema(&self) -> Value {
        let mut schema = (self.schema)();
        if let Some(props) = schema.get_mut("properties").and_then(Value::as_object_mut) {
            if OBSERVES.contains(&self.name) {
                props.insert(
                    "observe".into(),
                    json!({"type": "boolean", "description": "Default true: the result carries the window after acting (state: a screenshot once it changed or ~1 s passed, and its tree with element ids), so you need no screenshot after. state.unchanged true means your last screenshot of it still holds. false: skip it."}),
                );
            }
            props.insert(
                "machine".into(),
                json!({"type": "string", "description": "Run on another of your machines (a name or id from list_machines). Omit for this machine."}),
            );
            if self.acts() {
                props.insert(
                    CURSOR_TAG_ARG.into(),
                    json!({"type": "string", "description": "Optional: a short tag the person sees on your blue cursor (at most 60 characters), such as your task. It stays until you set another; by default the tag is your cmux workspace's name."}),
                );
            }
        }
        schema
    }

    /// Whether the tool may change something (for retries and look-only).
    pub fn acts(&self) -> bool {
        self.access == Access::Act
    }
}

fn obj(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required, "additionalProperties": false})
}

fn delivery() -> Value {
    json!({"type": "string", "enum": ["background", "foreground"], "description": "background (default): never takes focus or moves your pointer. foreground: raises the window and uses system-wide input; only when background fails and the person allowed it."})
}

fn window_id() -> Value {
    json!({"type": "string", "description": "The window, from list_windows or a screenshot."})
}

pub static TOOLS: &[Tool] = &[
    Tool {
        name: "status",
        access: Access::Discover,
        description: "cmux Computer Use on this machine: platform, display server, permissions, mode (fullAccess, approvedApps, askEveryTime, lookOnly, off) and denied apps. Call first when something is refused.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_machines",
        access: Access::Discover,
        description: "Your other machines running cmux that this agent can use (signed in as you, Computer Use on). Pass a name as `machine` to any tool.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_apps",
        access: Access::Discover,
        description: "Running apps: id (bundle id, executable or desktop id), name, pid, frontmost. Denied apps are listed with denied: true and cannot be used.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_windows",
        access: Access::Discover,
        description: "Top-level windows, front to back: window_id, app_id, title, frame (points), on_screen, minimized. Filter with app_id.",
        schema: || obj(json!({"app_id": {"type": "string"}}), &[]),
    },
    Tool {
        name: "screenshot",
        access: Access::Observe,
        description: "A screenshot of one window (window_id, works when covered) or of a display (no window_id). Coordinates you pass to click, scroll and drag are pixels of the latest screenshot of that window or display. Returns unchanged: true and no image when nothing changed since your last screenshot of it (pass force to get it anyway).",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "display": {"type": "string", "description": "A display id; omit for the main display."},
                    "force": {"type": "boolean"}
                }),
                &[],
            )
        },
    },
    Tool {
        name: "get_ui_tree",
        access: Access::Observe,
        description: "The window's accessibility tree: element ids, roles, names, values, frames (screenshot pixels) and actions. Prefer element_id targets over coordinates: they work in the background and survive layout changes.",
        schema: || {
            obj(
                json!({"window_id": window_id(), "max_nodes": {"type": "integer", "minimum": 1, "maximum": 5000}}),
                &["window_id"],
            )
        },
    },
    Tool {
        name: "click",
        access: Access::Act,
        description: "Click an element (element_id) or a point (x, y in screenshot pixels) in a window, in the background. With no window_id, x and y are pixels of your latest display screenshot.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "element_id": {"type": "string"},
                    "x": {"type": "number"}, "y": {"type": "number"},
                    "button": {"type": "string", "enum": ["left", "right", "middle"]},
                    "count": {"type": "integer", "minimum": 1, "maximum": 3},
                    "modifiers": {"type": "array", "items": {"type": "string"}, "description": "shift, ctrl, alt/option, cmd/meta"},
                    "delivery": delivery()
                }),
                &[],
            )
        },
    },
    Tool {
        name: "type_text",
        access: Access::Act,
        description: "Type text into the window's focused field, or into element_id. Background by default.",
        schema: || {
            obj(
                json!({"window_id": window_id(), "text": {"type": "string"}, "element_id": {"type": "string"}, "delivery": delivery()}),
                &["window_id", "text"],
            )
        },
    },
    Tool {
        name: "press_key",
        access: Access::Act,
        description: "Press a key combo in a window: \"Return\", \"cmd+s\", \"ctrl+shift+Tab\", \"F5\".",
        schema: || {
            obj(
                json!({"window_id": window_id(), "keys": {"type": "string"}, "delivery": delivery()}),
                &["window_id", "keys"],
            )
        },
    },
    Tool {
        name: "scroll",
        access: Access::Act,
        description: "Scroll at a point (x, y in screenshot pixels) or over element_id. dy > 0 scrolls down, dx > 0 right, in lines.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(), "element_id": {"type": "string"},
                    "x": {"type": "number"}, "y": {"type": "number"},
                    "dx": {"type": "number"}, "dy": {"type": "number"}
                }),
                &["window_id"],
            )
        },
    },
    Tool {
        name: "drag",
        access: Access::Act,
        description: "Drag from one point to another in a window (screenshot pixels).",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "from_x": {"type": "number"}, "from_y": {"type": "number"},
                    "to_x": {"type": "number"}, "to_y": {"type": "number"},
                    "button": {"type": "string", "enum": ["left", "right", "middle"]},
                    "delivery": delivery()
                }),
                &["window_id", "from_x", "from_y", "to_x", "to_y"],
            )
        },
    },
    Tool {
        name: "set_value",
        access: Access::Act,
        description: "Set an element's value directly (text fields, sliders, checkboxes), with no typing.",
        schema: || {
            obj(
                json!({"window_id": window_id(), "element_id": {"type": "string"}, "value": {"type": "string"}}),
                &["window_id", "element_id", "value"],
            )
        },
    },
    Tool {
        name: "perform_action",
        access: Access::Act,
        description: "Perform one of an element's accessibility actions (from get_ui_tree): press, confirm, show_menu, increment, decrement, expand, collapse, select, focus.",
        schema: || {
            obj(
                json!({"window_id": window_id(), "element_id": {"type": "string"}, "action": {"type": "string"}}),
                &["window_id", "element_id", "action"],
            )
        },
    },
    Tool {
        name: "launch_app",
        access: Access::Act,
        description: "Start an app by id (bundle id, executable or desktop id) without bringing it to the front where the platform allows. Returns its pid.",
        schema: || obj(json!({"app_id": {"type": "string"}}), &["app_id"]),
    },
    Tool {
        name: "request_permission",
        access: Access::Discover,
        description: "Ask the person for a missing OS permission (accessibility, screen_capture): shows the OS prompt or opens the right settings pane.",
        schema: || {
            obj(
                json!({"permission": {"type": "string", "enum": ["accessibility", "screen_capture"]}}),
                &["permission"],
            )
        },
    },
];

pub fn find(name: &str) -> Option<&'static Tool> {
    TOOLS.iter().find(|t| t.name == name)
}

/// The MCP `tools/list` result.
pub fn mcp_list() -> Value {
    let tools: Vec<Value> = TOOLS
        .iter()
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "inputSchema": t.schema(),
                "annotations": {
                    "readOnlyHint": !t.acts(),
                    "destructiveHint": false,
                    "openWorldHint": false
                }
            })
        })
        .collect();
    json!({ "tools": tools })
}

/// The instructions an agent gets with the server (MCP `instructions`).
pub const INSTRUCTIONS: &str = "cmux Computer Use is built into cmux: use these tools to see and use apps on this computer (and on your other machines with `machine`). There is nothing to install and no other computer-use driver is needed. Work in the background: list_windows, then screenshot or get_ui_tree a window, then act on element ids (best) or screenshot pixels. Every action returns the window after acting (state: screenshot and tree), so do not take another screenshot to check. Your actions never take the person's focus or pointer; a blue cmux cursor shows them where you act. If a call is refused, call status and tell the person which setting in Settings > Computer Use would allow it; never try to change Computer Use settings yourself.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_an_object_schema_with_machine() {
        for t in TOOLS {
            let s = t.schema();
            assert_eq!(s["type"], "object", "{}", t.name);
            assert!(s["properties"]["machine"].is_object(), "{}", t.name);
            assert_eq!(
                s["properties"]["observe"].is_object(),
                OBSERVES.contains(&t.name),
                "{}",
                t.name
            );
        }
        let names: std::collections::HashSet<_> = TOOLS.iter().map(|t| t.name).collect();
        assert_eq!(names.len(), TOOLS.len(), "duplicate tool names");
    }

    /// An acting tool takes an optional `cursor_tag`; a look-only one does not.
    #[test]
    fn acting_tools_take_a_cursor_tag_and_it_is_kept_short_and_on_one_line() {
        for t in TOOLS {
            let s = t.schema();
            assert_eq!(s["properties"][CURSOR_TAG_ARG].is_object(), t.acts(), "{}", t.name);
            let required = s["required"].as_array().cloned().unwrap_or_default();
            assert!(!required.contains(&serde_json::json!(CURSOR_TAG_ARG)), "{}", t.name);
        }
        assert_eq!(safe_tag("Fix\nthe\tbuild").as_deref(), Some("Fix the build"));
        assert_eq!(safe_tag(" \u{7} "), None);
        assert_eq!(safe_tag(&"y".repeat(61)).map(|t| t.chars().count()), Some(60));
    }
}
