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

use super::*;

/// Longest activity or plan step kept, in characters.
const ACTIVITY_CHARS: usize = 160;

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
}

impl TurnActivity {
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

impl Hub {
    /// Notes `update`'s activity on the running turn. Nothing while no turn
    /// runs: an update after the turn ended does not outlive it.
    pub(super) fn note_activity(&self, session: &Session, update: &Value) {
        let (Some(raw), Some(masked)) = (activity_of(update), masked_activity_of(update)) else {
            return;
        };
        let mut turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
        let Some(turn) = turn.as_mut() else {
            return;
        };
        let doing = &mut turn.doing;
        match (raw, masked) {
            (Activity::Tool(title), Activity::Tool(masked)) => {
                doing.activity = Some(title);
                doing.masked_activity = Some(masked);
            }
            (Activity::PlanStep(step), Activity::PlanStep(masked)) => {
                doing.plan_step = step;
                doing.masked_plan_step = masked;
            }
            _ => {}
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
