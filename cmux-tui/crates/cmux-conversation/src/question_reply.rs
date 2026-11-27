//! Transport-neutral presentation and selection of an existing question.
//!
//! This produces a choice, never permission approval or proof of a person's
//! identity. The caller must authenticate the sender, read the current pending
//! question, and commit a complete answer through its existing owner atomically.
//! A successful resolution alone does not consume a question or send anything.

use crate::{Question, QuestionSelection, QuestionState, Tapback, question};

#[path = "question_reply_envelope.rs"]
mod envelope;
#[path = "question_reply_render.rs"]
mod render;
pub use envelope::{ObservedReply, ReplyEnvelope, ReplyWindow};
pub use render::plain_messages;

/// Reject oversized input before normalization allocates. Uses the existing
/// question answer byte budget, rather than an independent transport limit.
pub const MAX_REPLY_BYTES: usize = crate::MAX_QUESTION_TEXT_BYTES;

/// Stable identities assigned by the question owner, not inferred from text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuestionIdentity {
    pub request_id: String,
    pub question_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyError {
    Ambiguous,
    Stale,
    WrongThread,
    UnboundTapback,
    NoMatch,
    InvalidQuestion,
    InvalidBinding,
    InputTooLong,
    Echo,
    RemovedTapback,
}

/// A tapback has no implied yes/no meaning. Its exact target and kind must
/// have been explicitly bound to an offered choice by the caller.
#[derive(Debug, Clone, Copy)]
pub enum QuestionReply<'a> {
    Text(&'a str),
    Tapback { message_id: &'a str, reaction: Tapback },
}

/// One selection, not necessarily a complete multi-item/multi-select answer.
/// Identifiers remain those of the immutable original request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedChoice {
    pub identity: QuestionIdentity,
    pub session: String,
    pub permission: Option<String>,
    pub item_id: String,
    pub selection: QuestionSelection,
    /// False for multi-select or multi-item questions: the owner must collect
    /// and submit a complete answer, never auto-submit this partial selection.
    pub completes_question: bool,
}

#[derive(Debug, Clone)]
struct TapbackBinding {
    message_id: String,
    reaction: Tapback,
    number: usize,
}

/// A frozen question as offered in one thread. Private fields prevent callers
/// from replacing the request while retaining its rendered numbers or bindings.
#[derive(Debug, Clone)]
pub struct QuestionReplyPrompt {
    identity: QuestionIdentity,
    thread: String,
    question: Question,
    tapbacks: Vec<TapbackBinding>,
    permission_aliases: Option<(usize, usize)>,
}

impl QuestionReplyPrompt {
    pub fn new(
        identity: QuestionIdentity,
        thread: String,
        question: Question,
    ) -> Result<Self, ReplyError> {
        if identity.request_id.trim().is_empty()
            || identity.question_id.trim().is_empty()
            || thread.trim().is_empty()
            || question::validate(&question).is_err()
        {
            return Err(ReplyError::InvalidQuestion);
        }
        if question.state != QuestionState::Pending {
            return Err(ReplyError::Stale);
        }
        Ok(Self { identity, thread, question, tapbacks: Vec::new(), permission_aliases: None })
    }

    pub fn identity(&self) -> &QuestionIdentity {
        &self.identity
    }

    pub fn question(&self) -> &Question {
        &self.question
    }

    /// Plain Messages text. Numbers are global across items, in request order,
    /// so a bare number never silently picks the first of several items.
    /// Collapse whitespace in labels/details so they cannot inject numbered rows.
    pub fn render(&self) -> String {
        let mut sections = Vec::new();
        let mut number = 0_usize;
        for item in &self.question.items {
            let mut lines = vec![format!("Question: {}", one_line(&plain_messages(&item.prompt)))];
            for option in &item.options {
                number = number.saturating_add(1);
                lines.push(format!("{number}. {}", one_line(&plain_messages(&option.label))));
                if let Some(detail) = &option.detail {
                    let detail = one_line(&plain_messages(detail));
                    if !detail.is_empty() {
                        lines.push(format!("   {detail}"));
                    }
                }
            }
            if item.multi_select {
                lines.push(
                    "Choose one or more; a single reply does not submit this question.".into(),
                );
            }
            sections.push(lines.join("\n"));
        }
        if number > 0 {
            sections.push("Reply with an option number or its exact text.".to_owned());
        }
        sections.join("\n\n")
    }

    /// Only an adapter that already knows this is a two-option permission
    /// prompt may declare these aliases. Labels never infer permission kind.
    /// This still returns a selection, not authorization or a proven gesture.
    pub fn with_permission_aliases(mut self, yes: usize, no: usize) -> Result<Self, ReplyError> {
        let valid = self.question.items.len() == 1
            && self
                .question
                .items
                .first()
                .is_some_and(|item| !item.multi_select && item.options.len() == 2)
            && yes != no
            && self.choice(yes).is_some()
            && self.choice(no).is_some();
        if !valid {
            return Err(ReplyError::InvalidBinding);
        }
        self.permission_aliases = Some((yes, no));
        Ok(self)
    }

    /// Bind an explicitly offered reaction on a delivered message to a rendered
    /// number. Rebinding the same (message, reaction) to another choice fails.
    /// Nothing here decides which reaction means which choice.
    pub fn with_tapback(
        mut self,
        message_id: String,
        reaction: Tapback,
        number: usize,
    ) -> Result<Self, ReplyError> {
        if message_id.trim().is_empty() || self.choice(number).is_none() {
            return Err(ReplyError::InvalidBinding);
        }
        if let Some(binding) = self
            .tapbacks
            .iter()
            .find(|binding| binding.message_id == message_id && binding.reaction == reaction)
        {
            return if binding.number == number { Ok(self) } else { Err(ReplyError::Ambiguous) };
        }
        self.tapbacks.push(TapbackBinding { message_id, reaction, number });
        Ok(self)
    }

    /// Compare the entire frozen request to the authoritative current question
    /// before interpreting input. `None` means the question is no longer live.
    /// The caller must revalidate at commit to close the resolution/commit race.
    /// Unmatched text is not converted to Other, an approval, or a fuzzy choice.
    pub fn resolve(
        &self,
        current_identity: &QuestionIdentity,
        current: Option<&Question>,
        thread: &str,
        reply: QuestionReply<'_>,
    ) -> Result<ResolvedChoice, ReplyError> {
        if thread != self.thread {
            return Err(ReplyError::WrongThread);
        }
        if current_identity != &self.identity || current != Some(&self.question) {
            return Err(ReplyError::Stale);
        }
        let number = match reply {
            QuestionReply::Text(text) => self.resolve_text(text)?,
            QuestionReply::Tapback { message_id, reaction } => self
                .tapbacks
                .iter()
                .find(|binding| binding.message_id == message_id && binding.reaction == reaction)
                .map(|binding| binding.number)
                .ok_or(ReplyError::UnboundTapback)?,
        };
        let (item, option) = self.choice(number).ok_or(ReplyError::NoMatch)?;
        Ok(ResolvedChoice {
            identity: self.identity.clone(),
            session: self.question.session.clone(),
            permission: self.question.permission.clone(),
            item_id: item.id.clone(),
            selection: QuestionSelection { option_ids: vec![option.id.clone()], other: None },
            completes_question: self.question.items.len() == 1 && !item.multi_select,
        })
    }

    fn resolve_text(&self, text: &str) -> Result<usize, ReplyError> {
        if text.len() > MAX_REPLY_BYTES {
            return Err(ReplyError::InputTooLong);
        }
        let text = one_line(text);
        let digits = text.strip_prefix('#').unwrap_or(&text);
        let digits = digits.strip_suffix('.').unwrap_or(digits);
        let numeric = !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit());
        let number = if numeric { digits.parse::<usize>().ok() } else { None };
        let folded = fold(&text);
        if folded.is_empty() {
            return Err(ReplyError::NoMatch);
        }
        let alias = self.permission_aliases.and_then(|(yes, no)| match folded.as_str() {
            "yes" => Some(yes),
            "no" => Some(no),
            _ => None,
        });
        let labels: Vec<_> = self
            .question
            .items
            .iter()
            .flat_map(|item| &item.options)
            .map(|option| fold(&one_line(&plain_messages(&option.label))))
            .collect();
        let exact: Vec<_> = labels
            .iter()
            .enumerate()
            .filter_map(|(index, label)| {
                let candidate = index.saturating_add(1);
                (number == Some(candidate) || alias == Some(candidate) || label == &folded)
                    .then_some(candidate)
            })
            .collect();
        if !exact.is_empty() {
            return unique(exact.into_iter());
        }
        // Digits and yes/no are never fuzzy guesses in ordinary choice prompts.
        if numeric || matches!(folded.as_str(), "yes" | "no") || text.chars().count() < 2 {
            return Err(ReplyError::NoMatch);
        }
        unique(labels.iter().enumerate().filter_map(|(index, label)| {
            label.starts_with(&folded).then_some(index.saturating_add(1))
        }))
    }

    fn choice(&self, number: usize) -> Option<(&crate::QuestionItem, &crate::QuestionOption)> {
        self.question
            .items
            .iter()
            .flat_map(|item| item.options.iter().map(move |option| (item, option)))
            .nth(number.checked_sub(1)?)
    }
}

fn unique(mut choices: impl Iterator<Item = usize>) -> Result<usize, ReplyError> {
    let choice = choices.next().ok_or(ReplyError::NoMatch)?;
    if choices.next().is_some() { Err(ReplyError::Ambiguous) } else { Ok(choice) }
}

fn fold(text: &str) -> String {
    unicase::UniCase::new(text).to_folded_case()
}

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
#[path = "question_reply_tests.rs"]
mod tests;
