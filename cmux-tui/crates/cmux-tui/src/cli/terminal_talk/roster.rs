//! Which terminals run an agent, from one daemon `session.snapshot`: the
//! harness (Claude Code, Codex, … from hook or plugin agent records, else a
//! program that reports OSC 7501 status), its state, its title and its
//! workspace. Pure: the caller reads the snapshot.

use std::collections::HashMap;

use serde_json::{Value, json};

use crate::cli::json_fields::JsonFields;

/// What a terminal agent does now, in the words the Chief uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(in crate::cli) enum AgentState {
    /// A permission dialog, a question or an error waits for an answer.
    WaitingForInput,
    Busy,
    Idle,
    /// The harness reported its session ended; a shell may run there now.
    Ended,
}

impl AgentState {
    pub(in crate::cli) fn as_str(self) -> &'static str {
        match self {
            Self::WaitingForInput => "waiting-for-input",
            Self::Busy => "busy",
            Self::Idle => "idle",
            Self::Ended => "ended",
        }
    }

    /// A daemon agent record's state (`agent.list`), or an OSC 7501
    /// program status state.
    pub(in crate::cli) fn from_record(state: &str) -> Option<Self> {
        Some(match state {
            "working" => Self::Busy,
            "blocked" | "input" | "waiting" | "attention" => Self::WaitingForInput,
            "idle" | "done" | "unknown" => Self::Idle,
            "ended" | "exited" => Self::Ended,
            _ => return None,
        })
    }
}

/// One terminal that runs an agent.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct AgentRow {
    pub terminal: String,
    pub harness: String,
    pub state: AgentState,
    pub title: Option<String>,
    pub workspace_id: Option<String>,
    pub workspace: Option<String>,
    pub cwd: Option<String>,
    /// When the state last changed, Unix ms, when a record says.
    pub updated_at_ms: Option<u64>,
    /// `hook`, `plugin`, `detected`, `socket` (daemon agent records) or
    /// `program_status` (OSC 7501).
    pub source: String,
}

impl AgentRow {
    pub(in crate::cli) fn to_json(&self, now_ms: u64) -> Value {
        json!({
            "terminal": self.terminal,
            "harness": self.harness,
            "state": self.state.as_str(),
            "title": self.title,
            "workspace_id": self.workspace_id,
            "workspace": self.workspace,
            "cwd": self.cwd,
            "updated_at_ms": self.updated_at_ms.map(|ms| ms.to_string()),
            "age_ms": self.updated_at_ms.map(|ms| now_ms.saturating_sub(ms).to_string()),
            "source": self.source,
        })
    }
}

fn number(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|text| !text.is_empty()).map(str::to_owned)
}

/// Each terminal's workspace `(id, name)`: terminal → tab → pane → screen
/// → workspace.
fn workspaces_of_terminals(snapshot: &Value) -> HashMap<String, (String, Option<String>)> {
    let list = |key: &str| snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default();
    let by_id = |key: &str, field: &str| -> HashMap<String, String> {
        list(key)
            .iter()
            .filter_map(|item| Some((text(&item["id"])?, text(&item[field])?)))
            .collect()
    };
    let pane_of_tab = by_id("tabs", "pane_id");
    let screen_of_pane = by_id("panes", "screen_id");
    let workspace_of_screen = by_id("screens", "workspace_id");
    let names: HashMap<String, Option<String>> = list("workspaces")
        .iter()
        .filter_map(|workspace| Some((text(&workspace["id"])?, text(&workspace["name"]))))
        .collect();
    list("terminals")
        .iter()
        .filter_map(|terminal| {
            let id = text(&terminal["id"])?;
            let tabs = std::iter::once(&terminal["tab_id"])
                .chain(terminal["tab_ids"].as_array().into_iter().flatten());
            let workspace = tabs.filter_map(Value::as_str).find_map(|tab| {
                let pane = pane_of_tab.get(tab)?;
                let screen = screen_of_pane.get(pane)?;
                workspace_of_screen.get(screen).cloned()
            })?;
            let name = names.get(&workspace).cloned().flatten();
            Some((id, (workspace, name)))
        })
        .collect()
}

/// The agent of one terminal record, from the daemon's agent records of
/// that terminal (newest first wins) or its OSC 7501 program status.
pub(in crate::cli) fn agent_of_terminal(terminal: &Value, agents: &[Value]) -> Option<AgentRow> {
    let id = text(&terminal["id"])?;
    let record = agents
        .iter()
        .filter(|agent| agent["terminal_id"] == id.as_str())
        .max_by_key(|agent| number(&agent["updated_at_ms"]).unwrap_or(0));
    let terminal_title = text(&terminal["title"]);
    if let Some(record) = record {
        let harness = text(record.field("extra").field("agent"))
            .or_else(|| text(&record["agent"]))
            .unwrap_or_else(|| "agent".to_owned());
        // Hooks say `claude`, the screen-detection plugin `claude-code`.
        let harness = if harness == "claude-code" { "claude".to_owned() } else { harness };
        // A daemon agent record is `done` when the harness session ended
        // (`agent.session.ended`); a status record's `done` is a turn's end.
        let state = match record["state"].as_str()? {
            "done" => AgentState::Ended,
            state => AgentState::from_record(state)?,
        };
        return Some(AgentRow {
            terminal: id,
            harness,
            state,
            title: text(&record["title"]).or(terminal_title),
            workspace_id: None,
            workspace: None,
            cwd: text(&record["cwd"]).or_else(|| text(&terminal["cwd"])),
            updated_at_ms: number(&record["updated_at_ms"]),
            source: text(&record["source"]).unwrap_or_else(|| "agent".to_owned()),
        });
    }
    let status = terminal.field("extra").field("program_status").as_array()?;
    let status = status
        .iter()
        .filter(|record| text(&record["app"]).is_some())
        .max_by_key(|record| number(&record["updated_at_ms"]).unwrap_or(0))?;
    Some(AgentRow {
        terminal: id,
        harness: text(&status["app"])?,
        state: status["state"].as_str().and_then(AgentState::from_record)?,
        title: text(&status["title"]).or(terminal_title),
        workspace_id: None,
        workspace: None,
        cwd: text(&terminal["cwd"]),
        updated_at_ms: number(&status["updated_at_ms"]),
        source: "program_status".to_owned(),
    })
}

/// Every terminal of `snapshot` that runs an agent: waiting for input
/// first, then busy, idle and ended, the most recently changed first.
pub(in crate::cli) fn agent_rows(snapshot: &Value) -> Vec<AgentRow> {
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let workspaces = workspaces_of_terminals(snapshot);
    let mut rows: Vec<AgentRow> = snapshot["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|terminal| terminal["lifecycle"] != "exited")
        .filter_map(|terminal| agent_of_terminal(terminal, agents))
        .map(|mut row| {
            if let Some((id, name)) = workspaces.get(&row.terminal) {
                row.workspace_id = Some(id.clone());
                row.workspace.clone_from(name);
            }
            row
        })
        .collect();
    rows.sort_by(|left, right| {
        left.state
            .cmp(&right.state)
            .then(right.updated_at_ms.cmp(&left.updated_at_ms))
            .then(left.terminal.cmp(&right.terminal))
    });
    rows
}

/// `42s`, `5m`, `3h`, `2d`.
pub(in crate::cli) fn age(ms: u64) -> String {
    let seconds = ms / 1_000;
    match seconds {
        0..60 => format!("{seconds}s"),
        60..3_600 => format!("{}m", seconds / 60),
        3_600..86_400 => format!("{}h", seconds / 3_600),
        _ => format!("{}d", seconds / 86_400),
    }
}

/// The human table of `terminal list --agents`.
pub(in crate::cli) fn table(rows: &[AgentRow], now_ms: u64) -> String {
    let cells: Vec<[String; 6]> = rows
        .iter()
        .map(|row| {
            [
                row.terminal.clone(),
                row.harness.clone(),
                row.state.as_str().to_owned(),
                row.updated_at_ms.map_or_else(|| "-".into(), |ms| age(now_ms.saturating_sub(ms))),
                row.workspace.clone().or_else(|| row.workspace_id.clone()).unwrap_or("-".into()),
                row.title.clone().unwrap_or_else(|| "-".into()),
            ]
        })
        .collect();
    let header = ["TERMINAL", "HARNESS", "STATE", "AGE", "WORKSPACE", "TITLE"];
    let mut widths = header.map(|cell| cell.chars().count());
    for row in &cells {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.chars().count()).min(48);
        }
    }
    let line = |row: &[String]| {
        let mut out = String::new();
        for (index, (cell, &width)) in row.iter().zip(&widths).enumerate() {
            let cell: String = cell.chars().take(width).collect();
            if index + 1 == row.len() {
                out.push_str(&cell);
            } else {
                let pad = width - cell.chars().count();
                out.push_str(&cell);
                out.push_str(&" ".repeat(pad + 2));
            }
        }
        out.trim_end().to_owned()
    };
    let mut lines = vec![line(&header.map(str::to_owned))];
    lines.extend(cells.iter().map(|row| line(row)));
    lines.join("\n")
}
