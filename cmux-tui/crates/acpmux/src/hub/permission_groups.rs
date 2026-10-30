//! Session-local permission batches. One lock owns membership, chat grants,
//! callbacks and receipts, so a decision cannot approve an unseen member.
use super::mac_approvers::MacProof;
use super::*;
use cmux_json::JsonSet as _;
use std::collections::{HashSet, VecDeque};
use std::time::{Duration, Instant};

pub const PERMISSION_GROUP_OPERATIONS: [&str; 3] = [
    method::MUX_PERMISSION_GROUPS,
    method::MUX_PERMISSION_GROUP_RESPOND,
    method::MUX_PERMISSION_CHAT_REVOKE,
];
const WINDOW: Duration = Duration::from_millis(100);
/// The most a group's timer waits past WINDOW for requests still on their
/// way (`AskInFlight`); one later than that forms a group of its own.
const LANDING_BOUND: Duration = Duration::from_secs(2);
const MAX_ITEMS: usize = 32;
const MAX_GROUPS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) struct AgentRequestKey {
    pub(super) host_incarnation: Option<String>,
    pub(super) request_id: String,
}

impl AgentRequestKey {
    pub(super) fn new(host_incarnation: Option<&str>, request_id: &Value) -> Self {
        Self {
            host_incarnation: host_incarnation.map(str::to_owned),
            request_id: request_id.to_string(),
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct PermissionState {
    pub pending: HashMap<String, PendingPermission>,
    /// What the asks no longer pending were answered, for a later answer (`permission_settled.rs`).
    pub settled: super::permissions::settled::Settled,
    /// Permission requests whose handlers have been admitted but have not
    /// completed. Cancellation markers are limited to this set and are
    /// removed when the handler finishes.
    pub active_requests: HashSet<AgentRequestKey>,
    pub cancelled_requests: HashSet<AgentRequestKey>,
    groups: VecDeque<Group>,
    pub chat_allowed: bool,
}

#[derive(Debug)]
struct Group {
    id: String,
    turn_id: Option<String>,
    epoch: u64,
    opened: Instant,
    revision: u64,
    state: &'static str,
    items: Vec<Item>,
    receipt: Option<(Value, Value)>,
}

#[derive(Debug)]
struct Item {
    id: String,
    request: Value,
    state: &'static str,
}

pub(super) fn eligible(request: &Value) -> bool {
    matches!(
        request["toolCall"]["kind"].as_str(),
        Some("read" | "search" | "edit" | "delete" | "move" | "execute" | "fetch" | "think")
    ) && not_interactive(request)
}

/// Whether `request` only asks to run a tool: no question, plan approval, folder trust or other
/// interactive ask, which only a person answers. Full access answers only these
/// (`permissions.rs` `full_access_allow`). A request shaped like a question that `normalize` could
/// not read (a Codex user-input request with no prompt text) is a question too.
pub(super) fn plain_tool_ask(request: &Value) -> bool {
    let tool = &request["toolCall"];
    tool["kind"].as_str() != Some("switch_mode")
        && super::questions::trust_cwd(request).is_none()
        && tool.pointer("/rawInput/questions").is_none()
        && tool.pointer("/_meta/codexAppServer/question").and_then(Value::as_bool) != Some(true)
        && not_interactive(request)
}

fn not_interactive(request: &Value) -> bool {
    let tool = &request["toolCall"];
    request.get("interactive").and_then(Value::as_bool) != Some(true)
        && request.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) != Some(true)
        && tool.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) != Some(true)
        && tool.pointer("/_meta/claude/interactive").and_then(Value::as_bool) != Some(true)
        && !matches!(
            tool.pointer("/_meta/claude/tool").and_then(Value::as_str),
            Some("AskUserQuestion" | "ExitPlanMode")
        )
        // A question (any harness) is answered on its own card, never in a batch.
        && !super::questions::needs_person(request)
}

pub(super) fn option(request: &Value, kind: &str) -> Option<String> {
    let options = request["options"].as_array()?;
    options.iter().find_map(|o| {
        let id = o["optionId"].as_str().filter(|id| !id.is_empty())?;
        (o["kind"] == kind && options.iter().filter(|other| other["optionId"] == id).count() == 1)
            .then(|| id.to_owned())
    })
}

impl Group {
    fn terminal(&self) -> bool {
        matches!(self.state, "resolved" | "cancelled")
    }

    fn value(&self, session_id: &str) -> Value {
        use crate::protocol::permission::{
            PermissionDecision, PermissionGroup, PermissionGroupItem,
        };
        let can_allow = self
            .items
            .iter()
            .filter(|i| i.state == "pending")
            .all(|i| option(&i.request, "allow_once").is_some());
        let group = PermissionGroup {
            group_id: self.id.clone(),
            session_id: session_id.to_owned(),
            turn_id: self.turn_id.clone(),
            revision: self.revision,
            state: self.state,
            items: self
                .items
                .iter()
                .map(|i| PermissionGroupItem {
                    permission_id: i.id.clone(),
                    request: i.request.clone(),
                    state: i.state,
                })
                .collect(),
            decisions: if can_allow {
                vec![
                    PermissionDecision::AllowOnce,
                    PermissionDecision::AllowChat,
                    PermissionDecision::Deny,
                ]
            } else {
                vec![PermissionDecision::Deny]
            },
            // Validated when it was taken (`respond_permission_group`).
            decision: self
                .receipt
                .as_ref()
                .and_then(|(body, _)| body["decision"].as_str())
                .and_then(PermissionDecision::from_wire),
        };
        serde_json::to_value(group).unwrap_or(Value::Null)
    }
}

/// A pending member of a group, for an approver's signed allow of the whole group.
pub(super) struct PendingMember {
    pub id: String,
    pub decision_nonce: String,
    pub request: Value,
}

/// `_meta.acpmux` field of a group allow from a connection that is not the person: an
/// approver's signed one-time allow for each pending member, by permission id,
/// `{decisionNonce, approverDecision}` (`person.rs`, `mac_approvers.rs`).
pub const APPROVER_DECISIONS_FIELD: &str = "approverDecisions";

impl PermissionState {
    /// The pending members of group `id` while it waits for a decision at `revision`: each
    /// one's permission id, its prompt's decision nonce and its request. None for no such
    /// group, one collecting, decided or at another revision, or a member whose prompt is gone.
    pub(super) fn pending_members(&self, id: &str, revision: u64) -> Option<Vec<PendingMember>> {
        let g = self
            .groups
            .iter()
            .find(|g| g.id == id && g.state == "pending" && g.revision == revision)?;
        g.items
            .iter()
            .filter(|i| i.state == "pending")
            .map(|i| {
                let p = self.pending.get(&i.id)?;
                Some(PendingMember {
                    id: i.id.clone(),
                    decision_nonce: p.decision_nonce.clone(),
                    request: p.request.clone(),
                })
            })
            .collect()
    }

    pub(super) fn pending_records(&self) -> Vec<Value> {
        self.pending
            .iter()
            .map(|(id, pending)| {
                let group = self.groups.iter().find(|g| g.items.iter().any(|item| &item.id == id));
                json!({"permissionId":id,"request":pending.request,"decisionNonce":pending.decision_nonce,
                    "groupId":group.map(|g| &g.id),"turnId":group.and_then(|g| g.turn_id.as_ref())})
            })
            .collect()
    }

    // Returns the group id and whether a new timer is needed.
    //
    // A request joins the group of its turn that is still collecting: the
    // group's timer (`start_permission_group_timer`, WINDOW after it opened,
    // once no request read before then is on its way: `AskInFlight`) ends
    // collection under this lock, so a group holds exactly what came before
    // it was shown. Membership never reads the clock at the request:
    // a burst the agent sent in one millisecond reached this lock 100 ms
    // and more apart on a busy daemon (its request tasks wait their turn),
    // and a clock test there split it into two groups (cx-nx5mb, rbx).
    pub fn register(
        &mut self,
        id: &str,
        request: &Value,
        turn: Option<String>,
        epoch: u64,
        now: Instant,
    ) -> Result<(String, bool), RpcError> {
        let existing = self.groups.iter().position(|g| {
            g.state == "collecting"
                && g.turn_id == turn
                && g.epoch == epoch
                && g.items.len() < MAX_ITEMS
        });
        let (index, fresh) = match existing {
            Some(i) => (i, false),
            None => {
                if self.groups.iter().filter(|g| !g.terminal()).count() >= MAX_GROUPS {
                    return Err(RpcError::new(-32000, "budget_exceeded")
                        .with_data(json!({"reason":"budget_exceeded"})));
                }
                self.groups.push_back(Group {
                    id: uuid::Uuid::now_v7().to_string(),
                    turn_id: turn,
                    epoch,
                    opened: now,
                    revision: 0,
                    state: "collecting",
                    items: Vec::new(),
                    receipt: None,
                });
                (self.groups.len() - 1, true)
            }
        };
        let g = &mut self.groups[index];
        g.items.push(Item { id: id.into(), request: request.clone(), state: "pending" });
        g.revision += 1;
        Ok((g.id.clone(), fresh))
    }

    fn prune(&mut self) {
        while self.groups.iter().filter(|g| g.terminal()).count() > MAX_GROUPS {
            if let Some(i) = self.groups.iter().position(Group::terminal) {
                self.groups.remove(i);
            }
        }
    }

    pub fn finish_item(&mut self, session_id: &str, id: &str, cancelled: bool) -> Option<Value> {
        let g = self.groups.iter_mut().find(|g| g.items.iter().any(|i| i.id == id))?;
        let item = g.items.iter_mut().find(|i| i.id == id)?;
        if item.state != "pending" {
            return None;
        }
        item.state = if cancelled { "cancelled" } else { "resolved" };
        g.revision += 1;
        if g.items.iter().all(|i| i.state != "pending") {
            g.state = if g.items.iter().any(|i| i.state == "cancelled") {
                "cancelled"
            } else {
                "resolved"
            };
        }
        let value = g.value(session_id);
        self.prune();
        Some(value)
    }
}

/// One agent `session/request_permission` on its way from the session's
/// inbound loop, which reads the agent's requests in order, to its group.
/// Dropped once the request joined a group or was decided without one.
/// A group's timer waits for every request counted when it fires, so a
/// burst the inbound loop read together is shown together however late
/// its request tasks run (cx-nx5mb).
pub(super) struct AskInFlight(Arc<Session>);

impl AskInFlight {
    pub(super) fn new(session: &Arc<Session>) -> Self {
        session.asks_in_flight.fetch_add(1, Ordering::SeqCst);
        Self(session.clone())
    }
}

impl Drop for AskInFlight {
    fn drop(&mut self) {
        if self.0.asks_in_flight.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.0.asks_landed.notify_waiters();
        }
    }
}

/// The group allow's `approverDecisions` matched to the group's pending `members`: one Mac
/// proof per member, over its one-time allow option (`options`, by member, the option the
/// allow selects). None unless there is a member, each has an entry whose `decisionNonce` is
/// its prompt's and whose `approverDecision` is an object, no entry names anything else, and
/// each member offers a single one-time allow.
fn approver_proofs<'a>(
    members: &'a [PendingMember],
    options: &'a [String],
    params: &'a Value,
) -> Option<Vec<MacProof<'a>>> {
    let decisions =
        params.pointer(&format!("/_meta/acpmux/{APPROVER_DECISIONS_FIELD}"))?.as_object()?;
    // Keys are unique: as many entries as members, each found, is no entry for another.
    if members.is_empty() || decisions.len() != members.len() || options.len() != members.len() {
        return None;
    }
    members
        .iter()
        .zip(options)
        .map(|(m, option)| {
            let entry = decisions.get(&m.id)?;
            let nonce = entry.get("decisionNonce")?.as_str()?;
            let decision = entry.get(super::approvers::DECISION_FIELD).filter(|v| v.is_object())?;
            cmux_local_auth::tokens_match(nonce, &m.decision_nonce).then_some(MacProof {
                permission: &m.id,
                request: &m.request,
                option,
                nonce,
                answers: None,
                decision,
            })
        })
        .collect()
}

/// Each member's one-time allow option (the one a group's Allow once selects), or None when
/// one has none.
fn allow_options(members: &[PendingMember]) -> Option<Vec<String>> {
    members.iter().map(|m| option(&m.request, "allow_once")).collect()
}

fn conflict(reason: &str, group: Value) -> RpcError {
    RpcError::new(-32000, reason).with_data(json!({"reason":reason,"group":group}))
}

impl Hub {
    /// The person gate's check of a group allow from a connection that is not the person
    /// (`person.rs`): `params` carries an enrolled Mac's valid signed one-time allow for every
    /// pending member of the group at its revision. It spends nothing; the answer checks again
    /// under the prompt state's lock and spends (`respond_permission_group`).
    pub(super) fn approver_allows_group(&self, params: &Value) -> bool {
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let (Some(id), Some(revision)) = (params["groupId"].as_str(), params["revision"].as_u64())
        else {
            return false;
        };
        let members = s
            .permissions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pending_members(id, revision);
        let Some(members) = members else { return false };
        let Some(options) = allow_options(&members) else { return false };
        approver_proofs(&members, &options, params)
            .is_some_and(|proofs| self.person.macs_prove(&s.id, &proofs))
    }

    /// The answer's check of a group allow from a connection that is not the person, under the
    /// prompt state's lock (`state`): every pending member's Mac signature verified and every
    /// nonce spent together, under one hold of the Mac set's lock (`PersonGate::macs_spend`;
    /// lock order: the prompt state's, the Mac set's, then the spent store, as a single
    /// answer). Either all count or none is spent, so a revocation or a spent nonce refuses
    /// the whole allow and leaves every member pending and answerable.
    fn approver_spends_group(
        &self,
        session: &Session,
        state: &PermissionState,
        id: &str,
        revision: u64,
        params: &Value,
    ) -> bool {
        let Some(members) = state.pending_members(id, revision) else { return false };
        let Some(options) = allow_options(&members) else { return false };
        approver_proofs(&members, &options, params)
            .is_some_and(|proofs| self.person.macs_spend(&session.id, &proofs))
    }

    pub fn permission_groups(&self, session: &Session, params: &Value) -> Result<Value, RpcError> {
        let state = session.permissions.lock().unwrap();
        let id = match params.get("groupId") {
            None => None,
            Some(Value::String(id)) if !id.is_empty() => Some(id.as_str()),
            _ => return Err(RpcError::invalid_params("groupId must be a nonempty string")),
        };
        let groups: Vec<Value> = state
            .groups
            .iter()
            .filter(|g| id.is_none_or(|id| id == g.id))
            .map(|g| g.value(&session.id))
            .collect();
        if id.is_some() && groups.is_empty() {
            return Err(RpcError::not_found("not_found"));
        }
        Ok(
            json!({"groups":groups, "chatAllowance":{"active":state.chat_allowed,"expires":"session_stop_or_daemon_restart"},
            "coverage":{"label":"acp_requests_only","isolation":"unverified","detail":"Only requests delivered through ACP are covered; harness-native bypasses are outside this layer."},
            "batching":{"windowMs":100,"maxItems":MAX_ITEMS,"maxPendingGroups":MAX_GROUPS,"maxReceipts":MAX_GROUPS}}),
        )
    }

    pub(super) fn start_permission_group_timer(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: String,
    ) {
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            // Use the group's actual opening instant, not timer-task scheduling.
            let deadline = {
                let state = session.permissions.lock().unwrap();
                state.groups.iter().find(|g| g.id == id).map(|g| g.opened + WINDOW)
            };
            let Some(deadline) = deadline else { return };
            tokio::time::sleep_until(deadline.into()).await;
            // A request the agent sent with this group's first may still be
            // on its way here: it joins before the group is shown. Each one
            // lands within its own request task (no wait on a person); the
            // bound keeps a request task that is stuck (a re-adopted host
            // that stopped reading) from holding the group back.
            let _ = tokio::time::timeout(LANDING_BOUND, async {
                loop {
                    let landed = session.asks_landed.notified();
                    tokio::pin!(landed);
                    landed.as_mut().enable();
                    if session.asks_in_flight.load(Ordering::SeqCst) == 0 {
                        break;
                    }
                    landed.await;
                }
            })
            .await;
            let mut state = session.permissions.lock().unwrap();
            if let Some(g) = state.groups.iter_mut().find(|g| g.id == id && g.state == "collecting")
            {
                g.state = "pending";
                g.revision += 1;
                hub.append(
                    &session,
                    "mux",
                    "permission_group",
                    json!({"group":g.value(&session.id)}),
                );
            }
        });
    }

    pub async fn respond_permission_group(
        &self,
        session: &Session,
        params: Value,
        control: Control,
        person: bool,
    ) -> Result<Value, RpcError> {
        // The Web's asking rule, at the answer: a deny only narrows
        // (`Hub::web_answer_check`). A group allow carries no proof of the person's; an
        // approver's signature (below) is held to the Web's control rule like none.
        let narrows = params["decision"].as_str() == Some("deny");
        self.web_answer_check(session, control, narrows, false)?;
        let text = |key: &str| -> Result<String, RpcError> {
            params[key]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 256)
                .map(str::to_owned)
                .ok_or_else(|| {
                    RpcError::invalid_params(format!(
                        "{key} must be a nonempty string of at most 256 bytes"
                    ))
                })
        };
        let id = text("groupId")?;
        let key = text("decisionKey")?;
        let choice = text("decision")?;
        if !matches!(choice.as_str(), "allow_once" | "allow_chat" | "deny") {
            return Err(RpcError::invalid_params("unknown decision"));
        }
        // A Web answer allows once or denies: it never grants the chat.
        if control == Control::Web && choice == "allow_chat" {
            return Err(super::web_control::lasting_grant_refused("allow_chat"));
        }
        let revision = params["revision"]
            .as_u64()
            .ok_or_else(|| RpcError::invalid_params("revision is required"))?;
        let body = json!({"groupId":id,"revision":revision,"decisionKey":key,"decision":choice});
        let cfg = self.config.read().await;
        let mut state = session.permissions.lock().unwrap();
        // A decision key belongs to one body within this session.
        if let Some((previous, receipt)) = state
            .groups
            .iter()
            .filter_map(|g| g.receipt.as_ref())
            .find(|(b, _)| b["decisionKey"] == key)
        {
            if previous != &body {
                return Err(RpcError::invalid_params("key_conflict")
                    .with_data(json!({"reason":"key_conflict"})));
            }
            let mut result = receipt.clone();
            result.set("replayed", json!(true));
            return Ok(result);
        }
        let index = state
            .groups
            .iter()
            .position(|g| g.id == id)
            .ok_or_else(|| RpcError::not_found("not_found"))?;
        let g = &state.groups[index];
        let value = g.value(&session.id);
        if g.terminal() {
            return Err(conflict("already_resolved", value));
        }
        if g.state == "collecting" {
            return Err(conflict("collecting", value));
        }
        if g.revision != revision {
            return Err(conflict("stale_revision", value));
        }
        let meta = session.meta();
        let policy = self.policy_for(session, cfg.permission_policy);
        if choice != "deny"
            && (policy == PermissionPolicy::DenyAll
                || g.items.iter().filter(|i| i.state == "pending").any(|i| {
                    meta.permission_rules
                        .as_ref()
                        .and_then(|rules| super::rules::decide(rules, &i.request))
                        == Some(super::rules::RuleDecision::Deny)
                }))
        {
            return Err(conflict("policy_changed", value));
        }
        let mut answers = Vec::new();
        for item in g.items.iter().filter(|i| i.state == "pending") {
            let selected =
                option(&item.request, if choice == "deny" { "reject_once" } else { "allow_once" });
            if selected.is_none() && choice != "deny" {
                return Err(RpcError::invalid_params("no single-use allow option"));
            }
            if !state.pending.contains_key(&item.id) {
                return Err(conflict("stale_revision", value));
            }
            let outcome = selected.map_or_else(
                || json!({"outcome":"cancelled"}),
                |o| json!({"outcome":"selected","optionId":o}),
            );
            answers.push((item.id.clone(), outcome));
        }
        // The authoritative person rule (`person.rs`), here under the prompt state's lock and
        // before any member is answered: without the person, an allow counts only as an
        // enrolled approver's signed one-time allow of every pending member, never a chat grant.
        if !person
            && choice != "deny"
            && (choice != "allow_once"
                || !self.approver_spends_group(session, &state, &id, revision, &params))
        {
            return Err(super::person::person_required("allowing a permission group"));
        }
        let mut replies = Vec::new();
        for (id, outcome) in answers {
            if let Some(pending) = state.pending.remove(&id) {
                // Told to a later answer at once (`permission_settled.rs`), as one answer is.
                state.settled.remember(&id, None, &outcome);
                replies.push((id, pending.reply, outcome));
            }
        }
        if choice == "allow_chat" {
            state.chat_allowed = true;
            self.append(session, "mux", "permission_chat_allowance", json!({"active":true}));
        }
        let g = &mut state.groups[index];
        for item in &mut g.items {
            if item.state == "pending" {
                item.state = if replies
                    .iter()
                    .any(|(id, _, outcome)| id == &item.id && outcome["outcome"] == "cancelled")
                {
                    "cancelled"
                } else {
                    "resolved"
                };
            }
        }
        g.state = "resolved";
        g.revision += 1;
        // Include decision in the snapshot before storing the replay receipt.
        g.receipt = Some((body.clone(), Value::Null));
        let result = json!({"group":g.value(&session.id),"replayed":false});
        g.receipt = Some((body, result.clone()));
        self.append(session, "mux", "permission_group", json!({"group":result["group"]}));
        state.prune();
        // All callbacks were removed and the receipt saved before any wake.
        for (_, reply, outcome) in replies {
            let _ = reply.send(outcome);
        }
        Ok(result)
    }

    pub fn revoke_permission_chat(&self, session: &Session) -> Value {
        let mut state = session.permissions.lock().unwrap();
        if state.chat_allowed {
            state.chat_allowed = false;
            self.append(session, "mux", "permission_chat_allowance", json!({"active":false}));
        }
        json!({"active":false})
    }

    pub(super) fn permission_policy_changed(
        &self,
        session: &Session,
        change: impl FnOnce(&mut SessionMeta),
    ) {
        let mut state = session.permissions.lock().unwrap();
        change(&mut session.meta.lock().unwrap());
        state.chat_allowed = false;
        self.append(session, "mux", "permission_chat_allowance", json!({"active":false}));
        for g in state.groups.iter_mut().filter(|g| !g.terminal()) {
            g.revision += 1;
            self.append(session, "mux", "permission_group", json!({"group":g.value(&session.id)}));
        }
    }

    pub(crate) fn permission_defaults_changed(&self) {
        for session in self.sessions() {
            self.permission_policy_changed(&session, |_| {});
        }
    }
}

#[cfg(test)]
mod plain_tool_ask_tests {
    use super::plain_tool_ask;
    use serde_json::json;

    /// Full access answers a tool approval, never anything only a person answers.
    #[test]
    fn only_a_tool_approval_is_a_plain_tool_ask() {
        let ask = |tool: serde_json::Value| json!({"toolCall": tool, "options": []});
        assert!(plain_tool_ask(&ask(json!({"kind": "execute", "title": "rm -rf f/*"}))));
        assert!(plain_tool_ask(&ask(json!({"kind": "other", "title": "Allow network access"}))));
        for not_plain in [
            json!({"kind": "switch_mode", "title": "Ready to code?"}),
            json!({"kind": "other", "_meta": {"acpmux": {"trust": {"cwd": "/w"}}}}),
            json!({"kind": "other", "_meta": {"claude": {"tool": "AskUserQuestion"}}}),
            json!({"kind": "other", "_meta": {"claude": {"tool": "ExitPlanMode"}}}),
            json!({"kind": "execute", "_meta": {"claude": {"interactive": true}}}),
            // A Codex user-input request with no prompt text: no normalized question, still one.
            json!({"kind": "other", "rawInput": {"questions": [{"id": "q", "question": ""}]},
                   "_meta": {"codexAppServer": {"question": true}}}),
            json!({"kind": "other", "_meta": {"codexAppServer": {"question": true}}}),
            json!({"kind": "execute", "rawInput": {"questions": []}}),
        ] {
            assert!(!plain_tool_ask(&ask(not_plain.clone())), "{not_plain}");
        }
    }
}

#[cfg(test)]
mod approver_proofs_tests {
    use super::{PendingMember, allow_options, approver_proofs};
    use serde_json::{Value, json};

    fn member(id: &str, nonce: &str, kind: &str) -> PendingMember {
        PendingMember {
            id: id.into(),
            decision_nonce: nonce.into(),
            request: json!({"toolCall": {"toolCallId": id, "kind": "execute"},
                            "options": [{"optionId": format!("yes-{id}"), "kind": kind}]}),
        }
    }

    fn body(entries: Value) -> Value {
        json!({"_meta": {"acpmux": {"approverDecisions": entries}}})
    }

    fn entry(nonce: &str) -> Value {
        json!({"decisionNonce": nonce, "approverDecision": {"approver": "mac-1"}})
    }

    /// A group's signed allow names every pending member once, with its own nonce, and each
    /// member offers a single one-time allow; anything else matches nothing.
    #[test]
    fn every_pending_member_needs_its_own_entry_and_nothing_else() {
        let members = [member("p1", "n1", "allow_once"), member("p2", "n2", "allow_once")];
        let options = allow_options(&members).expect("each offers a one-time allow");
        let both = body(json!({"p1": entry("n1"), "p2": entry("n2")}));
        let proofs = approver_proofs(&members, &options, &both).expect("both members");
        assert_eq!(proofs.iter().map(|p| p.option).collect::<Vec<_>>(), ["yes-p1", "yes-p2"]);
        assert_eq!(proofs.iter().map(|p| p.nonce).collect::<Vec<_>>(), ["n1", "n2"]);
        assert!(proofs.iter().all(|p| p.answers.is_none()));
        for refused in [
            body(json!({"p1": entry("n1")})),
            body(json!({"p1": entry("n1"), "p2": entry("n1")})),
            body(json!({"p1": entry("n1"), "p3": entry("n2")})),
            body(json!({"p1": entry("n1"), "p2": entry("n2"), "p3": entry("n3")})),
            body(json!({"p1": entry("n1"), "p2": {"decisionNonce": "n2"}})),
            body(json!([])),
            json!({}),
        ] {
            assert!(approver_proofs(&members, &options, &refused).is_none(), "{refused}");
        }
        assert!(approver_proofs(&[], &[], &body(json!({}))).is_none());
        let lasting = [member("p1", "n1", "allow_always")];
        assert!(allow_options(&lasting).is_none());
    }
}
