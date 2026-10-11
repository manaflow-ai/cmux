//! Agent questions in a conversation (plans/cmux-next/agent-questions.md):
//! the `question` part an agent posts, the `question.answer` op a person
//! commits, and the rules the owner checks for both.
//!
//! Only an agent posts a question; only a human answers one, once. The owner
//! stamps who answered (and from which paired device) from the connection's
//! participant, never from the request.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::reducer::Reject;
use crate::types::{Part, Participant, ParticipantKind};

/// Most items (questions) in one ask.
pub const MAX_QUESTION_ITEMS: usize = 4;
/// Most options in one item.
pub const MAX_QUESTION_OPTIONS: usize = 12;
/// Longest prompt, option detail or Other answer, in UTF-8 bytes.
pub const MAX_QUESTION_TEXT_BYTES: usize = 2048;
/// Longest header chip or option label, in UTF-8 bytes.
pub const MAX_QUESTION_LABEL_BYTES: usize = 256;
/// Longest option preview, in UTF-8 bytes.
pub const MAX_QUESTION_PREVIEW_BYTES: usize = 8192;

/// The harness that asked; it decides how the answer reaches the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuestionHarness {
    Claude,
    Codex,
    Acp,
    Chief,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub harness: QuestionHarness,
    /// The acpmux session that asked.
    pub session: String,
    /// The acpmux permission the answer settles, when the ask is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<String>,
    /// The asking agent's display name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub items: Vec<QuestionItem>,
    #[serde(default)]
    pub state: QuestionState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionItem {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub prompt: String,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
    #[serde(default = "default_true")]
    pub allows_other: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<QuestionPreview>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionPreview {
    pub text: String,
    #[serde(default)]
    pub format: PreviewFormat,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreviewFormat {
    #[default]
    Monospace,
    Markdown,
}

/// `{"kind": "pending" | "answered" | "cancelled", "answer"?}`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum QuestionState {
    #[default]
    Pending,
    Answered {
        answer: QuestionAnswer,
    },
    Cancelled,
}

/// What a person chose. In a `question.answer` op only `selections` is
/// read; the owner sets `respondent` and `answered_at`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionAnswer {
    pub selections: BTreeMap<String, QuestionSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub respondent: Option<Respondent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionSelection {
    #[serde(default)]
    pub option_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
}

/// Who answered, stamped by the owner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Respondent {
    /// The person (`user_local`, `user_<id>`); a paired device answers as its person.
    pub participant: String,
    pub display_name: String,
    /// The paired device's name, for an answer from a paired install.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(default)]
    pub remote: bool,
}

fn short(value: &str, max: usize) -> bool {
    !value.trim().is_empty() && value.len() <= max
}

/// Checks a question part's shape: sizes and unique ids. A send also
/// requires `pending` (reducer); an edit may only cancel (`check_edit`).
pub(crate) fn validate(question: &Question) -> Result<(), Reject> {
    let items_ok = !question.items.is_empty() && question.items.len() <= MAX_QUESTION_ITEMS;
    let ids_ok = question.items.iter().map(|item| item.id.as_str()).collect::<BTreeSet<_>>().len()
        == question.items.len();
    let refs_ok = short(&question.session, MAX_QUESTION_LABEL_BYTES)
        && question.permission.as_deref().is_none_or(|p| short(p, MAX_QUESTION_LABEL_BYTES))
        && question.agent.as_deref().is_none_or(|a| short(a, MAX_QUESTION_LABEL_BYTES));
    if !items_ok || !ids_ok || !refs_ok {
        return Err(Reject::InvalidParts);
    }
    for item in &question.items {
        let option_ids = item.options.iter().map(|o| o.id.as_str()).collect::<BTreeSet<_>>();
        let valid = short(&item.id, MAX_QUESTION_LABEL_BYTES)
            && short(&item.prompt, MAX_QUESTION_TEXT_BYTES)
            && item.header.as_deref().is_none_or(|h| short(h, MAX_QUESTION_LABEL_BYTES))
            && item.options.len() <= MAX_QUESTION_OPTIONS
            && option_ids.len() == item.options.len()
            && (!item.options.is_empty() || item.allows_other)
            && item.options.iter().all(|option| {
                short(&option.id, MAX_QUESTION_LABEL_BYTES)
                    && short(&option.label, MAX_QUESTION_LABEL_BYTES)
                    && option.detail.as_deref().is_none_or(|d| d.len() <= MAX_QUESTION_TEXT_BYTES)
                    && option
                        .preview
                        .as_ref()
                        .is_none_or(|p| p.text.len() <= MAX_QUESTION_PREVIEW_BYTES)
            });
        if !valid {
            return Err(Reject::InvalidParts);
        }
    }
    Ok(())
}

/// A message edit may not touch a question except to cancel a pending one:
/// the question parts must sit at the same indexes with the same content.
pub(crate) fn check_edit(before: &[Part], after: &[Part]) -> Result<(), Reject> {
    let questions = |parts: &[Part]| {
        parts
            .iter()
            .enumerate()
            .filter_map(|(index, part)| match part {
                Part::Question(question) => Some((index, question.clone())),
                _ => None,
            })
            .collect::<Vec<_>>()
    };
    let (old, new) = (questions(before), questions(after));
    if old.len() != new.len() {
        return Err(Reject::InvalidParts);
    }
    for ((old_index, old), (new_index, new)) in old.iter().zip(&new) {
        let same_content = Question { state: QuestionState::Pending, ..old.clone() }
            == Question { state: QuestionState::Pending, ..new.clone() };
        let state_ok = old.state == new.state
            || (old.state == QuestionState::Pending && new.state == QuestionState::Cancelled);
        if old_index != new_index || !same_content || !state_ok {
            return Err(Reject::InvalidParts);
        }
    }
    Ok(())
}

/// Commits a person's answer into `question`: it must be pending and the
/// answer complete and valid; the owner stamps the respondent from `actor`.
pub(crate) fn answer(
    question: &mut Question,
    answer: &QuestionAnswer,
    actor: &Participant,
    now: &str,
) -> Result<(), Reject> {
    if actor.kind != ParticipantKind::Human {
        return Err(Reject::HumanOnly);
    }
    if question.state != QuestionState::Pending {
        return Err(Reject::QuestionClosed);
    }
    let known = question.items.iter().map(|item| item.id.as_str()).collect::<BTreeSet<_>>();
    if answer.selections.keys().any(|key| !known.contains(key.as_str())) {
        return Err(Reject::InvalidAnswer);
    }
    let mut selections = BTreeMap::new();
    for item in &question.items {
        let selection = answer.selections.get(&item.id).cloned().unwrap_or_default();
        let other = selection.other.map(|o| o.trim().to_owned()).filter(|o| !o.is_empty());
        let chosen = selection.option_ids.iter().collect::<BTreeSet<_>>();
        let valid = (!chosen.is_empty() || other.is_some())
            && chosen.len() == selection.option_ids.len()
            && chosen.iter().all(|id| item.options.iter().any(|o| &o.id == *id))
            && other
                .as_deref()
                .is_none_or(|o| item.allows_other && o.len() <= MAX_QUESTION_TEXT_BYTES)
            && (item.multi_select || chosen.len() + usize::from(other.is_some()) == 1);
        if !valid {
            return Err(Reject::InvalidAnswer);
        }
        // Option order follows the item, not the request.
        let option_ids =
            item.options.iter().filter(|o| chosen.contains(&o.id)).map(|o| o.id.clone()).collect();
        selections.insert(item.id.clone(), QuestionSelection { option_ids, other });
    }
    let respondent = match &actor.person {
        Some(person) => Respondent {
            participant: person.clone(),
            display_name: actor.display_name.clone(),
            device: Some(actor.display_name.clone()),
            remote: true,
        },
        None => Respondent {
            participant: actor.id.clone(),
            display_name: actor.display_name.clone(),
            device: None,
            remote: false,
        },
    };
    question.state = QuestionState::Answered {
        answer: QuestionAnswer {
            selections,
            respondent: Some(respondent),
            answered_at: Some(now.to_owned()),
        },
    };
    Ok(())
}
