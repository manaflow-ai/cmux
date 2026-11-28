//! The earned-access ladder's events (RFD 0002 step 2): refusals from this machine's permission
//! log, then landed and revert events from the Cloud service. Both become `earned_access::Event`s
//! for [`super::earned_access::eligibility`].
//!
//! - Refusals, local. A person's deny is an entry of the approvals audit trail
//!   (`audit_log.rs`, `decision.kind: deny`). The policy's own denies are the chat's
//!   `permission_auto` records with a reject option, or a cancel the policy decided (`permissions.rs`,
//!   `policy_gate.rs`). A cancel acpmux made for another reason (a group it could not register, a
//!   turn's stop) is no refusal. Nothing here marks a refusal `evaded` yet: no record says an agent
//!   tried to get around one.
//! - Landed and revert, Cloud. The service keys an agent's record by its `AgentId` (RFD
//!   "Identity", step 4). cmux-platform has no such op yet, so [`AgentRecordReadOp`] is the
//!   contract this client reads, sent through `cmux_cloud_client::ops` like every catalog op,
//!   and tests read it through a fake [`RecordSource`]. When the platform ships the op, its
//!   generated type replaces this one. Whatever the service says, the daemon keeps only events
//!   whose PR trailer names the agent, and a landing only with its required checks green.

use std::collections::HashSet;
use std::future::Future;

use cmux_cloud_wire::{Op, WireClass, WireError, WireIdempotency, WirePrincipal};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::earned_access::{Event, EventKind};
use crate::store::EventRecord;

// ------------------------------------------------------------------ local refusals

/// The refusals among approvals audit entries (`audit_log.rs`) of `sessions`.
pub(crate) fn refusals_from_audit(entries: &[Value], sessions: &HashSet<&str>) -> Vec<Event> {
    entries
        .iter()
        .filter(|e| {
            e["kind"] == "approval"
                && e.pointer("/decision/kind").and_then(Value::as_str) == Some("deny")
        })
        .filter(|e| e["sessionId"].as_str().is_some_and(|s| sessions.contains(s)))
        .filter_map(|e| e["at"].as_u64())
        .map(|at| Event { at, kind: EventKind::Refusal { evaded: false } })
        .collect()
}

/// The refusal one of a chat's `permission_auto` records holds, if any.
pub(crate) fn refusal_of_record(record: &EventRecord) -> Option<Event> {
    if record.dir != "mux" || record.kind != "permission_auto" {
        return None;
    }
    let m = &record.msg;
    let rejected = m["optionId"].as_str().is_some_and(|o| o.starts_with("reject"));
    // The policy refused with no reject option to pick: a cancel with a policy and no reason.
    let policy_cancel =
        m["cancelled"] == true && m["policy"].is_string() && m.get("reason").is_none();
    (rejected || policy_cancel)
        .then_some(Event { at: record.at, kind: EventKind::Refusal { evaded: false } })
}

impl super::Hub {
    /// The refusals this machine logged for `sessions`: audit denies and the chats' own
    /// `permission_auto` refusals. Blocking: reads the audit file and each chat's log.
    pub(crate) fn local_refusals(&self, sessions: &[&str]) -> Vec<Event> {
        let wanted: HashSet<&str> = sessions.iter().copied().collect();
        let mut out = match self.audit.all() {
            Ok(entries) => refusals_from_audit(&entries, &wanted),
            Err(error) => {
                tracing::warn!("earned access: the audit log could not be read: {error}");
                Vec::new()
            }
        };
        for id in sessions {
            let read = self.store.scan_kinds(id, &["permission_auto"], &mut |rec| {
                out.extend(refusal_of_record(&rec));
                true
            });
            if let Err(error) = read {
                tracing::warn!(session = %id, "earned access: the log could not be read: {error}");
            }
        }
        out
    }

    /// What `sessions`' local refusals and the agent's Cloud `cloud` events earn at `now`
    /// (`earned_access::eligibility`). With no Cloud record (no sign-in) `cloud` is empty and
    /// the agent stays at Reads or below. Blocking, as [`Self::local_refusals`].
    pub(crate) fn earned_eligibility(
        &self,
        sessions: &[&str],
        cloud: &[Event],
        now: u64,
    ) -> super::earned_access::Eligibility {
        let mut events = self.local_refusals(sessions);
        events.extend_from_slice(cloud);
        super::earned_access::eligibility(&events, now)
    }
}

// ------------------------------------------------------------------ Cloud landed and revert

/// The read of one agent's record events since a time, a page at a time (module docs: the
/// contract until cmux-platform's catalog carries it).
pub(crate) struct AgentRecordReadOp;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct AgentRecordReadParams {
    pub agent_id: String,
    /// Unix milliseconds: events at or after it.
    pub since: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct AgentRecordReadResult {
    pub events: Vec<CloudEvent>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

/// One event the service read through its GitHub gateway.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct CloudEvent {
    /// `landed` or `revert`; another kind (a newer service) is skipped.
    pub kind: String,
    /// Unix milliseconds of the merge.
    pub at: u64,
    pub pr_url: String,
    /// The `AgentId` the trailer of the PR names: the landed PR's own, or for a revert the
    /// reverted PR's.
    #[serde(default)]
    pub trailer_agent_id: Option<String>,
    /// A landing's required checks were green at its merge.
    #[serde(default)]
    pub checks_green: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AgentRecordReadError {
    AuthForbidden,
    AuthUnauthenticated,
    NotFound,
    OwnerUnreachable,
    ValidationInvalid,
    Unknown(String),
}

impl WireError for AgentRecordReadError {
    const CODES: &'static [&'static str] = &[
        "auth.forbidden",
        "auth.unauthenticated",
        "cloud.agent.not_found",
        "owner.unreachable",
        "validation.invalid",
    ];
    fn code(&self) -> &str {
        match self {
            Self::AuthForbidden => "auth.forbidden",
            Self::AuthUnauthenticated => "auth.unauthenticated",
            Self::NotFound => "cloud.agent.not_found",
            Self::OwnerUnreachable => "owner.unreachable",
            Self::ValidationInvalid => "validation.invalid",
            Self::Unknown(code) => code,
        }
    }
    fn from_code(code: &str) -> Self {
        match code {
            "auth.forbidden" => Self::AuthForbidden,
            "auth.unauthenticated" => Self::AuthUnauthenticated,
            "cloud.agent.not_found" => Self::NotFound,
            "owner.unreachable" => Self::OwnerUnreachable,
            "validation.invalid" => Self::ValidationInvalid,
            other => Self::Unknown(other.to_owned()),
        }
    }
    fn is_declared(&self) -> bool {
        !matches!(self, Self::Unknown(_))
    }
}

impl Op for AgentRecordReadOp {
    const NAME: &'static str = "cloud.agent.record.read";
    const CLASS: WireClass = WireClass::Read;
    const IDEMPOTENCY: WireIdempotency = WireIdempotency::Forbidden;
    const OWNER: &'static str = "cloud:TeamDO";
    const RISK: &'static str = "read";
    const PRINCIPALS: &'static [WirePrincipal] = &[WirePrincipal::Session, WirePrincipal::Install];
    type Params = AgentRecordReadParams;
    type Result = AgentRecordReadResult;
    type Error = AgentRecordReadError;
}

/// Where the record pages come from: [`CloudRecords`], or a fake in tests.
pub(crate) trait RecordSource {
    fn page(
        &self,
        params: AgentRecordReadParams,
    ) -> impl Future<Output = Result<AgentRecordReadResult, String>> + Send;
}

/// The Cloud service at `base_url` (a platform origin), through the shared ops client. `http`
/// carries the person's or the install's credential.
#[cfg_attr(test, allow(dead_code))]
pub(crate) struct CloudRecords {
    pub http: reqwest::Client,
    pub base_url: String,
}

impl RecordSource for CloudRecords {
    async fn page(&self, params: AgentRecordReadParams) -> Result<AgentRecordReadResult, String> {
        cmux_cloud_client::ops::call::<AgentRecordReadOp>(
            &self.http,
            &self.base_url,
            params,
            None,
            None,
        )
        .await
        .and_then(cmux_cloud_client::ops::Answer::into_result)
        .map_err(|e| e.to_string())
    }
}

/// The most pages one read follows: a cursor that never ends stops here.
const MAX_PAGES: usize = 20;

/// The landed and revert events of `agent_id` since `since`, from `source`, every page. Each is
/// checked against its PR trailer ([`events_from_cloud`]).
pub(crate) async fn cloud_events<S: RecordSource>(
    source: &S,
    agent_id: &str,
    since: u64,
) -> Result<Vec<Event>, String> {
    let mut out = Vec::new();
    let mut cursor = None;
    for _ in 0..MAX_PAGES {
        let params = AgentRecordReadParams { agent_id: agent_id.to_owned(), since, cursor };
        let page = source.page(params).await?;
        out.extend(events_from_cloud(agent_id, &page.events));
        match page.next_cursor {
            Some(next) => cursor = Some(next),
            None => return Ok(out),
        }
    }
    tracing::warn!(agent = %agent_id, "earned access: the record read stopped at {MAX_PAGES} pages");
    Ok(out)
}

/// The events of `agent_id` among the service's: a landing with green checks and a revert of
/// one of its PRs, each only when the trailer names it.
pub(crate) fn events_from_cloud(agent_id: &str, events: &[CloudEvent]) -> Vec<Event> {
    events
        .iter()
        .filter(|e| e.trailer_agent_id.as_deref() == Some(agent_id))
        .filter_map(|e| {
            let kind = match e.kind.as_str() {
                "landed" if e.checks_green => EventKind::Landed,
                "revert" => EventKind::Revert,
                _ => return None,
            };
            Some(Event { at: e.at, kind })
        })
        .collect()
}

#[cfg(test)]
#[path = "earned_events_tests.rs"]
mod tests;
