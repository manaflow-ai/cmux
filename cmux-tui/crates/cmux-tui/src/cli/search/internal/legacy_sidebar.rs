//! The daemon's legacy control protocol, read for `cmux search`'s workspace and terminal kinds.
//!
//! The sidebar tree (`list-workspaces`) names a tab by its numeric `surface` and a workspace
//! by its sidebar `short_id`, and the find bar (`terminal-find`) takes that `surface`. Those
//! are private wire keys: this module reads them to walk the tree, match a typed sidebar
//! handle and page a terminal's scrollback, and the rows it builds carry only the opaque
//! prefixed IDs (`terminal_id`, `tab_resource_id`, `resource_id`) into `--json`. It sits
//! under `internal/`, outside the resource-v2 public boundary scan
//! (`cmux-tui/scripts/check-resource-api-boundary.py`).

use std::time::Instant;

use serde_json::{Map, Value, json};

use super::super::{Daemon, Kind, MATCHES_PER_TERMINAL, Row, SCROLLBACK_PAGES, first_text, text};

#[derive(Debug, Clone, PartialEq)]
pub(in crate::cli::search) struct TerminalRef {
    /// The tab's legacy control-protocol handle, for `terminal-find` only; never printed.
    pub(in crate::cli::search) surface: u64,
    pub(in crate::cli::search) terminal_id: String,
    pub(in crate::cli::search) title: String,
    pub(in crate::cli::search) workspace: String,
}

/// A row per workspace and per tab of the `list-workspaces` tree, and the live terminals
/// (active workspace first, so its scrollback is searched before the budget runs out).
pub(in crate::cli::search) fn sidebar_rows(tree: &Value) -> (Vec<Row>, Vec<TerminalRef>) {
    let mut rows = Vec::new();
    let mut terminals = Vec::new();
    let workspaces = tree.get("workspaces").and_then(Value::as_array).cloned().unwrap_or_default();
    for workspace in &workspaces {
        let name = first_text(workspace, &["title", "name", "key", "id"]);
        let group = text(workspace, "group");
        let mut handles = Vec::new();
        for key in ["short_id", "id", "resource_id", "key"] {
            if let Some(handle) = workspace.get(key).and_then(value_text) {
                handles.push(handle);
            }
        }
        let mut record = Map::new();
        // `--json` carries the workspace's own IDs, not the sidebar's short handle.
        for key in ["id", "resource_id", "key", "name", "title", "group", "active"] {
            if let Some(value) = workspace.get(key) {
                record.insert(key.into(), value.clone());
            }
        }
        record.insert("type".into(), json!("workspace"));
        let mut tabs = Vec::new();
        collect_tabs(workspace, &mut tabs);
        let tab_titles = tabs.iter().map(tab_title).collect::<Vec<_>>();
        rows.push(Row {
            kind: Kind::Workspace,
            title: name.clone(),
            subtitle: if group.is_empty() {
                format!("{} tab(s)", tabs.len())
            } else {
                format!("{group} · {} tab(s)", tabs.len())
            },
            keywords: [vec![group, text(workspace, "name")], tab_titles].concat(),
            handles,
            found: false,
            record: Value::Object(record),
        });
        let active = workspace.get("active").and_then(Value::as_bool) == Some(true);
        for tab in &tabs {
            let title = tab_title(tab);
            let cwd = text(tab, "cwd");
            let branch = text(tab, "git_branch");
            let url = first_text(tab, &["url", "pinned_url"]);
            let detail = [url.as_str(), cwd.as_str(), branch.as_str()]
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
            let mut handles = Vec::new();
            for key in ["short_id", "tab_resource_id", "terminal_id"] {
                if let Some(handle) = tab.get(key).and_then(value_text) {
                    handles.push(handle);
                }
            }
            let mut record = Map::new();
            // `--json` names the tab by its opaque IDs, not the numeric surface or short handle.
            for key in
                ["tab_resource_id", "terminal_id", "name", "title", "cwd", "git_branch", "url"]
            {
                if let Some(value) = tab.get(key).filter(|value| !value.is_null()) {
                    record.insert(key.into(), value.clone());
                }
            }
            record.insert("type".into(), json!("tab"));
            record.insert("workspace".into(), json!(name));
            rows.push(Row {
                kind: Kind::Workspace,
                title: title.clone(),
                subtitle: if detail.is_empty() {
                    format!("tab in {name}")
                } else {
                    format!("tab in {name} · {detail}")
                },
                keywords: vec![cwd, branch, url, name.clone()],
                handles,
                found: false,
                record: Value::Object(record),
            });
            let live = tab.get("dead").and_then(Value::as_bool) != Some(true);
            if let (Some(surface), Some(terminal_id), true) = (
                tab.get("surface").and_then(Value::as_u64),
                tab.get("terminal_id").and_then(Value::as_str),
                live,
            ) {
                let terminal = TerminalRef {
                    surface,
                    terminal_id: terminal_id.to_owned(),
                    title,
                    workspace: name.clone(),
                };
                if active { terminals.insert(0, terminal) } else { terminals.push(terminal) }
            }
        }
    }
    (rows, terminals)
}

/// Every tab under `node` (screens, panes and tab lists): an object with a numeric `surface`.
fn collect_tabs(node: &Value, tabs: &mut Vec<Value>) {
    match node {
        Value::Object(object) => {
            if object.get("surface").is_some_and(Value::is_u64) {
                tabs.push(node.clone());
                return;
            }
            for (key, child) in object {
                // A layout node names panes by id only; the panes list carries the tabs.
                if key != "layout" {
                    collect_tabs(child, tabs);
                }
            }
        }
        Value::Array(items) => items.iter().for_each(|item| collect_tabs(item, tabs)),
        _ => {}
    }
}

/// A tab's name, else its title or folder, else its opaque ID (never the numeric surface).
fn tab_title(tab: &Value) -> String {
    let title = first_text(tab, &["name", "title", "cwd", "terminal_id", "tab_resource_id"]);
    if title.is_empty() { "tab".to_owned() } else { title }
}

fn value_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// The newest find-bar matches in one terminal's whole retained scrollback, a page at a time.
pub(in crate::cli::search) fn terminal_matches(
    daemon: &mut Daemon,
    surface: u64,
    query: &str,
    deadline: Instant,
) -> Result<Vec<Value>, String> {
    let mut matches = Vec::new();
    let mut before = Value::Null;
    let mut epoch = Value::Null;
    for _ in 0..SCROLLBACK_PAGES {
        let mut request = json!({
            "cmd": "terminal-find",
            "surface": surface,
            "query": query,
            "max_matches": MATCHES_PER_TERMINAL,
        });
        if let (false, Some(object)) = (before.is_null(), request.as_object_mut()) {
            object.insert("before".into(), before.clone());
            object.insert("epoch".into(), epoch.clone());
        }
        let page = daemon.call(request)?;
        matches.extend(page.get("matches").and_then(Value::as_array).cloned().unwrap_or_default());
        let complete = page.get("complete").and_then(Value::as_bool) != Some(false);
        before = page.get("next_before").cloned().unwrap_or(Value::Null);
        epoch = page.get("epoch").cloned().unwrap_or(Value::Null);
        if complete
            || before.is_null()
            || matches.len() >= MATCHES_PER_TERMINAL
            || Instant::now() >= deadline
        {
            break;
        }
    }
    matches.truncate(MATCHES_PER_TERMINAL);
    Ok(matches)
}

#[cfg(test)]
#[path = "legacy_sidebar_tests.rs"]
mod tests;
