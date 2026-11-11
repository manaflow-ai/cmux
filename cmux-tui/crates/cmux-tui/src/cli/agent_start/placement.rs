//! Where `agent start` and `resume` open the agent's tab, and opening it.
//!
//! - No `--pane` and no `--split`: a new pane in the caller's space (the
//!   caller's pane, or outside a cmux-tui terminal the focused pane, with
//!   the agent panes it started), [`Placement::Beside`]. A cmux-tui
//!   terminal of another session is never placed by focus (agent_start.rs
//!   `caller_terminal` refuses that start). `resume` without
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
//! The caller's space (W6-F, bench round 5 orchestration row 8: the caller
//! of two agents was left 9 columns wide) is the caller's pane, the agent
//! panes stacked with it, and the agent columns right after it in its row.
//! A default start adds a column only for the space's first agent, and only
//! when the caller's pane and the new one both keep [`MIN_AGENT_COLUMNS`]
//! terminal columns after the split; else the first agent goes below the
//! caller. Every later agent goes below the space's last agent pane, and
//! the agents of that stack share its height, while each keeps
//! [`MIN_AGENT_ROWS`] terminal rows; else it opens as a new tab in that
//! last agent pane. So a column, once there, keeps its width (a new column
//! never resizes existing ones), the caller never goes under the minimum
//! while it had it, and no pane outside the space changes. A start whose
//! target pane is itself an agent pane (no caller known: the focused pane,
//! often the agent the last start focused) stacks the same way and never
//! adds a column. Without the target's size in the snapshot, or in a screen
//! that is no split tree, a default start splits the target to the right.
//!
//! The agent runs in a tab of its own (`pane run --on-exit keep --name
//! NAME`), so its name, argv and harness session stay on record after it
//! exits. A split (or a new workspace) first opens a shell tab, whose shell
//! ends once the agent's tab runs there ([`end_placeholder`]).

use serde_json::{Value, json};

use super::super::agent_names::{self, Found};
use super::super::terminal_talk::send::{self, Daemon};
use super::{Failure, plan};

/// The fewest terminal columns a default start leaves the caller and its
/// first agent before it stacks the agent below the caller instead (W6-F):
/// an agent's permission dialog stays readable, and the caller keeps room
/// to work.
const MIN_AGENT_COLUMNS: f64 = 40.0;

/// The fewest terminal rows a default start leaves each agent of a stack
/// before it opens the next agent as a tab in the stack's last agent pane
/// (W6-F): a permission dialog of a few lines and the input box still show.
const MIN_AGENT_ROWS: f64 = 8.0;

/// The columns a pane's frame takes from its terminal: the client draws a
/// border box in the pane and, by default, a scrollbar column inside it
/// (`scrollbar.position = column`; app/frame_geometry.rs). The snapshot's
/// `cols` is the terminal's, so a 49-column pane has a 46-column terminal.
const FRAME_COLUMNS: f64 = 3.0;

/// The rows a pane's frame takes from its terminal: the border box's top
/// row (the tab bar) and its bottom row.
const FRAME_ROWS: f64 = 2.0;

/// A new tab in a pane, or a new pane next to it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Placement {
    /// A split in this direction (`right`, `down`, `left`, `up`).
    Split(String),
    /// No `--pane` and no `--split`: a new pane in the caller's space
    /// (module doc).
    Beside,
    Tab,
}

impl Placement {
    pub(in crate::cli) fn as_str(&self) -> &'static str {
        match self {
            Self::Split(_) | Self::Beside => "split",
            Self::Tab => "tab",
        }
    }
}

/// Where [`Placement::Beside`] opens the agent.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Room {
    /// A new column right of this pane (the caller's, for its first agent).
    Column(String),
    /// A new pane below this one; the agents of its stack then share it.
    Stack(String),
    /// A new tab in this pane: the last agent pane of a full stack.
    Tab(String),
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
/// places it in the caller's space for [`Placement::Beside`], runs `argv`
/// there as a named tab that keeps its terminal after exit, and ends the
/// split's shell ([`end_placeholder`]). Returns the new tab and the
/// placement it got: [`Placement::Beside`] becomes the split it made, or
/// [`Placement::Tab`] in the last agent pane of a full stack.
pub(in crate::cli) fn open<D: Daemon + ?Sized>(
    daemon: &D,
    pane: &str,
    placement: &Placement,
    name: Option<&str>,
    cwd: Option<&str>,
    argv: &[String],
) -> Result<(Created, Placement), Failure> {
    let (target, shell_tab, placed) = match placement {
        Placement::Split(direction) => {
            let split = split(daemon, pane, direction, cwd)?;
            balance(daemon, split.screen.as_deref(), &split.pane, None);
            (split.pane.clone(), Some(Placeholder::of(&split)), placement.clone())
        }
        Placement::Beside => {
            let (split, direction) = match room(daemon, pane) {
                Some(Room::Tab(last)) => {
                    // W6-F: shows how often a stack is full.
                    crate::client_log::log(
                        "debug",
                        "agent_start",
                        &format!("agent stack full: the agent opens as a tab in {last}"),
                    );
                    return run_in(daemon, &last, None, Placement::Tab, name, cwd, argv);
                }
                Some(Room::Column(beside)) => {
                    let split = split(daemon, &beside, "right", cwd)?;
                    balance(daemon, split.screen.as_deref(), &split.pane, Some(pane));
                    (split, "right")
                }
                Some(Room::Stack(below)) => {
                    let split = split(daemon, &below, "down", cwd)?;
                    balance(daemon, split.screen.as_deref(), &split.pane, None);
                    (split, "down")
                }
                None => {
                    // W6-F: shows how often a start lacks the caller's size.
                    crate::client_log::log(
                        "debug",
                        "agent_start",
                        &format!(
                            "default placement fell back to a right split of {pane}: \
                             no caller size in the snapshot or no split tree"
                        ),
                    );
                    let split = split(daemon, pane, "right", cwd)?;
                    balance(daemon, split.screen.as_deref(), &split.pane, None);
                    (split, "right")
                }
            };
            let placed = Placement::Split(direction.to_owned());
            (split.pane.clone(), Some(Placeholder::of(&split)), placed)
        }
        Placement::Tab => (pane.to_owned(), None, Placement::Tab),
    };
    run_in(daemon, &target, shell_tab.as_ref(), placed, name, cwd, argv)
}

/// Runs `argv` in `target` as a named tab that keeps its terminal after
/// exit and ends `shell_tab`, the new pane's shell; a failed run also
/// closes the new pane, so no shell pane stays behind.
fn run_in<D: Daemon + ?Sized>(
    daemon: &D,
    target: &str,
    shell_tab: Option<&Placeholder>,
    placed: Placement,
    name: Option<&str>,
    cwd: Option<&str>,
    argv: &[String],
) -> Result<(Created, Placement), Failure> {
    let mut words = vec!["pane", target, "run", "--on-exit", "keep"];
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
            if let Some(shell) = shell_tab {
                end_placeholder(daemon, shell);
                if let Ok(close) = plan(&["pane", target, "close"]) {
                    let _ = daemon.request(None, close);
                }
            }
            return Err(failure);
        }
    };
    if let Some(shell) = shell_tab {
        end_placeholder(daemon, shell);
    }
    Ok((created, placed))
}

/// `pane split <pane> --<direction>`: the new pane and its shell tab.
fn split<D: Daemon + ?Sized>(
    daemon: &D,
    pane: &str,
    direction: &str,
    cwd: Option<&str>,
) -> Result<Created, Failure> {
    let flag = format!("--{direction}");
    let mut words = vec!["pane", pane, "split", flag.as_str()];
    if let Some(cwd) = cwd {
        words.extend(["--cwd", cwd]);
    }
    Created::from_result(&daemon.request(None, plan(&words)?)?)
}

/// The session snapshot and the layout of `pane`'s screen (`screen` when
/// known), when both can be read.
fn layout_of<D: Daemon + ?Sized>(
    daemon: &D,
    screen: Option<&str>,
    pane: &str,
) -> (Option<Value>, Option<Value>) {
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
    let layout = screen.and_then(|screen| {
        let export = plan(&["screen", screen.as_str(), "layout", "export"]).ok()?;
        let layout = daemon.request(None, export).ok()?;
        Some(layout.get("root").cloned().unwrap_or(layout))
    });
    (snapshot, layout)
}

/// Where a default start opens beside `target` ([`beside`]); `None` when
/// the snapshot or the layout cannot tell.
fn room<D: Daemon + ?Sized>(daemon: &D, target: &str) -> Option<Room> {
    let (snapshot, layout) = layout_of(daemon, None, target);
    let snapshot = snapshot?;
    beside(&snapshot, &layout?, target)
}

/// Evens the new `pane`'s row by setting the ratios of the splits that
/// change: the agent panes around it ([`row_ratios`]), or with `caller`
/// the columns of the caller's space ([`space_ratios`]).
fn balance<D: Daemon + ?Sized>(daemon: &D, screen: Option<&str>, pane: &str, caller: Option<&str>) {
    let (snapshot, layout) = layout_of(daemon, screen, pane);
    let Some(root) = layout else { return };
    let is_agent = |id: &str| {
        id == pane || snapshot.as_ref().is_some_and(|snapshot| started_agents(snapshot, id))
    };
    let ratios = match caller {
        Some(caller) => space_ratios(&root, caller, &is_agent),
        None => row_ratios(&root, pane, &is_agent),
    };
    for (split, ratio) in ratios {
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

/// The caller's space in its row: the caller's cell (its pane and the
/// agent panes stacked with it) and the agent cells right after it.
struct Space<'a> {
    /// The row's top split; `None` when the caller's cell is not in a row.
    row: Option<&'a Value>,
    /// The row's cells (only the caller's cell without a row).
    cells: Vec<Cell<'a>>,
    /// The caller's cell.
    caller: usize,
    /// One past the space's last cell.
    end: usize,
}

/// The caller's space in `root` ([`Space`]); `None` when `caller` is not in
/// a split tree.
fn space<'a>(root: &'a Value, caller: &str, is_agent: &dyn Fn(&str) -> bool) -> Option<Space<'a>> {
    let mut path = Vec::new();
    if !matches!(root["kind"].as_str(), Some("split" | "leaf")) || !path_to(root, caller, &mut path)
    {
        return None;
    }
    let all_agents = |node: &Value| {
        let mut panes = Vec::new();
        leaves(node, &mut panes);
        !panes.is_empty() && panes.iter().all(|pane| is_agent(pane))
    };
    let holds_caller = |node: &Value| path_to(node, caller, &mut Vec::new());
    let child = |split: &'a Value| {
        if holds_caller(&split["first"]) { &split["first"] } else { &split["second"] }
    };
    // Climb the stacks whose other side holds only agents: the caller's cell.
    let mut at = path.len();
    while let Some(split) = at.checked_sub(1).and_then(|index| path.get(index)) {
        let other = if holds_caller(&split["first"]) { &split["second"] } else { &split["first"] };
        if split["direction"] != "vertical" || !all_agents(other) {
            break;
        }
        at -= 1;
    }
    let cell = match (path.get(at), path.last()) {
        (Some(split), _) => *split,
        (None, Some(&parent)) => child(parent),
        (None, None) => root,
    };
    let top = path
        .get(..at)
        .unwrap_or_default()
        .iter()
        .rposition(|split| split["direction"] != "horizontal")
        .map_or(0, |different| different + 1);
    let Some(row) = path.get(top).filter(|_| top < at).copied() else {
        let mut panes = Vec::new();
        leaves(cell, &mut panes);
        return Some(Space {
            row: None,
            cells: vec![Cell { node: cell, panes, width: 1.0 }],
            caller: 0,
            end: 1,
        });
    };
    let mut cells = Vec::new();
    cells_of(row, &json!("horizontal"), 1.0, &mut cells);
    let caller_cell = cells.iter().position(|candidate| std::ptr::eq(candidate.node, cell))?;
    let agent =
        |cell: &Cell<'_>| !cell.panes.is_empty() && cell.panes.iter().all(|id| is_agent(id));
    let after = cells.get(caller_cell + 1..).unwrap_or_default();
    let end = caller_cell + 1 + after.iter().take_while(|cell| agent(cell)).count();
    Some(Space { row: Some(row), cells, caller: caller_cell, end })
}

/// The size of `pane`'s terminal along `key` (`cols` or `rows`): its
/// largest terminal's in `snapshot`, without the pane's frame.
fn pane_size(snapshot: &Value, pane: &str, key: &str) -> Option<f64> {
    let tabs: Vec<&str> = list(snapshot, "tabs")
        .iter()
        .filter(|tab| tab["pane_id"] == pane)
        .filter_map(|tab| tab["content_id"].as_str())
        .collect();
    list(snapshot, "terminals")
        .iter()
        .filter(|terminal| terminal["id"].as_str().is_some_and(|id| tabs.contains(&id)))
        .filter_map(|terminal| terminal[key].as_f64())
        .reduce(f64::max)
}

/// Where a default start opens beside `target` (module doc): the caller
/// alone takes a new column while both halves keep [`MIN_AGENT_COLUMNS`],
/// else a pane below it; once the space has an agent, a pane below the
/// space's last agent pane while each agent of that stack keeps
/// [`MIN_AGENT_ROWS`] ([`stack_rows`]), else a tab in that pane. `None`
/// without the target's width or a split tree.
fn beside(snapshot: &Value, root: &Value, target: &str) -> Option<Room> {
    let is_agent = |id: &str| started_agents(snapshot, id);
    let columns = pane_size(snapshot, target, "cols")?;
    let space = space(root, target, &is_agent)?;
    let last = space.cells.get(space.end.checked_sub(1)?)?;
    let last_pane = (*last.panes.last()?).to_owned();
    if last_pane == target && !is_agent(target) {
        // The space's first agent: the daemon gives the first side of an
        // even split `round(width / 2)`, so the narrower side is the floor.
        let half = ((columns + FRAME_COLUMNS) / 2.0).floor() - FRAME_COLUMNS;
        return Some(if half >= MIN_AGENT_COLUMNS && last.node["kind"] == "leaf" {
            Room::Column(last_pane)
        } else {
            Room::Stack(last_pane)
        });
    }
    Some(match stack_rows(snapshot, root, &last_pane, &is_agent) {
        Some(rows) if rows < MIN_AGENT_ROWS => Room::Tab(last_pane),
        _ => Room::Stack(last_pane),
    })
}

/// The terminal rows each agent of `pane`'s stack keeps after a split puts
/// one more agent below `pane`: [`row_ratios`] then evens the run of agent
/// panes around the new one in `pane`'s column (the chain of vertical splits
/// above it). Rows come from the snapshot (each pane's terminal plus its
/// frame); a cell with no terminal size takes its share of the column.
/// `None` when no size is known.
fn stack_rows(
    snapshot: &Value,
    root: &Value,
    pane: &str,
    is_agent: &dyn Fn(&str) -> bool,
) -> Option<f64> {
    let mut path = Vec::new();
    if !path_to(root, pane, &mut path) {
        return None;
    }
    let vertical = json!("vertical");
    let top = path
        .iter()
        .rposition(|split| split["direction"] != vertical)
        .map_or(0, |different| different + 1);
    let Some(column) = path.get(top) else {
        // `pane` is not in a stack: the split halves it.
        let rows = pane_size(snapshot, pane, "rows")? + FRAME_ROWS;
        return Some((rows / 2.0).floor() - FRAME_ROWS);
    };
    let mut cells = Vec::new();
    cells_of(column, &vertical, 1.0, &mut cells);
    let at = cells.iter().position(|cell| cell.panes.contains(&pane))?;
    let known = |cell: &Cell<'_>| match cell.panes.as_slice() {
        [only] if cell.node["kind"] == "leaf" => {
            pane_size(snapshot, only, "rows").map(|rows| rows + FRAME_ROWS)
        }
        _ => None,
    };
    let (mut known_rows, mut known_share) = (0.0, 0.0);
    for cell in &cells {
        if let Some(rows) = known(cell) {
            known_rows += rows;
            known_share += cell.width;
        }
    }
    if known_share <= 0.0 {
        return None;
    }
    let rows = |cell: &Cell<'_>| known(cell).unwrap_or(known_rows / known_share * cell.width);
    let agent =
        |cell: &Cell<'_>| !cell.panes.is_empty() && cell.panes.iter().all(|id| is_agent(id));
    let before = cells.get(..at).unwrap_or_default();
    let first = at - before.iter().rev().take_while(|cell| agent(cell)).count();
    let after = cells.get(at + 1..).unwrap_or_default();
    let end = at + 1 + after.iter().take_while(|cell| agent(cell)).count();
    let run = cells.get(first..end)?;
    let total: f64 = run.iter().map(rows).sum();
    Some((total / (run.len() as f64 + 1.0)).floor() - FRAME_ROWS)
}

/// The split ratios that give each column of `caller`'s space (with the
/// new pane, which `is_agent` counts) the same width; every other cell of
/// the row keeps its width. Ratios that already fit are left out.
fn space_ratios(root: &Value, caller: &str, is_agent: &dyn Fn(&str) -> bool) -> Vec<(String, f64)> {
    let Some(space) = space(root, caller, is_agent) else { return Vec::new() };
    let Some(row) = space.row else { return Vec::new() };
    let mut widths: Vec<f64> = space.cells.iter().map(|cell| cell.width).collect();
    let Some(shared) = widths.get_mut(space.caller..space.end) else { return Vec::new() };
    let total: f64 = shared.iter().sum();
    let count = shared.len() as f64;
    shared.fill(total / count);
    let mut ratios = Vec::new();
    let mut next = 0;
    assign(row, &json!("horizontal"), &widths, &mut next, &mut ratios);
    ratios
}

/// One pane (or stack, or split across the row) of a row, with its share of
/// the row's width.
struct Cell<'a> {
    node: &'a Value,
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
    // A split across the row is one cell with every pane in it: shared
    // only when each is an agent pane (a stack of agents).
    let mut panes = Vec::new();
    leaves(node, &mut panes);
    cells.push(Cell { node, panes, width });
}

/// The panes under `node`, in order (a stack's panes too), into `panes`.
fn leaves<'a>(node: &'a Value, panes: &mut Vec<&'a str>) {
    match node["kind"].as_str() {
        Some("leaf") => panes.extend(node["pane_id"].as_str()),
        Some("stack") => panes
            .extend(node["pane_ids"].as_array().into_iter().flatten().filter_map(Value::as_str)),
        Some("split") => {
            leaves(&node["first"], panes);
            leaves(&node["second"], panes);
        }
        _ => {}
    }
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
