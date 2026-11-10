//! The one-tap answers of a waiting ask (wow idea 42, Leo 2026-11-08: "go think of things/look at
//! things, esp valuable things that people would think \"wow this is awesome\""): at most
//! [`MAX_CHOICES`] choices, each with an id that stays the same for the ask's whole life, so a
//! notification can carry them and a tap on one answers the ask without opening the chat.
//!
//! - A plan approval: `approve` (its allow-once option) and `keep_planning` (its reject-once).
//! - A tool permission: `allow_once` and `deny`. Never a lasting grant: a paired device may only
//!   allow once (`web_control::lasting_grant_refused`).
//! - A question: `option.<n>`, the n-th choice of its only question, when it has one question with
//!   one pick among at most [`MAX_CHOICES`] choices and no typed input. Any other ask has none: it
//!   needs the chat.
//! - A folder-trust card has none: only the app or the CLI trusts a folder.
//!
//! A tap answers through `mux/permission_respond` with `choiceId` ([`Hub::respond_choice`]): the
//! choice becomes the option and answers the chat's own card would send, then the same answer
//! path runs with the same checks. An allow or a question's answer from a device that is not the
//! person still needs the person's decision proof or the phone's signature over that very answer;
//! a deny needs none, as a deny from anywhere. A tap on an ask that was answered meanwhile is
//! refused as any late answer is, saying who answered it.

use super::Session;
use super::plan_build::plan_of;
use super::questions;
use crate::rpc::RpcError;
use serde_json::{Value, json};

/// The most choices an ask carries.
pub(crate) const MAX_CHOICES: usize = 3;

/// What an ask is, for the choices it carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ask {
    Plan,
    Question,
    Permission,
}

impl Ask {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Ask::Plan => "plan",
            Ask::Question => "question",
            Ask::Permission => "permission",
        }
    }
}

/// One choice: its stable `id`, the button's `label`, what it does (`allow`, `deny` or `answer`)
/// and whether a device that is not the person must sign it (every choice but a deny).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Choice {
    pub id: String,
    pub label: String,
    pub kind: &'static str,
    /// The request's option the choice answers with.
    option: String,
    /// A question's answers, keyed as its harness reads them.
    answers: Option<Value>,
}

impl Choice {
    pub(crate) fn json(&self) -> Value {
        json!({"id": self.id, "label": self.label, "kind": self.kind, "signed": self.kind != "deny"})
    }
}

/// The request's option of `kind`, when it offers exactly one.
fn option_of(request: &Value, kind: &str) -> Option<String> {
    let mut found = request["options"]
        .as_array()?
        .iter()
        .filter(|o| o["kind"] == kind)
        .filter_map(|o| o["optionId"].as_str());
    let first = found.next()?;
    found.next().is_none().then(|| first.to_owned())
}

fn choice(id: &str, label: &str, kind: &'static str, option: String) -> Choice {
    Choice { id: id.to_owned(), label: label.to_owned(), kind, option, answers: None }
}

/// What `request` is and the choices it carries, in the order they show.
pub(crate) fn choices(request: &Value) -> (Ask, Vec<Choice>) {
    if questions::trust_cwd(request).is_some() {
        return (Ask::Question, Vec::new());
    }
    let allow = option_of(request, "allow_once");
    // Once only, as a paired device may answer (`web_control::lasting_grant_refused`).
    let reject = option_of(request, "reject_once");
    if plan_of(request).is_some() {
        let out = [
            allow.map(|o| choice("approve", "Approve plan", "allow", o)),
            reject.map(|o| choice("keep_planning", "Keep planning", "deny", o)),
        ];
        return (Ask::Plan, out.into_iter().flatten().collect());
    }
    if questions::needs_person(request) {
        return (Ask::Question, question_choices(request, allow).unwrap_or_default());
    }
    let out = [
        allow.map(|o| choice("allow_once", "Allow once", "allow", o)),
        reject.map(|o| choice("deny", "Deny", "deny", o)),
    ];
    (Ask::Permission, out.into_iter().flatten().collect())
}

/// A question's choices: one question, one pick, no typed input, 1 to [`MAX_CHOICES`] choices.
fn question_choices(request: &Value, allow: Option<String>) -> Option<Vec<Choice>> {
    let allow = allow?;
    let question = questions::question(request)?;
    let [item] = question["items"].as_array()?.as_slice() else { return None };
    if item["multiSelect"] == true || item.get("input").is_some() {
        return None;
    }
    let options = item["options"].as_array()?;
    if options.is_empty() || options.len() > MAX_CHOICES {
        return None;
    }
    let codex = question["harness"] == "codex";
    let key = if codex { item["id"].as_str()? } else { item["prompt"].as_str()? };
    options
        .iter()
        .enumerate()
        .map(|(n, option)| {
            let label = option["label"].as_str()?;
            let answer = if codex { json!({"answers": [label]}) } else { json!(label) };
            Some(Choice {
                id: format!("option.{n}"),
                label: label.to_owned(),
                kind: "answer",
                option: allow.clone(),
                answers: Some(json!({ key: answer })),
            })
        })
        .collect()
}

/// The option and answers choice `id` of `request` answers with.
pub(crate) fn resolve(request: &Value, id: &str) -> Result<(String, Option<Value>), RpcError> {
    let (_, offered) = choices(request);
    let picked = offered.into_iter().find(|c| c.id == id).ok_or_else(|| {
        RpcError::invalid_params(format!("choice {id:?} is not offered for this ask"))
            .with_data(json!({"reason": "choice.not_offered", "choiceId": id}))
    })?;
    Ok((picked.option, picked.answers))
}

impl super::Hub {
    /// The option and answers choice `choice_id` of `session`'s pending ask `permission_id`
    /// answers with. An ask that is no longer pending is refused as `respond_permission` refuses
    /// a late answer: not found, saying who answered it while that is kept.
    pub(crate) fn pending_choice(
        &self,
        session: &Session,
        permission_id: &str,
        choice_id: &str,
    ) -> Result<(String, Option<Value>), RpcError> {
        let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let Some(pending) = state.pending.get(permission_id) else {
            let lost = RpcError::not_found(format!("no pending permission {permission_id}"));
            return Err(match state.settled.lost(permission_id) {
                Some(data) => lost.with_data(data),
                None => lost,
            });
        };
        resolve(&pending.request, choice_id)
    }

    /// Answers `session`'s pending ask `permission_id` with its choice `choice_id`, through the
    /// one answer path (`respond_permission`) and its checks, for `answerer` under `control`.
    pub(crate) async fn respond_choice(
        &self,
        session: &Session,
        permission_id: &str,
        choice_id: &str,
        answered_by: Option<Value>,
        answerer: super::person::Answerer<'_>,
        control: super::Control,
    ) -> Result<(), RpcError> {
        let (option, answers) = self.pending_choice(session, permission_id, choice_id)?;
        self.respond_permission(
            session,
            permission_id,
            Some(option),
            answers,
            answered_by,
            answerer,
            control,
        )
        .await
    }
}

#[cfg(test)]
#[path = "ask_choices_tests.rs"]
mod tests;
