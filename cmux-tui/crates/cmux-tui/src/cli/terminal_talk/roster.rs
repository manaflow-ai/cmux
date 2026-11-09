//! Which terminals run an agent, from one daemon `session.snapshot`: the
//! harness (Claude Code, Codex, … from hook or plugin agent records, else a
//! program that reports OSC 7501 status), its state, its title and its
//! workspace. Pure: the caller reads the snapshot.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::AgentStatus;
use serde_json::{Value, json};

/// What a terminal agent does now, in the older CLI words (`state` in the
/// JSON rows, `send` receipts). The shared vocabulary is
/// [`AgentStatus`] (`status` in the JSON rows, the table's STATE column).
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
    /// The shared status (`working`, `blocked`, `done` for a finished turn
    /// nobody has viewed, `idle`, `unknown`); `None` for an ended session.
    pub status: Option<AgentStatus>,
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
    /// The table's STATE word: the shared status, `ended` for an ended
    /// session.
    pub(in crate::cli) fn status_word(&self) -> &'static str {
        self.status.map_or("ended", AgentStatus::as_str)
    }

    /// Attention order: blocked, done, working, idle, unknown, then ended.
    fn attention(&self) -> u8 {
        self.status.map_or(0, |status| status.rank() + 1)
    }

    pub(in crate::cli) fn to_json(&self, now_ms: u64) -> Value {
        json!({
            "terminal": self.terminal,
            "harness": self.harness,
            "state": self.state.as_str(),
            "status": self.status.map(AgentStatus::as_str),
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

/// The terminals with an unread notification: a turn finished there that
/// nobody has viewed (done-until-seen). Reading the snapshot clears nothing.
fn unseen_terminals(snapshot: &Value) -> HashSet<&str> {
    let notifications = snapshot["notifications"].as_array().map(Vec::as_slice);
    super::super::wire::unseen_terminals(notifications.unwrap_or_default())
}

/// The shared status of a status word: a daemon agent record's state or an
/// OSC 7501 program status state. `done` there is a finished turn
/// (program status) and `idle` an agent at its prompt; either one is `done`
/// while its terminal is `unseen`.
fn status_of(word: &str, unseen: bool) -> Option<AgentStatus> {
    match AgentStatus::parse(word)? {
        AgentStatus::Done | AgentStatus::Idle if unseen => Some(AgentStatus::Done),
        AgentStatus::Done => Some(AgentStatus::Idle),
        status => Some(status),
    }
}

/// Whether an agent record is the agent's own report (its hooks, or a
/// report over the socket), not a guess from the screen (the screen-detection
/// plugin, `plugin`, or the older `detected`). Only an own report says when
/// an agent accepts a message or took one (W5-R: a screen record said idle
/// before Claude Code had started).
pub(in crate::cli) fn reported_by_agent(record: &Value) -> bool {
    !matches!(record.get("source").and_then(Value::as_str), Some("plugin" | "detected"))
}

/// Whether the hooks cmux installs for `harness` (any alias,
/// cmux-tui-hooks `provider_events`) include one that `kind` matches, a
/// cmux-tui-core `agent_hook_event_*` predicate. A harness with no such hook
/// never reports that event, so no wait may depend on it.
pub(in crate::cli) fn harness_hooks_report(harness: &str, kind: fn(&str, &str) -> bool) -> bool {
    let harness = super::super::agent_vocabulary::harness_name(harness);
    cmux_tui_hooks::provider_events(&harness)
        .is_some_and(|events| events.iter().any(|event| kind(&harness, event)))
}

/// Whether a screen guess of `idle` must wait for the agent's own report:
/// `harness`'s hooks report a session start, and none has come for this
/// terminal yet (`session_id`, the harness session id its hooks leave on the
/// terminal, `extra.agent_session_id`). Claude Code draws its input box
/// seconds before its `SessionStart`, and a prompt typed then is lost
/// (W5-T real-build check). `agent start`, `terminal wait --until ready`
/// and `terminal wait --any|--all` share this rule.
pub(in crate::cli) fn session_report_pending(harness: &str, session_id: Option<&str>) -> bool {
    session_id.is_none_or(str::is_empty)
        && harness_hooks_report(harness, cmux_tui_core::agent_hook_event_starts_session)
}

/// The agent of one terminal record, from the daemon's agent records of
/// that terminal (newest first wins) or its OSC 7501 program status.
/// `unseen` is whether the terminal carries an unread notification.
pub(in crate::cli) fn agent_of_terminal(
    terminal: &Value,
    agents: &[Value],
    unseen: bool,
) -> Option<AgentRow> {
    let id = text(&terminal["id"])?;
    let record = agents
        .iter()
        .filter(|agent| agent["terminal_id"] == id.as_str())
        .max_by_key(|agent| number(&agent["updated_at_ms"]).unwrap_or(0));
    let terminal_title = text(&terminal["title"]);
    if let Some(record) = record {
        let harness = text(&record["extra"]["agent"])
            .or_else(|| text(&record["agent"]))
            .unwrap_or_else(|| "agent".to_owned());
        // Hooks say `claude`, the screen-detection plugin `claude-code`.
        let harness = if harness == "claude-code" { "claude".to_owned() } else { harness };
        // A daemon agent record is `done` when the harness session ended
        // (`agent.session.ended`); a status record's `done` is a turn's end.
        let word = record["state"].as_str()?;
        let (state, status) = match word {
            "done" => (AgentState::Ended, None),
            word => (AgentState::from_record(word)?, Some(status_of(word, unseen)?)),
        };
        return Some(AgentRow {
            terminal: id,
            harness,
            state,
            status,
            title: text(&record["title"]).or(terminal_title),
            workspace_id: None,
            workspace: None,
            cwd: text(&record["cwd"]).or_else(|| text(&terminal["cwd"])),
            updated_at_ms: number(&record["updated_at_ms"]),
            source: text(&record["source"]).unwrap_or_else(|| "agent".to_owned()),
        });
    }
    let status = terminal["extra"]["program_status"].as_array()?;
    let status = status
        .iter()
        .filter(|record| text(&record["app"]).is_some())
        .max_by_key(|record| number(&record["updated_at_ms"]).unwrap_or(0))?;
    let word = status["state"].as_str()?;
    let state = AgentState::from_record(word)?;
    Some(AgentRow {
        terminal: id,
        harness: text(&status["app"])?,
        state,
        status: if state == AgentState::Ended { None } else { status_of(word, unseen) },
        title: text(&status["title"]).or(terminal_title),
        workspace_id: None,
        workspace: None,
        cwd: text(&terminal["cwd"]),
        updated_at_ms: number(&status["updated_at_ms"]),
        source: "program_status".to_owned(),
    })
}

/// Every terminal of `snapshot` that runs an agent: blocked first, then
/// done, working, idle, unknown and ended, the most recently changed first.
pub(in crate::cli) fn agent_rows(snapshot: &Value) -> Vec<AgentRow> {
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let workspaces = workspaces_of_terminals(snapshot);
    let unseen = unseen_terminals(snapshot);
    let mut rows: Vec<AgentRow> = snapshot["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|terminal| terminal["lifecycle"] != "exited")
        .filter_map(|terminal| {
            let unseen = terminal["id"].as_str().is_some_and(|id| unseen.contains(id));
            agent_of_terminal(terminal, agents, unseen)
        })
        .map(|mut row| {
            if let Some((id, name)) = workspaces.get(&row.terminal) {
                row.workspace_id = Some(id.clone());
                row.workspace.clone_from(name);
            }
            row
        })
        .collect();
    rows.sort_by(|left, right| {
        right
            .attention()
            .cmp(&left.attention())
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
                row.status_word().to_owned(),
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
        for (index, cell) in row.iter().enumerate() {
            let cell: String = cell.chars().take(widths[index]).collect();
            if index + 1 == row.len() {
                out.push_str(&cell);
            } else {
                let pad = widths[index] - cell.chars().count();
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
