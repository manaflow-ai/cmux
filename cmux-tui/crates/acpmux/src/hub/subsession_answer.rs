//! Part of `Hub`; see `hub/mod.rs`. A session answers its sub-sessions'
//! questions (`_acpmux/subsession/answer`, the `answer_question` tool of
//! `subsession_mcp.rs`).
//!
//! A question here is Claude Code's AskUserQuestion or a Grok or Cursor ask:
//! a permission request recorded as answerable when it was asked
//! (`PendingPermission::ancestor_may_answer`, `questions::ancestor_answerable`),
//! from who asked and never from its input's shape, so a tool call whose
//! input merely holds `questions` is not one. Its answer is text the
//! agent reads, which the same caller could already send the child as a
//! prompt (`_acpmux/subsession/send`): it starts nothing, allows no tool and
//! changes no mode, policy or rule. So the caller may answer one when:
//! - it is the proven caller (`hub/person.rs` (a)) of an ancestor of the
//!   asking session, on the write path of `send` and `stop`
//!   (`Hub::subsession_write_target`): never its own question, its parent's,
//!   another family's, or one under a chat the person started from a
//!   suggested task;
//! - the request is such a question with a one-time allow option
//!   (`allow_once`). A permission prompt, a plan approval (ExitPlanMode,
//!   `x.ai/exit_plan_mode`, `cursor/create_plan`), any tool whose input holds
//!   `questions`, a question that offers only a lasting allow, a Codex
//!   user-input request (its adapter's shape is unverified) and a writer's
//!   own `_meta.acpmux.question` stay the person's; the refusal names the
//!   child;
//! - the person turned `agents.subsessions.answerQuestions` on (off by
//!   default: it loosens the rule that only the person answers). Off, every
//!   question is the person's (`subsessions.answers_off`).
//!
//! The answers are checked as a person's are (`questions::check_answers`)
//! and go through `Hub::respond_permission`, whose rule under the prompt's
//! lock checks the prompt's conditions again (`Answerer::ancestor`, the
//! recorded flag, the one-time allow). The setting is read once per answer,
//! before the lock: a person who turns it off during that one call does not
//! stop it. The
//! decision record's `answeredBy` is `{session, name}` of the caller, so the
//! child's transcript shows who answered.
//!
//! Descendants, not only children: `get` and `stop` already reach the whole
//! subtree, and every session in it was started, step by step, by the
//! caller's own sessions. A middle session that is alive may answer too;
//! the first answer counts and the next finds nothing pending.

use super::*;

/// Whether ancestors answer questions (settings
/// `agents.subsessions.answerQuestions`, else the catalog default).
fn answers_on() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, super::subsessions::SETTING_ANSWER_QUESTIONS)
                .and_then(|v| v.as_bool())
                .unwrap_or(super::subsessions::catalog().answer_questions)
        }
        _ => super::subsessions::catalog().answer_questions,
    }
}

/// The `allow_once` option of a question request, the one an ancestor answers with.
fn answer_option(request: &Value) -> Option<String> {
    request["options"].as_array()?.iter().find(|o| o["kind"] == "allow_once")?["optionId"]
        .as_str()
        .map(str::to_owned)
}

/// `answers` keyed as the asking harness reads them: by an item's prompt
/// (Claude Code and the Chief, one string) or its id (Codex, `{answers:
/// [..]}`). The caller may key an item by either and give a string or a
/// list of strings; anything else passes through for `check_answers` to refuse.
fn harness_answers(question: &Value, answers: Value) -> Value {
    let Value::Object(given) = answers else { return answers };
    let codex = question["harness"] == "codex";
    let items = question["items"].as_array().cloned().unwrap_or_default();
    let mut out = serde_json::Map::new();
    for (key, value) in given {
        let item = items.iter().find(|i| i["id"] == key.as_str() || i["prompt"] == key.as_str());
        let Some(item) = item else {
            out.insert(key, value);
            continue;
        };
        let target = if codex { &item["id"] } else { &item["prompt"] };
        let target = target.as_str().unwrap_or(&key).to_owned();
        let strings = match &value {
            Value::String(s) => Some(vec![s.clone()]),
            Value::Array(list) => list.iter().map(|v| v.as_str().map(str::to_owned)).collect(),
            _ => None,
        };
        let value = match (strings, codex) {
            (Some(list), true) => json!({"answers": list}),
            (Some(list), false) => json!(list.join(", ")),
            (None, _) => value,
        };
        out.insert(target, value);
    }
    Value::Object(out)
}

impl Hub {
    /// The pending questions of `s`, oldest first: `{permissionId, agent,
    /// answerable, items: [{id, header?, prompt, options: [{label, detail?}],
    /// multiSelect, allowsOther}]}`, with the text masked (`secret_scan`) as
    /// everything else the tools read back. `answerable` false: only the
    /// person answers it (module docs).
    pub fn subsession_questions(&self, s: &Session) -> Value {
        let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut rows: Vec<(String, Value)> = state
            .pending
            .iter()
            .filter_map(|(id, p)| {
                let q = super::questions::question(&p.request)?;
                let mask = |v: &Value| v.as_str().map(crate::secret_scan::mask);
                let items: Vec<Value> = q["items"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|item| {
                        let options: Vec<Value> = item["options"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .map(|o| json!({"label": mask(&o["label"]), "detail": mask(&o["detail"])}))
                            .collect();
                        json!({
                            "id": item["id"],
                            "header": mask(&item["header"]),
                            "prompt": mask(&item["prompt"]),
                            "options": options,
                            "multiSelect": item["multiSelect"],
                            "allowsOther": item["allowsOther"],
                        })
                    })
                    .collect();
                Some((
                    id.clone(),
                    json!({"permissionId": id, "agent": q["agent"], "items": items,
                           "answerable": p.ancestor_may_answer}),
                ))
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        Value::Array(rows.into_iter().map(|(_, row)| row).collect())
    }

    /// `_acpmux/subsession/answer`: `caller` answers the pending question
    /// `permission_id` of `target`, a descendant on the write path (module docs).
    pub async fn subsession_answer(
        &self,
        caller: &Session,
        target: &Session,
        permission_id: &str,
        answers: Value,
    ) -> Result<Value, RpcError> {
        let child = target.meta().name.clone();
        let data = || json!({"sessionId": target.id, "permissionId": permission_id});
        if !answers_on() {
            return Err(super::subsessions::refused(
                "subsessions.answers_off",
                format!(
                    "the user answers {child}'s questions themselves (Settings > Agents > Sub-sessions): tell them {child} is asking, or send {child} what to do with send_message"
                ),
                data(),
            ));
        }
        let (option, answers) = {
            let state =
                target.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let pending = state.pending.get(permission_id).ok_or_else(|| {
                RpcError::not_found(format!("no pending permission {permission_id}"))
            })?;
            let question = super::questions::question(&pending.request)
                .filter(|_| pending.ancestor_may_answer);
            let option = answer_option(&pending.request);
            let (Some(question), Some(option)) = (question, option) else {
                return Err(super::subsessions::refused(
                    "subsessions.not_a_question",
                    format!(
                        "{child} is asking for permission (or to approve a plan), or asks in a way only the user answers: only the user answers that, in cmux NEXT. Tell them {child} is waiting"
                    ),
                    data(),
                ));
            };
            (option, harness_answers(question, answers))
        };
        let answered_by = json!({"session": caller.id, "name": caller.meta().name});
        let answerer = super::person::Answerer { ancestor: Some(&caller.id), ..Default::default() };
        self.respond_permission(
            target,
            permission_id,
            Some(option),
            Some(answers),
            Some(answered_by),
            answerer,
            Control::Local,
        )
        .await?;
        Ok(json!({"answered": true, "sessionId": target.id, "permissionId": permission_id}))
    }
}
