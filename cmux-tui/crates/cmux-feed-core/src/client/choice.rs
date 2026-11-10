//! The client-side check of a `choice` answer before it is sent (Swift
//! `FeedChoiceValidation`); the owner checks again against the kind's
//! schema. The answer is the wire value `{answers: {<qid>: {selected: [id],
//! other?}}}`.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::{Map, Value, json};

use super::prompt::ChoiceQuestion;

/// Why a choice answer is not sendable yet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "issue", rename_all = "snake_case")]
pub enum ChoiceIssue {
    /// No option and no "Other" text for this question.
    Unanswered {
        question: String,
    },
    /// A single-select question got more than one answer.
    TooMany {
        question: String,
    },
    UnknownOption {
        question: String,
        option: String,
    },
    UnknownQuestion {
        question: String,
    },
    /// "Other" text on a question that does not allow it.
    OtherNotAllowed {
        question: String,
    },
}

/// One question's answer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    pub selected: Vec<String>,
    pub other: Option<String>,
}

/// The selections of an answer value, by question id. A malformed value
/// reads as no selections (every question unanswered).
pub fn selections(answer: &Value) -> BTreeMap<String, Selection> {
    let Some(answers) = answer.get("answers").and_then(Value::as_object) else {
        return BTreeMap::new();
    };
    answers
        .iter()
        .map(|(id, value)| {
            let selected = value
                .get("selected")
                .and_then(Value::as_array)
                .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            let other = value.get("other").and_then(Value::as_str).map(str::to_owned);
            (id.clone(), Selection { selected, other })
        })
        .collect()
}

/// Every issue of `answers` for `questions`, unknown questions first.
pub fn issues(
    answers: &BTreeMap<String, Selection>,
    questions: &[ChoiceQuestion],
) -> Vec<ChoiceIssue> {
    let mut issues = Vec::new();
    let known: BTreeSet<&str> = questions.iter().map(|q| q.id.as_str()).collect();
    for id in answers.keys().filter(|id| !known.contains(id.as_str())) {
        issues.push(ChoiceIssue::UnknownQuestion { question: id.clone() });
    }
    let empty = Selection::default();
    for question in questions {
        let selection = answers.get(&question.id).unwrap_or(&empty);
        let other = selection.other.as_deref().unwrap_or_default().trim();
        let options: BTreeSet<&str> = question.options.iter().map(|o| o.id.as_str()).collect();
        for option in selection.selected.iter().filter(|o| !options.contains(o.as_str())) {
            issues.push(ChoiceIssue::UnknownOption {
                question: question.id.clone(),
                option: option.clone(),
            });
        }
        if !other.is_empty() && !question.allow_other {
            issues.push(ChoiceIssue::OtherNotAllowed { question: question.id.clone() });
        }
        let distinct: BTreeSet<&str> = selection.selected.iter().map(String::as_str).collect();
        let count = distinct.len().saturating_add(usize::from(!other.is_empty()));
        if count == 0 {
            issues.push(ChoiceIssue::Unanswered { question: question.id.clone() });
        } else if count > 1 && !question.multi {
            issues.push(ChoiceIssue::TooMany { question: question.id.clone() });
        }
    }
    issues
}

/// The answer value with blank "Other" text removed and every question
/// present, or its issues.
pub fn normalized(answer: &Value, questions: &[ChoiceQuestion]) -> Result<Value, Vec<ChoiceIssue>> {
    let answers = selections(answer);
    let found = issues(&answers, questions);
    if !found.is_empty() {
        return Err(found);
    }
    let mut out = Map::new();
    for question in questions {
        let selection = answers.get(&question.id).cloned().unwrap_or_default();
        let other = selection.other.as_deref().unwrap_or_default().trim().to_owned();
        let entry = if other.is_empty() {
            json!({"selected": selection.selected})
        } else {
            json!({"selected": selection.selected, "other": other})
        };
        out.insert(question.id.clone(), entry);
    }
    Ok(json!({"answers": out}))
}
