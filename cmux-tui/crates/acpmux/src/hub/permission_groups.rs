//! Session-local permission batches. One lock owns membership, chat grants,
//! callbacks and receipts, so a decision cannot approve an unseen member.
use super::*;
use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const PERMISSION_GROUP_OPERATIONS: [&str; 3] = [
    method::MUX_PERMISSION_GROUPS,
    method::MUX_PERMISSION_GROUP_RESPOND,
    method::MUX_PERMISSION_CHAT_REVOKE,
];
const WINDOW: Duration = Duration::from_millis(100);
const MAX_ITEMS: usize = 32;
const MAX_GROUPS: usize = 64;

#[derive(Debug, Default)]
pub(super) struct PermissionState {
    pub pending: HashMap<String, PendingPermission>,
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
    let tool = &request["toolCall"];
    matches!(
        tool["kind"].as_str(),
        Some("read" | "search" | "edit" | "delete" | "move" | "execute" | "fetch" | "think")
    ) && request.get("interactive").and_then(Value::as_bool) != Some(true)
        && request.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) != Some(true)
        && tool.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) != Some(true)
        && tool.pointer("/_meta/claude/interactive").and_then(Value::as_bool) != Some(true)
        && !matches!(
            tool.pointer("/_meta/claude/tool").and_then(Value::as_str),
            Some("AskUserQuestion" | "ExitPlanMode")
        )
}

pub(super) fn option(request: &Value, kind: &str) -> Option<String> {
    request["options"].as_array()?.iter().find_map(|o| {
        (o["kind"] == kind)
            .then(|| o["optionId"].as_str().filter(|id| !id.is_empty()).map(str::to_owned))
            .flatten()
    })
}

impl Group {
    fn terminal(&self) -> bool {
        matches!(self.state, "resolved" | "cancelled")
    }

    fn value(&self, session_id: &str) -> Value {
        let can_allow = self
            .items
            .iter()
            .filter(|i| i.state == "pending")
            .all(|i| option(&i.request, "allow_once").is_some());
        json!({"groupId":self.id, "sessionId":session_id, "turnId":self.turn_id,
            "revision":self.revision, "state":self.state,
            "items":self.items.iter().map(|i| json!({"permissionId":i.id,"request":i.request,"state":i.state})).collect::<Vec<_>>(),
            "decisions":if can_allow {json!(["allow_once","allow_chat","deny"])} else {json!(["deny"])},
            "decision":self.receipt.as_ref().map(|(body,_)| body["decision"].clone())})
    }
}

impl PermissionState {
    // Returns the group id and whether a new timer is needed.
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
                && now.duration_since(g.opened) < WINDOW
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

fn conflict(reason: &str, group: Value) -> RpcError {
    RpcError::new(-32000, reason).with_data(json!({"reason":reason,"group":group}))
}

impl Hub {
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
    ) -> Result<Value, RpcError> {
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
            result["replayed"] = json!(true);
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
        let mut replies = Vec::new();
        for (id, outcome) in answers {
            if let Some(pending) = state.pending.remove(&id) {
                replies.push((pending.reply, outcome));
            }
        }
        if choice == "allow_chat" {
            state.chat_allowed = true;
            self.append(session, "mux", "permission_chat_allowance", json!({"active":true}));
        }
        let g = &mut state.groups[index];
        for item in &mut g.items {
            if item.state == "pending" {
                item.state = "resolved";
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
        for (reply, outcome) in replies {
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
#[path = "permission_groups/tests.rs"]
mod tests;
