//! Where `agent start` and `resume` open the agent's tab, and opening it.
//!
//! - No `--pane` and no `--split`: split the caller's pane (or, outside a
//!   cmux-tui terminal, the focused pane) to the right. `resume` without
//!   either reopens the agent in the pane of its exited tab instead.
//! - `--pane SEL`: a new tab in that pane.
//! - `--pane SEL --split DIR`, or `--split DIR` alone: split that pane.
//! - A session with no pane yet (a daemon no client opened): a new workspace
//!   named after the agent, whose first shell tab the agent's tab replaces.
//!
//! A split takes the new pane's width only from the pane it splits: every
//! other pane of the row (the chain of splits in the same direction around
//! it) keeps its width, so a person's column keeps its width. The agent
//! panes next to the new one in that row (each tab's terminal has the
//! daemon's `extra.agent_start` mark and runs; a tab's name does not count,
//! and an exited agent's pane keeps its width) then
//! share their space equally, so the third agent of a row is not an eighth
//! of it (W5-Q, bench round 4 orchestration friction 6). A screen of
//! viewport columns keeps each column's width.
//!
//! The agent runs in a tab of its own (`pane run --on-exit keep --name
//! NAME`), so its name, argv and harness session stay on record after it
//! exits. A split (or a new workspace) first opens a shell tab, whose shell
//! ends once the agent's tab runs there ([`end_placeholder`]).

use serde_json::{Value, json};

use super::super::agent_names::{self, Found};
use super::super::terminal_talk::send::{self, Daemon};
use super::{Failure, plan};

/// A new tab in a pane, or a new pane next to it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Placement {
    /// A split in this direction (`right`, `down`, `left`, `up`).
    Split(String),
    Tab,
}

impl Placement {
    pub(in crate::cli) fn as_str(&self) -> &'static str {
        match self {
            Self::Split(_) => "split",
            Self::Tab => "tab",
        }
    }
}

/// The ids of the agent's new tab.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct Created {
    pub workspace: Option<String>,
    pub screen: Option<String>,
    pub pane: String,
    pub tab: String,
    pub terminal: String,
}

impl Created {
    /// The created path of a `pane.split` or `pane.run` result: the
    /// mutation receipt's `value` (`{generation, revision, value: {pane_id,
    /// tab_id, terminal_id, ...}}`), a `path`, or the record itself.
    pub(in crate::cli) fn from_result(result: &Value) -> Result<Self, Failure> {
        let path = ["value", "path"]
            .into_iter()
            .filter_map(|key| result.get(key))
            .find(|inner| inner.is_object())
            .unwrap_or(result);
        let text = |key: &str| path[key].as_str().map(str::to_owned);
        match (text("pane_id"), text("tab_id"), text("terminal_id")) {
            (Some(pane), Some(tab), Some(terminal)) => Ok(Self {
                workspace: text("workspace_id"),
                screen: text("screen_id"),
                pane,
                tab,
                terminal,
            }),
            _ => Err(Failure::local(
                "agent.start_failed",
                "the session did not report the new terminal",
                json!({"result": result}),
                1,
            )),
        }
    }
}

/// The shell tab a new pane or workspace opened with, which holds the pane
/// until the agent's tab runs there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Placeholder {
    pub tab: String,
    /// Its terminal, when the session reported it.
    pub terminal: Option<String>,
}

impl Placeholder {
    fn of(created: &Created) -> Self {
        Self { tab: created.tab.clone(), terminal: Some(created.terminal.clone()) }
    }

    /// The shell tab a split or `screen create` result names (`tab_id`,
    /// `terminal_id`).
    pub(in crate::cli) fn from_path(path: &Value) -> Self {
        Self {
            tab: path.get("tab_id").and_then(Value::as_str).unwrap_or_default().to_owned(),
            terminal: path.get("terminal_id").and_then(Value::as_str).map(str::to_owned),
        }
    }

    /// The command that ends it: `terminal <t> close` ends the shell and its
    /// tab. Without a terminal id it is `tab <t> close`, and the session's
    /// reaper ends the shell after its grace.
    pub(in crate::cli) fn end_command(&self) -> [&str; 3] {
        match &self.terminal {
            Some(terminal) => ["terminal", terminal.as_str(), "close"],
            None => ["tab", self.tab.as_str(), "close"],
        }
    }
}

/// Ends the placeholder's shell and so its tab (`terminal <t> close`). A
/// `tab close` only took the tab away and left the shell running with no
/// tab, out of sight, until the session ended (W5-O, bench round 4). Without
/// a terminal id, or when the session refuses the terminal close, the tab
/// closes and the session's reaper ends the shell. Any failure is ignored:
/// the agent runs either way.
pub(in crate::cli) fn end_placeholder<D: Daemon + ?Sized>(daemon: &D, placeholder: &Placeholder) {
    let ended =
        plan(&placeholder.end_command()).is_ok_and(|close| daemon.request(None, close).is_ok());
    if !ended
        && placeholder.terminal.is_some()
        && let Ok(close) = plan(&["tab", placeholder.tab.as_str(), "close"])
    {
        let _ = daemon.request(None, close);
    }
}

fn list<'a>(snapshot: &'a Value, key: &str) -> &'a [Value] {
    snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

/// The pane of the tab that shows `terminal`.
pub(in crate::cli) fn pane_of_terminal(snapshot: &Value, terminal: &str) -> Option<String> {
    let record = list(snapshot, "terminals").iter().find(|record| record["id"] == terminal)?;
    let tab = record["tab_id"].as_str()?;
    let tab = list(snapshot, "tabs").iter().find(|candidate| candidate["id"] == tab)?;
    tab["pane_id"].as_str().map(str::to_owned)
}

/// The pane the person looks at: the focused pane of the focused screen of
/// the focused workspace, else any focused pane, else the first pane.
pub(in crate::cli) fn focused_pane(snapshot: &Value) -> Option<String> {
    let focused = |key: &str| -> Vec<&str> {
        list(snapshot, key)
            .iter()
            .filter(|record| record["focused"] == true)
            .filter_map(|record| record["id"].as_str())
            .collect()
    };
    let workspaces = focused("workspaces");
    let screens: Vec<&str> = list(snapshot, "screens")
        .iter()
        .filter(|screen| screen["focused"] == true)
        .filter(|screen| screen["workspace_id"].as_str().is_some_and(|ws| workspaces.contains(&ws)))
        .filter_map(|screen| screen["id"].as_str())
        .collect();
    let panes = list(snapshot, "panes");
    let id = |pane: &Value| pane["id"].as_str().map(str::to_owned);
    panes
        .iter()
        .find(|pane| {
            pane["focused"] == true
                && pane["screen_id"].as_str().is_some_and(|screen| screens.contains(&screen))
        })
        .or_else(|| panes.iter().find(|pane| pane["focused"] == true))
        .or_else(|| panes.first())
        .and_then(id)
}

/// For a session with no pane: creates a workspace named `name` and returns
/// its pane and the shell tab it opened with (end it with
/// [`end_placeholder`] once the agent's tab runs). `None` when the session
/// has a pane.
///
/// The ids come from the create receipt, else from the pane of the receipt's
/// workspace, never from focus: another `agent start` may create (and focus)
/// its own workspace at the same time.
pub(in crate::cli) fn empty_session_pane<D: Daemon + ?Sized>(
    daemon: &D,
    snapshot: &Value,
    name: &str,
    cwd: Option<&str>,
) -> Result<Option<(String, Option<Placeholder>)>, Failure> {
    if !list(snapshot, "panes").is_empty() {
        return Ok(None);
    }
    let mut words = vec!["workspace", "create", "--name", name];
    if let Some(cwd) = cwd {
        words.extend(["--cwd", cwd]);
    }
    let result = daemon.request(None, plan(&words)?)?;
    if let Ok(created) = Created::from_result(&result) {
        let shell = Placeholder::of(&created);
        return Ok(Some((created.pane, Some(shell))));
    }
    let workspace = ["/value/workspace_id", "/path/workspace_id", "/workspace_id", "/id"]
        .into_iter()
        .find_map(|pointer| result.pointer(pointer).and_then(Value::as_str))
        .filter(|id| id.starts_with("ws_"))
        .map(str::to_owned)
        .ok_or_else(|| {
            Failure::local(
                "agent.start_failed",
                "the session did not report the new workspace",
                json!({"result": result}),
                1,
            )
        })?;
    let snapshot = send::snapshot(daemon, None)?;
    let pane = pane_of_workspace(&snapshot, &workspace).ok_or_else(|| {
        not_found(&workspace, format!("the new workspace {workspace} has no pane"))
    })?;
    let shell = list(&snapshot, "tabs")
        .iter()
        .find(|tab| tab["pane_id"] == pane.as_str())
        .and_then(|tab| {
            Some(Placeholder {
                tab: tab.get("id")?.as_str()?.to_owned(),
                terminal: tab
                    .get("content_id")
                    .and_then(Value::as_str)
                    .filter(|id| id.starts_with("term_"))
                    .map(str::to_owned),
            })
        });
    Ok(Some((pane, shell)))
}

/// A pane of `workspace` (its focused pane first).
fn pane_of_workspace(snapshot: &Value, workspace: &str) -> Option<String> {
    let screens: Vec<&str> = list(snapshot, "screens")
        .iter()
        .filter(|screen| screen["workspace_id"] == workspace)
        .filter_map(|screen| screen["id"].as_str())
        .collect();
    let panes: Vec<&Value> = list(snapshot, "panes")
        .iter()
        .filter(|pane| pane["screen_id"].as_str().is_some_and(|screen| screens.contains(&screen)))
        .collect();
    panes
        .iter()
        .find(|pane| pane["focused"] == true)
        .or_else(|| panes.first())
        .and_then(|pane| pane["id"].as_str())
        .map(str::to_owned)
}

fn not_found(selector: &str, message: String) -> Failure {
    Failure::local("selector.not_found", message, json!({"pane": selector}), 1)
}

/// The pane `selector` names (`None`: the caller's pane, else the focused
/// one): an id or unique id prefix, `current`, `caller`, `focused`, an agent
/// name or unique tab name (its pane), or a pane name.
pub(in crate::cli) fn target_pane(
    snapshot: &Value,
    selector: Option<&str>,
    caller_terminal: Option<&str>,
) -> Result<String, Failure> {
    let caller = || caller_terminal.and_then(|terminal| pane_of_terminal(snapshot, terminal));
    let focused = || {
        focused_pane(snapshot).ok_or_else(|| not_found("focused", "the session has no pane".into()))
    };
    let selector = match selector {
        None | Some("current") => return caller().map_or_else(focused, Ok),
        Some("focused") => return focused(),
        Some("caller") => {
            return caller().ok_or_else(|| {
                not_found("caller", "no caller terminal is known in this session".into())
            });
        }
        Some(selector) => selector,
    };
    let panes = list(snapshot, "panes");
    let ids: Vec<&str> = panes.iter().filter_map(|pane| pane["id"].as_str()).collect();
    if ids.contains(&selector) {
        return Ok(selector.to_owned());
    }
    if selector.starts_with("pane_") {
        let matches: Vec<&&str> = ids.iter().filter(|id| id.starts_with(selector)).collect();
        return match matches.as_slice() {
            [one] => Ok((**one).to_owned()),
            [] => Err(not_found(selector, format!("no pane is {selector:?}"))),
            many => Err(Failure::local(
                "selector.ambiguous",
                format!("{} panes start with {selector:?}; name one by its full id", many.len()),
                json!({"pane": selector, "candidates": many}),
                1,
            )),
        };
    }
    let named: Vec<&str> = panes
        .iter()
        .filter(|pane| pane["name"] == selector)
        .filter_map(|pane| pane["id"].as_str())
        .collect();
    if let [one] = named.as_slice() {
        return Ok((*one).to_owned());
    }
    match agent_names::resolve(snapshot, selector) {
        Found::One(place) => Ok(place.pane),
        Found::Ambiguous(tabs) => Err(Failure::local(
            "selector.ambiguous",
            format!("{} tabs are named {selector:?}; name the pane by its id", tabs.len()),
            json!({"pane": selector, "candidates": tabs}),
            1,
        )),
        Found::Missing => Err(not_found(
            selector,
            format!("no pane, agent or tab is named {selector:?}; cmux pane list lists the panes"),
        )),
    }
}

/// Opens the agent's tab: splits `pane` first for [`Placement::Split`],
/// runs `argv` there as a named tab that keeps its terminal after exit,
/// and ends the split's shell ([`end_placeholder`]).
pub(in crate::cli) fn open<D: Daemon + ?Sized>(
    daemon: &D,
    pane: &str,
    placement: &Placement,
    name: Option<&str>,
    cwd: Option<&str>,
    argv: &[String],
) -> Result<Created, Failure> {
    let (target, shell_tab) = match placement {
        Placement::Split(direction) => {
            let flag = format!("--{direction}");
            let mut words = vec!["pane", pane, "split", flag.as_str()];
            if let Some(cwd) = cwd {
                words.extend(["--cwd", cwd]);
            }
            let split = Created::from_result(&daemon.request(None, plan(&words)?)?)?;
            balance(daemon, split.screen.as_deref(), &split.pane);
            (split.pane.clone(), Some(Placeholder::of(&split)))
        }
        Placement::Tab => (pane.to_owned(), None),
    };
    let mut words = vec!["pane", target.as_str(), "run", "--on-exit", "keep"];
    if let Some(name) = name {
        words.extend(["--name", name]);
    }
    if let Some(cwd) = cwd {
        words.extend(["--cwd", cwd]);
    }
    words.push("--");
    words.extend(argv.iter().map(String::as_str));
    let ran = plan(&words)
        .and_then(|run| Ok(daemon.request(None, run)?))
        .and_then(|result| Created::from_result(&result));
    let created = match ran {
        Ok(created) => created,
        Err(failure) => {
            // Leave no shell pane, and no shell, behind a failed start: the
            // shell's end takes its tab, and the pane with its last tab.
            if let Some(shell) = &shell_tab {
                end_placeholder(daemon, shell);
                if let Ok(close) = plan(&["pane", target.as_str(), "close"]) {
                    let _ = daemon.request(None, close);
                }
            }
            return Err(failure);
        }
    };
    if let Some(shell) = &shell_tab {
        end_placeholder(daemon, shell);
    }
    Ok(created)
}

/// Evens the agent panes of the new `pane`'s row ([`row_ratios`]) by
/// setting the ratios of the splits that change.
fn balance<D: Daemon + ?Sized>(daemon: &D, screen: Option<&str>, pane: &str) {
    let snapshot = send::snapshot(daemon, None).ok();
    let screen = match screen {
        Some(screen) => Some(screen.to_owned()),
        None => snapshot.as_ref().and_then(|snapshot| {
            list(snapshot, "panes")
                .iter()
                .find(|record| record["id"] == pane)
                .and_then(|record| record["screen_id"].as_str())
                .map(str::to_owned)
        }),
    };
    let Some(screen) = screen else { return };
    let Ok(export) = plan(&["screen", screen.as_str(), "layout", "export"]) else { return };
    let Ok(layout) = daemon.request(None, export) else { return };
    let root = layout.get("root").unwrap_or(&layout);
    let is_agent = |id: &str| {
        id == pane || snapshot.as_ref().is_some_and(|snapshot| started_agents(snapshot, id))
    };
    for (split, ratio) in row_ratios(root, pane, &is_agent) {
        let ratio = format!("{ratio:.6}");
        let words = [
            "pane",
            pane,
            "split",
            "ratio",
            "set",
            "--split",
            split.as_str(),
            "--ratio",
            ratio.as_str(),
        ];
        if let Ok(set) = plan(&words) {
            // The agent runs either way; an uneven row is no failure.
            let _ = daemon.request(None, set);
        }
    }
}

/// Whether `pane` holds running agents agent start made: it has tabs, and
/// each one's terminal carries the daemon's `extra.agent_start` mark (its
/// stored spawn argv is the agent start launch,
/// cmux_tui_core::agent_start_launch) and is live: its lifecycle is
/// `running`, `launching` or `adopting` (`terminal_lifecycle::is_live`, the
/// one allow-list). Any other word (a later protocol's state) or no
/// `lifecycle` field counts as the person's pane, so a new state never
/// resizes a column. The agent's own state (`working`, `idle`, `blocked`,
/// ...) is a different field and does not count: a live idle or blocked
/// agent runs in a `running` terminal. A person's tab never has the mark,
/// whatever its name; an exited agent kept with `--on-exit keep` keeps its
/// mark but counts as the person's pane, so its width stays. Nothing reads
/// a process.
fn started_agents(snapshot: &Value, pane: &str) -> bool {
    let marked: std::collections::HashSet<&str> = list(snapshot, "terminals")
        .iter()
        .filter(|terminal| terminal.pointer("/extra/agent_start") == Some(&Value::Bool(true)))
        .filter(|terminal| super::super::terminal_lifecycle::is_live(terminal))
        .filter_map(|terminal| terminal["id"].as_str())
        .collect();
    let mut tabs = list(snapshot, "tabs").iter().filter(|tab| tab["pane_id"] == pane).peekable();
    tabs.peek().is_some()
        && tabs.all(|tab| tab["content_id"].as_str().is_some_and(|id| marked.contains(id)))
}

/// The split ratios (`split_id`, share of `first`) after a split made
/// `pane`: the row is the largest chain of splits in the direction of
/// `pane`'s own split. The run of agent panes around `pane` along the row
/// (`is_agent`, [`started_agents`]) shares its width equally; every other pane of the row keeps
/// its width, so a new pane takes space only from agent panes (the column
/// rule). Ratios that already fit are left out; a layout that is not a
/// split tree gives none.
fn row_ratios(root: &Value, pane: &str, is_agent: &dyn Fn(&str) -> bool) -> Vec<(String, f64)> {
    let mut path = Vec::new();
    if root["kind"] != "split" || !path_to(root, pane, &mut path) {
        return Vec::new();
    }
    let Some(direction) = path.last().map(|split| &split["direction"]) else {
        return Vec::new();
    };
    let top = path
        .iter()
        .rposition(|split| split["direction"] != *direction)
        .map_or(0, |different| different + 1);
    let Some(row) = path.get(top) else { return Vec::new() };
    let mut cells = Vec::new();
    cells_of(row, direction, 1.0, &mut cells);
    let Some(new) = cells.iter().position(|cell| cell.panes.contains(&pane)) else {
        return Vec::new();
    };
    let agent =
        |cell: &Cell<'_>| !cell.panes.is_empty() && cell.panes.iter().all(|id| is_agent(id));
    let before = cells.get(..new).unwrap_or_default();
    let first = new.saturating_sub(before.iter().rev().take_while(|cell| agent(cell)).count());
    let after = cells.get(new..).unwrap_or_default();
    let end = new.saturating_add(after.iter().take_while(|cell| agent(cell)).count());
    let Some(run) = cells.get(first..end) else { return Vec::new() };
    let mut total = 0.0;
    let mut count = 0.0;
    for cell in run {
        total += cell.width;
        count += 1.0;
    }
    let mut widths: Vec<f64> = cells.iter().map(|cell| cell.width).collect();
    if let Some(shared) = widths.get_mut(first..end) {
        shared.fill(total / count);
    }
    let mut ratios = Vec::new();
    let mut next = 0;
    assign(row, direction, &widths, &mut next, &mut ratios);
    ratios
}

/// One pane (or stack, or split across the row) of a row, with its share of
/// the row's width.
struct Cell<'a> {
    panes: Vec<&'a str>,
    width: f64,
}

/// The cells of `node`'s row along `direction`, in order, into `cells`.
fn cells_of<'a>(node: &'a Value, direction: &Value, width: f64, cells: &mut Vec<Cell<'a>>) {
    if node["kind"] == "split" && node["direction"] == *direction {
        let ratio = node["ratio"].as_f64().filter(|ratio| ratio.is_finite()).unwrap_or(0.5);
        cells_of(&node["first"], direction, width * ratio, cells);
        cells_of(&node["second"], direction, width * (1.0 - ratio), cells);
        return;
    }
    let panes = match node["kind"].as_str() {
        Some("leaf") => node["pane_id"].as_str().into_iter().collect(),
        Some("stack") => node["pane_ids"]
            .as_array()
            .map(|ids| ids.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default(),
        // A split across the row holds panes of other rows: never shared.
        _ => Vec::new(),
    };
    cells.push(Cell { panes, width });
}

/// Pushes the ratio of each row split under `node` that `widths` (the
/// cells' new widths, from `next` on) needs and returns `node`'s width.
fn assign(
    node: &Value,
    direction: &Value,
    widths: &[f64],
    next: &mut usize,
    ratios: &mut Vec<(String, f64)>,
) -> f64 {
    if node["kind"] != "split" || node["direction"] != *direction {
        let width = widths.get(*next).copied().unwrap_or(0.0);
        *next = next.saturating_add(1);
        return width;
    }
    let first = assign(&node["first"], direction, widths, next, ratios);
    let second = assign(&node["second"], direction, widths, next, ratios);
    let total = first + second;
    if total > 0.0 {
        let ratio = first / total;
        let current = node["ratio"].as_f64().unwrap_or(f64::NAN);
        if let Some(split) = node["split_id"].as_str()
            && (current.is_nan() || (current - ratio).abs() > 0.001)
        {
            ratios.push((split.to_owned(), ratio));
        }
    }
    total
}

/// The splits from `node` down to `pane`'s leaf (or stack), into `path`.
fn path_to<'a>(node: &'a Value, pane: &str, path: &mut Vec<&'a Value>) -> bool {
    match node["kind"].as_str() {
        Some("leaf") => node["pane_id"] == pane,
        Some("stack") => {
            node["pane_ids"].as_array().is_some_and(|panes| panes.iter().any(|id| id == pane))
        }
        Some("split") => {
            path.push(node);
            if path_to(&node["first"], pane, path) || path_to(&node["second"], pane, path) {
                return true;
            }
            path.pop();
            false
        }
        _ => false,
    }
}
