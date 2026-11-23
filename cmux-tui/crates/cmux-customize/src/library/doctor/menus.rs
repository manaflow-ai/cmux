//! The doctor's menu pass: Command Palette actions (`actions`), right-click menu layouts
//! (`contextMenus.layouts`) and workspace group menus (`workspaceGroups.byCwd.*.contextMenu`) in
//! the settings file. The app skips an entry it cannot run or a row that names no action, and
//! says so only in a toast; the doctor names each one with its line and a way back.
//!
//! The rules are the app's own readers' (`ConfigActionParser.swift`, `ContextMenusSetting.swift`,
//! `WorkspaceGroupConfig+Parse.swift`); a row key is known when the action catalog has it (or a
//! legacy alias of it), or it is a submenu (`group:`, `folder:`) or a separator.

use serde_json::{Map, Value};

use super::*;

/// One menu entry cmux skips: its dotted path in the settings file, what is wrong, and the
/// text to look for to find its line (a key, or a row's quoted value after `after`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MenuProblem {
    pub path: String,
    pub message: String,
    pub level: Level,
    look_for: Look,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Look {
    Key(String),
    Value { value: String, after: String },
}

/// The settings sections this pass reads; the schema has no rows for them, so the unknown-key
/// pass leaves them to it.
pub(super) const SECTIONS: &[&str] = &["actions", "contextMenus.layouts", "workspaceGroups"];

const SEPARATOR: &str = "-";
const TARGETS: &[&str] = &["newTabInCurrentPane", "currentTerminal"];
const MAX_DEPTH: usize = 8;

/// Every menu entry in `root` (the settings file) that cmux skips.
pub(super) fn problems(root: &Value) -> Vec<MenuProblem> {
    let mut out = Vec::new();
    let actions = root.get("actions");
    let names: Vec<String> = actions
        .and_then(Value::as_object)
        .map(|entries| entries.keys().cloned().collect())
        .unwrap_or_default();
    if let Some(actions) = actions {
        action_problems(actions, &mut out);
    }
    if let Some(layouts) =
        cmux_config::value::value_at(root, &cmux_config::keypath::key_path("contextMenus.layouts"))
    {
        layout_problems(layouts, &mut out);
    }
    if let Some(groups) =
        cmux_config::value::value_at(root, &cmux_config::keypath::key_path("workspaceGroups.byCwd"))
            .and_then(Value::as_object)
    {
        for (glob, group) in groups {
            if let Some(rows) = group.get("contextMenu") {
                group_menu_problems(
                    &format!("workspaceGroups.byCwd.{glob}"),
                    rows,
                    &names,
                    &mut out,
                );
            }
        }
    }
    out
}

fn push(out: &mut Vec<MenuProblem>, path: String, level: Level, message: String, look_for: Look) {
    out.push(MenuProblem { path, message, level, look_for });
}

fn key(name: &str) -> Look {
    Look::Key(name.to_owned())
}

fn text(fields: &Map<String, Value>, name: &str) -> Option<String> {
    fields
        .get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn action_problems(actions: &Value, out: &mut Vec<MenuProblem>) {
    let Some(entries) = actions.as_object() else {
        push(
            out,
            "actions".into(),
            Level::Warning,
            "actions is not an object, so no action of yours is in the Command Palette".into(),
            key("actions"),
        );
        return;
    };
    for (name, value) in entries {
        let path = format!("actions.{name}");
        let skipped = |why: &str| format!("Action {name} is not in the Command Palette: {why}");
        let Some(fields) = value.as_object() else {
            push(out, path, Level::Warning, skipped("it is not an object"), key(name));
            continue;
        };
        let kind = text(fields, "type").unwrap_or_else(|| {
            if fields.contains_key("agent") { "agent" } else { "command" }.to_owned()
        });
        match kind.as_str() {
            "command" if text(fields, "command").is_none() => {
                push(
                    out,
                    path,
                    Level::Warning,
                    skipped("a command action needs a command"),
                    key(name),
                );
            }
            "agent"
                if text(fields, "agent")
                    .is_none_or(|agent| agent.contains(char::is_whitespace)) =>
            {
                push(
                    out,
                    path,
                    Level::Warning,
                    skipped("agent must be one command name; put flags in args"),
                    key(name),
                );
            }
            "command" | "agent" => {
                if let Some(target) = fields.get("target")
                    && !target.as_str().is_some_and(|target| TARGETS.contains(&target))
                {
                    push(
                        out,
                        format!("{path}.target"),
                        Level::Info,
                        format!(
                            "Action {name} opens in a new tab: its target is not newTabInCurrentPane or currentTerminal"
                        ),
                        Look::Value { value: "target".into(), after: name.clone() },
                    );
                }
            }
            other => push(
                out,
                path,
                Level::Warning,
                skipped(&format!("type {other:?} is not one cmux NEXT runs (command or agent)")),
                key(name),
            ),
        }
    }
}

/// A row key cmux can draw: a catalog action, a submenu or a separator.
fn known_row(row: &str) -> bool {
    row == SEPARATOR
        || row.starts_with("group:")
        || row.starts_with("folder:")
        || cmux_action_catalog::find(row).is_some()
}

fn layout_problems(layouts: &Value, out: &mut Vec<MenuProblem>) {
    let Some(menus) = layouts.as_object() else {
        push(out, "contextMenus.layouts".into(), Level::Warning, "contextMenus.layouts is not an object, so every right-click menu is drawn as the app makes it".into(), key("layouts"));
        return;
    };
    for (menu, layout) in menus {
        let path = format!("contextMenus.layouts.{menu}");
        let mut rows = Vec::new();
        if !layout_shape(layout, &mut rows) {
            push(
                out,
                path,
                Level::Warning,
                format!(
                    "Your {menu} menu layout is not one cmux reads, so that menu is drawn as the app makes it: expected {{\"items\": [...], \"hidden\": [...]}} of row keys, \"-\" and {{\"key\", \"title\", \"items\"}} submenus"
                ),
                key(menu),
            );
            continue;
        }
        let mut said = BTreeSet::new();
        for row in rows.into_iter().filter(|row| !known_row(row)) {
            if !said.insert(row.clone()) {
                continue;
            }
            push(
                out,
                format!("{path}.{row}"),
                Level::Info,
                format!(
                    "Row {row} in your {menu} menu names no action, so it is left out of the menu"
                ),
                Look::Value { value: row, after: menu.clone() },
            );
        }
    }
}

/// Whether `layout` has a shape the app reads; collects every row key it names.
fn layout_shape(layout: &Value, rows: &mut Vec<String>) -> bool {
    let Some(fields) = layout.as_object() else { return false };
    let keys = |list: Option<&Value>, rows: &mut Vec<String>| -> bool {
        match list {
            None => true,
            Some(Value::Array(items)) => items.iter().all(|item| match item.as_str() {
                Some(row) => {
                    rows.push(row.to_owned());
                    true
                }
                None => false,
            }),
            Some(_) => false,
        }
    };
    if !keys(fields.get("hidden"), rows) {
        return false;
    }
    match fields.get("items") {
        Some(items) => nodes(items, 0, rows),
        None => {
            fields.contains_key("top")
                && keys(fields.get("top"), rows)
                && keys(fields.get("more"), rows)
        }
    }
}

fn nodes(items: &Value, depth: usize, rows: &mut Vec<String>) -> bool {
    let Some(items) = items.as_array().filter(|_| depth <= MAX_DEPTH) else { return false };
    items.iter().all(|item| {
        if let Some(row) = item.as_str() {
            rows.push(row.to_owned());
            return true;
        }
        let Some(key) = item.get("key").and_then(Value::as_str) else { return false };
        if key.starts_with("group:") && item.get("title").and_then(Value::as_str).is_none() {
            return false;
        }
        if !key.starts_with("group:") {
            rows.push(key.to_owned());
        }
        nodes(item.get("items").unwrap_or(&Value::Array(Vec::new())), depth + 1, rows)
    })
}

fn group_menu_problems(path: &str, rows: &Value, names: &[String], out: &mut Vec<MenuProblem>) {
    let group = path.rsplit_once("byCwd.").map_or(path, |(_, glob)| glob).to_owned();
    let Some(rows) = rows.as_array() else {
        push(
            out,
            format!("{path}.contextMenu"),
            Level::Warning,
            format!(
                "The {group} group's contextMenu is not a list of {{\"action\": ...}}, so it adds no rows"
            ),
            Look::Value { value: "contextMenu".into(), after: group },
        );
        return;
    };
    for (index, row) in rows.iter().enumerate() {
        let at = format!("{path}.contextMenu.{index}");
        let Some(action) = row.get("action").and_then(Value::as_str).filter(|a| !a.is_empty())
        else {
            push(
                out,
                at,
                Level::Warning,
                format!(
                    "Row {} of the {group} group's menu names no action, so it is left out",
                    index + 1
                ),
                Look::Value { value: "contextMenu".into(), after: group.clone() },
            );
            continue;
        };
        let own = action.strip_prefix("cmuxConfig.").unwrap_or(action);
        if cmux_action_catalog::find(action).is_none() && !names.iter().any(|name| name == own) {
            push(
                out,
                at,
                Level::Info,
                format!(
                    "Row {action} of the {group} group's menu names no action, so it does nothing"
                ),
                Look::Value { value: action.to_owned(), after: group.clone() },
            );
        }
    }
}

impl MenuProblem {
    /// The 1-based line of the entry in `text`.
    pub(super) fn line(&self, text: &str) -> Option<u32> {
        match &self.look_for {
            Look::Key(name) => line_of_key(text, name),
            Look::Value { value, after } => {
                let start = line_of_key(text, after).unwrap_or(1);
                let needle = format!("\"{value}\"");
                text.lines()
                    .enumerate()
                    .skip(start.saturating_sub(1) as usize)
                    .find(|(_, line)| line.contains(&needle))
                    .map(|(n, _)| n as u32 + 1)
            }
        }
    }
}

impl Customize {
    /// Menu entries the settings file holds that cmux skips; each is put back with the file's
    /// newest version that loads and has none of them.
    pub(super) fn menu_findings(&self, text: &str, root: &Value, out: &mut Found) {
        let file = &self.roots().settings_file;
        let restore = self.last_good_settings().is_some();
        for problem in problems(root) {
            let line = problem.line(text);
            out.push(
                FindingKind::Ignored,
                problem.level,
                &format!("menu:{}", problem.path),
                problem.message.clone(),
                "The rest of your settings still apply. Fix or remove this entry, or put back the last settings file whose menus all load.".to_owned(),
                match line {
                    Some(line) => format!("{}:{line}", file_name(file)),
                    None => file_name(file),
                },
                Some(file),
                line,
                if restore { vec![Fix::open(false), Fix::restore()] } else { vec![Fix::open(false)] },
            );
        }
    }

    /// The newest settings file in a generation that loads and whose menus all load.
    pub(super) fn last_good_settings(&self) -> Option<(u32, Vec<u8>)> {
        self.last_good_version_where(SETTINGS, |bytes| {
            std::str::from_utf8(bytes)
                .ok()
                .and_then(|text| jsonc::parse(text).ok())
                .is_some_and(|root| problems(&root).is_empty())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_clean_menu_setup_has_no_problems() {
        let root = json!({
            "actions": {
                "codex": {"type": "agent", "agent": "codex", "target": "currentTerminal"},
                "build": {"command": "make"}
            },
            "contextMenus": {"layouts": {"workspaceRow": {
                "items": ["renameWorkspace", "-", {"key": "group:a", "title": "Mine", "items": ["closeWorkspace"]},
                          {"key": "folder:more", "items": []}],
                "hidden": ["workspace.copyPath"]
            }}},
            "workspaceGroups": {"byCwd": {"~/src/*": {"contextMenu": [
                {"action": "renameWorkspace"}, {"action": "cmuxConfig.build"}, {"action": "codex"}
            ]}}}
        });
        assert_eq!(problems(&root), Vec::new());
    }

    #[test]
    fn each_skipped_entry_is_named() {
        let root = json!({
            "actions": {"a": "x", "b": {"type": "command"}, "c": {"agent": "claude --x"}, "d": {"type": "workspace"}},
            "contextMenus": {"layouts": {"pane": {"items": [1]}, "tab": {"items": ["no.such.row"]}}},
            "workspaceGroups": {"byCwd": {"g": {"contextMenu": [{"title": "x"}, {"action": "nope"}]}}}
        });
        let paths: Vec<_> = problems(&root).into_iter().map(|p| p.path).collect();
        assert_eq!(
            paths,
            [
                "actions.a",
                "actions.b",
                "actions.c",
                "actions.d",
                "contextMenus.layouts.pane",
                "contextMenus.layouts.tab.no.such.row",
                "workspaceGroups.byCwd.g.contextMenu.0",
                "workspaceGroups.byCwd.g.contextMenu.1",
            ]
        );
    }
}
