//! `agents dialog list` for the terminal agents of a session (W6-C, bench
//! round 5 orchestration row 4): the app's feed lists the dialogs of its
//! agent chats only, and a cmux-tui session has no app at all, so the list
//! failed with `app.not_found` there. The daemon's snapshot says which
//! terminal agents are blocked (the word every agent list shows); each one's
//! screen gives its dialog (agent_start/dialog_options.rs `blocked_dialog`).

use serde_json::{Value, json};

use super::super::Surface;
use super::super::agent_start::dialog_options;
use super::super::command::{self, CommandPlan, RequestPlan};
use super::super::mcp::Backend;
use super::super::terminal_talk::roster::AgentState;
use super::super::terminal_talk::roster_names;

/// The blocked terminal agents of the session's `snapshot`, each
/// `{terminal, name, harness, tab_id, pane_id, dialog}`, blocked first as
/// the lists sort them. A screen that cannot be read leaves that dialog's
/// options out.
pub(super) fn list<B: Backend>(backend: &B, session: Option<&str>, snapshot: &Value) -> Vec<Value> {
    let facts = roster_names::facts(snapshot);
    let agents = snapshot["agents"].as_array().map(Vec::as_slice).unwrap_or_default();
    let terminals = snapshot["terminals"].as_array().map(Vec::as_slice).unwrap_or_default();
    roster_names::rows(snapshot)
        .into_iter()
        .filter(|row| row.state == AgentState::Blocked)
        .filter_map(|row| {
            let terminal = terminals.iter().find(|terminal| terminal["id"] == *row.terminal)?;
            let screen = screen_plan(&row.terminal)
                .and_then(|plan| backend.resource(session, plan, &[]).ok())
                .and_then(|read| read.get("text").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_default();
            let dialog = dialog_options::blocked_dialog(terminal, agents, &screen)?;
            let known = facts.get(&row.terminal).cloned().unwrap_or_default();
            Some(json!({
                "terminal": row.terminal,
                "name": known.name(),
                "harness": row.harness,
                "tab_id": known.tab_id,
                "pane_id": known.pane_id,
                "dialog": dialog,
            }))
        })
        .collect()
}

/// `terminal <id> screen read` as a daemon request.
fn screen_plan(terminal: &str) -> Option<RequestPlan> {
    let words = ["terminal", terminal, "screen", "read"].map(str::to_owned);
    match command::parse(&words, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => Some(*plan),
        _ => None,
    }
}
