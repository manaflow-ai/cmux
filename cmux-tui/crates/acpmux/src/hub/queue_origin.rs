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

#[cfg(test)]
#[path = "queue_origin_tests.rs"]
mod tests;
