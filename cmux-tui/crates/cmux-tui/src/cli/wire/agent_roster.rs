//! `agent list`: the `agent.list` rows ranked by who needs the person,
//! limited, counted by state, and joined with their terminals' titles and
//! folders. The daemon's rows are unchanged; only the CLI shapes them.

use std::borrow::Cow;
use std::cmp::Reverse;
use std::collections::HashMap;
use std::io::BufReader;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use ratatui::buffer::CellWidth;
use serde_json::{Map, Value, json};

use super::super::command::{AgentRosterView, AgentSort, RequestPlan, ResponseView};
use super::{append_table_row, human_cell, sanitize_human_cell};

/// The states in the order the counts line names them.
const STATES: [&str; 5] = ["blocked", "working", "idle", "done", "unknown"];

/// The widest TITLE cell, in characters, ellipsis included.
const MAX_TITLE: usize = 48;

/// `agent list`: the rows ranked, counted and joined with the session's
/// terminals, read on the same connection. Without that read (an older
/// daemon or a refused read) the rows have no title or folder. Any other
/// command's result is returned as it is.
pub(super) fn with_terminals(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    plan: &RequestPlan,
    result: Value,
) -> Value {
    let ResponseView::AgentRoster(view) = plan.view else { return result };
    let route = plan.params.as_object().map(super::super::resolve::route).unwrap_or_default();
    let terminals = super::super::resolve::read(reader, ResourceOperation::TerminalList, route)
        .ok()
        .and_then(|terminals| terminals.as_array().cloned())
        .unwrap_or_default();
    // A bare list is the roster of everything `cmux agent message` can
    // reach. A terminal selector intentionally keeps the daemon's existing
    // agent.list response and never starts or contacts acpmux.
    let result = if plan.params.get("terminal_id").is_none() {
        let mut queued_params =
            plan.params.as_object().map(super::super::resolve::route).unwrap_or_default();
        queued_params.insert("state".into(), json!("queued"));
        queued_params.insert("limit".into(), json!(1000));
        let queued =
            super::super::resolve::read(reader, ResourceOperation::AgentMessageList, queued_params)
                .ok()
                .and_then(|messages| messages.as_array().cloned())
                .unwrap_or_default();
        let sessions = super::super::agent_message::acp::sessions().unwrap_or_default();
        merge_sources(result, &sessions, &queued, plan.params.get("state").and_then(Value::as_str))
    } else {
        result
    };
    shape(result, &terminals, view, unix_ms())
}

/// Add the address and delivery metadata shared by terminal and acpmux rows.
/// Terminal rows are already filtered by the daemon; the state filter must be
/// applied to acpmux summaries here because they come from a second source.
fn merge_sources(rows: Value, sessions: &[Value], queued: &[Value], state: Option<&str>) -> Value {
    let mut rows = match rows {
        Value::Array(rows) => rows,
        other => return other,
    };
    let queued = queued_counts(queued);
    for row in &mut rows {
        let Some(address) = row.get("terminal_id").and_then(Value::as_str).map(str::to_owned)
        else {
            continue;
        };
        if let Some(object) = row.as_object_mut() {
            object.insert("address".into(), Value::String(address.clone()));
            object.insert("kind".into(), json!("terminal"));
            object.insert(
                "queued_messages".into(),
                json!(queued.get(&address).copied().unwrap_or(0)),
            );
        }
    }
    for session in sessions {
        let Some(id) = session.get("sessionId").and_then(Value::as_str) else { continue };
        let acp_state =
            acp_state(session.get("status").and_then(Value::as_str).unwrap_or_default());
        if state.is_some_and(|wanted| wanted != acp_state) {
            continue;
        }
        let address = format!("acp:{id}");
        rows.push(json!({
            "address": address,
            "kind": "acp",
            "name": session.get("name").cloned().unwrap_or(Value::String(id.to_owned())),
            "agent": session.get("harness").cloned().unwrap_or(Value::Null),
            "state": acp_state,
            "status": session.get("status").cloned().unwrap_or(Value::Null),
            "cwd": session.get("cwd").cloned().unwrap_or(Value::Null),
            "model": session.get("model").cloned().unwrap_or(Value::Null),
            "agent_session_id": session.get("agentSessionId").cloned().unwrap_or(Value::Null),
            "updated_at_ms": session.get("updatedAt").cloned().unwrap_or(json!(0)),
            "queued_messages": queued.get(&address).copied().unwrap_or(0),
        }));
    }
    Value::Array(rows)
}

fn queued_counts(messages: &[Value]) -> HashMap<String, u64> {
    let mut counts = HashMap::new();
    for message in messages {
        for delivery in message.get("deliveries").and_then(Value::as_array).into_iter().flatten() {
            if delivery.get("state").and_then(Value::as_str) == Some("queued")
                && let Some(recipient) = delivery.get("recipient").and_then(Value::as_str)
            {
                *counts.entry(recipient.to_owned()).or_insert(0) += 1;
            }
        }
    }
    counts
}

fn acp_state(status: &str) -> &'static str {
    match status {
        "running" => "working",
        "waiting" => "blocked",
        "idle" | "ready" => "idle",
        "closed" => "done",
        _ => "unknown",
    }
}

/// [`with_terminals`] for `--all-sessions`: `agents` is the joined rows,
/// `terminals` every session's terminals.
pub(in crate::cli) fn across(view: ResponseView, agents: Value, terminals: &[Value]) -> Value {
    match view {
        ResponseView::AgentRoster(view) => shape(agents, terminals, view, unix_ms()),
        _ => agents,
    }
}

/// What a machine-readable mode prints. `--json` stays the bare ranked
/// array that scripts already read; `--json --counts` is the whole
/// `{"agents","counts"}` roster. `--jsonl` prints one agent per line.
pub(super) fn machine_view<'a>(
    plan: &RequestPlan,
    result: &'a Value,
    output: super::OutputMode,
) -> Cow<'a, Value> {
    match (plan.view, result.get("agents")) {
        (ResponseView::AgentRoster(view), Some(_))
            if view.counts && output == super::OutputMode::Json =>
        {
            Cow::Borrowed(result)
        }
        (ResponseView::AgentRoster(_), Some(agents)) => Cow::Borrowed(agents),
        _ => Cow::Borrowed(result),
    }
}

/// The human roster for `agent list`, `None` for any other command.
pub(super) fn human_view(plan: &RequestPlan, result: &Value) -> Option<Cow<'static, Value>> {
    if !matches!(plan.view, ResponseView::AgentRoster(_)) || result.get("agents").is_none() {
        return None;
    }
    let home = std::env::var("HOME").ok();
    Some(Cow::Owned(Value::String(human(result, home.as_deref()))))
}

fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// The printed roster: `{"agents":[...],"counts":{...}}`. Each agent keeps
/// every daemon field and gains `age_ms` (since its `updated_at_ms`) and,
/// when its terminal is in `terminals`, that terminal's `title` and `cwd`.
/// `counts` covers every listed agent, before `view.limit`.
pub(super) fn shape(rows: Value, terminals: &[Value], view: AgentRosterView, now_ms: u64) -> Value {
    let mut agents = match rows {
        Value::Array(rows) => rows,
        other => return other,
    };
    let mut counts = Map::new();
    for state in STATES {
        let count = agents.iter().filter(|agent| state_of(agent) == state).count();
        counts.insert(state.into(), json!(count));
    }
    counts.insert("total".into(), json!(agents.len()));
    match view.sort {
        AgentSort::NeedsMe => agents.sort_by_cached_key(|agent| {
            (needs_me_rank(state_of(agent)), Reverse(updated_at(agent)), id_of(agent).to_owned())
        }),
        AgentSort::Recent => {
            agents
                .sort_by_cached_key(|agent| (Reverse(updated_at(agent)), id_of(agent).to_owned()));
        }
        AgentSort::None => {}
    }
    if let Some(limit) = view.limit {
        agents.truncate(limit);
    }
    let terminals: HashMap<&str, &Value> = terminals
        .iter()
        .filter_map(|terminal| Some((terminal.get("id")?.as_str()?, terminal)))
        .collect();
    for agent in &mut agents {
        let age_ms = now_ms.saturating_sub(updated_at(agent));
        let terminal = agent
            .get("terminal_id")
            .and_then(Value::as_str)
            .and_then(|id| terminals.get(id).copied());
        let Some(object) = agent.as_object_mut() else { continue };
        object.insert("age_ms".into(), json!(age_ms));
        for field in ["title", "cwd"] {
            if let Some(value) = terminal
                .and_then(|terminal| terminal.get(field))
                .filter(|v| v.as_str().is_some_and(|s| !s.is_empty()))
            {
                object.insert(field.into(), value.clone());
            }
        }
    }
    json!({"agents": agents, "counts": counts})
}

/// The human roster: a counts line, then one row per agent. `home` is
/// shown as `~` in FOLDER.
pub(super) fn human(result: &Value, home: Option<&str>) -> String {
    let agents = result["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let count = |key: &str| result["counts"][key].as_u64().unwrap_or(0);
    let total = count("total");
    if total == 0 {
        return "No agents.\n".to_owned();
    }
    let mut output = STATES
        .iter()
        .filter(|state| **state != "unknown" || count(state) != 0)
        .map(|state| format!("{} {state}", count(state)))
        .collect::<Vec<_>>()
        .join(" · ");
    if (agents.len() as u64) < total {
        output.push_str(&format!(" (showing {} of {total})", agents.len()));
    }
    output.push('\n');

    let sessions = agents.iter().any(|agent| agent.get("session").is_some());
    let mut header = Vec::new();
    if sessions {
        header.push("SESSION");
    }
    header.extend(["STATE", "AGE", "AGENT", "TITLE", "FOLDER", "TERMINAL"]);
    let rows = agents
        .iter()
        .map(|agent| {
            let mut row = Vec::new();
            if sessions {
                row.push(cell(agent.get("session")));
            }
            row.push(cell(agent.get("state")));
            row.push(agent["age_ms"].as_u64().map_or_else(|| "-".to_owned(), age_text));
            row.push(agent_name(agent));
            row.push(truncate(
                agent
                    .get("title")
                    .or_else(|| agent.get("name"))
                    .map_or_else(|| "-".to_owned(), human_cell),
                MAX_TITLE,
            ));
            row.push(agent["cwd"].as_str().map_or_else(|| "-".to_owned(), |cwd| folder(cwd, home)));
            row.push(cell(agent.get("terminal_id").or_else(|| agent.get("address"))));
            row
        })
        .collect::<Vec<_>>();
    let header = header.into_iter().map(str::to_owned).collect::<Vec<_>>();
    let widths = (0..header.len())
        .map(|index| {
            std::iter::once(&header)
                .chain(&rows)
                .map(|row| usize::from(row[index].cell_width()))
                .max()
                .unwrap_or(0)
        })
        .collect::<Vec<_>>();
    append_table_row(&header, &widths, &mut output);
    for row in &rows {
        append_table_row(row, &widths, &mut output);
    }
    output
}

/// A compact age, one unit: `45s`, `12m`, `3h`, `2d`.
fn age_text(age_ms: u64) -> String {
    let seconds = age_ms / 1_000;
    match seconds {
        0..60 => format!("{seconds}s"),
        60..3_600 => format!("{}m", seconds / 60),
        3_600..86_400 => format!("{}h", seconds / 3_600),
        _ => format!("{}d", seconds / 86_400),
    }
}

/// Blocked agents wait on the person; working ones may soon; idle and done
/// ones have finished their turn.
fn needs_me_rank(state: &str) -> u8 {
    match state {
        "blocked" => 0,
        "working" => 1,
        "idle" | "done" => 2,
        _ => 3,
    }
}

/// The agent's state, `unknown` for a state the CLI does not know (a newer
/// daemon's, or an `--all-sessions` error row), so every row is counted once.
fn state_of(agent: &Value) -> &str {
    agent
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| STATES.contains(state))
        .unwrap_or("unknown")
}

fn id_of(agent: &Value) -> &str {
    agent
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| agent.get("address").and_then(Value::as_str))
        .unwrap_or_default()
}

fn agent_name(agent: &Value) -> String {
    agent
        .pointer("/extra/agent")
        .and_then(Value::as_str)
        .or_else(|| agent.get("agent").and_then(Value::as_str))
        .map_or_else(|| "-".to_owned(), str::to_owned)
}

/// `updated_at_ms` is a decimal string on the wire.
fn updated_at(agent: &Value) -> u64 {
    match agent.get("updated_at_ms") {
        Some(Value::String(value)) => value.parse().unwrap_or(0),
        Some(Value::Number(value)) => value.as_u64().unwrap_or(0),
        _ => 0,
    }
}

fn cell(value: Option<&Value>) -> String {
    value.map_or_else(|| "-".to_owned(), human_cell)
}

fn folder(cwd: &str, home: Option<&str>) -> String {
    let shown = match home.filter(|home| !home.is_empty() && *home != "/") {
        Some(home) if cwd == home => "~".to_owned(),
        Some(home) => match cwd.strip_prefix(home).filter(|rest| rest.starts_with('/')) {
            Some(rest) => format!("~{rest}"),
            None => cwd.to_owned(),
        },
        None => cwd.to_owned(),
    };
    sanitize_human_cell(&shown)
}

fn truncate(cell: String, max: usize) -> String {
    if cell.chars().count() <= max {
        return cell;
    }
    let mut short = cell.chars().take(max - 1).collect::<String>();
    short.push('…');
    short
}

#[cfg(test)]
mod tests;
