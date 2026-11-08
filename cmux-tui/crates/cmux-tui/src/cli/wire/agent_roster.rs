//! `agent list`: the `agent.list` rows ranked by who needs the person,
//! limited, counted by status, and joined with their terminals' titles and
//! folders. The daemon's fields are unchanged; the CLI adds `status`, the
//! one status vocabulary (`working`, `blocked`, `done`, `idle`, `unknown`;
//! `cmux_tui_core::AgentStatus`) that `terminal list --agents` and the TUI
//! show. `done` is a finished turn nobody has viewed (the terminal's unread
//! notification). The daemon's own `state` says `done` for a session that
//! ended, which has `status: null` and counts as `ended`; the printed
//! `state` is a deprecated alias of `status` (`ended` there), so a row has
//! one word (W5-Q). An ended agent of a closed terminal is left out unless
//! `--state ended` asks for it.

use std::borrow::Cow;
use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::io::BufReader;

use cmux_tui_core::AgentStatus;
use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use ratatui::buffer::CellWidth;
use serde_json::{Map, Value, json};

use super::super::command::{AgentRosterView, AgentSort, RequestPlan, ResponseView};
use super::{append_table_row, human_cell, sanitize_human_cell};

/// The status words in the order the counts line names them (the TUI's
/// attention order), then `ended` for a session that ended.
const STATUSES: [&str; 6] = ["blocked", "done", "working", "idle", "unknown", "ended"];

/// The status word of a row whose session ended (`status: null`).
const ENDED: &str = "ended";

/// The daemon `state` that `agent list --state <status>` asks for; the CLI
/// then keeps the rows whose `status` is that word. `done` and `idle` are
/// both the daemon's `idle` (the unread marker tells them apart), and
/// `ended` is the daemon's `done`.
pub(in crate::cli) fn daemon_state_for_status(status: &str) -> &str {
    match status {
        "done" | "idle" => "idle",
        ENDED => "done",
        other => other,
    }
}

/// The terminals with an unread notification: a turn finished there that
/// nobody has viewed (done-until-seen). `notifications` are
/// `notification.list` (or `session.snapshot`) rows.
pub(in crate::cli) fn unseen_terminals(notifications: &[Value]) -> HashSet<&str> {
    notifications
        .iter()
        .filter(|notification| notification["unread"] == true)
        .filter_map(|notification| notification["terminal_id"].as_str())
        .collect()
}

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
    let terminals =
        super::super::resolve::read(reader, ResourceOperation::TerminalList, route.clone())
            .ok()
            .and_then(|terminals| terminals.as_array().cloned())
            .unwrap_or_default();
    // Unread markers make an idle agent `done`. A refused read (an older
    // daemon) leaves every idle agent `idle`.
    let mut notification_params = route.clone();
    notification_params.insert("limit".into(), json!(NOTIFICATION_LIMIT));
    let notifications = super::super::resolve::read(
        reader,
        ResourceOperation::NotificationList,
        notification_params,
    )
    .ok()
    .and_then(|notifications| notifications.as_array().cloned())
    .unwrap_or_default();
    // A bare list is this session's roster: its terminal agents and the
    // acpmux chats that run in its workspaces (`--all-sessions` lists every
    // chat). A terminal selector intentionally keeps the daemon's existing
    // agent.list response and never starts or contacts acpmux.
    let result = if plan.params.get("terminal_id").is_none() {
        // A refused or failed workspace read lists no chat: the roster never
        // widens to other sessions' chats by accident.
        let workspaces =
            super::super::resolve::read(reader, ResourceOperation::WorkspaceList, route)
                .ok()
                .and_then(|workspaces| workspaces.as_array().cloned())
                .unwrap_or_default();
        let keys = workspace_keys(&workspaces);
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
        merge_sources(
            result,
            &sessions,
            &queued,
            plan.params.get("state").and_then(Value::as_str),
            Some(&keys),
        )
    } else {
        result
    };
    let tabs = super::super::resolve::read(reader, ResourceOperation::TabList, route_of(plan))
        .ok()
        .and_then(|tabs| tabs.as_array().cloned())
        .unwrap_or_default();
    let mut roster = shape(result, &terminals, &unseen_terminals(&notifications), view, unix_ms());
    add_names(&mut roster, &terminals, &tabs);
    roster
}

/// The session route of `plan`'s request, for the reads that join it.
fn route_of(plan: &RequestPlan) -> Map<String, Value> {
    plan.params.as_object().map(super::super::resolve::route).unwrap_or_default()
}

/// `notification.list`'s largest `limit`: a session keeps at most this many.
pub(in crate::cli) const NOTIFICATION_LIMIT: u32 = 256;

/// The keys of `workspaces` (`extra.key`) in one comparable form: lowercase,
/// without dashes, as the daemon's `agent_message_policy::workspace_key`.
fn workspace_keys(workspaces: &[Value]) -> HashSet<String> {
    workspaces
        .iter()
        .filter_map(|workspace| workspace.pointer("/extra/key")?.as_str())
        .map(workspace_key)
        .collect()
}

fn workspace_key(value: &str) -> String {
    value.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect()
}

/// Whether the acpmux chat `session` runs in one of `workspaces`: the
/// workspace it was created from (`createdBy.workspace`; the app names its
/// pane's workspace, an agent's chat its creator's). `None` takes every chat.
fn chat_in_scope(session: &Value, workspaces: Option<&HashSet<String>>) -> bool {
    workspaces.is_none_or(|keys| {
        session
            .pointer("/createdBy/workspace")
            .and_then(Value::as_str)
            .is_some_and(|workspace| keys.contains(&workspace_key(workspace)))
    })
}

/// Add the address and delivery metadata shared by terminal and acpmux rows.
/// Terminal rows are already filtered by the daemon; the state filter must be
/// applied to acpmux summaries here because they come from a second source.
/// `workspaces` limits the chats to those of this session ([`chat_in_scope`]).
fn merge_sources(
    rows: Value,
    sessions: &[Value],
    queued: &[Value],
    state: Option<&str>,
    workspaces: Option<&HashSet<String>>,
) -> Value {
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
        if !chat_in_scope(session, workspaces) {
            continue;
        }
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
            // acpmux's own word; `status` is the shared one ([`shape`]).
            "acp_status": session.get("status").cloned().unwrap_or(Value::Null),
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
/// `terminals` and `tabs` every session's terminals and tabs, and `notifications` every
/// session's notifications. Without a terminal selector every acpmux chat
/// on this machine joins them, whatever its workspace, filtered by
/// `params.state` as the daemons filtered their rows.
pub(in crate::cli) fn across(
    view: ResponseView,
    agents: Value,
    terminals: &[Value],
    tabs: &[Value],
    notifications: &[Value],
    params: &Value,
) -> Value {
    let ResponseView::AgentRoster(view) = view else { return agents };
    let agents = if params.get("terminal_id").is_none() {
        let sessions = super::super::agent_message::acp::sessions().unwrap_or_default();
        let state = params.get("state").and_then(Value::as_str);
        merge_sources(agents, &sessions, &[], state, None)
    } else {
        agents
    };
    let mut roster = shape(agents, terminals, &unseen_terminals(notifications), view, unix_ms());
    add_names(&mut roster, terminals, tabs);
    roster
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
/// every daemon field but `state`, which becomes an alias of its `status`
/// (`ended` for a session that ended), and gains `status` (its terminal is in `unseen` when
/// it has an unread notification), `age_ms` (since its `updated_at_ms`)
/// and, when its terminal is in `terminals`, that terminal's `title` and
/// `cwd`. `view.status` keeps only the agents with that status word;
/// without it, an ended agent of a terminal not in `terminals` is left out
/// (when `terminals` is not empty).
/// `counts` (by status word) covers every listed agent, before
/// `view.limit`.
pub(super) fn shape(
    rows: Value,
    terminals: &[Value],
    unseen: &HashSet<&str>,
    view: AgentRosterView,
    now_ms: u64,
) -> Value {
    let mut agents = match rows {
        Value::Array(rows) => rows,
        other => return other,
    };
    for agent in &mut agents {
        let status = status_of(agent, unseen).map(AgentStatus::as_str);
        if let Some(object) = agent.as_object_mut() {
            object.insert("status".into(), json!(status));
            // `state` is a deprecated alias of `status` (`ended` for a
            // session that ended): one word per agent (W5-Q).
            object.insert("state".into(), json!(status.unwrap_or(ENDED)));
        }
    }
    if let Some(wanted) = view.status {
        agents.retain(|agent| status_word(agent) == wanted);
    } else if !terminals.is_empty() {
        // An ended agent of a closed terminal is history, not an agent:
        // `--state ended` still lists it. With no terminals read (an older
        // daemon), nothing is left out.
        let open: HashSet<&str> = terminals
            .iter()
            .filter_map(|terminal| terminal.get("id").and_then(Value::as_str))
            .collect();
        agents.retain(|agent| {
            status_word(agent) != ENDED
                || agent
                    .get("terminal_id")
                    .and_then(Value::as_str)
                    .is_none_or(|terminal| open.contains(terminal))
        });
    }
    let mut counts = Map::new();
    for status in STATUSES {
        let count = agents.iter().filter(|agent| status_word(agent) == status).count();
        counts.insert(status.into(), json!(count));
    }
    counts.insert("total".into(), json!(agents.len()));
    match view.sort {
        AgentSort::NeedsMe => agents.sort_by_cached_key(|agent| {
            (needs_me_rank(agent), Reverse(updated_at(agent)), id_of(agent).to_owned())
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

/// Adds each terminal agent's `name` (W5-Q): its tab's name when that is an
/// agent name, the name `terminal list --agents` shows (roster_names.rs),
/// else null. An acpmux chat keeps its own `name`.
pub(super) fn add_names(result: &mut Value, terminals: &[Value], tabs: &[Value]) {
    let facts = super::super::terminal_talk::roster_names::facts(
        &json!({"tabs": tabs, "terminals": terminals}),
    );
    let Some(agents) = result.get_mut("agents").and_then(Value::as_array_mut) else { return };
    for agent in agents {
        let Some(terminal) = agent.get("terminal_id").and_then(Value::as_str) else { continue };
        let name = facts.get(terminal).and_then(|facts| facts.name()).map(str::to_owned);
        if let Some(object) = agent.as_object_mut() {
            object.insert("name".into(), json!(name));
        }
    }
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
    let mut output = STATUSES
        .iter()
        .filter(|status| !matches!(**status, "unknown" | ENDED) || count(status) != 0)
        .map(|status| format!("{} {status}", count(status)))
        .collect::<Vec<_>>()
        .join(" · ");
    if (agents.len() as u64) < total {
        output.push_str(&format!(" (showing {} of {total})", agents.len()));
    }
    output.push('\n');

    let sessions = agents.iter().any(|agent| agent.get("session").is_some());
    let names = agents.iter().any(|agent| agent.get("name").and_then(Value::as_str).is_some());
    let mut header = Vec::new();
    if sessions {
        header.push("SESSION");
    }
    if names {
        header.push("NAME");
    }
    header.extend(["STATE", "AGE", "AGENT", "TITLE", "FOLDER", "TERMINAL"]);
    let rows = agents
        .iter()
        .map(|agent| {
            let mut row = Vec::new();
            if sessions {
                row.push(cell(agent.get("session")));
            }
            if names {
                row.push(cell(agent.get("name").filter(|name| !name.is_null())));
            }
            row.push(status_word(agent).to_owned());
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

/// The attention order of the TUI and `terminal list --agents`: blocked
/// (waits on the person), done (a turn nobody has viewed), working, idle,
/// unknown, then sessions that ended.
fn needs_me_rank(agent: &Value) -> u8 {
    match agent.get("status").and_then(Value::as_str).and_then(AgentStatus::parse) {
        Some(status) => 4 - status.rank(),
        None => 5,
    }
}

/// The shared status of a listed agent: from the daemon's `state`, `done`
/// for an idle terminal agent in `unseen`. A state the CLI does not know (a
/// newer daemon's, or an `--all-sessions` error row) is `unknown`, so every
/// row is counted once; `None` for a session that ended.
fn status_of(agent: &Value, unseen: &HashSet<&str>) -> Option<AgentStatus> {
    let state = agent.get("state").and_then(Value::as_str).unwrap_or_default();
    let unseen = agent
        .get("terminal_id")
        .and_then(Value::as_str)
        .is_some_and(|terminal| unseen.contains(terminal));
    AgentStatus::from_state_str(state, unseen)
}

/// The row's status word ([`shape`] set it): `ended` for `status: null`.
fn status_word(agent: &Value) -> &str {
    agent.get("status").and_then(Value::as_str).unwrap_or(ENDED)
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
