//! Who put a queued prompt in the chat's queue (`QueuedPromptSummary.origin`), read from its
//! provenance alone, never from its words. Leo, 2026-11-24, on a surge digest and a subagent's
//! resume drawn as the person's steerable queue rows: "these held during message surge, esume
//! subagent things... maybe shouldn't look liek they're in the steer thing. because why would a
//! user steer or whatever on these? they should be separated out from the user visible steer ui
//! area. maybe not even interactable?"
//!
//! - `person`: the chat's owner or a teammate typed it (no provenance, `person_message`), or the
//!   person's own scheduled prompt (`trigger`). Only these are the composer's steer rows.
//! - `agent`: another agent's message, a lane's report, a tool's notice, acpmux's inbox notice or
//!   digest of such messages: the transcript draws them as received messages.
//! - `acpmux`: the daemon's own prompt to the chat's agent: a surge digest, a subagent's resume or
//!   retry, a cut turn's continuation, a turn cap's note, a suggested task's first reply, a forum
//!   announcement. An app draws them apart from the steer rows, with none of the person's actions.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Who put a queued prompt in the queue ([`of`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum QueueOrigin {
    /// The person typed it: the composer's steer rows.
    Person,
    /// Another agent's message, or acpmux's notice or digest of such messages.
    Agent,
    /// acpmux's own prompt to the chat's agent: no steer row and none of the person's actions.
    Acpmux,
}

/// The provenance kinds acpmux sets on its own prompts (never taken from a client:
/// `prompt_provenance::of` drops them).
const ACPMUX_KINDS: &[&str] = &[
    super::surge_triage::PROVENANCE_KIND,
    super::subagent_retry::PROVENANCE_KIND,
    super::subagent_resume::PROVENANCE_KIND,
    super::turn_cap::NOTICE_KIND,
    super::forum::PROVENANCE_KIND,
    "auto_resume",
    "offer_result",
    crate::lane_death_watch::KIND,
];

/// The provenance kinds of other agents' messages and acpmux's notices or digests of them.
const AGENT_KINDS: &[&str] = &[
    "agent_message",
    "session_message",
    "task_result",
    crate::prompt_provenance::NOTICE_KIND,
    super::inbox::NOTICE_KIND,
    super::digest::DIGEST_KIND,
    super::subsessions::PROVENANCE_KIND,
    super::lane_reports::KIND,
    crate::prompt_provenance::UNVERIFIED_KIND,
];

/// Who put the prompt with `provenance` in the queue; `agent` is the sending agent's name the
/// daemon bound (`QueuedPrompt.run.agent`).
pub(crate) fn of(provenance: Option<&Value>, agent: Option<&str>) -> QueueOrigin {
    let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
    match kind {
        Some(kind) if ACPMUX_KINDS.contains(&kind) => QueueOrigin::Acpmux,
        _ if agent.is_some() => QueueOrigin::Agent,
        Some(kind) if AGENT_KINDS.contains(&kind) => QueueOrigin::Agent,
        _ => QueueOrigin::Person,
    }
}

/// Whether `q` was put in the queue by the person ([`of`] over its provenance and sender).
pub(super) fn is_persons(q: &super::queue::QueuedPrompt) -> bool {
    of(q.run.provenance.as_ref(), q.run.agent.as_deref()) == QueueOrigin::Person
}

/// Where the person's new prompt goes in `queue`: ahead of the first prompt a failed turn holds,
/// and ahead of the first one the person did not send (another agent's message, an inbox notice
/// or digest, acpmux's surge digest or resume), behind the person's own and a prompt sent now.
/// Before, only another agent's message (`run.agent`) counted: an inbox notice, an inbox digest
/// and a surge digest carry no sender, so the person's prompt queued behind them. Leo's
/// coordinator, 2026-11-27 02:5xZ, showed "Held during a message surge: 7 message(s) in 6
/// thread(s) need you" with his own message waiting behind that inbox traffic. Leo: "just go
/// re-analyze our work and our token efficiency/usage and what we're achieving"; the coordinator
/// rule from that pass: the person's turn goes first, inbox items and digests wait until after it.
pub(super) fn person_place(queue: &[super::queue::QueuedPrompt]) -> Option<usize> {
    queue.iter().position(|q| q.held || (!q.sent_now && !is_persons(q)))
}

#[cfg(test)]
#[path = "queue_origin_place_tests.rs"]
mod place_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn kind(kind: &str) -> Value {
        json!({"kind": kind})
    }

    #[test]
    fn the_persons_prompt_is_the_persons() {
        assert_eq!(of(None, None), QueueOrigin::Person);
        assert_eq!(of(Some(&kind("person_message")), None), QueueOrigin::Person);
        assert_eq!(of(Some(&kind("trigger")), None), QueueOrigin::Person);
    }

    #[test]
    fn acpmux_own_prompts_are_acpmux() {
        for k in [
            "surge_digest",
            "subagent_retry",
            "subagent_resume",
            "auto_resume",
            "turn_cap",
            "offer_result",
            "announcement",
        ] {
            assert_eq!(of(Some(&kind(k)), None), QueueOrigin::Acpmux, "{k}");
        }
    }

    #[test]
    fn other_agents_messages_are_agents() {
        assert_eq!(of(Some(&kind("agent_message")), Some("lane-a")), QueueOrigin::Agent);
        assert_eq!(of(None, Some("lane-a")), QueueOrigin::Agent);
        for k in ["inbox_notice", "agent_digest", "subsession_message", "lane_report", "notice"] {
            assert_eq!(of(Some(&kind(k)), None), QueueOrigin::Agent, "{k}");
        }
    }

    #[test]
    fn serializes_snake_case() {
        assert_eq!(serde_json::to_value(QueueOrigin::Acpmux).unwrap(), json!("acpmux"));
    }
}
