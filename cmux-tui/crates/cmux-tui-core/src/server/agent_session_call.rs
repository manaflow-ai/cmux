use super::*;

pub(super) fn call(
    attachment: &Attachment,
    command: AgentSessionCommand,
) -> Result<Value, Refused> {
    let session = attachment.session.as_str();
    let answer: Result<Value, Refusal> = match command {
        AgentSessionCommand::Attach(params) => {
            let newest_first = params.after_seq.is_none() || params.before_seq.is_some();
            let mut params = page_params(session, &params, true)?;
            if attachment.author.is_some() {
                teammate_kinds(&mut params);
            }
            let page =
                attachment.link.call("_acpmux/attach", attachment.stamp(params), CALL_TIMEOUT);
            page.map_err(Refusal::of)
                .and_then(|page| attachment.private(bound_page(page, newest_first)))
        }
        AgentSessionCommand::Events(params) => {
            let newest_first = params.before_seq.is_some();
            let mut params = page_params(session, &params, false)?;
            if attachment.author.is_some() {
                teammate_kinds(&mut params);
            }
            let page =
                attachment.link.call("_acpmux/events", attachment.stamp(params), CALL_TIMEOUT);
            page.map_err(Refusal::of)
                .and_then(|page| attachment.private(bound_page(page, newest_first)))
        }
        AgentSessionCommand::Prompt(PromptParams { prompt_id, text, content, steer, .. }) => {
            return prompt(attachment, prompt_id, text, content, steer);
        }
        AgentSessionCommand::QueueApprove(QueueDecisionParams {
            prompt_id,
            turn_id,
            revision,
            ..
        }) => {
            let (Some(turn_id), Some(revision)) = (turn_id, revision) else {
                return Err(Refusal::BadRequest.into());
            };
            if !valid_prompt_id(&prompt_id) || turn_id.is_empty() || turn_id.len() > 128 {
                return Err(Refusal::BadRequest.into());
            }
            let params = json!({"sessionId": session, "promptId": prompt_id, "turnId": turn_id,
                "revision": revision});
            attachment.link.call("_acpmux/queue_approve", params, CALL_TIMEOUT).map_err(Refusal::of)
        }
        AgentSessionCommand::QueueDecline(QueueDecisionParams { prompt_id, .. }) => {
            if !valid_prompt_id(&prompt_id) {
                return Err(Refusal::BadRequest.into());
            }
            let params = json!({"sessionId": session, "promptId": prompt_id});
            attachment.link.call("_acpmux/queue_decline", params, CALL_TIMEOUT).map_err(Refusal::of)
        }
        AgentSessionCommand::Permission(PermissionParams {
            permission_id,
            option_id,
            answers,
            annotations,
            decision_nonce,
            person_decision,
            answered_by,
            ..
        }) => {
            if option_id.is_empty() || option_id.len() > 256 {
                return Err(Refusal::BadRequest.into());
            }
            let answers = answers.filter(|a| !a.is_null());
            let annotations = annotations.filter(|a| !a.is_null());
            let bad = |v: &Option<Value>| {
                v.as_ref()
                    .is_some_and(|a| !a.is_object() || a.to_string().len() > MAX_ANSWERS_BYTES)
            };
            // Annotations go only beside answers.
            if bad(&answers) || bad(&annotations) || (annotations.is_some() && answers.is_none()) {
                return Err(Refusal::BadRequest.into());
            }
            if !decision_nonce.as_deref().is_none_or(is_hex64)
                || !person_decision.as_deref().is_none_or(is_hex64)
                || answered_by
                    .as_ref()
                    .is_some_and(|a| !is_answer_id(&a.device) || !is_answer_id(&a.feed_item))
            {
                return Err(Refusal::BadRequest.into());
            }
            if !attachment.has_permission(&permission_id) {
                return Err(Refusal::UnknownPermission.into());
            }
            let mut params =
                json!({"sessionId": session, "permissionId": permission_id, "optionId": option_id});
            if let Some(answers) = answers {
                params["answers"] = answers;
            }
            if let Some(annotations) = annotations {
                params["annotations"] = annotations;
            }
            let mut meta = serde_json::Map::new();
            if let Some(nonce) = decision_nonce {
                meta.insert("decisionNonce".into(), Value::String(nonce));
            }
            if let Some(proof) = person_decision {
                meta.insert("personDecision".into(), Value::String(proof));
            }
            if let Some(by) = answered_by {
                meta.insert(
                    "answeredBy".into(),
                    json!({"device": by.device, "feedItem": by.feed_item}),
                );
            }
            if !meta.is_empty() {
                params.insert("_meta", json!({"acpmux": meta}));
            }
            let answered = attachment.link.call(
                "_acpmux/permission_respond",
                attachment.stamp(params),
                CALL_TIMEOUT,
            );
            // A failed answer stays answerable; a delivered one is spent.
            if answered.is_ok() {
                attachment.forget_permission(&permission_id);
            }
            answered.map_err(Refusal::of)
        }
        // A shared chat covers that chat only: a teammate lists no descendants.
        AgentSessionCommand::Children(_) if attachment.author.is_some() => Err(Refusal::NotTrusted),
        AgentSessionCommand::Children(_) => agent_session_children::list(attachment),
        // Forking creates a machine/transcript descendant and is owner-only. Shared Cloud
        // attachments may read and drive their pinned chat, but must not spend owner resources.
        AgentSessionCommand::Fork(_) if attachment.author.is_some() => Err(Refusal::NotTrusted),
        AgentSessionCommand::Fork(ForkParams { through_seq, name, .. }) => {
            if through_seq == 0 || name.as_ref().is_some_and(|name| name.len() > 256) {
                return Err(Refusal::BadRequest.into());
            }
            let mut params = json!({
                "sessionId": session,
                "throughSeq": through_seq,
            });
            if let (Some(name), Some(fields)) =
                (name.filter(|name| !name.trim().is_empty()), params.as_object_mut())
            {
                fields.insert("name".to_owned(), Value::String(name));
            }
            let forked = attachment
                .link
                // Use acp.session.fork, the validated through-turn boundary. A plain session/fork
                // strips the internal throughSeq metadata and would copy a later snapshot.
                .call("acp.session.fork", attachment.stamp(params), CALL_TIMEOUT)
                .map_err(Refusal::of)?;
            // The fork's id is this machine's acpmux answer, never the request's: follow and
            // remember it like a listed child, so `new-conversation-tab` admits its sibling tab
            // (a fork carries `parentId`, which the children walk does not read).
            if let Some(id) =
                forked.get("sessionId").and_then(Value::as_str).filter(|id| !id.is_empty())
            {
                attachment.follow_children(&[id.to_owned()]);
            }
            Ok(forked)
        }
        // A side chat is a new chat on the owner's machine, as a fork is: the owner's only.
        AgentSessionCommand::Side(_) if attachment.author.is_some() => Err(Refusal::NotTrusted),
        AgentSessionCommand::Side(params) => side::call(attachment, params),
        AgentSessionCommand::Media(MediaParams {
            path,
            offset: None,
            length: None,
            handle: None,
            ..
        }) => media(attachment, path),
        AgentSessionCommand::Media(MediaParams {
            path,
            offset: Some(offset),
            length,
            handle,
            ..
        }) => media_range(attachment, path, offset, length, handle),
        AgentSessionCommand::Media(_) => Err(Refusal::BadRequest),
        // The session is the tab's own; acpmux bounds typing (2 a second, `typing.rate_limited`).
        // acpmux's rate refusal is the attachment's bound (`agent_session.limit`): the pane says
        // so again with its next keystroke.
        AgentSessionCommand::Typing(TypingParams { on, .. }) => {
            let params = attachment.stamp(json!({"sessionId": session, "on": on}));
            attachment.link.call("_acpmux/typing", params, CALL_TIMEOUT).map_err(|error| {
                match &error {
                    LinkError::Rpc(_, data)
                        if data.get("reason").and_then(Value::as_str)
                            == Some("typing.rate_limited") =>
                    {
                        Refusal::Limit
                    }
                    _ => Refusal::of(error),
                }
            })
        }
        AgentSessionCommand::View(ViewParams { visible, attending, seen_seq, .. }) => {
            let mut fields = serde_json::Map::new();
            fields.insert("sessionId".into(), json!(session));
            fields.insert("visible".into(), json!(visible));
            if let Some(attending) = attending {
                fields.insert("attending".into(), json!(attending));
            }
            if let Some(seen_seq) = seen_seq {
                fields.insert("seenSeq".into(), json!(seen_seq));
            }
            let params = attachment.stamp(Value::Object(fields));
            attachment.link.call("_acpmux/view", params, CALL_TIMEOUT).map_err(Refusal::of)
        }
        // The person's picks, on the tab's own session; acpmux's answer goes back unchanged (a
        // set_config_option answers the agent's whole `configOptions`, which the page shows).
        AgentSessionCommand::SetModel(SetModelParams { model_id, .. }) => {
            let ok = is_setting_id(&model_id);
            setting(attachment, ok, "session/set_model", json!({"modelId": model_id}))
        }
        AgentSessionCommand::SetMode(SetModeParams { mode_id, .. }) => {
            let ok = is_setting_id(&mode_id);
            setting(attachment, ok, "session/set_mode", json!({"modeId": mode_id}))
        }
        AgentSessionCommand::SetConfig(SetConfigParams { config_id, value, .. }) => {
            let ok = is_setting_id(&config_id) && is_setting_id(&value);
            let params = json!({"configId": config_id, "value": value});
            setting(attachment, ok, "session/set_config_option", params)
        }
        AgentSessionCommand::Login(params) => login(attachment, params),
        AgentSessionCommand::Context(params) => context::call(attachment, params),
        AgentSessionCommand::Btw(BtwParams { question, .. }) => btw(attachment, question),
        AgentSessionCommand::Cancel(_) | AgentSessionCommand::Detach(_) => Ok(json!({})),
    };
    answer.map_err(Refused::from)
}
