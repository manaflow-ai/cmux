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
    &["click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action", "batch"];

/// The acting tools whose pre-action guards `force` skips ([`crate::observe::guards`]).
pub const GUARDED: &[&str] = &["click", "type_text", "scroll", "set_value", "perform_action"];

/// `format`: how a look comes back.
fn format_arg() -> Value {
    json!({"type": "string", "enum": ["outline", "json"], "description": "outline (default) or json (the whole tree, for scripts)."})
}

/// `full`: the whole outline instead of the changes.
fn full_arg() -> Value {
    json!({"type": "boolean", "description": "true: the whole tree, out-of-view elements too, not only the changes."})
}

/// One tool.
pub struct Tool {
    pub name: &'static str,
    pub access: Access,
    pub description: &'static str,
    schema: fn() -> Value,
}

impl Tool {
    /// The tool takes `delivery` (its schema lists it): it parses it and
    /// authorizes foreground delivery as such before it acts. Every other tool
    /// acts in the background whatever `delivery` an agent names on it.
    pub fn takes_delivery(&self) -> bool {
        (self.schema)().pointer("/properties/delivery").is_some()
    }

    pub fn schema(&self) -> Value {
        let mut schema = (self.schema)();
        if let Some(props) = schema.get_mut("properties").and_then(Value::as_object_mut) {
            if OBSERVES.contains(&self.name) {
                props.insert(
                    "settle".into(),
                    json!({"type": "string", "enum": ["adaptive", "anthropic", "openai"], "description": "Wait before capturing: adaptive (default; until the window changes, at most 1 s), anthropic (2 s), openai (none)."}),
                );
                props.insert(
                    "observe".into(),
                    json!({"type": "boolean", "description": "false: no window state after acting."}),
                );
                props.insert("full".into(), full_arg());
                props.insert("format".into(), format_arg());
            }
            if GUARDED.contains(&self.name) {
                props.insert(
                    "force".into(),
                    json!({"type": "boolean", "description": "Skip the checks that refuse a no-op (disabled, title bar, no text focus, out of view). Only when sure."}),
                );
            }
            props.insert(
                "machine".into(),
                json!({"type": "string", "description": "Another machine (list_machines); omit for this one."}),
            );
            if self.acts() {
                props.insert(
                    CURSOR_TAG_ARG.into(),
                    json!({"type": "string", "description": "Short tag on your cursor (at most 60 characters), kept until changed."}),
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
    json!({"type": "string", "enum": ["background", "foreground"], "description": "background (default): no focus or pointer taken. foreground: raises the window, system-wide input; only if background fails and the person allowed it."})
}

fn window_id() -> Value {
    json!({"type": "string", "description": "From list_windows."})
}

pub static TOOLS: &[Tool] = &[
    Tool {
        name: "status",
        access: Access::Discover,
        description: "Platform, permissions, mode (fullAccess, approvedApps, askEveryTime, lookOnly, off) and denied apps. Call first when something is refused.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_machines",
        access: Access::Discover,
        description: "Your other machines with cmux Computer Use on; pass a name as `machine`.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_apps",
        access: Access::Discover,
        description: "Running apps: id, name, pid, frontmost. denied: true apps cannot be used.",
        schema: || obj(json!({}), &[]),
    },
    Tool {
        name: "list_windows",
        access: Access::Discover,
        description: "Windows, front to back: window_id, app_id, title, frame (points), on_screen, minimized. Filter with app_id.",
        schema: || obj(json!({"app_id": {"type": "string"}}), &[]),
    },
    Tool {
        name: "screenshot",
        access: Access::Observe,
        description: "A window (works when covered) or, without window_id, a display. click, scroll and drag take pixels of the latest screenshot. unchanged: true, no image, when nothing changed since your last (force: get it anyway).",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "display": {"type": "string", "description": "Omit for the main display."},
                    "force": {"type": "boolean"}
                }),
                &[],
            )
        },
    },
    Tool {
        name: "get_ui_tree",
        access: Access::Observe,
        description: "The window's elements: [id] role \"name\" = value, flags (focused, disabled, checked, shortcut, actions). Ids are stable; act on them as element_id (best: works in the background). Later looks show only changes (+ added, ~ changed, - removed). Out-of-view elements are counted on their container: scroll its element_id to see them. perform_action show_menu opens any element's context menu. Menu bar: click a menu's id to list its items (it stays closed), then click an item's id.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "max_nodes": {"type": "integer", "minimum": 1, "maximum": 5000},
                    "full": full_arg(),
                    "format": format_arg(),
                    "frames": {"type": "boolean", "description": "Add each frame in screenshot pixels."},
                    "menus": {"type": "boolean", "description": "Every menu bar menu's items too."}
                }),
                &["window_id"],
            )
        },
    },
    Tool {
        name: "click",
        access: Access::Act,
        description: "Click element_id, or x, y in screenshot pixels (without window_id: the display screenshot's). A pop-up or menu button, a right click or a control-click opens its menu and the result lists its items; click one next, or pass menu_item to choose it and close the menu in this call. Refused, with what to do instead, when it would do nothing (disabled, title bar, out of view).",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "element_id": {"type": "string"},
                    "x": {"type": "number"}, "y": {"type": "number"},
                    "button": {"type": "string", "enum": ["left", "right", "middle"]},
                    "count": {"type": "integer", "minimum": 1, "maximum": 3},
                    "modifiers": {"type": "array", "items": {"type": "string"}, "description": "shift, ctrl, alt/option, cmd/meta"},
                    "menu_item": {"type": "string", "description": "The item to choose in the menu the click opens: its title (any case, or a unique prefix) or a path (\"Sort By > Name\")."},
                    "delivery": delivery()
                }),
                &[],
            )
        },
    },
    Tool {
        name: "type_text",
        access: Access::Act,
        description: "Type into element_id (focused first) or the focused field. Refused on a control that takes no text, or when focus is on a checkbox, slider or pop-up. No change in the result means the text did not land.",
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
        description: "A key combo: \"Return\", \"cmd+s\", \"ctrl+shift+Tab\".",
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
        description: "Scroll over element_id or at x, y (screenshot pixels), in lines: dy > 0 down, dx > 0 right.",
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
        description: "Drag between two points (screenshot pixels).",
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
        description: "Set a value with no typing (text field, slider, checkbox). On a pop-up or menu button, value is the item's title (any case, or a unique prefix), chosen in this call; a missing item's error lists the items. A read-only slider or stepper (macOS volume, brightness) is stepped: a number in its range or \"25%\".",
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
        description: "An element's accessibility action from get_ui_tree: press, confirm, increment, decrement, expand, collapse, select, focus, show_menu. show_menu, or press on a pop-up, opens its menu and lists its items.",
        schema: || {
            obj(
                json!({"window_id": window_id(), "element_id": {"type": "string"}, "action": {"type": "string"}}),
                &["window_id", "element_id", "action"],
            )
        },
    },
    Tool {
        name: "wait",
        access: Access::Observe,
        description: "Wait for slow work (page load, build, animation), then return what changed in the window (without window_id: a display screenshot). ms: default 2000; or duration in seconds.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "full": full_arg(),
                    "format": format_arg(),
                    "ms": {"type": "number", "minimum": 0, "maximum": 100000},
                    "duration": {"type": "number", "minimum": 0, "maximum": 100}
                }),
                &[],
            )
        },
    },
    Tool {
        name: "batch",
        access: Access::Act,
        description: "Run up to 20 steps on one window in order in one call; one state at the end. A step is an acting tool's name as \"action\" with its arguments minus window_id, {\"action\": \"wait\", \"ms\": N}, or wait_for. Each acting step is checked and run like its own call and gets its own outcome; an error, or its \"require\", stops the batch. \"target\" instead of element_id finds the element when the step runs, so a step can act on what an earlier one opened; several matches are refused, never guessed. wait_for waits until an element (element_id or target) appears, disappears, or its value equals or contains a text; a timeout stops the batch. All waits add up to at most 120 s. results lists each step: done (outcome, read_back, changes), failed (code, message) or not_run; stopped_at says which stopped it and why. A malformed step runs nothing. No loops or conditions: call tools one at a time for those. Example: [{\"action\": \"press_key\", \"keys\": \"cmd+s\"}, {\"action\": \"wait_for\", \"target\": {\"role\": \"sheet\"}}, {\"action\": \"set_value\", \"target\": {\"role\": \"text_field\", \"label\": \"Save As\"}, \"value\": \"notes\", \"require\": \"confirmed\"}, {\"action\": \"click\", \"target\": {\"role\": \"button\", \"label\": \"Save\"}}].",
        schema: || {
            let target = json!({
                "type": "object",
                "description": "The element by what it is: found when the step runs; none or several is refused.",
                "properties": {
                    "role": {"type": "string", "description": "As get_ui_tree shows it: button, text_field, sheet, ..."},
                    "label": {"type": "string", "description": "Its whole name, any case."},
                    "text": {"type": "string", "description": "Part of its name or value, any case."}
                },
                "additionalProperties": false
            });
            obj(
                json!({
                    "window_id": window_id(),
                    "actions": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 20,
                        "items": {
                            "type": "object",
                            "properties": {
                                "action": {"type": "string", "enum": ["click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action", "wait", "wait_for"]},
                                "require": {"type": "string", "enum": ["confirmed", "not_no_effect", "no_error"], "description": "When this step stops the batch: confirmed (unless read back), not_no_effect (if it did nothing), no_error (default, on an error)."},
                                "target": target,
                                "element_id": {"type": "string"},
                                "perform": {"type": "string", "description": "perform_action's accessibility action (\"action\" names the step)."},
                                "until": {"type": "string", "enum": ["appears", "disappears"], "description": "wait_for: appears (default) or disappears."},
                                "value_equals": {"type": "string", "description": "wait_for: until its value is this."},
                                "value_contains": {"type": "string", "description": "wait_for: until its value contains this."},
                                "timeout_ms": {"type": "number", "minimum": 0, "maximum": 100000, "description": "wait_for: default 10000."},
                                "ms": {"type": "number", "minimum": 0, "maximum": 100000, "description": "wait: how long."}
                            },
                            "required": ["action"]
                        }
                    }
                }),
                &["window_id", "actions"],
            )
        },
    },
    Tool {
        name: "launch_app",
        access: Access::Act,
        description: "Start an app by id (bundle id, executable or desktop id; macOS: also its name) without bringing it to the front where possible; returns its pid. To put it in front (if foreground is allowed), act on its window with delivery foreground.",
        schema: || obj(json!({"app_id": {"type": "string"}}), &["app_id"]),
    },
    Tool {
        name: "request_permission",
        access: Access::Discover,
        description: "Ask the person for a missing OS permission: the OS prompt or its settings pane.",
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
pub const INSTRUCTIONS: &str = "cmux Computer Use is built in (nothing to install; `machine` \
reaches your other machines). For a task about this computer, look before you answer: \
list_windows (or list_apps), then screenshot or get_ui_tree a window, and act on element ids or \
pixels. Menu commands are in the tree's menu bar: click the menu's id, then the item. Each action \
returns what changed and a screenshot; \"No change\" means it did nothing, so try another way \
before saying it worked. batch runs a fixed sequence of steps on one window in one call. Act in \
the background; use delivery foreground only when status says the person allowed it, and only for \
a system-wide shortcut or to bring a window to them. If a call is refused, call status and tell \
the person which Settings > Computer Use setting would allow it; never change those settings \
yourself.";

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

    /// Every request carries the whole `tools/list`, so its size is a cost per
    /// turn: it was 30,632 bytes (compact JSON) before the descriptions were
    /// trimmed. Raise the bound only for guidance an agent needs.
    #[test]
    fn the_tool_list_stays_small() {
        let bytes = serde_json::to_string(&mcp_list()).unwrap().len();
        println!("tools/list bytes: {bytes}");
        assert!(bytes <= 21_000, "tools/list is {bytes} bytes");
    }

    /// The batch schema names every step field an agent can use.
    #[test]
    fn the_batch_schema_lists_its_step_fields() {
        let s = find("batch").unwrap().schema();
        let step = &s["properties"]["actions"]["items"]["properties"];
        assert_eq!(s["properties"]["actions"]["maxItems"], crate::engine::BATCH_MAX);
        for key in
            ["action", "require", "target", "until", "value_equals", "value_contains", "timeout_ms"]
        {
            assert!(step[key].is_object(), "{key}");
        }
        let actions = step["action"]["enum"].as_array().unwrap();
        assert!(actions.contains(&json!("wait_for")));
        assert_eq!(step["require"]["enum"], json!(["confirmed", "not_no_effect", "no_error"]));
        assert_eq!(step["target"]["additionalProperties"], false);
    }
}
