//! `cmux search`'s workspace, tab and scrollback kinds, read over the session daemon's legacy
//! line protocol (`list-workspaces`, `terminal-find`).
//!
//! These are daemon-internal commands whose rows still carry the daemon's own keys (`surface`,
//! `short_id`); they are not the public resource v2 surface, so this reader lives in an
//! `internal` folder the resource API boundary check skips. The public `cmux search` usage and
//! the browser kind (resource v2 `history.entries.list`) stay in `search.rs`.

use super::*;

/// The whole scrollback scan's budget: terminals past it are named under `incomplete`.
const SCROLLBACK_BUDGET: Duration = Duration::from_secs(6);
/// Find-bar pages read per terminal (8192 rows each) before moving on.
const SCROLLBACK_PAGES: usize = 16;
/// Matches kept per terminal.
const MATCHES_PER_TERMINAL: usize = 3;

/// One connection to the session daemon, legacy commands answered in order.
struct Daemon {
    reader: BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    next_id: u64,
}

impl Daemon {
    fn connect(global: &GlobalArgs) -> Result<Self, String> {
        let (socket, derived) = super::super::wire::resolve_socket_with_origin(global)
            .map_err(|error| super::super::wire::resolve_failure_message(&error))?;
        let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
            .map_err(|error| format!("cannot connect to {}: {error}", socket.display()))?;
        let _ = stream.set_read_timeout(Some(DAEMON_READ_TIMEOUT));
        Ok(Self { reader: BufReader::new(stream), next_id: 1 })
    }

    fn call(&mut self, mut request: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        if let Some(object) = request.as_object_mut() {
            object.insert("id".into(), json!(id));
        }
        writeln!(self.reader.get_mut(), "{request}")
            .and_then(|()| self.reader.get_mut().flush())
            .map_err(|error| error.to_string())?;
        let mut line = String::new();
        loop {
            line.clear();
            match self.reader.read_line(&mut line) {
                Ok(0) => return Err("the daemon closed the connection".into()),
                Ok(_) => {}
                Err(error) => return Err(error.to_string()),
            }
            let Ok(response) = serde_json::from_str::<Value>(&line) else { continue };
            if response.get("event").is_some() || response.get("id") != Some(&json!(id)) {
                continue;
            }
            if response.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(response.get("data").cloned().unwrap_or(Value::Null));
            }
            return Err(response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("request rejected")
                .to_owned());
        }
    }
}

/// The sidebar's workspace and tab rows and, with `scrollback`, every live terminal's
/// find-bar matches, from one daemon connection.
pub(super) fn sidebar_and_scrollback(
    global: &GlobalArgs,
    query: &str,
    limit: usize,
    scrollback: bool,
) -> Result<(Vec<Row>, Vec<String>), String> {
    let mut daemon = Daemon::connect(global)?;
    let tree = daemon.call(json!({"cmd": "list-workspaces"}))?;
    let (mut rows, terminals) = sidebar_rows(&tree);
    let mut incomplete = Vec::new();
    if !scrollback {
        return Ok((rows, incomplete));
    }
    let deadline = Instant::now() + SCROLLBACK_BUDGET;
    let mut found = 0usize;
    let mut skipped = 0usize;
    for terminal in &terminals {
        if Instant::now() >= deadline || found >= limit * 4 {
            skipped += 1;
            continue;
        }
        let matches = match terminal_matches(&mut daemon, terminal.surface, query, deadline) {
            Ok(matches) => matches,
            // A terminal that closed or is not a PTY since the tree was read: skip it.
            Err(_) => continue,
        };
        for hit in matches {
            found += 1;
            let snippet = text(&hit, "snippet");
            rows.push(Row {
                kind: Kind::Terminal,
                title: snippet.trim().to_owned(),
                subtitle: format!("{} › {}", terminal.workspace, terminal.title),
                keywords: vec![terminal.title.clone(), terminal.workspace.clone()],
                handles: Vec::new(),
                found: true,
                record: json!({
                    "surface": terminal.surface,
                    "terminal_id": terminal.terminal_id,
                    "workspace": terminal.workspace,
                    "tab": terminal.title,
                    "match": hit,
                }),
            });
        }
    }
    if skipped > 0 {
        incomplete.push(format!("{skipped} terminal(s) not searched within the time budget"));
    }
    Ok((rows, incomplete))
}

#[derive(Debug, Clone, PartialEq)]
pub(super) struct TerminalRef {
    pub(super) surface: u64,
    pub(super) terminal_id: String,
    pub(super) title: String,
    pub(super) workspace: String,
}

/// A row per workspace and per tab of the `list-workspaces` tree, and the live terminals
/// (active workspace first, so its scrollback is searched before the budget runs out).
pub(super) fn sidebar_rows(tree: &Value) -> (Vec<Row>, Vec<TerminalRef>) {
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
        for key in ["id", "resource_id", "key", "short_id", "name", "title", "group", "active"] {
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
            for key in [
                "surface",
                "tab_resource_id",
                "terminal_id",
                "short_id",
                "name",
                "title",
                "cwd",
                "git_branch",
                "url",
            ] {
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

fn tab_title(tab: &Value) -> String {
    let title = first_text(tab, &["name", "title", "cwd"]);
    if title.is_empty() {
        format!("tab {}", tab.get("surface").and_then(Value::as_u64).unwrap_or(0))
    } else {
        title
    }
}

fn value_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// The newest find-bar matches in one terminal's whole retained scrollback, a page at a time.
fn terminal_matches(
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
