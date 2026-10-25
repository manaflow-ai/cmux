//! Part of `Hub`; see `hub/mod.rs`. What a running turn does right now, one
//! line, for a parent session that reports its sub-sessions' progress
//! (`get_session`'s `doing`) and for any client's summary (`turn.activity`,
//! `turn.planStep`).
//!
//! The turn's latest tool call titles it ("Run cargo test -p acpmux"); its
//! plan's entry in progress is the step around it. Both live on the running
//! turn only (`TurnInfo`) and end with it, so a finished turn never reads as
//! still doing its last tool. Each is kept twice: raw for the owner's views,
//! and masked before its cut for the sub-session tools (`subsession_row`), so
//! a secret across the cut leaves no head there.
//!
//! The turn also keeps the ids of its tool calls in flight (started, not yet
//! completed or failed): a turn with none, whose model has been quiet for
//! `stalledTurnMs`, has stalled (`stalled_since`). A long build in one tool
//! call is in flight, so it never stalls.

use super::*;

/// Longest activity or plan step kept, in characters.
const ACTIVITY_CHARS: usize = 160;
/// Most tool-call ids a turn keeps in flight; calls past it are counted (`open_past_cap`).
const MAX_OPEN_TOOLS: usize = 256;

/// What a running turn does now (`TurnInfo::doing`), one line each.
#[derive(Debug, Clone, Default)]
pub struct TurnActivity {
    /// Its latest tool call's title. None until it calls one.
    pub activity: Option<String>,
    /// Its plan's entry in progress.
    pub plan_step: Option<String>,
    /// `activity` with its secrets masked before its cut (`secret_scan`).
    pub masked_activity: Option<String>,
    /// `plan_step` with its secrets masked before its cut.
    pub masked_plan_step: Option<String>,
    /// The ids of its tool calls in flight.
    pub open_tools: std::collections::BTreeSet<String>,
    /// How many tool calls started past [`MAX_OPEN_TOOLS`] are in flight, by count, not id: the
    /// end of a call whose id isn't kept ends one of them.
    pub open_past_cap: usize,
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
            if !self.open_tools.remove(id) {
                self.open_past_cap = self.open_past_cap.saturating_sub(1);
            }
            return;
        }
        // A new call, or an update that says it runs; an update with no status changes nothing.
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
        match activity_of(update).zip(masked_activity_of(update)) {
            Some((Activity::Tool(title), Activity::Tool(masked))) => {
                self.activity = Some(title);
                self.masked_activity = Some(masked);
            }
            Some((Activity::PlanStep(step), Activity::PlanStep(masked))) => {
                self.plan_step = step;
                self.masked_plan_step = masked;
            }
            _ => {}
        }
    }

    /// Whether a tool call of the turn is in flight.
    pub(super) fn tool_in_flight(&self) -> bool {
        !self.open_tools.is_empty() || self.open_past_cap > 0
    }

    /// Puts the masked lines in `turn`, a summary's running turn, for the
    /// sub-session tools.
    pub(super) fn mask_into(&self, turn: &mut Value) {
        turn["activity"] = json!(self.masked_activity);
        turn["planStep"] = json!(self.masked_plan_step);
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

/// The activity in `update` (a `session/update`'s `update`), if any. A tool
/// call without a title says nothing new; an update to an existing call
/// counts only when it retitles it.
pub(super) fn activity_of(update: &Value) -> Option<Activity> {
    activity_cut(update, short_text)
}

/// [`activity_of`] with its text masked before the cut (`session::masked_preview`).
fn masked_activity_of(update: &Value) -> Option<Activity> {
    activity_cut(update, super::session::masked_preview)
}

/// The activity in `update`, each line cut to [`ACTIVITY_CHARS`] by `cut`.
fn activity_cut(update: &Value, cut: fn(&str, usize) -> String) -> Option<Activity> {
    let line = |v: &Value| v.as_str().map(|t| cut(t, ACTIVITY_CHARS)).filter(|t| !t.is_empty());
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
mod tests {
    use super::*;

    #[test]
    fn a_tool_call_names_the_activity() {
        let u = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run  cargo test\n-p acpmux", "status": "pending"});
        assert_eq!(activity_of(&u), Some(Activity::Tool("Run cargo test -p acpmux".into())));
    }

    #[test]
    fn an_untitled_update_says_nothing() {
        let u =
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"});
        assert_eq!(activity_of(&u), None);
        assert_eq!(activity_of(&json!({"sessionUpdate": "agent_message_chunk"})), None);
    }

    #[test]
    fn a_plan_names_its_step_in_progress() {
        let u = json!({"sessionUpdate": "plan", "entries": [
            {"content": "Read the brief", "status": "completed", "priority": "high"},
            {"content": "Fix send_message", "status": "in_progress", "priority": "high"},
            {"content": "Open the PR", "status": "pending", "priority": "high"},
        ]});
        assert_eq!(activity_of(&u), Some(Activity::PlanStep(Some("Fix send_message".into()))));
        let done =
            json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "completed"}]});
        assert_eq!(activity_of(&done), Some(Activity::PlanStep(None)));
    }

    #[test]
    fn a_tool_call_is_in_flight_until_it_completes_or_fails() {
        let mut doing = TurnActivity::default();
        doing
            .note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": "a", "title": "Build"}));
        doing.note_tool(
            &json!({"sessionUpdate": "tool_call", "toolCallId": "b", "status": "pending"}),
        );
        assert!(doing.tool_in_flight());
        doing.note_tool(
            &json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "title": "Built"}),
        );
        doing.note_tool(
            &json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed"}),
        );
        assert!(doing.tool_in_flight(), "b still runs");
        doing.note_tool(
            &json!({"sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "failed"}),
        );
        assert!(!doing.tool_in_flight());
        // A call that starts already done is never in flight.
        doing.note_tool(
            &json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "completed"}),
        );
        assert!(!doing.tool_in_flight());
    }

    #[test]
    fn tool_calls_past_the_cap_stay_in_flight_only_until_they_end() {
        let mut doing = TurnActivity::default();
        let n = MAX_OPEN_TOOLS + 3;
        for i in 0..n {
            let id = format!("t{i}");
            doing.note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": id}));
            doing.note_tool(&json!({
                "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress"
            }));
        }
        for i in 0..n {
            assert!(doing.tool_in_flight(), "t{i} and later still run");
            doing.note_tool(&json!({
                "sessionUpdate": "tool_call_update", "toolCallId": format!("t{i}"),
                "status": "completed"
            }));
        }
        assert!(!doing.tool_in_flight());
    }

    #[test]
    fn a_turn_stalls_when_its_model_is_quiet_with_no_tool_in_flight() {
        let after = Some(600_000);
        // Heard a minute ago: not stalled.
        assert_eq!(stalled_since(1_000, 2_000_000, false, 2_060_000, after), None);
        // Quiet ten minutes: stalled since it was last heard.
        assert_eq!(stalled_since(1_000, 2_000_000, false, 2_600_000, after), Some(2_000_000));
        // Never heard: quiet since the prompt.
        assert_eq!(stalled_since(1_000, 0, false, 601_000, after), Some(1_000));
        // Heard only in an earlier turn: quiet since this turn's prompt.
        assert_eq!(stalled_since(5_000, 4_000, false, 300_000, after), None);
        // A tool call in flight (a long build) never stalls, and 0 turns it off.
        assert_eq!(stalled_since(1_000, 0, true, 99_000_000, after), None);
        assert_eq!(stalled_since(1_000, 0, false, 99_000_000, None), None);
    }

    #[test]
    fn a_long_title_is_cut() {
        let u = json!({"sessionUpdate": "tool_call", "title": "x".repeat(500)});
        let Some(Activity::Tool(t)) = activity_of(&u) else { panic!() };
        assert_eq!(t.chars().count(), ACTIVITY_CHARS + 1);
    }

    #[test]
    fn the_doing_line_joins_step_and_tool() {
        assert_eq!(
            doing_line(Some("Fix it"), Some("Edit a.rs")).as_deref(),
            Some("Fix it · Edit a.rs")
        );
        assert_eq!(doing_line(Some("Fix it"), None).as_deref(), Some("Fix it"));
        assert_eq!(doing_line(None, Some("Edit a.rs")).as_deref(), Some("Edit a.rs"));
        assert_eq!(doing_line(Some("same"), Some("same")).as_deref(), Some("same"));
        assert_eq!(doing_line(None, None), None);
    }
}
