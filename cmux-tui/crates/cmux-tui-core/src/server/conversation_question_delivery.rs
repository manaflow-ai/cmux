//! Delivery lifecycle: persist the intent before sending, then commit only an exact ACP receipt.
//! A retry queries the same receipt; it never reuses the person's proof or sends again.
use super::*;
use crate::conversation_store::OpOutcome;
use crate::conversation_store::deliveries::{
    DeliveryBinding, DeliveryClaim, DeliveryCompletion, DeliveryIntent, DeliveryResult,
};
use cmux_conversation::Op;
use std::sync::Arc;

#[allow(clippy::too_many_arguments)]
pub(in super::super) fn answer(
    mux: &Mux,
    client: u64,
    conversation: &str,
    key: &str,
    actor: &str,
    op: &Op,
    decision: Option<&Value>,
    transaction: &Option<Arc<str>>,
) -> anyhow::Result<OpOutcome> {
    let claim = mux.with_conversations(|store| {
        if let Some(existing) = store.lookup_question_delivery(conversation, key, actor, op)? {
            return Ok(existing);
        }
        let asked = match store.prepare_question_answer(conversation, key, actor, op)? {
            Ok(question) => question,
            Err(replay) => return Ok(DeliveryClaim::Finished(replay)),
        };
        // Decode and replace the temporary reservation under the same store lock.
        // A malformed proof must not leave a durable pending intent behind.
        let binding = (|| {
            if let Some(native) = decision.and_then(|d| d.get("native_record")) {
                if !super::super::super::origin_gate::is_user(mux, client)
                    || actor != crate::conversation_store::LOCAL_USER
                    || store.question_chief_author(conversation, op)?.is_none()
                {
                    Err(refuse("question.person_decision_required"))
                } else {
                    prepare_native(&asked, op, native)
                }
            } else {
                prepare(&asked, op, decision)
            }
        })();
        if let Some(message) = op.target_message_id() {
            store.release_question_answer(message);
        }
        store.claim_question_delivery(conversation, key, actor, op, &binding?)
    })?;
    let (intent, send) = match claim {
        DeliveryClaim::Finished(outcome) => return Ok(outcome),
        DeliveryClaim::Refused(reason) => return Err(refuse(&reason)),
        DeliveryClaim::Send(intent) => (intent, true),
        DeliveryClaim::Reconcile(intent) => (intent, false),
    };
    // No store/SQLite lock survives across these bounded network operations.
    let result = transport(mux, &intent, send.then_some(decision).flatten())?;
    let completion = mux.conversation_write(
        |store| store.finish_question_delivery(&intent.id, &intent.binding, result),
        |completion| {
            let DeliveryCompletion::Answered(outcome) = completion else { return None };
            if outcome.replayed {
                return None;
            }
            Some(super::super::MuxEvent::Conversation(Arc::new(
                crate::conversation_store::ConversationEvent::Changed {
                    conversation: intent.conversation.clone(),
                    rev: outcome.result.rev,
                    transaction: transaction.clone(),
                    change: outcome.result.change.clone(),
                },
            )))
        },
    )?;
    match completion {
        DeliveryCompletion::Answered(outcome) => Ok(outcome),
        DeliveryCompletion::Refused(reason) => Err(refuse(&reason)),
    }
}

fn prepare(question: &Question, op: &Op, value: Option<&Value>) -> anyhow::Result<DeliveryBinding> {
    let decision = decode(question, value)?;
    let Op::QuestionAnswer { answer, .. } = op else {
        return Err(refuse("question.invalid_answer"));
    };
    Ok(DeliveryBinding {
        session_id: local_session(&question.session)?,
        permission_id: question.permission.clone().ok_or_else(|| refuse("question.no_request"))?,
        instance: decision.instance,
        decision_nonce: decision.decision_nonce,
        request_digest: decision.digest,
        option_id: decision.option_id,
        answers_digest: digest(&encode_answers(question, answer)?),
        receipt_id: None,
    })
}

fn local_session(session: &str) -> anyhow::Result<String> {
    super::super::super::chief_question_routes::local_session_id(session)
        .map(str::to_owned)
        .ok_or_else(|| refuse("question.not_local"))
}

#[derive(Deserialize)]
// skew: strict person-proof receipt: an ignored field could pass an answer the person did not sign
#[serde(deny_unknown_fields)]
struct NativeRecord {
    question: Question,
    receipt_id: String,
    instance: String,
    decision_nonce: String,
}

fn prepare_native(question: &Question, op: &Op, value: &Value) -> anyhow::Result<DeliveryBinding> {
    let record: NativeRecord =
        serde_json::from_value(value.clone()).map_err(|_| refuse("question.invalid_receipt"))?;
    if record.question != *question
        || question.state != QuestionState::Pending
        || question.harness != QuestionHarness::Chief
        || question.items.len() != 1
        || record.instance.is_empty()
        || !hex64(&record.decision_nonce)
        || record.receipt_id.is_empty()
        || record.receipt_id.len() > 128
        || !record.receipt_id.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
    {
        return Err(refuse("question.stale"));
    }
    let item = &question.items[0];
    let expected = item
        .id
        .strip_prefix("approval:")
        .filter(|s| hex64(s))
        .ok_or_else(|| refuse("question.not_approval"))?;
    if item.multi_select
        || item.allows_other
        || item.options.len() != 2
        || item.options.iter().filter(|o| o.id == "allow").count() != 1
        || item.options.iter().filter(|o| o.id == "deny").count() != 1
    {
        return Err(refuse("question.not_approval"));
    }
    let preview = item
        .options
        .iter()
        .find(|o| o.id == "allow")
        .and_then(|o| o.preview.as_ref())
        .ok_or_else(|| refuse("question.not_approval"))?;
    let request: Value =
        serde_json::from_str(&preview.text).map_err(|_| refuse("question.not_approval"))?;
    if digest(&request) != expected
        || request.pointer("/toolCall/_meta/acpmux/question").is_some()
        || request.pointer("/toolCall/rawInput/tool").and_then(Value::as_str)
            == Some("AskUserQuestion")
        || request.pointer("/toolCall/title").and_then(Value::as_str) == Some("AskUserQuestion")
    {
        return Err(refuse("question.stale"));
    }
    let Op::QuestionAnswer { answer, .. } = op else {
        return Err(refuse("question.invalid_answer"));
    };
    let selected = answer
        .selections
        .get(&item.id)
        .filter(|s| s.option_ids.len() == 1 && s.other.is_none())
        .and_then(|s| s.option_ids.first())
        .ok_or_else(|| refuse("question.invalid_answer"))?;
    let kind = match selected.as_str() {
        "allow" => "allow_once",
        "deny" => "reject_once",
        _ => return Err(refuse("question.invalid_answer")),
    };
    let options = request["options"].as_array().ok_or_else(|| refuse("question.not_approval"))?;
    let choices: Vec<_> = options.iter().filter(|o| o["kind"] == kind).collect();
    if choices.len() != 1 {
        return Err(refuse("question.stale"));
    }
    let option_id = choices[0]["optionId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| refuse("question.stale"))?;
    if options.iter().filter(|o| o["optionId"] == option_id).count() != 1 {
        return Err(refuse("question.stale"));
    }
    Ok(DeliveryBinding {
        session_id: local_session(&question.session)?,
        permission_id: question.permission.clone().ok_or_else(|| refuse("question.no_request"))?,
        instance: record.instance,
        decision_nonce: record.decision_nonce,
        request_digest: expected.into(),
        option_id: option_id.into(),
        answers_digest: String::new(),
        receipt_id: Some(record.receipt_id),
    })
}

fn receipt_id(intent: &DeliveryIntent) -> &str {
    intent.binding.receipt_id.as_deref().unwrap_or(&intent.id)
}

fn attempt(intent: &DeliveryIntent) -> Value {
    let b = &intent.binding;
    json!({"id":receipt_id(intent), "instance":b.instance, "decisionNonce":b.decision_nonce,
        "requestDigest":b.request_digest, "answersDigest":b.answers_digest})
}

fn receipt(intent: &DeliveryIntent, info: &Value) -> anyhow::Result<DeliveryResult> {
    let row = &info["deliveryAttempt"];
    let b = &intent.binding;
    // Missing, expired, old-version and mismatched evidence are all indeterminate.
    if row["id"] != receipt_id(intent)
        || row["instance"] != b.instance
        || row["decisionNonce"] != b.decision_nonce
        || row["requestDigest"] != b.request_digest
        || row["answersDigest"] != b.answers_digest
        || row["annotationsDigest"] != ""
        || row["session"] != b.session_id
        || row["permission"] != b.permission_id
        || row["option"] != b.option_id
    {
        return Err(refuse("question.delivery_unknown"));
    }
    match row["state"].as_str() {
        Some("delivered") => Ok(DeliveryResult::Delivered),
        Some("refused") if row["reason"] == "agent_gone" => {
            Ok(DeliveryResult::Refused("question.agent_gone".into()))
        }
        _ => Err(refuse("question.delivery_unknown")),
    }
}

fn transport(
    mux: &Mux,
    intent: &DeliveryIntent,
    decision: Option<&Value>,
) -> anyhow::Result<DeliveryResult> {
    use super::super::super::chief_question_routes as routes;
    use std::time::Instant;
    let chief = mux.with_conversations(|store| {
        store.question_chief_author(&intent.conversation, &intent.op)
    })?;
    let resolved = chief
        .as_deref()
        .map(|chief| routes::resolve(mux, chief))
        .transpose()
        .map_err(|_| refuse("question.delivery_unknown"))?;
    let sockets = resolved
        .as_ref()
        .map(|r| r.candidates.clone())
        .unwrap_or_else(|| mux.control_clients.agent_sessions.socket().into_iter().collect());
    let deadline = Instant::now() + Duration::from_secs(15);
    for socket in sockets {
        // connect itself has a three-second bound; do not start it past the shared budget.
        if deadline.saturating_duration_since(Instant::now()) < TIMEOUT {
            break;
        }
        let Ok(link) = AcpmuxLink::connect(&socket, |_| {}) else { continue };
        let call = |method: &str, params: Value| {
            use super::super::super::agent_session_attach::agent_session_link::LinkError;
            let remaining = deadline.saturating_duration_since(Instant::now()).min(TIMEOUT);
            if remaining.is_zero() {
                return Err(refuse("question.delivery_unknown"));
            }
            link.call_until(method, params, deadline.min(Instant::now() + remaining)).map_err(
                |error| {
                    let reason = match error {
                        LinkError::Rpc(_, data) => match data.get("reason").and_then(Value::as_str)
                        {
                            Some("agent_gone") => "question.agent_gone",
                            Some("permission.person_required") => {
                                "question.person_decision_required"
                            }
                            Some("question.stale") => "question.stale",
                            Some("policy_changed") => "question.refused",
                            _ => "question.delivery_unknown",
                        },
                        _ => "question.delivery_unknown",
                    };
                    refuse(reason)
                },
            )
        };
        // A successful read on one configured socket does not imply session ownership.
        let found = (|| -> anyhow::Result<bool> {
            call("initialize", json!({"protocolVersion":1,
                "clientInfo":{"name":"cmux-home-question","version":"1"},"clientCapabilities":{}}))?;
            let info = call("_acpmux/info", json!({"sessionId":format!("local/{}", intent.binding.session_id), "waitLogs":false}))?;
            if info["sessionId"] != intent.binding.session_id
                || !info.get("peer").is_none_or(Value::is_null) {
                return Ok(false);
            }
            if intent.binding.receipt_id.is_some() {
                return Ok(resolved.as_ref().is_some_and(|r|
                    routes::is_owner_subagent(&info, &intent.binding.session_id, &r.chief_home_id)));
            }
            Ok(true)
        })().unwrap_or(false);
        if !found {
            link.close();
            continue;
        }
        // With a fresh decision this is the sole selected route; after this point never
        // try sending on another socket, even when the acknowledgement is lost.
        let result = exchange(intent, decision, |method, params| {
            if method == "initialize" {
                return Ok(json!({}));
            }
            call(method, params)
        });
        link.close();
        if decision.is_some() || result.is_ok() {
            return result;
        }
        // Query-only recovery may search the remaining trusted environments.
    }
    if decision.is_some() {
        Ok(DeliveryResult::Refused("question.agent_unavailable".into()))
    } else {
        Err(refuse("question.delivery_unknown"))
    }
}

fn exchange(
    intent: &DeliveryIntent,
    decision: Option<&Value>,
    mut call: impl FnMut(&str, Value) -> anyhow::Result<Value>,
) -> anyhow::Result<DeliveryResult> {
    if let Some(value) = decision {
        let decoded = decode(&intent.question, Some(value))?;
        let Op::QuestionAnswer { answer, .. } = &intent.op else {
            return Err(refuse("question.invalid_answer"));
        };
        let mut submitted = false;
        let sent = deliver_with(&intent.question, answer, &decoded, |method, mut params| {
            if method == "_acpmux/info" || method == "_acpmux/permission_respond" {
                params["sessionId"] = json!(format!("local/{}", intent.binding.session_id));
            }
            if method == "_acpmux/permission_respond" {
                params
                    .as_object_mut()
                    .ok_or_else(|| refuse("question.invalid_answer"))?
                    .insert("deliveryAttempt".into(), attempt(intent));
                submitted = true;
            }
            call(method, params)
        });
        if let Err(error) = sent {
            // Explicit rejection before delivery is safe to retain. Transport loss after
            // submission is never evidence that the agent is gone or the answer failed.
            if let Some(refusal) = error.downcast_ref::<Refusal>()
                && refusal.0 != "question.delivery_unknown"
            {
                return Ok(DeliveryResult::Refused(refusal.0.clone()));
            }
            if !submitted {
                return Ok(DeliveryResult::Refused("question.agent_unavailable".into()));
            }
        }
    } else {
        call(
            "initialize",
            json!({"protocolVersion":1,
            "clientInfo":{"name":"cmux-home-question","version":"1"},"clientCapabilities":{}}),
        )?;
    }
    let info = call(
        "_acpmux/info",
        json!({"sessionId":format!("local/{}", intent.binding.session_id),
        "deliveryAttempt":receipt_id(intent)}),
    )?;
    receipt(intent, &info)
}

#[cfg(test)]
#[path = "conversation_question_delivery_tests.rs"]
mod tests;
