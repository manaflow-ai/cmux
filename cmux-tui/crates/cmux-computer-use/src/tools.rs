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
    json!({"type": "string", "enum": ["outline", "json"], "description": "outline (default): one line per element, [id] role \"name\" = value, flags. json: the tree as JSON, every look whole (for scripts)."})
}

/// `full`: the whole outline instead of the changes.
fn full_arg() -> Value {
    json!({"type": "boolean", "description": "After your first look at a window, a look shows only what changed since your last one; true shows the whole tree, elements scrolled out of view included."})
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
                    json!({"type": "string", "enum": ["adaptive", "anthropic", "openai"], "description": "How to wait before the state is captured. adaptive (default setting): ~120 ms, then until the window changes, at most 1 s. anthropic: a fixed 2 s (none after typing; typing goes 12 ms per key). openai: capture at once."}),
                );
                props.insert(
                    "observe".into(),
                    json!({"type": "boolean", "description": "Default true: the result carries the window after acting (state: its screenshot once it changed, and its elements: what changed since your last look, or that nothing did). false: skip it."}),
                );
                props.insert("full".into(), full_arg());
                props.insert("format".into(), format_arg());
            }
            if GUARDED.contains(&self.name) {
                props.insert(
                    "force".into(),
                    json!({"type": "boolean", "description": "Skip the checks that refuse an action that would do nothing (disabled element, title bar, no text focus, element out of view). Only when you are sure."}),
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
        description: "The window's elements, one line each: [id] role \"name\" = value, then flags (focused, disabled, checked, a menu item's shortcut, extra actions). Ids stay the same for the same element across looks and actions; use them as element_id (best: works in the background). After your first look, a look shows only the changes since your last one (+ added, ~ changed with what it was, - removed), or says nothing changed. Elements scrolled out of view are counted on their container (out of view: 12 below): scroll it (scroll with its element_id) to see them. Any element takes perform_action show_menu (its context menu). The menu bar lists its menus: click a menu's id to list its items (it stays closed), then click an item's id to run it.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "max_nodes": {"type": "integer", "minimum": 1, "maximum": 5000},
                    "full": full_arg(),
                    "format": format_arg(),
                    "frames": {"type": "boolean", "description": "End each line with its frame in screenshot pixels (@x,y wxh)."},
                    "menus": {"type": "boolean", "description": "List every menu bar menu's items too."}
                }),
                &["window_id"],
            )
        },
    },
    Tool {
        name: "click",
        access: Access::Act,
        description: "Click an element (element_id) or a point (x, y in screenshot pixels) in a window, in the background. With no window_id, x and y are pixels of your latest display screenshot. A click on a pop-up or menu button, or a right click or control-click, opens its menu and leaves it open: the result shows only that menu, its items with ids, and the next call clicks one. With menu_item, the menu opens, that item is pressed and the menu closes in this one call (a context menu too; use it when the menu would hide items or hold the person's keyboard). To choose a pop-up item in one call, set_value also works. A menu bar menu's id lists its items without opening it. Refused, with what to do instead, when the click would do nothing: a disabled element, a pixel on the title bar, an element scrolled out of view.",
        schema: || {
            obj(
                json!({
                    "window_id": window_id(),
                    "element_id": {"type": "string"},
                    "x": {"type": "number"}, "y": {"type": "number"},
                    "button": {"type": "string", "enum": ["left", "right", "middle"]},
                    "count": {"type": "integer", "minimum": 1, "maximum": 3},
                    "modifiers": {"type": "array", "items": {"type": "string"}, "description": "shift, ctrl, alt/option, cmd/meta"},
                    "menu_item": {"type": "string", "description": "For a click that opens a menu (right click, control-click, a pop-up or menu button): the title of the item to choose (exact, any case, or a unique prefix), or a path for an item in a submenu (\"Sort By > Name\"); the menu opens, the item is pressed and the menu closes in one call."},
                    "delivery": delivery()
                }),
                &[],
            )
        },
    },
    Tool {
        name: "type_text",
        access: Access::Act,
        description: "Type text into element_id (a text field, focused first through accessibility), or into the window's focused field. Refused when element_id is a control that takes no text, or when the focus is on a native checkbox, slider or pop-up that would take the keys as commands. Check the result: the field's new value shows as a change; no change means the text did not land.",
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
        description: "Set an element's value directly (text fields, sliders, checkboxes), with no typing. On a pop-up or menu button, the value is the title of the item to choose (exact, any case, or a unique prefix): it is picked without opening the menu when the pop-up lists its items while closed, else its menu opens, the item is pressed and the menu closes in this one call. An item that is not there closes the menu again and the error lists the items. On macOS a slider or stepper whose value is read-only (volume, brightness) is stepped to the value; give a number in its own range or a percentage such as \"25%\".",
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
        description: "Perform one of an element's accessibility actions (from get_ui_tree): press, confirm, increment, decrement, expand, collapse, select, focus. show_menu (a context menu) or press on a pop-up opens the menu and leaves it open with its items in the result; set_value with an item title picks and closes in one call.",
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
        description: "Wait for slow work (a page load, a build, an animation), then return the window's state: what changed since your last look (or a display screenshot without window_id). ms defaults to 2000, at most 100000; duration in seconds also works.",
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
        description: "Run up to 20 steps on one window in order, in one call, and get one state at the end. A step is {\"action\": \"click\" | \"type_text\" | \"press_key\" | \"scroll\" | \"drag\" | \"set_value\" | \"perform_action\", ...that tool's arguments without window_id}, {\"action\": \"wait\", \"ms\": N}, or {\"action\": \"wait_for\", ...}. Every acting step is checked and run like its own call (settings, deny list, guards, never the person's focus) and gets its own outcome after its own settle. Steps: \"require\": \"confirmed\" stops the batch unless that step's outcome is confirmed (read back); \"not_no_effect\" stops it when the step did nothing; by default only an error stops it. \"target\": {\"role\", \"label\", \"text\"} instead of element_id names an element by what it is (label: the whole name, any case; text: part of the name or value), found when the step runs, so a step can act on what an earlier step opened; two matches are refused (ambiguous_element), never guessed. wait_for waits until an element (element_id or target) appears (default), disappears (\"until\": \"disappears\"), or its value equals (\"value_equals\") or contains (\"value_contains\") a text, reading the window again on every change the app reports, for at most timeout_ms (default 10000, at most 100000); a timeout stops the batch. The waits of one batch add up to at most 120 s. The reply's results lists every step: done (outcome, outcome_reason, read_back, changes: what changed in the window during that step), failed (code, message), or not_run; stopped_at names the step that stopped the batch and why. Nothing is checked or run when any step is malformed. No loops or conditions: for those, call the tools one at a time. A perform_action step names its accessibility action as \"perform\" (\"action\" is the step's). Example: [{\"action\": \"press_key\", \"keys\": \"cmd+s\"}, {\"action\": \"wait_for\", \"target\": {\"role\": \"sheet\"}}, {\"action\": \"set_value\", \"target\": {\"role\": \"text_field\", \"label\": \"Save As\"}, \"value\": \"notes\", \"require\": \"confirmed\"}, {\"action\": \"click\", \"target\": {\"role\": \"button\", \"label\": \"Save\"}}].",
        schema: || {
            let target = json!({
                "type": "object",
                "description": "An element by what it is, instead of element_id: found when the step runs, refused when none or several match.",
                "properties": {
                    "role": {"type": "string", "description": "As get_ui_tree shows it: button, text_field, sheet, ..."},
                    "label": {"type": "string", "description": "The element's whole name, any case."},
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
                                "require": {"type": "string", "enum": ["confirmed", "not_no_effect", "no_error"], "description": "Acting steps: when this step stops the batch. confirmed: unless its outcome is confirmed. not_no_effect: when its outcome is no_effect. no_error (default): only on an error."},
                                "target": target,
                                "element_id": {"type": "string"},
                                "perform": {"type": "string", "description": "perform_action: the accessibility action (press, confirm, ...), since action names the step."},
                                "until": {"type": "string", "enum": ["appears", "disappears"], "description": "wait_for: appears (default) or disappears."},
                                "value_equals": {"type": "string", "description": "wait_for: until the element's value is exactly this."},
                                "value_contains": {"type": "string", "description": "wait_for: until the element's value contains this."},
                                "timeout_ms": {"type": "number", "minimum": 0, "maximum": 100000, "description": "wait_for: the longest it waits (default 10000); a timeout stops the batch."},
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
        description: "Start an app by id (bundle id, executable or desktop id; on macOS also its name, such as Notes) without bringing it to the front where the platform allows. Returns its pid. When the task needs the app in front (shown to the person, frontmost) and the person allowed foreground input, act on one of its windows with delivery foreground, which raises it.",
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
pub const INSTRUCTIONS: &str = "cmux Computer Use is built into cmux: use these tools to see and use apps on this computer (and on your other machines with `machine`). There is nothing to install and no other computer-use driver is needed. When the task is about something on this computer, look before you answer: it usually means an app or document already open, so start with list_windows (or list_apps) and work in that window rather than replying in chat. Work in the background: list_windows, then screenshot or get_ui_tree a window, then act on element ids (best) or screenshot pixels. Element ids stay the same across looks. App menu commands are in the tree's menu bar: click a menu's id to list its items, then click the item to run it. Every action returns the window after acting: what changed since your last look (+ added, ~ changed, - removed, windows opened or closed) and a screenshot when it changed. Read it before you say a step worked: \"No change\" means the action did nothing visible, so try another way instead of reporting it done. For a fixed run of steps on one window (open a sheet, wait for it, fill it, save), batch does them in one call: each step reports its own outcome, wait_for waits for an element or value, target names an element by role and label, and require: \"confirmed\" stops at a step that did not read back. Work in the background first: it never takes the person's focus or pointer, a blue cmux cursor shows them where you act, and it works for nearly everything. Use delivery foreground only when the person allowed it (status says), and only for a system-wide shortcut (cmd+space for Spotlight) or when the person wants the app in front: when the task is to open or show them something, finish by bringing that window forward (a foreground click on its title bar raises it). Foreground takes their focus. If a call is refused, call status and tell the person which setting in Settings > Computer Use would allow it; never try to change Computer Use settings yourself.";

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
