//! `cmux agent list` without `--terminal` (cmux #16417): every agent cmux
//! can message, in one list. Terminal agents come from `agent.list` and keep
//! its fields; acpmux sessions come from the running acpmux daemon. Each row
//! adds `address` (what `cmux agent message` takes), `kind` and
//! `queued_messages`.

use std::collections::HashMap;
use std::io::Write;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Value, json};

use super::agent_message::{Connection, acp};
use super::resolve::Failure;
use super::{GlobalArgs, OutputMode};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct AgentListPlan {
    pub state: Option<String>,
}

pub(super) fn run(global: GlobalArgs, plan: AgentListPlan) -> i32 {
    let output = global.output;
    let rows = match list(&global, &plan) {
        Ok(rows) => rows,
        Err(failure) => return failure.report(output),
    };
    let printed = match output {
        OutputMode::Human => text(&rows),
        OutputMode::Quiet => String::new(),
        OutputMode::Json => format!("{}\n", Value::Array(rows)),
        OutputMode::JsonLines => rows.iter().map(|row| format!("{row}\n")).collect(),
    };
    let mut stdout = std::io::stdout().lock();
    match stdout.write_all(printed.as_bytes()).and_then(|()| stdout.flush()) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

fn list(global: &GlobalArgs, plan: &AgentListPlan) -> Result<Vec<Value>, Failure> {
    let mut connection = Connection::open(global)?;
    let terminal_agents = connection.read(ResourceOperation::AgentList, json!({}))?;
    // The counts are extra: a daemon without agent messages lists agents
    // with none queued. They cover the newest 1000 messages still queued.
    let queued = connection
        .read(ResourceOperation::AgentMessageList, json!({"state": "queued", "limit": 1000}))
        .unwrap_or(Value::Null);
    Ok(rows(
        terminal_agents.as_array().map(Vec::as_slice).unwrap_or_default(),
        &acp::sessions(),
        &queued_counts(queued.as_array().map(Vec::as_slice).unwrap_or_default()),
        plan.state.as_deref(),
    ))
}

/// Queued receipts per recipient address.
fn queued_counts(messages: &[Value]) -> HashMap<String, u64> {
    let mut counts = HashMap::new();
    for message in messages {
        for delivery in message["deliveries"].as_array().into_iter().flatten() {
            if delivery["state"] == "queued"
                && let Some(recipient) = delivery["recipient"].as_str()
            {
                *counts.entry(recipient.to_owned()).or_insert(0) += 1;
            }
        }
    }
    counts
}

/// The agent states of `agent.list` for an acpmux session status.
fn acp_state(status: &str) -> &'static str {
    match status {
        "running" => "working",
        "waiting" => "blocked",
        "idle" | "ready" => "idle",
        "closed" => "done",
        _ => "unknown",
    }
}

fn rows(
    terminal_agents: &[Value],
    acp_sessions: &[Value],
    queued: &HashMap<String, u64>,
    state: Option<&str>,
) -> Vec<Value> {
    let count = |address: &str| queued.get(address).copied().unwrap_or(0);
    let mut rows = Vec::new();
    for agent in terminal_agents {
        let Some(terminal) = agent["terminal_id"].as_str() else { continue };
        let mut row = agent.clone();
        row["address"] = json!(terminal);
        row["kind"] = json!("terminal");
        row["queued_messages"] = json!(count(terminal));
        rows.push(row);
    }
    for session in acp_sessions {
        let Some(id) = session["sessionId"].as_str() else { continue };
        let address = format!("acp:{id}");
        rows.push(json!({
            "address": address,
            "kind": "acp",
            "name": session["name"],
            "agent": session["harness"],
            "state": acp_state(session["status"].as_str().unwrap_or_default()),
            "status": session["status"],
            "cwd": session["cwd"],
            "model": session["model"],
            "agent_session_id": session["agentSessionId"],
            "updated_at_ms": session["updatedAt"],
            "queued_messages": count(&address),
        }));
    }
    if let Some(state) = state {
        rows.retain(|row| row["state"] == state);
    }
    rows
}

fn text(rows: &[Value]) -> String {
    if rows.is_empty() {
        return "No agents.\n".to_owned();
    }
    let mut out = String::new();
    for row in rows {
        let address = row["address"].as_str().unwrap_or_default();
        let agent =
            row["agent"].as_str().or_else(|| row["extra"]["agent"].as_str()).unwrap_or("agent");
        let state = row["state"].as_str().unwrap_or("unknown");
        let name = row["name"].as_str().map(|name| format!("  {name}")).unwrap_or_default();
        let queued = match row["queued_messages"].as_u64().unwrap_or(0) {
            0 => String::new(),
            1 => "  1 queued message".to_owned(),
            n => format!("  {n} queued messages"),
        };
        out.push_str(&format!("{address}  {agent}  {state}{name}{queued}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const TERM: &str = "term_0123456789abcdef0123456789abcdef";

    #[test]
    fn terminal_agents_keep_their_fields_and_acpmux_sessions_join_them() {
        let terminal = json!({
            "id": "agent_1", "terminal_id": TERM, "state": "working",
            "extra": {"agent": "codex", "agent_session_id": "thr"},
        });
        let session = json!({
            "sessionId": "s1", "name": "review", "harness": "claude", "status": "waiting",
            "cwd": "/repo", "agentSessionId": "c1", "updatedAt": 5,
        });
        let queued = HashMap::from([(TERM.to_owned(), 2), ("acp:s1".to_owned(), 1)]);
        let rows = rows(std::slice::from_ref(&terminal), &[session], &queued, None);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], "agent_1");
        assert_eq!(rows[0]["extra"], terminal["extra"]);
        assert_eq!(rows[0]["address"], TERM);
        assert_eq!(rows[0]["kind"], "terminal");
        assert_eq!(rows[0]["queued_messages"], 2);
        assert_eq!(rows[1]["address"], "acp:s1");
        assert_eq!(rows[1]["kind"], "acp");
        assert_eq!(rows[1]["agent"], "claude");
        assert_eq!(rows[1]["state"], "blocked");
        assert_eq!(rows[1]["queued_messages"], 1);
        assert_eq!(
            text(&rows),
            format!(
                "{TERM}  codex  working  2 queued messages\nacp:s1  claude  blocked  review  1 queued message\n"
            )
        );
    }

    #[test]
    fn the_state_filter_applies_to_both_kinds() {
        let terminal = json!({"terminal_id": TERM, "state": "idle"});
        let sessions = [
            json!({"sessionId": "s1", "status": "ready"}),
            json!({"sessionId": "s2", "status": "running"}),
        ];
        let idle = rows(&[terminal], &sessions, &HashMap::new(), Some("idle"));
        let addresses: Vec<&str> = idle.iter().filter_map(|row| row["address"].as_str()).collect();
        assert_eq!(addresses, [TERM, "acp:s1"]);
        assert_eq!(text(&[]), "No agents.\n");
    }

    #[test]
    fn queued_receipts_are_counted_per_recipient() {
        let counts = queued_counts(&[
            json!({"deliveries": [
                {"recipient": TERM, "state": "queued"},
                {"recipient": "acp:s1", "state": "delivered"},
            ]}),
            json!({"deliveries": [{"recipient": TERM, "state": "queued"}]}),
        ]);
        assert_eq!(counts.get(TERM), Some(&2));
        assert_eq!(counts.get("acp:s1"), None);
    }

    #[test]
    fn acpmux_statuses_map_to_agent_states() {
        for (status, state) in [
            ("running", "working"),
            ("waiting", "blocked"),
            ("idle", "idle"),
            ("ready", "idle"),
            ("closed", "done"),
            ("disconnected", "unknown"),
        ] {
            assert_eq!(acp_state(status), state);
        }
    }
}
