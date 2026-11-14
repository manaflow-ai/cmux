//! Part of `Hub`; see `hub/mod.rs`. What a running turn does right now, one
//! line, for a parent session that reports its sub-sessions' progress
//! (`get_session`'s `doing`) and for any client's summary (`turn.activity`,
//! `turn.planStep`).
//!
//! The turn's latest tool call titles it ("Run cargo test -p acpmux"); its
//! plan's entry in progress is the step around it. Both live on the running
//! turn only (`TurnInfo`) and end with it, so a finished turn never reads as
//! still doing its last tool. Each is kept masked before its cut
//! (`secret_scan`): a tool call's title is often a command with its
//! arguments, and every view of the summary shows it (the app's sidebar row,
//! `acpmux ls --fields turn.activity`, the sub-session tools), so a secret in
//! it, or across the cut, leaves no head anywhere.
//!
//! The turn also keeps the ids of its tool calls in flight (started, not yet
//! completed or failed): a turn with none, whose model has been quiet for
//! `stalledTurnMs`, has stalled (`stalled_since`). A long build in one tool
//! call is in flight, so it never stalls. Those in flight that run a known build
//! or test (`host_load::heavy_of_tool`) say so: the machine's load sample reads
//! them from `daemon status` (`host_pressure.heavy`) instead of scanning processes.

use super::*;

/// Longest activity or plan step kept, in characters.
const ACTIVITY_CHARS: usize = 160;
/// Most tool-call ids a turn keeps in flight; calls past it are counted (`open_past_cap`).
const MAX_OPEN_TOOLS: usize = 256;

/// What a running turn does now (`TurnInfo::doing`), one line each.
#[derive(Debug, Clone, Default)]
pub struct TurnActivity {
    /// Its latest tool call's title, masked. None until it calls one.
    pub activity: Option<String>,
    /// Its plan's entry in progress, masked.
    pub plan_step: Option<String>,
    /// The ids of its tool calls in flight.
    pub open_tools: std::collections::BTreeSet<String>,
    /// How many tool calls started past [`MAX_OPEN_TOOLS`] are in flight, by count, not id: the
    /// end of a call whose id isn't kept ends one of them.
    pub open_past_cap: usize,
    /// The tool calls of [`Self::open_tools`] that run a known build or test, by id.
    pub open_heavy: std::collections::BTreeMap<String, crate::host_load::Heavy>,
}

impl TurnActivity {
    /// Notes a `tool_call` or `tool_call_update` in `update`: in flight until it completes or fails.
    fn note_tool(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return;
        }
        let status = update.get("status").and_then(Value::as_str);
        if matches!(status, Some("completed" | "failed")) {
            self.open_heavy.remove(id);
            if !self.open_tools.remove(id) {
                self.open_past_cap = self.open_past_cap.saturating_sub(1);
            }
            return;
        }
        self.note_open(id, kind, status);
        // Its command may come with the call or in a later update (a call named early).
        if self.open_tools.contains(id)
            && let Some(heavy) = crate::host_load::heavy_of_tool(update)
        {
            self.open_heavy.insert(id.to_owned(), heavy);
        }
    }

    /// A new call, or an update that says it runs, is in flight; an update with no status changes
    /// nothing.
    fn note_open(&mut self, id: &str, kind: Option<&str>, status: Option<&str>) {
        if status.is_none() && kind != Some("tool_call") || self.open_tools.contains(id) {
            return;
        }
        if self.open_past_cap == 0 && self.open_tools.len() < MAX_OPEN_TOOLS {
            self.open_tools.insert(id.to_owned());
        } else if kind == Some("tool_call") {
            // Past the cap only a new call counts: an update may be for a call already counted.
            self.open_past_cap += 1;
        }
    }

    /// Notes `update`'s activity and tool calls (`Hub::note_activity`; an adopted host's turn,
    /// rebuilt from the log, `hosts.rs`).
    pub(super) fn note(&mut self, update: &Value) {
        if matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) {
            self.note_tool(update);
        }
        match activity_of(update) {
            Some(Activity::Tool(title)) => self.activity = Some(title),
            Some(Activity::PlanStep(step)) => self.plan_step = step,
            None => {}
        }
    }

    /// Whether a tool call of the turn is in flight.
    pub(super) fn tool_in_flight(&self) -> bool {
        !self.open_tools.is_empty() || self.open_past_cap > 0
    }
}

/// What one `session/update` says the turn does now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Activity {
    /// A tool call started or was retitled: its title.
    Tool(String),
    /// The plan changed: its entry in progress, or None when none is.
    PlanStep(Option<String>),
}

/// The activity in `update` (a `session/update`'s `update`), if any, each
/// line masked and then cut to [`ACTIVITY_CHARS`] (`session::masked_preview`).
/// A tool call without a title says nothing new; an update to an existing
/// call counts only when it retitles it.
pub(super) fn activity_of(update: &Value) -> Option<Activity> {
    let line = |v: &Value| {
        v.as_str()
            .map(|t| super::session::masked_preview(t, ACTIVITY_CHARS))
            .filter(|t| !t.is_empty())
    };
    match update.get("sessionUpdate").and_then(Value::as_str)? {
        "tool_call" | "tool_call_update" => line(&update["title"]).map(Activity::Tool),
        "plan" => {
            let entries = update.get("entries").and_then(Value::as_array)?;
            let step = entries
                .iter()
                .find(|e| e["status"] == "in_progress")
                .and_then(|e| line(&e["content"]));
            Some(Activity::PlanStep(step))
        }
        _ => None,
    }
}

/// The one "currently doing" line of a turn: the plan step and the tool in
/// it, either alone, or None when the turn has said neither yet.
pub(crate) fn doing_line(plan_step: Option<&str>, activity: Option<&str>) -> Option<String> {
    match (plan_step, activity) {
        (Some(step), Some(tool)) if step != tool => Some(format!("{step} · {tool}")),
        (Some(step), _) => Some(step.to_owned()),
        (None, Some(tool)) => Some(tool.to_owned()),
        (None, None) => None,
    }
}

/// Since when a running turn that started at `started_at` has stalled, or None: its model's last
/// sign was at `heard_at` (0: none; the prompt counts as one), no tool call is in flight
/// (`in_flight`), and it has been quiet `after` ms or more by `now` (module docs).
pub(super) fn stalled_since(
    started_at: u64,
    heard_at: u64,
    in_flight: bool,
    now: u64,
    after: Option<u64>,
) -> Option<u64> {
    let quiet_since = started_at.max(heard_at);
    (!in_flight && now.saturating_sub(quiet_since) >= after?).then_some(quiet_since)
}

impl Hub {
    /// Notes `update`'s activity and tool calls on the running turn. Nothing while no turn
    /// runs: an update after the turn ended does not outlive it.
    pub(super) fn note_activity(&self, session: &Session, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update" | "plan")) {
            return;
        }
        let mut turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(turn) = turn.as_mut() {
            turn.doing.note(update);
        }
    }
}

#[cfg(test)]
mod tests;
