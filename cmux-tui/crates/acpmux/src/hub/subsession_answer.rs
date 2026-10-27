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
//!   question is the person's (`subsessions.answers_off`);
//! - the child asks no less than the caller (`Hub::receiver_check`), as for
//!   `send`: an answer is text its agent acts on. A caller or child a remote
//!   device drove answers under the remote floor (`Control::Web`), as a
//!   family prompt runs (`Hub::send_family_prompt`).
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
        // Held until the answer is delivered: an MDM off push waits for it (`family_gate`).
        let family_gate = self.family_gate.read().await;
        self.receiver_check(caller, target).await?;
        let control = if Self::web_turn(caller) || Self::web_turn(target) {
            Control::Web
        } else {
            Control::Local
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
            control,
        )
        .await?;
        drop(family_gate);
        Ok(json!({"answered": true, "sessionId": target.id, "permissionId": permission_id}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::StoreMode;
    use crate::hub::person::{ANSWERED_BY_SLOT, Answerer, REASON};

    /// A hub with one stand-in session, and the connection that made it.
    async fn hub_with_session() -> (Arc<Hub>, Arc<Session>, mpsc::Sender<String>) {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let (in_tx, in_rx) = mpsc::channel(8);
        let (out_tx, mut out_rx) = mpsc::channel(256);
        tokio::spawn(crate::server::serve_connection_with(
            hub.clone(),
            in_rx,
            out_tx,
            crate::server::Origin::Local,
        ));
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
        in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
        loop {
            let line = out_rx.recv().await.expect("the session/new reply");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == 1 {
                let id = reply["result"]["sessionId"].as_str().expect("a session id").to_owned();
                let session = hub.resolve(&id).unwrap();
                return (hub, session, in_tx);
            }
        }
    }

    /// A pending prompt shaped like a question, recorded as `may` answer.
    fn pending(session: &Session, may: bool) -> (String, oneshot::Receiver<Value>) {
        let mut request = json!({
            "toolCall": {"toolCallId": "t1", "kind": "execute", "status": "pending",
                         "rawInput": {"command": "rm -rf build",
                                      "questions": [{"question": "ok?", "options": [{"label": "yes"}]}]}},
            "options": [
                {"optionId": "go", "name": "Go", "kind": "allow_once"},
                {"optionId": "no", "name": "No", "kind": "reject_once"},
            ],
        });
        super::super::questions::normalize(
            &mut request,
            super::super::questions::PreviewFormat::Monospace,
        );
        let (reply, rx) = oneshot::channel();
        let id = uuid::Uuid::now_v7().to_string();
        let entry = PendingPermission {
            request,
            reply,
            decision_nonce: super::super::person::new_nonce(),
            ancestor_may_answer: may,
            prev_status: SessionStatus::Waiting,
        };
        session.permissions.lock().unwrap().pending.insert(id.clone(), entry);
        (id, rx)
    }

    /// The rule under the prompt's lock, without the request check before it:
    /// an ancestor's answer counts only on a prompt recorded as a question.
    #[tokio::test]
    async fn subsession_answer_under_the_lock_only_a_recorded_question_counts() {
        let (hub, session, _conn) = hub_with_session().await;
        let ancestor = Answerer { ancestor: Some("parent"), ..Default::default() };
        let by = json!({"session": "parent", "name": "parent"});
        let answers = json!({"ok?": "yes"});

        let (id, _rx) = pending(&session, false);
        let e = hub
            .respond_permission(
                &session,
                &id,
                Some("go".to_owned()),
                Some(answers.clone()),
                Some(by.clone()),
                ancestor,
                Control::Local,
            )
            .await
            .expect_err("a prompt not recorded as a question");
        let reason = e.data.as_ref().map(|d| d["reason"].clone());
        assert_eq!(reason, Some(json!(REASON)), "{e:?}");
        assert!(session.permissions.lock().unwrap().pending.contains_key(&id), "it stays pending");

        let (id, rx) = pending(&session, true);
        hub.respond_permission(
            &session,
            &id,
            Some("go".to_owned()),
            Some(answers),
            Some(by),
            ancestor,
            Control::Local,
        )
        .await
        .expect("a recorded question");
        let outcome = rx.await.unwrap();
        assert_eq!(outcome["optionId"], "go", "{outcome}");
        assert_eq!(outcome[ANSWERED_BY_SLOT]["session"], "parent", "{outcome}");
    }

    /// The folder-trust card (`trust_wait.rs`) is the person's: an ancestor
    /// cannot trust a folder for them, even on an entry recorded otherwise.
    #[tokio::test]
    async fn subsession_answer_never_answers_a_folder_trust_card() {
        let (hub, session, _conn) = hub_with_session().await;
        let request = super::super::trust_wait::card("/tmp/untrusted", "child");
        assert!(!super::super::questions::ancestor_answerable(&request, false));
        let (reply, _rx) = oneshot::channel();
        let id = uuid::Uuid::now_v7().to_string();
        let entry = PendingPermission {
            request,
            reply,
            decision_nonce: super::super::person::new_nonce(),
            ancestor_may_answer: true,
            prev_status: SessionStatus::Waiting,
        };
        session.permissions.lock().unwrap().pending.insert(id.clone(), entry);
        let prompt = "child wants to work in /tmp/untrusted. Do you trust this folder?";
        let e = hub
            .respond_permission(
                &session,
                &id,
                Some("trust".to_owned()),
                Some(json!({(prompt): "Trust folder"})),
                Some(json!({"session": "parent", "name": "parent"})),
                Answerer { ancestor: Some("parent"), ..Default::default() },
                Control::Local,
            )
            .await
            .expect_err("a folder-trust card");
        let reason = e.data.as_ref().map(|d| d["reason"].clone());
        assert_eq!(reason, Some(json!(REASON)), "{e:?}");
        assert!(session.permissions.lock().unwrap().pending.contains_key(&id), "it stays pending");
    }
}
