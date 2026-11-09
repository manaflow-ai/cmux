//! Where `agent start` and `resume` open the agent's tab, and opening it.
//!
//! - No `--pane` and no `--split`: split the caller's pane (or, outside a
//!   cmux-tui terminal, the focused pane) to the right. `resume` without
//!   either reopens the agent in the pane of its exited tab instead.
//! - `--pane SEL`: a new tab in that pane.
//! - `--pane SEL --split DIR`, or `--split DIR` alone: split that pane.
//! - A session with no pane yet (a daemon no client opened): a new workspace
//!   named after the agent, whose first shell ends once the agent's tab runs.
//!
//! The agent runs in a tab of its own (`pane run --on-exit keep --name
//! NAME`), so its name, argv and harness session stay on record after it
//! exits. A split first opens a shell tab in the new pane; that shell ends
//! (`end_placeholder`) once the agent's tab runs there.

use serde_json::{Value, json};

use super::super::agent_names::{self, Found};
use super::daemon::{self, Daemon};
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
/// its pane and the shell it opened with (end it with `end_placeholder`
/// once the agent's tab runs). `None` when the session has a pane. Main's `workspace create` takes
/// no folder; the agent's own tab gets `--cwd` (`pane run`).
///
/// The ids come from the create receipt, else from the pane of the receipt's
/// workspace, never from focus: another `agent start` may create (and focus)
/// its own workspace at the same time.
pub(in crate::cli) fn empty_session_pane<D: Daemon + ?Sized>(
    daemon: &D,
    snapshot: &Value,
    name: &str,
) -> Result<Option<(String, Option<Placeholder>)>, Failure> {
    if !list(snapshot, "panes").is_empty() {
        return Ok(None);
    }
    let result = daemon.request(None, plan(&["workspace", "create", "--name", name])?)?;
    if let Ok(created) = Created::from_result(&result) {
        let placeholder = Placeholder::of(&created);
        return Ok(Some((created.pane, Some(placeholder))));
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
    let snapshot = daemon::snapshot(daemon)?;
    let pane = pane_of_workspace(&snapshot, &workspace).ok_or_else(|| {
        not_found(&workspace, format!("the new workspace {workspace} has no pane"))
    })?;
    let shell = list(&snapshot, "tabs")
        .iter()
        .find(|tab| tab["pane_id"] == pane.as_str())
        .and_then(|tab| {
            Some(Placeholder {
                tab: tab["id"].as_str()?.to_owned(),
                terminal: tab["content_id"]
                    .as_str()
                    .filter(|content| content.starts_with("term_"))
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

/// The shell tab a new pane or workspace started with, and its terminal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Placeholder {
    /// The shell's tab.
    pub tab: String,
    /// Its terminal, when the session reported it.
    pub terminal: Option<String>,
}

impl Placeholder {
    fn of(created: &Created) -> Self {
        Self { tab: created.tab.clone(), terminal: Some(created.terminal.clone()) }
    }
}

/// Ends a placeholder shell with `terminal <t> close`, as `pane move` does:
/// closing only its tab would leave the shell running without a tab. A tab
/// close is the fallback when the terminal is not known or will not close;
/// main has no reaper, so that shell stays until the session ends. A shell
/// that stays is harmless to the agent, so a failure is ignored.
pub(in crate::cli) fn end_placeholder<D: Daemon + ?Sized>(daemon: &D, placeholder: &Placeholder) {
    let ended = placeholder.terminal.as_deref().is_some_and(|terminal| {
        plan(&["terminal", terminal, "close"])
            .is_ok_and(|close| daemon.request(None, close).is_ok())
    });
    if !ended && let Ok(close) = plan(&["tab", placeholder.tab.as_str(), "close"]) {
        let _ = daemon.request(None, close);
    }
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
/// and ends the split's placeholder shell (`end_placeholder`).
pub(in crate::cli) fn open<D: Daemon + ?Sized>(
    daemon: &D,
    pane: &str,
    placement: &Placement,
    name: Option<&str>,
    cwd: Option<&str>,
    argv: &[String],
) -> Result<Created, Failure> {
    let (target, placeholder) = match placement {
        Placement::Split(direction) => {
            let flag = format!("--{direction}");
            let mut words = vec!["pane", pane, "split", flag.as_str()];
            if let Some(cwd) = cwd {
                words.extend(["--cwd", cwd]);
            }
            let split = Created::from_result(&daemon.request(None, plan(&words)?)?)?;
            let placeholder = Placeholder::of(&split);
            (split.pane, Some(placeholder))
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
            // Leave no empty shell pane behind a failed start.
            if let Some(shell) = &placeholder {
                end_placeholder(daemon, shell);
                if let Ok(close) = plan(&["pane", target.as_str(), "close"]) {
                    let _ = daemon.request(None, close);
                }
            }
            return Err(failure);
        }
    };
    if let Some(shell) = &placeholder {
        end_placeholder(daemon, shell);
    }
    Ok(created)
}
