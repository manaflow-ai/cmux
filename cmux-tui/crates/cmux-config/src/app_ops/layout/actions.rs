//! `actions` and the surface tab bar buttons: Swift `ConfigActionParser`, `SurfaceTabBarParser`,
//! `BuiltInButtonActions`.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::{Diag, OpError, at, diags_json, opt_string, root_of};

const REMOVED: &str = "ignored: the tab bar buttons were removed";
const ACTION_PREFIX: &str = "cmuxConfig.";

/// (config id, action id, symbol).
const BUILT_INS: [(&str, &str, &str); 9] = [
    ("cmux.newTerminal", "newSurface", "terminal"),
    ("cmux.newBrowser", "openBrowser", "globe"),
    ("cmux.splitRight", "splitRight", "square.split.2x1"),
    ("cmux.splitDown", "splitDown", "square.split.1x2"),
    ("cmux.newWorkspace", "newTab", "plus.square"),
    ("cmux.newAgentChat", "palette.newAgentChat", "message"),
    ("cmux.newCloudWorkspace", "newCloudWorkspace", "cloud.fill"),
    ("cmux.newCloudMachine", "newCloudMachine", "cloud"),
    ("cmux.mobileconnect", "palette.mobileConnect", "iphone"),
];

/// Each canonical id's spellings.
const ALIASES: [(&str, &[&str]); 9] = [
    ("cmux.newTerminal", &["cmux.newTerminal", "newTerminal"]),
    ("cmux.newBrowser", &["cmux.newBrowser", "newBrowser"]),
    ("cmux.splitRight", &["cmux.splitRight", "splitRight"]),
    ("cmux.splitDown", &["cmux.splitDown", "splitDown"]),
    ("cmux.newWorkspace", &["cmux.newWorkspace", "newWorkspace"]),
    (
        "cmux.newAgentChat",
        &["cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat"],
    ),
    ("cmux.newCloudWorkspace", &["cmux.newCloudWorkspace", "newCloudWorkspace"]),
    ("cmux.newCloudMachine", &["cmux.newCloudMachine", "newCloudMachine"]),
    (
        "cmux.mobileconnect",
        &[
            "cmux.mobileconnect",
            "cmux.mobileConnect",
            "mobileConnect",
            "mobileconnect",
            "cmux.connectPhone",
            "connectPhone",
        ],
    ),
];

const UNSUPPORTED: [&str; 10] = [
    "cmux.cloudvm",
    "cmux.cloudVM",
    "cloudVM",
    "cloudvm",
    "cmux.newCloudVM",
    "cmux.startCloudVM",
    "cmux.newSimulator",
    "newSimulator",
    "new-simulator",
    "simulator",
];

/// The built-in a spelling names: (config id, action id, symbol).
fn built_in(identifier: &str) -> Option<(&'static str, &'static str, &'static str)> {
    let canonical = ALIASES.iter().find(|(_, spellings)| spellings.contains(&identifier))?.0;
    BUILT_INS.iter().copied().find(|(id, _, _)| *id == canonical)
}

#[derive(Clone)]
struct Action {
    name: String,
    title: String,
    tooltip: Option<String>,
    icon: Option<Value>,
    command: String,
    target: &'static str,
}

impl Action {
    fn id(&self) -> String {
        format!("{ACTION_PREFIX}{}", self.name)
    }

    fn json(&self) -> Value {
        json!({"actionID": self.id(), "name": self.name, "title": self.title, "tooltip": self.tooltip,
            "icon": self.icon, "command": self.command, "target": self.target, "cwd": null})
    }

    fn button(&self, id: String) -> Button {
        Button {
            id,
            action_id: self.id(),
            title: Some(self.title.clone()),
            tooltip: self.tooltip.clone(),
            icon: self.icon.clone(),
        }
    }
}

struct Button {
    id: String,
    action_id: String,
    title: Option<String>,
    tooltip: Option<String>,
    icon: Option<Value>,
}

impl Button {
    fn json(&self) -> Value {
        json!({"id": self.id, "actionID": self.action_id, "title": self.title, "tooltip": self.tooltip, "icon": self.icon})
    }
}

/// The text of a string member, trimmed; `None` when absent, not a string or blank.
fn trimmed(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// Swift `URL.standardizedFileURL` on a path: `.` and `..` folded, repeated `/` collapsed.
fn standardize(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

struct Context<'a> {
    config_directory: &'a str,
    home: &'a str,
}

impl Context<'_> {
    fn icon(&self, value: Option<&Value>) -> Option<Value> {
        let value = value?;
        if let Some(name) = trimmed(Some(value)) {
            return Some(json!({"symbol": name}));
        }
        let fields = value.as_object()?;
        match trimmed(fields.get("type")).as_deref() {
            Some("symbol" | "sfSymbol" | "systemImage") => {
                trimmed(fields.get("name")).map(|name| json!({"symbol": name}))
            }
            Some("image" | "file") => {
                let path = trimmed(fields.get("path"))?;
                let expanded = if path == "~" {
                    self.home.to_string()
                } else if let Some(rest) = path.strip_prefix("~/") {
                    format!("{}/{rest}", self.home)
                } else {
                    path
                };
                let full = if expanded.starts_with('/') {
                    expanded
                } else {
                    format!("{}/{expanded}", self.config_directory)
                };
                Some(json!({"image": standardize(&full)}))
            }
            _ => None,
        }
    }
}

fn agent_command(agent: &str) -> &str {
    match agent {
        "claude" | "claudeCode" | "claude-code" => "claude",
        "opencode" | "openCode" | "open-code" => "opencode",
        other => other,
    }
}

fn command_text(
    kind: &str,
    fields: &Map<String, Value>,
    path: &str,
    diags: &mut Vec<Diag>,
) -> Option<String> {
    match kind {
        "command" => {
            let command = trimmed(fields.get("command"));
            if command.is_none() {
                diags.push(Diag::invalid(
                    format!("{path}.command"),
                    "command actions need a command",
                ));
            }
            command
        }
        "agent" => {
            let agent =
                trimmed(fields.get("agent")).filter(|a| !a.chars().any(char::is_whitespace));
            let Some(agent) = agent else {
                diags.push(Diag::invalid(
                    format!("{path}.agent"),
                    "agent must be one command name; put flags in args",
                ));
                return None;
            };
            let name = agent_command(&agent).to_string();
            Some(match trimmed(fields.get("args")) {
                Some(args) => format!("{name} {args}"),
                None => name,
            })
        }
        other => {
            diags.push(Diag::unknown_action(
                format!("{path}.type"),
                format!("type '{other}' is not supported in cmux-next yet"),
            ));
            None
        }
    }
}

fn target(value: Option<&Value>, path: &str, diags: &mut Vec<Diag>) -> &'static str {
    let Some(value) = value else { return "newTabInCurrentPane" };
    match value.as_str() {
        Some("newTabInCurrentPane") => "newTabInCurrentPane",
        Some("currentTerminal") => "currentTerminal",
        _ => {
            diags.push(Diag::invalid(
                format!("{path}.target"),
                "expected newTabInCurrentPane or currentTerminal",
            ));
            "newTabInCurrentPane"
        }
    }
}

fn parse_actions(root: &Value, ctx: &Context, diags: &mut Vec<Diag>) -> BTreeMap<String, Action> {
    let mut result = BTreeMap::new();
    let Some(section) = root.get("actions") else { return result };
    let Some(entries) = section.as_object() else {
        diags.push(Diag::invalid("actions", "expected an object"));
        return result;
    };
    for (name, value) in entries {
        let path = format!("actions.{name}");
        let Some(fields) = value.as_object() else {
            diags.push(Diag::invalid(path, "expected an object"));
            continue;
        };
        let kind = trimmed(fields.get("type")).unwrap_or_else(|| {
            if fields.contains_key("agent") { "agent" } else { "command" }.to_string()
        });
        let Some(command) = command_text(&kind, fields, &path, diags) else { continue };
        let tooltip = trimmed(fields.get("tooltip"));
        let action = Action {
            name: name.clone(),
            title: trimmed(fields.get("title"))
                .or_else(|| tooltip.clone())
                .unwrap_or_else(|| name.clone()),
            tooltip,
            icon: ctx.icon(fields.get("icon")),
            command,
            target: target(fields.get("target"), &path, diags),
        };
        result.insert(name.clone(), action);
    }
    result
}

pub(super) fn surface_tab_bar_op(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let ctx = Context {
        config_directory: opt_string(request, "configDirectory")?.unwrap_or("/"),
        home: opt_string(request, "home")?.unwrap_or("/"),
    };
    let mut diags = Vec::new();
    let mut actions = parse_actions(root, &ctx, &mut diags);
    let located = at(root, &["ui", "surfaceTabBar", "buttons"])
        .map(|v| (v, "ui.surfaceTabBar.buttons"))
        .or_else(|| root.get("surfaceTabBarButtons").map(|v| (v, "surfaceTabBarButtons")));
    let mut buttons: Vec<Button> = Vec::new();
    let mut uses_defaults = true;
    if let Some((value, path)) = located {
        // TAB-STRIP-TRAILING-BUTTONS-REMOVED: the strip draws no buttons.
        diags.push(Diag::removed(path, REMOVED));
        if let Some(entries) = value.as_array() {
            uses_defaults = false;
            for (index, entry) in entries.iter().enumerate() {
                let entry_path = format!("{path}.{index}");
                let Some(button) = resolve(entry, &entry_path, &mut actions, &ctx, &mut diags)
                else {
                    continue;
                };
                if buttons.iter().any(|seen| seen.id == button.id) {
                    diags.push(Diag::invalid(
                        entry_path,
                        format!("duplicate button id '{}'", button.id),
                    ));
                    continue;
                }
                buttons.push(button);
            }
        }
    }
    Ok(json!({
        "tabBar": {"buttons": buttons.iter().map(Button::json).collect::<Vec<_>>(), "usesDefaults": uses_defaults},
        "actions": actions.values().map(Action::json).collect::<Vec<_>>(),
        "diagnostics": diags_json(&diags),
    }))
}

fn reference(
    identifier: &str,
    id: Option<String>,
    path: &str,
    actions: &BTreeMap<String, Action>,
    diags: &mut Vec<Diag>,
) -> Option<Button> {
    if let Some(action) = actions.get(identifier) {
        return Some(action.button(id.unwrap_or_else(|| identifier.to_string())));
    }
    if let Some((config_id, action_id, symbol)) = built_in(identifier) {
        return Some(Button {
            id: id.unwrap_or_else(|| config_id.to_string()),
            action_id: action_id.to_string(),
            title: None,
            tooltip: None,
            icon: Some(json!({"symbol": symbol})),
        });
    }
    if UNSUPPORTED.contains(&identifier) {
        diags.push(Diag::unknown_action(
            path,
            format!("'{identifier}' is not supported in cmux-next yet"),
        ));
        return None;
    }
    Some(Button {
        id: id.unwrap_or_else(|| identifier.to_string()),
        action_id: identifier.to_string(),
        title: None,
        tooltip: None,
        icon: None,
    })
}

fn resolve(
    entry: &Value,
    path: &str,
    actions: &mut BTreeMap<String, Action>,
    ctx: &Context,
    diags: &mut Vec<Diag>,
) -> Option<Button> {
    if entry.is_string() {
        let Some(identifier) = trimmed(Some(entry)) else {
            diags.push(Diag::invalid(path, "blank button"));
            return None;
        };
        return reference(&identifier, None, path, actions, diags);
    }
    let Some(fields) = entry.as_object() else {
        diags.push(Diag::invalid(path, "expected a string or an object"));
        return None;
    };
    let forms: Vec<&str> = ["action", "builtin", "command", "agent", "type"]
        .into_iter()
        .filter(|k| fields.contains_key(*k))
        .collect();
    if forms.len() > 1 {
        diags.push(Diag::invalid(path, format!("define only one of {}", forms.join(", "))));
        return None;
    }
    let explicit_id = trimmed(fields.get("id"));
    let button = match forms.first().copied() {
        Some("action") => match trimmed(fields.get("action")) {
            Some(identifier) => reference(&identifier, explicit_id, path, actions, diags),
            None => None,
        },
        Some("builtin") => {
            let identifier = trimmed(fields.get("builtin")).filter(|i| built_in(i).is_some());
            let Some(identifier) = identifier else {
                diags.push(Diag::unknown_action(format!("{path}.builtin"), "unknown built-in"));
                return None;
            };
            reference(&identifier, explicit_id, path, actions, diags)
        }
        Some(kind @ ("command" | "agent")) => {
            let command = command_text(kind, fields, path, diags)?;
            let name = explicit_id.unwrap_or_else(|| format!("{kind}.{command}"));
            let tooltip = trimmed(fields.get("tooltip"));
            let action = Action {
                name: name.clone(),
                title: trimmed(fields.get("title"))
                    .or_else(|| tooltip.clone())
                    .unwrap_or_else(|| command.clone()),
                tooltip,
                icon: Some(
                    ctx.icon(fields.get("icon")).unwrap_or_else(|| json!({"symbol": "terminal"})),
                ),
                command,
                target: target(fields.get("target"), path, diags),
            };
            let button = action.button(name.clone());
            actions.insert(name, action);
            Some(button)
        }
        Some(_) => {
            diags.push(Diag::unknown_action(
                format!("{path}.type"),
                "workspace buttons are not supported in cmux-next yet",
            ));
            return None;
        }
        None => match explicit_id.filter(|id| built_in(id).is_some()) {
            Some(id) => reference(&id, None, path, actions, diags),
            None => {
                diags.push(Diag::invalid(path, "button needs action, builtin, command, or agent"));
                return None;
            }
        },
    };
    let mut button = button?;
    if let Some(title) = trimmed(fields.get("title")) {
        button.title = Some(title);
    }
    if let Some(tooltip) = trimmed(fields.get("tooltip")) {
        button.tooltip = Some(tooltip);
    }
    if let Some(icon) = ctx.icon(fields.get("icon")) {
        button.icon = Some(icon);
    }
    Some(button)
}
