//! Where `agent start` and `resume` open the agent's tab, and opening it.
//!
//! - No `--pane` and no `--split`: split the caller's pane (or, outside a
//!   cmux-tui terminal, the focused pane) to the right. `resume` without
//!   either reopens the agent in the pane of its exited tab instead.
//! - `--pane SEL`: a new tab in that pane.
//! - `--pane SEL --split DIR`, or `--split DIR` alone: split that pane.
//!
//! The agent runs in a tab of its own (`pane run --on-exit keep --name
//! NAME`), so its name, argv and harness session stay on record after it
//! exits. A split first opens a shell tab in the new pane, which is closed
//! once the agent's tab runs there.

use serde_json::{Value, json};

use super::super::agent_names::{self, Found};
use super::super::terminal_talk::send::Daemon;
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
    /// The created path of a `pane.split` or `pane.run` result.
    pub(in crate::cli) fn from_result(result: &Value) -> Result<Self, Failure> {
        let path = if result["path"].is_object() { &result["path"] } else { result };
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
/// and closes the split's shell tab.
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
            (split.pane, Some(split.tab))
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
            if shell_tab.is_some()
                && let Ok(close) = plan(&["pane", target.as_str(), "close"])
            {
                let _ = daemon.request(None, close);
            }
            return Err(failure);
        }
    };
    if let Some(tab) = shell_tab
        && let Ok(close) = plan(&["tab", tab.as_str(), "close"])
    {
        // The agent runs either way; a shell tab that stays is harmless.
        let _ = daemon.request(None, close);
    }
    Ok(created)
}
