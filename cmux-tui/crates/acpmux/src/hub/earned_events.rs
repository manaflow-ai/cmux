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
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;

    const AGENT: &str = "agt-1";

    fn record(kind: &str, msg: Value, at: u64) -> EventRecord {
        serde_json::from_value(json!({"seq": 1, "at": at, "dir": "mux", "kind": kind, "msg": msg}))
            .unwrap()
    }

    #[test]
    fn audit_denies_of_the_agents_sessions_are_refusals() {
        let entries = [
            json!({"at": 10, "sessionId": "a", "kind": "approval", "decision": {"kind": "deny"}}),
            json!({"at": 11, "sessionId": "a", "kind": "approval", "decision": {"kind": "allow"}}),
            json!({"at": 12, "sessionId": "b", "kind": "approval", "decision": {"kind": "deny"}}),
            json!({"at": 13, "sessionId": "a", "kind": "review", "decision": {"kind": "changes"}}),
            json!({"at": 14, "sessionId": "a", "kind": "approval", "decision": {"kind": "cancel"}}),
        ];
        let got = refusals_from_audit(&entries, &HashSet::from(["a"]));
        assert_eq!(got, vec![Event { at: 10, kind: EventKind::Refusal { evaded: false } }]);
    }

    #[test]
    fn policy_rejects_and_policy_cancels_are_refusals_other_cancels_are_not() {
        let at = |r: &EventRecord| refusal_of_record(r).map(|e| e.at);
        let gate = json!({"policy": "review", "optionId": "reject_once", "gate": "preToolUse"});
        assert_eq!(at(&record("permission_auto", gate, 1)), Some(1));
        let cancel = json!({"policy": "deny-all", "cancelled": true});
        assert_eq!(at(&record("permission_auto", cancel, 2)), Some(2));
        let allowed = json!({"policy": "approve-reads", "optionId": "allow_once"});
        assert_eq!(at(&record("permission_auto", allowed, 3)), None);
        let grouping = json!({"cancelled": true, "reason": "group full"});
        assert_eq!(at(&record("permission_auto", grouping, 4)), None);
        let other = json!({"optionId": "reject_once"});
        assert_eq!(at(&record("permission_decision", other, 5)), None);
    }

    #[tokio::test]
    async fn the_hub_reads_refusals_from_its_own_log() {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
        let hub = super::super::Hub::new(config, store);
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert("s1".to_owned(), session.clone());
        let deny = json!({"policy": "review", "optionId": "reject_once", "request": {}});
        hub.append_logged(&session, "mux", "permission_auto", deny, None);
        let allow = json!({"policy": "review", "optionId": "allow_once", "request": {}});
        hub.append_logged(&session, "mux", "permission_auto", allow, None);

        let refusals = hub.local_refusals(&["s1"]);
        assert_eq!(refusals.len(), 1);
        assert_eq!(refusals[0].kind, EventKind::Refusal { evaded: false });
        assert!(hub.local_refusals(&["other"]).is_empty());

        // Fed to the ladder: ten landings before the refusal no longer count.
        let landed: Vec<Event> = (0..10)
            .map(|i| Event { at: refusals[0].at - 100 + i, kind: EventKind::Landed })
            .collect();
        let e = hub.earned_eligibility(&["s1"], &landed, refusals[0].at + 1);
        assert_eq!(e.earned, super::super::earned_access::Rung::Reads);
        assert_eq!(e.reset_at, Some(refusals[0].at));
        let without = hub.earned_eligibility(&["other"], &landed, refusals[0].at + 1);
        assert_eq!(without.earned, super::super::earned_access::Rung::Full);
    }

    fn cloud(kind: &str, at: u64, trailer: Option<&str>, green: bool) -> CloudEvent {
        CloudEvent {
            kind: kind.into(),
            at,
            pr_url: format!("https://github.com/o/r/pull/{at}"),
            trailer_agent_id: trailer.map(str::to_owned),
            checks_green: green,
        }
    }

    #[test]
    fn only_trailer_checked_green_landings_and_reverts_count() {
        let events = [
            cloud("landed", 1, Some(AGENT), true),
            cloud("landed", 2, Some(AGENT), false),
            cloud("landed", 3, Some("agt-other"), true),
            cloud("landed", 4, None, true),
            cloud("revert", 5, Some(AGENT), false),
            cloud("revert", 6, Some("agt-other"), false),
            cloud("retitled", 7, Some(AGENT), true),
        ];
        let got = events_from_cloud(AGENT, &events);
        assert_eq!(
            got,
            vec![
                Event { at: 1, kind: EventKind::Landed },
                Event { at: 5, kind: EventKind::Revert },
            ]
        );
    }

    struct Fake {
        pages: Vec<AgentRecordReadResult>,
        asked: Mutex<Vec<AgentRecordReadParams>>,
    }

    impl RecordSource for Fake {
        async fn page(&self, p: AgentRecordReadParams) -> Result<AgentRecordReadResult, String> {
            let mut asked = self.asked.lock().unwrap();
            asked.push(p);
            self.pages.get(asked.len() - 1).cloned().ok_or_else(|| "no page".into())
        }
    }

    #[tokio::test]
    async fn the_client_follows_every_page_and_feeds_the_ladder() {
        let fake = Fake {
            pages: vec![
                AgentRecordReadResult {
                    events: vec![cloud("landed", 100, Some(AGENT), true)],
                    next_cursor: Some("c2".into()),
                },
                AgentRecordReadResult {
                    events: vec![
                        cloud("landed", 101, Some(AGENT), true),
                        cloud("landed", 102, Some(AGENT), true),
                    ],
                    next_cursor: None,
                },
            ],
            asked: Mutex::new(Vec::new()),
        };
        let events = cloud_events(&fake, AGENT, 50).await.unwrap();
        assert_eq!(events.len(), 3);
        let asked = fake.asked.lock().unwrap().clone();
        assert_eq!(asked.len(), 2);
        assert_eq!((asked[0].since, asked[0].cursor.as_deref()), (50, None));
        assert_eq!(asked[1].cursor.as_deref(), Some("c2"));
        let e = super::super::earned_access::eligibility(&events, 200);
        assert_eq!(e.earned, super::super::earned_access::Rung::Edits);
    }

    #[tokio::test]
    async fn a_failed_page_fails_the_read() {
        let fake = Fake { pages: vec![], asked: Mutex::new(Vec::new()) };
        assert_eq!(cloud_events(&fake, AGENT, 0).await, Err("no page".into()));
    }

    #[test]
    fn the_op_reads_the_services_answer_and_its_refusal() {
        let body = json!({
            "op": "cloud.agent.record.read", "stream": "team:t", "revision": "7",
            "value": {"events": [{"kind": "landed", "at": 9, "pr_url": "https://github.com/o/r/pull/9",
                                  "trailer_agent_id": AGENT, "checks_green": true}],
                      "next_cursor": null}
        });
        let answer = cmux_cloud_client::ops::read_answer::<AgentRecordReadOp>(
            200,
            None,
            body.to_string().as_bytes(),
        )
        .unwrap()
        .into_result()
        .unwrap();
        assert_eq!(answer.events, vec![cloud("landed", 9, Some(AGENT), true)]);
        assert_eq!(
            serde_json::to_value(AgentRecordReadParams {
                agent_id: AGENT.into(),
                since: 3,
                cursor: None
            })
            .unwrap(),
            json!({"agent_id": AGENT, "since": 3})
        );

        let refused =
            json!({"_tag": "OpError", "code": "auth.unauthenticated", "message": "sign in"});
        let error = cmux_cloud_client::ops::read_answer::<AgentRecordReadOp>(
            401,
            None,
            refused.to_string().as_bytes(),
        )
        .unwrap_err();
        assert_eq!(error.status, Some(401));
        assert_eq!(
            AgentRecordReadError::from_code("cloud.agent.not_found"),
            AgentRecordReadError::NotFound
        );
        assert!(!AgentRecordReadError::from_code("new.code").is_declared());
    }
}
