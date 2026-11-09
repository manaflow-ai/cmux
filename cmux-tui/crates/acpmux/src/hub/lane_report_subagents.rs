//! Part of `Hub`; see `hub/mod.rs`. A lane's report of a turn a Claude Code subagent of its
//! parent asked for goes to that subagent, not to the parent's own chat (W5-M, 2026-11-08).
//!
//! A subagent (the Agent tool) runs in its lead's process with the lead's caller token, so its
//! `acpmux run` and `acpmux send` prove the lead's session; only the Bash hook's mark tells which
//! of its agents sent one (`_meta.acpmux.callerSubagent`, the prompt's `fromSubagent`). Seen three
//! times on 2026-11-08: a subagent's reviewer reported each review turn into the lead's chat
//! (claude-17), and the reviewer, reading claude-17 as its sender, sent the review there too.
//!
//! - A turn whose caller waited for the reply and printed it is read, and reports nothing
//!   (`lane_report_reads.rs` [`super::lane_report_reads::LaneReplyReader`]).
//! - Any other turn whose prompt a subagent of the parent sent ([`asking_subagent`]) reports to
//!   that subagent while it may still run: the report is left for it
//!   (`crate::subagent_notice`), and acpmux's hook gives it to the subagent after its next Bash
//!   or acpmux MCP call (`bg_hook.rs`). acpmux has no other way into a subagent's context.
//! - Once the subagent has stopped (its `SubagentStop` hook marked it) or no subagent of the
//!   parent runs any more (`SubagentTree::running_count`, which also covers one that ended with no
//!   hook), a report it did not take goes to the parent's chat as any report does, saying whose
//!   it was (`forSubagent`, [`label`]). Reports left in the folder are looked at again whenever
//!   the parent's count of running subagents changes, its harness ends, or a turn of it ends
//!   ([`Hub::subagent_notices_sweep`]).
//!
//! A daemon restart keeps the left reports on disk; they reach the lead at the parent's next
//! turn end or change of running subagents. A closed parent's folder is removed with its link.
//!
//! A subagent that calls acpmux through MCP tools (`mcp__acpmux__send`, cmux's
//! `acpmux_bg_start`, a `cmux_exec` script) and not through Bash is named by its call's tool use
//! id (`crate::subagent_call`). Not covered: a cmux workflow script's calls (they carry no tool
//! use id), `run_wait`, and a send the MCP server hands to the send relay; their reports go to
//! the lead. A background task's end message (`bg_notify.rs`) goes to the lead's chat whoever
//! started it. A subagent that makes no Bash or acpmux MCP call after its report came keeps it until
//! it ends.
//! A subagent that ends with no `SubagentStop` keeps its reports until no subagent of the lead
//! runs. A message steered into a running turn, or one that joined another message's turn
//! (`digest.rs`), reports with that turn; one Claude Code carried into a turn of its own
//! (`carried_turn.rs`) reports to its subagent.

use super::lane_reports::Report;
use super::*;

/// On a lane report the parent's chat gets for one of its subagents: `{id, type}`.
pub(super) const FOR_SUBAGENT: &str = "forSubagent";

/// "TYPE subagent ID8" of `sub` (`{id, type}`), as `acpmux send` names a subagent.
pub(super) fn label(sub: Option<&Value>) -> Option<String> {
    let sub = sub?;
    let id = sub.get("id").and_then(Value::as_str)?;
    let kind = sub.get("type").and_then(Value::as_str).unwrap_or("subagent");
    Some(format!("{kind} subagent {}", id.chars().take(8).collect::<String>()))
}

/// The subagent of `parent` (the session the lane reports to) whose message the turn runs on,
/// from the turn's `provenance`: a `session_message` from `parent` with `fromSubagent`, or a turn
/// of messages (`digest.rs`) whose every message from `parent` names the same one. None for any
/// other turn: the parent's own, the person's, another session's.
pub(super) fn asking_subagent(parent: Option<&str>, provenance: Option<&Value>) -> Option<Value> {
    let (parent, p) = (parent?, provenance?);
    if p.get("kind").and_then(Value::as_str) == Some(super::digest::DIGEST_KIND) {
        let from_parent: Vec<&Value> = p
            .get("messages")
            .and_then(Value::as_array)?
            .iter()
            .filter_map(|m| m.get("provenance"))
            .filter(|m| from_session(m) == Some(parent))
            .collect();
        let first = from_parent.first().and_then(|m| subagent_of(m))?;
        return from_parent
            .iter()
            .all(|m| subagent_of(m).as_ref() == Some(&first))
            .then_some(first);
    }
    (from_session(p) == Some(parent)).then(|| subagent_of(p)).flatten()
}

/// The session a `session_message` provenance names as its sender.
fn from_session(p: &Value) -> Option<&str> {
    if p.get("kind").and_then(Value::as_str) != Some("session_message") {
        return None;
    }
    let from = p.get("from").and_then(Value::as_str)?;
    Some(from.strip_prefix("acp:").unwrap_or(from))
}

/// A provenance's `fromSubagent`, when its id and type are plain words.
fn subagent_of(p: &Value) -> Option<Value> {
    let sub = p.get(crate::prompt_provenance::FROM_SUBAGENT)?;
    let word = |key: &str| {
        sub.get(key).and_then(Value::as_str).filter(|w| crate::cli::sender::subagent_word(w))
    };
    let (id, kind) = (word("id")?, word("type")?);
    Some(json!({"id": id, "type": kind}))
}

/// What the subagent reads of `report`.
fn notice_text(report: &Report) -> String {
    let name = &report.name;
    format!(
        "[acpmux] A session you started or prompted without waiting for its reply ended a \
turn. Its report:\n{}\nAnswer it only if it needs you, with the send tool (to: \"{name}\"); the \
last tool (name: \"{name}\") reads its whole reply.",
        report.text()
    )
}

impl Hub {
    /// Leaves `report` for its subagent in parent `p` (`report.for_subagent`): true when it is
    /// left for it, false when the subagent has stopped or no subagent of `p` runs, so the
    /// report goes to `p` itself.
    /// `question`: the report answers a question the subagent asked a session it did not start
    /// (`question_replies.rs`), so a sweep hands it to the lead that way, not as a lane's.
    pub(super) fn lane_report_to_subagent(
        &self,
        p: &Session,
        report: &Report,
        question: bool,
    ) -> bool {
        let Some(id) =
            report.for_subagent.as_ref().and_then(|s| s.get("id")).and_then(Value::as_str)
        else {
            return false;
        };
        let running = || p.subagents.lock().unwrap_or_else(|e| e.into_inner()).running_count() > 0;
        let home = crate::config::home();
        let Some(dir) = crate::subagent_notice::agent_dir(&home, &p.id, id) else { return false };
        if !running() || crate::subagent_notice::stopped(&dir) {
            return false;
        }
        let notice = json!({
            "text": notice_text(report),
            "lane": report.session,
            "report": report,
            "question": question,
        });
        let path = match crate::subagent_notice::leave(&dir, &report.prompt_id, &notice) {
            Ok(path) => path,
            Err(e) => {
                tracing::warn!(parent = %p.id, "lane report not left for its subagent: {e}");
                return false;
            }
        };
        // It stopped, or the last subagent ended, while this was being left: whoever takes it
        // first has it (the hook for the subagent, or this for the parent).
        if (!running() || crate::subagent_notice::stopped(&dir))
            && crate::subagent_notice::take(&path).is_some()
        {
            return false;
        }
        true
    }

    /// The count of `session`'s running subagents changed to `count`: recorded for watchers
    /// (`views.rs` `SUBAGENTS_RUNNING`), and the reports left for its subagents are looked at
    /// again ([`Hub::subagent_notices_sweep`]).
    pub(super) fn subagents_running(&self, session: &Session, count: usize) {
        self.append(session, "mux", super::views::SUBAGENTS_RUNNING, json!({"count": count}));
        self.subagent_notices_sweep(session);
    }

    /// The reports left for `session`'s subagents that none of them will take go to `session`
    /// itself: those of a subagent that stopped, or all of them when none runs. Run when its
    /// count of running subagents changes, when its harness ends, and at each of its turn ends,
    /// which also finds the ones a daemon restart left on disk.
    pub(super) fn subagent_notices_sweep(&self, session: &Session) {
        let home = crate::config::home();
        let left = crate::subagent_notice::agents(&home, &session.id);
        if left.is_empty() {
            return;
        }
        // Taken only where they can go on: a hub and a runtime to deliver them.
        let (Some(hub), Ok(runtime)) = (
            self.hub_ref.get().and_then(std::sync::Weak::upgrade),
            tokio::runtime::Handle::try_current(),
        ) else {
            return;
        };
        let count = session.subagents.lock().unwrap_or_else(|e| e.into_inner()).running_count();
        let notices: Vec<(PathBuf, Value)> = left
            .iter()
            .filter(|(_, stopped)| count == 0 || *stopped)
            .flat_map(|(dir, _)| {
                crate::subagent_notice::take_all(dir).into_iter().map(|n| (dir.clone(), n))
            })
            .collect();
        if count == 0 {
            crate::subagent_notice::tidy(&home, &session.id);
        }
        if notices.is_empty() {
            return;
        }
        let parent = session.id.clone();
        runtime.spawn(async move {
            for (dir, notice) in notices {
                let report = notice.get("report").cloned().map(serde_json::from_value::<Report>);
                let (Some(Ok(mut report)), Some(lane)) =
                    (report, notice.get("lane").and_then(Value::as_str))
                else {
                    continue;
                };
                report.subagent_ended = true;
                // A question's reply goes to the lead (`question_replies.rs`); a lane's report
                // has the same checks as any: the lane still reports here, its turn unread.
                let delivered = if notice.get("question") == Some(&Value::Bool(true)) {
                    hub.question_reply_deliver(&parent, lane, &report).await
                } else {
                    hub.lane_deliver(&parent, lane, &report).await
                };
                if let Err(e) = delivered {
                    tracing::warn!(parent = %parent, lane, "lane report not delivered: {}", e.message);
                    // Left again, for the next look (a turn end of the parent).
                    let _ = crate::subagent_notice::leave(&dir, &report.prompt_id, &notice);
                }
            }
        });
    }
}
