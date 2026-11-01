//! Pending prompt identities remain owned by the session until they settle.

use super::{Hub, PromptOutcome, Session};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::Digest;
use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

/// Settles a restored prompt's outcome once: the first settled answer stays (a decline before its
/// restored task claimed it, `queue_approve.rs`, is never replaced by that task's `withdrawn`).
pub(super) fn settle_once(outcome: &PromptOutcome, answer: Result<Value, crate::rpc::RpcError>) {
    outcome.send_if_modified(|settled| settled.is_none() && settled.replace(answer).is_none());
}

/// An adopted turn owns its prompt id until its real answer arrives. A resend then joins
/// this pending outcome instead of interpreting the open journal turn as interrupted.
pub(super) fn recover(session: &Session, prompt_id: &str) -> PromptOutcome {
    let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, outcome)) = ledger.iter().find(|(id, _)| id == prompt_id) {
        return outcome.clone();
    }
    let outcome = Arc::new(tokio::sync::watch::channel(None).0);
    ledger.push_back((prompt_id.to_owned(), outcome.clone()));
    outcome
}

/// Only completed outcomes count against the retry cache's bound. Pending senders
/// must stay discoverable, including restored prompts whose completion looks them up.
pub(super) fn prune(ledger: &mut VecDeque<(String, PromptOutcome)>) {
    const COMPLETED_OUTCOMES: usize = 64;
    let mut excess = ledger
        .iter()
        .filter(|(_, outcome)| outcome.borrow().is_some())
        .count()
        .saturating_sub(COMPLETED_OUTCOMES);
    if excess == 0 {
        return;
    }
    ledger.retain(|(_, outcome)| {
        if excess > 0 && outcome.borrow().is_some() {
            excess -= 1;
            false
        } else {
            true
        }
    });
}

impl Hub {
    /// Whether session `session`'s log records a turn that ran `prompt_id` (its `user_message`,
    /// alone or joined with other agent messages, `digest.rs`). Blocking: it reads the log.
    pub(crate) fn ran_prompt(&self, session: &str, prompt_id: &str) -> bool {
        let names = |m: &Value| m.get("promptId").and_then(Value::as_str) == Some(prompt_id);
        let mut ran = false;
        let _ = self.store.scan_kinds(session, &["user_message"], &mut |rec| {
            let joined = rec.msg.pointer("/_meta/provenance/messages").and_then(Value::as_array);
            ran = names(&rec.msg) || joined.is_some_and(|m| m.iter().any(names));
            !ran
        });
        ran
    }

    /// Whether session `session` took prompt `prompt_id` already: its ledger holds it, or, for a
    /// `resend`, its log does (`requests.rs`: a resend whose uploads are gone still answers with
    /// its first run). Blocking: it may read the log.
    pub fn knows_prompt(&self, session: &Session, prompt_id: &str, resend: bool) -> bool {
        let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let held = ledger.iter().any(|(id, _)| id == prompt_id);
        drop(ledger);
        held || (resend && self.logged_prompt(session, prompt_id).is_some())
    }

    /// Read one trigger delivery from the durable event log. This deliberately does not use
    /// `lastTurn` or the live preview: another human turn may have advanced those fields.
    pub(crate) fn trigger_delivery(&self, session: &Session, delivery: &str) -> Value {
        const MAX_REPLY: usize = 16 * 1024;
        let mut turn_id = None::<String>;
        let mut result = None::<Value>;
        let mut state = "unknown";
        let mut reply = String::new();
        let mut reply_chars = 0;
        let mut reply_open = false;
        let mut active = false;
        let mut started = false;
        let mut settled = false;
        let mut closed_window = false;
        let mut prompt_hash = None::<String>;
        let mut permissions = HashSet::<String>::new();
        let scanned = self.store.scan_strict(&session.id, 0, &mut |rec| {
            let field = |key: &str| rec.msg.get(key).and_then(Value::as_str);
            let mux = rec.dir == "mux";
            // Only daemon-authored admission records bind a delivery. A human prompt
            // or a harness event can reuse its promptId, but grants no trigger authority.
            if mux && matches!(rec.kind.as_str(), "queued" | "user_message")
                && field("promptId") == Some(delivery)
            {
                let provenance = crate::prompt_provenance::recorded(&rec.msg);
                let trusted = provenance.as_ref().is_some_and(|p| {
                    p.get("kind").and_then(Value::as_str) == Some("trigger")
                        && p.get("deliveryId").and_then(Value::as_str) == Some(delivery)
                        && p.get("session").and_then(Value::as_str) == Some(session.id.as_str())
                        && crate::prompt_provenance::of(
                            &json!({"_meta": {"acpmux": {"provenance": p}}}),
                            crate::prompt_provenance::Sender::Trigger,
                        ).is_ok()
                });
                if !started && result.is_none() && trusted {
                    if let (Some(id), Some(text)) = (field("turnId"), field("text")) {
                        let hash = format!("{:x}", sha2::Sha256::digest(text.as_bytes()));
                        if prompt_hash.as_ref().is_some_and(|prior| prior != &hash) {
                            state = "failed";
                            result = Some(json!({"status": "failed", "error": "trigger prompt changed after admission"}));
                            return false;
                        }
                        prompt_hash = Some(hash);
                        turn_id = Some(id.to_owned());
                        state = "queued";
                    }
                } else if !started && turn_id.is_some() && !trusted {
                    // A person's queue edit drops the trigger provenance. Do not
                    // attribute the edited prompt's output to the original delivery.
                    state = "failed";
                    result = Some(json!({"status": "failed", "error": "trigger prompt ownership changed"}));
                    return false;
                }
            }
            let Some(id) = turn_id.as_deref() else { return true };
            let exact = field("turnId") == Some(id);
            if mux && rec.kind == "queue_updated" && field("promptId") == Some(delivery) {
                state = "failed";
                result = Some(json!({"status": "failed", "error": "trigger prompt was edited"}));
                return false;
            }
            if mux && rec.kind == "permission_decision"
                && let Some(permission) = field("permissionId")
            {
                // Decisions omit turnId. Only IDs established by this exact turn's
                // request may settle its attention, even after another turn starts.
                permissions.remove(permission);
            }
            if closed_window { return true; }
            if mux && rec.kind == "turn_started" {
                if started && !exact {
                    active = false;
                    closed_window = true;
                    if !settled {
                        state = "failed";
                        result = Some(json!({"status": "interrupted", "turnId": id}));
                    }
                    return true;
                }
                if exact && field("promptId") == Some(delivery) && rec.msg.get("trigger").and_then(Value::as_bool) == Some(true)
                    && result.is_none()
                {
                    active = true;
                    started = true;
                    state = "running";
                } else if exact && !started {
                    state = "failed";
                    result = Some(json!({"status": "failed", "error": "trigger turn ownership changed"}));
                    return false;
                }
            }
            if mux && matches!(rec.kind.as_str(), "permission_request" | "permission_reissued")
                && exact
                && let Some(permission) = field("permissionId")
            {
                permissions.insert(permission.to_owned());
            }
            if active && rec.dir == "in"
                && rec.msg.get("method").and_then(Value::as_str) == Some("session/update")
                && rec.msg.pointer("/params/_meta/acpmux/subagent").is_none()
                && field("turnId").is_none_or(|turn| turn == id)
            {
                match rec.kind.as_str() {
                    "agent_message_chunk" if rec.msg.pointer("/params/update/sessionUpdate")
                        .and_then(Value::as_str) == Some("agent_message_chunk") => {
                        if let Some(text) = rec.msg.pointer("/params/update/content/text").and_then(Value::as_str) {
                            if !reply_open {
                                reply.clear();
                                reply_chars = 0;
                                reply_open = true;
                            }
                            let chunk: String = text.chars().take(MAX_REPLY.saturating_sub(reply_chars)).collect();
                            reply_chars += chunk.chars().count();
                            reply.push_str(&chunk);
                        }
                    }
                    "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => reply_open = false,
                    _ => {}
                }
            }
            if mux && exact && !settled {
                match rec.kind.as_str() {
                    "turn_end" | "turn_error" => {
                        active = false;
                        state = if rec.kind == "turn_error" { "failed" } else { "running" };
                        result = Some(rec.msg.clone());
                        // turn_result follows and carries the authoritative status;
                        // do not mistake turn_error (which has no status) for success.
                    }
                    "turn_result" => {
                        active = false;
                        settled = true;
                        state = match field("status") {
                            Some("completed") => "completed",
                            Some("attention" | "input_required" | "waiting") => "attention",
                            _ => "failed",
                        };
                        result = Some(rec.msg.clone());
                    }
                    "queue_removed" | "prompt_refused" | "turn_stop_requested" => {
                        active = false;
                        // A stop request may still receive its authoritative result.
                        settled = rec.kind != "turn_stop_requested";
                        state = "failed";
                        result = Some(rec.msg.clone());
                    }
                    _ => {}
                }
            }
            true
        });
        if scanned.is_err() {
            // A partial journal is not evidence of completion or of a safe resend.
            return json!({"delivery": delivery, "state": "failed", "error": "trigger delivery journal could not be read"});
        }
        if !permissions.is_empty() {
            state = "attention";
        }
        let mut out = json!({"delivery": delivery, "state": state});
        if let Some(id) = turn_id {
            out.set("turnId", json!(id));
        }
        if let Some(hash) = prompt_hash {
            out.set("promptHash", json!(hash));
        }
        if let Some(result) = result {
            out.set("result", result);
        }
        if !permissions.is_empty() {
            out.set("pendingPermissions", json!(permissions.len()));
        }
        if !reply.is_empty() {
            out.set("reply", json!(reply));
        }
        out
    }

    /// A prompt id the session's log already holds (`user_message` or
    /// `queued`), answered from the log: its turn's result when it ended,
    /// else `interrupted` (the daemon stopped during the turn). A durable decline remains
    /// an error after restart or eviction from the bounded in-memory outcome ledger.
    pub(super) fn logged_prompt(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<Result<Value, crate::rpc::RpcError>> {
        // Another agent's message the inbox took (`inbox.rs`): answered from its records.
        if let Some(inbox) = self.logged_inbox(session, prompt_id) {
            return Some(Ok(inbox));
        }
        // The last completed turn may predate a later queued/declined incarnation reusing
        // this client id. Reconstruct the latest incarnation from its ordered durable records.
        let mut turn_id: Option<String> = None;
        let mut stopped_turns = HashSet::new();
        let mut started = false;
        let mut ended: Option<Value> = None;
        // The owner declined it (`queue_approve.rs`): its resend is told so, after a restart too.
        let mut declined = false;
        // The inbox digest that took it, once one did (`inbox_digest.rs`). Its turn is the
        // digest's only once the digest's turn starts: one that never did gave it back.
        let mut digest: Option<String> = None;
        let _ = self.store.scan(&session.id, 0, &mut |rec| {
            let field = |k: &str| rec.msg.get(k).and_then(Value::as_str);
            // Admission installs the live turn before user_message is durable. Stop can
            // therefore be journaled before we learn which turn owns this prompt.
            if rec.kind == "turn_stop_requested"
                && let Some(id) = rec.msg.get("turnId").and_then(Value::as_str)
            {
                stopped_turns.insert(id.to_owned());
                // New Stop records name the accepted prompt even if the daemon died
                // before writing any user_message. Older records still join by turn ID.
                if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                    && !started
                    && ended.is_none()
                {
                    turn_id = Some(id.to_owned());
                }
            }
            match (rec.kind.as_str(), &turn_id) {
                // Put back after the turn it joined failed (`digest.rs` `requeue_joined`): it
                // waits again under its own turn id. Ahead of the arm below, which would take
                // the record too and keep the refused digest this prompt's.
                ("queued", Some(_))
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                        && rec.msg.get("requeued") == Some(&Value::Bool(true)) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    started = false;
                    ended = None;
                    declined = false;
                    // Out of an inbox digest that failed too (`inbox_digest.rs`).
                    digest = None;
                }
                ("user_message" | "queued", _)
                    if !started
                        && ended.is_none()
                        && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    // An earlier message may be an orphan from a crash before admission.
                    // Follow this ID's later resend to the turn that actually ran it.
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    // A steer is accepted into an already-running parent turn and
                    // therefore has no turn_started of its own. Its user_message is
                    // the durable execution record for duplicate suppression.
                    started |= rec.msg.get("steer") == Some(&Value::Bool(true));
                }
                // A new incarnation under its client-chosen id, once the last one ran or left the
                // queue (a daemon whose ledger forgot it took the id as new): its records are this
                // prompt's now, so a decline of the new one is the answer (`queue_approve.rs`).
                ("queued", Some(_))
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    started = false;
                    ended = None;
                    declined = false;
                    digest = None;
                }
                ("turn_started", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    started = true;
                }
                // Read on: a failed turn of agent messages may put it back (`requeued` below).
                ("turn_result", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    ended = Some(rec.msg);
                }
                ("turn_stop_requested", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    // Stop may precede turn_started while a retry waits for startup.
                    // Its message is no longer an eligible orphan: cancellation consumed
                    // the prompt even though the harness never received it. Keep scanning
                    // so an eventual result can provide the final outcome.
                    ended = Some(json!({"stopReason": "cancelled", "status": "cancelled"}));
                }
                ("queue_declined" | "queue_removed", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    // Withdrawal is a terminal outcome even when the prompt never
                    // reached turn_started. A resend must return cancellation, or the decline.
                    // Read on: a later incarnation may reuse its id (above).
                    declined |= rec.kind == "queue_declined"
                        || rec.msg.get("reason").and_then(Value::as_str) == Some("declined");
                    started = true;
                    ended = Some(json!({"stopReason": "cancelled", "status": "withdrawn"}));
                }
                // It went in with an earlier agent message's turn (`digest.rs`): that turn's.
                ("dequeued", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get("joinedTurnId").is_some_and(Value::is_string) =>
                {
                    turn_id = rec.msg["joinedTurnId"].as_str().map(str::to_owned);
                    // Joined prompts run inside the existing turn and therefore do not
                    // receive their own turn_started record.
                    started = true;
                }
                // Taken into an inbox digest (`inbox_digest.rs`): its `dequeued` record names it,
                // and so does the digest's own `queued` record, logged first.
                ("dequeued", Some(id))
                    if field("turnId") == Some(id.as_str())
                        && field("digestPromptId").is_some() =>
                {
                    digest = field("digestPromptId").map(str::to_owned);
                }
                ("queued", Some(_))
                    if digest.is_none()
                        && super::digest::inbox_digest::took(&rec.msg)
                            .iter()
                            .any(|id| id == prompt_id) =>
                {
                    digest = field("promptId").map(str::to_owned);
                }
                // The digest it went into was withdrawn before its turn: so was it.
                ("queue_removed", Some(_))
                    if digest.is_some() && field("promptId") == digest.as_deref() =>
                {
                    ended = Some(json!({"stopReason": "cancelled", "status": "withdrawn"}));
                    return false;
                }
                // The digest's turn started, as the queue's restore reads it (`queue_waiting.rs`
                // `Digests`): its `turn_started`, or its steer's `user_message` (a steer goes into
                // the turn that ran then). That turn is this prompt's.
                ("turn_started", Some(_))
                    if digest.is_some() && field("promptId") == digest.as_deref() =>
                {
                    turn_id = field("turnId").map(str::to_owned);
                    started = true;
                    ended = None;
                }
                ("user_message", Some(_))
                    if digest.is_some()
                        && field("promptId") == digest.as_deref()
                        && rec.msg.get("steer") == Some(&Value::Bool(true)) =>
                {
                    turn_id = field("turnId").map(str::to_owned);
                    started = true;
                    ended = None;
                }
                _ => {}
            }
            if ended.is_none() && turn_id.as_ref().is_some_and(|id| stopped_turns.contains(id)) {
                ended = Some(json!({"stopReason": "cancelled", "status": "cancelled"}));
            }
            true
        });
        let turn_id = turn_id?;
        if declined {
            return Some(Err(super::queue::declined_error(prompt_id, &turn_id)));
        }
        // A user_message is written before turn_started. A crash in that interval leaves a
        // prompt that has not run and must remain eligible for recovery/resend.
        if !started && ended.is_none() {
            return None;
        }
        let status = ended
            .as_ref()
            .and_then(|e| e.get("status").cloned())
            .unwrap_or_else(|| json!("interrupted"));
        Some(Ok(json!({
            "stopReason": ended.as_ref().and_then(|e| e.get("stopReason").cloned()).unwrap_or(Value::Null),
            "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "status": status, "duplicate": true}},
        })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    #[tokio::test]
    async fn durable_prompt_admission_and_terminal_records_suppress_only_consumed_prompts() {
        // Records are in crash order. A plain user_message precedes admission, whereas
        // steer and joined messages use an existing turn. Withdrawal consumes an ID
        // without admission. These distinctions must survive an empty in-memory ledger.
        for (point, expected_status) in [
            ("message", None),
            ("queued", None),
            ("started", Some("interrupted")),
            ("steer", Some("interrupted")),
            ("joined", Some("interrupted")),
            ("withdrawn", Some("withdrawn")),
            ("stopped_before_start", Some("cancelled")),
            ("stopped_before_message", Some("cancelled")),
            ("stopped_without_message", Some("cancelled")),
            ("orphan_stopped_without_message", Some("cancelled")),
            ("unrelated_stop_before_message", None),
            ("stopped_then_result", Some("failed")),
            ("completed", Some("completed")),
            ("orphan_resend", Some("completed")),
            ("orphan_steer", Some("interrupted")),
            ("requeued", None),
        ] {
            let mut cfg = crate::config::Config::default();
            cfg.store.mode = crate::config::StoreMode::Memory;
            let store =
                crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
            store.save(&serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": "ledger", "name": "ledger",
                "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
            })).unwrap()).unwrap();
            let hub = Hub::new(cfg, store);
            let session = hub.resolve("ledger").unwrap();
            if point == "stopped_before_message" {
                hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "t"}));
            }
            // A later cancellation of another turn must neither replace nor create
            // cancellation for the prompt we are looking up.
            hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "unrelated"}));
            let queued = ["queued", "joined", "withdrawn"].contains(&point);
            if point == "orphan_stopped_without_message" {
                hub.append(
                    &session,
                    "in",
                    "user_message",
                    json!({"turnId": "orphan", "promptId": "p"}),
                );
            }
            if ["stopped_without_message", "orphan_stopped_without_message"].contains(&point) {
                hub.append(
                    &session,
                    "mux",
                    "turn_stop_requested",
                    json!({"turnId": "t", "promptId": "p"}),
                );
            } else {
                hub.append(
                &session,
                "in",
                if queued { "queued" } else { "user_message" },
                json!({"promptId": "p", "turnId": "t", "steer": point == "steer", "text": "hello"}),
            );
            }
            if ["started", "completed", "requeued"].contains(&point) {
                hub.append(
                    &session,
                    "mux",
                    "turn_started",
                    json!({"promptId": "p", "turnId": "t"}),
                );
            }
            match point {
                "stopped_before_start" | "stopped_then_result" => {
                    hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "t"}));
                    if point == "stopped_then_result" {
                        hub.append(
                            &session,
                            "mux",
                            "turn_result",
                            json!({
                                "turnId": "t", "status": "failed", "stopReason": "cancelled"
                            }),
                        );
                    }
                }
                "joined" => {
                    hub.append(
                        &session,
                        "mux",
                        "dequeued",
                        json!({"promptId": "p", "turnId": "t", "joinedTurnId": "head"}),
                    );
                    hub.append(
                        &session,
                        "mux",
                        "turn_started",
                        json!({"promptId": "digest-head", "turnId": "head"}),
                    );
                }
                "withdrawn" => {
                    hub.append(
                        &session,
                        "mux",
                        "queue_removed",
                        json!({"promptId": "p", "turnId": "t"}),
                    );
                }
                "completed" => {
                    hub.append(
                        &session,
                        "mux",
                        "turn_result",
                        json!({"turnId": "t", "status": "completed", "stopReason": "end_turn"}),
                    );
                }
                "orphan_resend" | "orphan_steer" => {
                    hub.append(
                        &session,
                        "in",
                        "user_message",
                        json!({
                            "promptId": "p", "turnId": "actual", "steer": point == "orphan_steer"
                        }),
                    );
                    if point == "orphan_resend" {
                        hub.append(
                            &session,
                            "mux",
                            "turn_started",
                            json!({"promptId": "p", "turnId": "actual"}),
                        );
                        hub.append(
                            &session,
                            "mux",
                            "turn_result",
                            json!({"promptId": "p", "turnId": "actual", "status": "completed"}),
                        );
                    }
                    // The result cannot come from lastTurn's shortcut or the live ledger.
                    session.meta.lock().unwrap().last_turn = Some(json!({
                        "promptId": "different", "turnId": "newer", "status": "completed"
                    }));
                }
                "requeued" => {
                    hub.append(
                        &session,
                        "mux",
                        "turn_result",
                        json!({"turnId": "t", "status": "failed"}),
                    );
                    hub.append(
                        &session,
                        "mux",
                        "queued",
                        json!({"promptId": "p", "turnId": "again", "requeued": true}),
                    );
                }
                _ => {}
            }
            assert!(session.prompts.lock().unwrap().is_empty());
            let logged = hub.logged_prompt(&session, "p").map(|l| l.unwrap());
            assert_eq!(
                logged
                    .as_ref()
                    .and_then(|v| v.pointer("/_meta/acpmux/status"))
                    .and_then(Value::as_str),
                expected_status,
                "crash after {point}: {logged:?}"
            );
            assert_eq!(
                hub.knows_prompt(&session, "p", true),
                expected_status.is_some(),
                "resend after {point}"
            );
            if ["orphan_resend", "orphan_steer"].contains(&point) {
                assert_eq!(logged.unwrap()["_meta"]["acpmux"]["turnId"], "actual");
            }
        }
    }

    /// A message an inbox digest took, put back when the digest was refused before its turn,
    /// then run on its own turn: a resend answers from that turn, not as withdrawn with the
    /// digest whose removal is logged after the message went back (`inbox_digest.rs`).
    #[tokio::test]
    async fn a_message_a_refused_digest_put_back_answers_from_its_own_turn() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        store.save(&serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "ledger", "name": "ledger",
            "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
        })).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("ledger").unwrap();
        let digest = json!({"promptId": "d", "turnId": "td", "took": [{"promptId": "p"}],
            "_meta": {"provenance": {"kind": crate::hub::digest::inbox_digest::KIND}}});
        for (kind, msg) in [
            ("queued", json!({"promptId": "p", "turnId": "t"})),
            ("queued", digest),
            ("dequeued", json!({"promptId": "p", "turnId": "t", "digestPromptId": "d"})),
            ("prompt_refused", json!({"promptId": "d", "turnId": "td"})),
            ("queued", json!({"promptId": "p", "turnId": "back", "requeued": true})),
            ("queue_removed", json!({"promptId": "d", "turnId": "td"})),
            ("turn_started", json!({"promptId": "p", "turnId": "back"})),
            (
                "turn_result",
                json!({"turnId": "back", "status": "completed", "stopReason": "end_turn"}),
            ),
        ] {
            hub.append(&session, "mux", kind, msg);
        }
        let logged = hub.logged_prompt(&session, "p").unwrap().unwrap();
        assert_eq!(logged["_meta"]["acpmux"]["status"], "completed", "{logged}");
        assert_eq!(logged["_meta"]["acpmux"]["turnId"], "back", "{logged}");
        assert_eq!(logged["stopReason"], "end_turn", "{logged}");
    }

    #[test]
    fn prompt_ledger_keeps_pending_and_bounds_completed_outcomes_as_they_settle() {
        let outcomes: Vec<PromptOutcome> =
            (0..130).map(|_| Arc::new(tokio::sync::watch::channel(None).0)).collect();
        let mut ledger: VecDeque<_> = outcomes
            .iter()
            .enumerate()
            .map(|(i, outcome)| (i.to_string(), outcome.clone()))
            .collect();
        prune(&mut ledger);
        assert_eq!(ledger.len(), 130, "pending prompts were evicted");

        // Settle newer prompts first: pending entries at the front must not be evicted.
        for i in (0..130).rev() {
            outcomes[i].send_replace(Some(Ok(json!({"promptId": i}))));
            prune(&mut ledger);
            let pending = i;
            let completed = (130 - i).min(64);
            assert_eq!(ledger.len(), pending + completed, "settled prompt {i}");
            let ids: Vec<_> = ledger.iter().map(|(id, _)| id.parse::<usize>().unwrap()).collect();
            let expected: Vec<_> = (0..pending).chain((130 - completed)..130).collect();
            assert_eq!(ids, expected, "pruning changed pending or recent completed identities");
        }
    }
}

#[cfg(test)]
#[path = "trigger_delivery_tests.rs"]
mod trigger_delivery_tests;
