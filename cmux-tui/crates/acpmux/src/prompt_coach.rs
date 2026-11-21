//! Prompt coach: after a chat the person had to correct several times before they moved on, the
//! chat offers its first prompt rewritten with what the person added later, so the next one can
//! land in one shot. Leo, 2026-11-08: "go think of things/look at things, esp valuable things that
//! people would think \"wow this is awesome\"".
//!
//! - Each person prompt is checked once, when it is sent ([`Coach::prompt`]), never per token: a
//!   correction is a prompt that says no, stop, actually, not that, I meant, or re-explains
//!   ([`is_redirect`], on top of the memory inbox's [`crate::memory_inbox::is_correction`]). Only
//!   a prompt a connection proved the person's counts (`server/requests.rs` `person_admitted`).
//! - A completed turn whose own prompt was the person's and not a correction, after [`THRESHOLD`]
//!   or more corrections, means the person kept the result and moved on ([`Coach::turn_ended`]).
//!   Each prompt is kept by its id until its own turn ends, so a prompt queued behind a running
//!   turn, or a turn an agent or a peer started, never settles another turn's. The chat then
//!   logs a `mux` `coach_offer` record once (`hub/prompt_coach.rs`). No model is asked for that.
//! - Only when the chat page shows it (its setting on, the card not dismissed) does it ask for the
//!   rewrite (`_acpmux/prompt_coach`): one small-model call that reads the chat's first prompt and
//!   the corrections, never the transcript ([`rewrite_prompt`]). Its answer is logged as a `mux`
//!   `coach` record the chat draws as a card.

/// Corrections a chat takes before it is offered a rewrite.
pub const THRESHOLD: usize = 3;
/// The most corrections kept for the rewrite; later ones are dropped.
pub const MAX_KEPT: usize = 8;
/// The longest prompt kept, in characters: the first prompt and each correction.
pub const MAX_PROMPT_CHARS: usize = 2000;
/// The longest rewrite kept, in characters.
pub const MAX_REWRITE_CHARS: usize = 4000;
/// The most person prompts kept waiting for their turns to end; the oldest goes first. A steer
/// joins a running turn and never ends one of its own, so it waits here until pushed out.
pub const MAX_PENDING: usize = 32;

/// A chat's corrections and offer, this daemon run only. Corrections made before a restart are
/// not counted, so a restart can only make an offer later, never one more.
#[derive(Debug, Default)]
pub struct Coach {
    /// The person's corrections, oldest first, at most [`MAX_KEPT`].
    corrections: Vec<String>,
    /// Every correction counted, kept or not.
    count: usize,
    /// The person's prompts whose turns have not ended, oldest first, by prompt id: whether
    /// each was a correction. At most [`MAX_PENDING`].
    pending: std::collections::VecDeque<(String, bool)>,
    /// The offer logged, by its id.
    offered: Option<String>,
    /// The offer's rewrite is being made, or was made: never asked twice.
    asked: bool,
}

impl Coach {
    /// A person's prompt `id`, whose turn ends later ([`Coach::turn_ended`]). A resend of an id
    /// still waiting is the same prompt: it counts once.
    pub fn prompt(&mut self, id: &str, text: &str) {
        if self.pending.iter().any(|(p, _)| p == id) {
            return;
        }
        let corrects = is_redirect(text);
        if self.pending.len() >= MAX_PENDING {
            self.pending.pop_front();
        }
        self.pending.push_back((id.to_owned(), corrects));
        if !corrects || self.offered.is_some() {
            return;
        }
        self.count += 1;
        if self.corrections.len() < MAX_KEPT {
            self.corrections.push(cut(text, MAX_PROMPT_CHARS));
        }
    }

    /// The turn of prompt `prompt_id` ended, `completed` or not: true when the chat qualifies for
    /// its offer now. Only that prompt's own turn settles it: a turn whose prompt was no person's
    /// (an agent's or a peer's) decides nothing, and one that did not complete drops its prompt.
    pub fn turn_ended(&mut self, prompt_id: &str, completed: bool) -> bool {
        let Some(at) = self.pending.iter().position(|(p, _)| p == prompt_id) else {
            return false;
        };
        let corrects = self.pending.remove(at).is_some_and(|(_, corrects)| corrects);
        completed && !corrects && self.offered.is_none() && self.count >= THRESHOLD
    }

    /// The offer was logged as `id`, or an earlier daemon run's offer was found: none again.
    pub fn offer(&mut self, id: String) {
        self.offered = Some(id);
    }

    /// The corrections to rewrite from, once, for the offer `id`; None when it is not this chat's
    /// offer or was asked already.
    pub fn take_ask(&mut self, id: &str) -> Option<(Vec<String>, usize)> {
        if self.asked || self.offered.as_deref() != Some(id) {
            return None;
        }
        self.asked = true;
        Some((self.corrections.clone(), self.count))
    }

    /// The offer `id` whose rewrite a chat's log already holds: never asked again.
    pub fn offer_made(&mut self, id: String) {
        self.offered = Some(id);
        self.asked = true;
    }

    /// An offer that was never logged and has no id to stand in for it: none held, so a later
    /// turn may log one.
    pub fn forget_offer(&mut self) {
        self.offered = None;
    }

    /// The offer logged, if any.
    pub fn offered(&self) -> Option<&str> {
        self.offered.as_deref()
    }

    /// Every correction counted.
    pub fn count(&self) -> usize {
        self.count
    }

    /// The rewrite could not be made: it may be asked again.
    pub fn ask_failed(&mut self) {
        self.asked = false;
    }
}

/// `text` cut to `max` characters, trimmed.
pub fn cut(text: &str, max: usize) -> String {
    let text = text.trim();
    match text.char_indices().nth(max) {
        Some((end, _)) => format!("{}…", text.get(..end).unwrap_or(text).trim_end()),
        None => text.to_owned(),
    }
}

/// Whether the person's prompt corrects or redirects the agent: a memory inbox correction ("no,
/// use pnpm"), or a prompt that opens with not that, actually, hmm no, or says it re-explains ("I
/// meant", "still wrong", "let me rephrase"). Simple, conservative words only: a prompt that
/// asks for something new is not one.
pub fn is_redirect(text: &str) -> bool {
    if crate::memory_inbox::is_correction(text) {
        return true;
    }
    let text: String = text.chars().take(600).collect::<String>().to_lowercase();
    let text = text.trim().replace('’', "'");
    const OPENERS: &[&str] = &[
        "actually ",
        "not that",
        "not what i",
        "hmm, no",
        "hmm no",
        "ugh",
        "still ",
        "again,",
        "try again",
        "that's not",
        "that isn't",
        "that is not",
        "this is not",
        "this isn't",
        "it's still",
        "it still",
    ];
    const PHRASES: &[&str] = &[
        "not what i asked",
        "not what i meant",
        "not what i wanted",
        "that's not what",
        "that is not what",
        "i meant ",
        "what i meant",
        "what i want is",
        "what i wanted was",
        "i said ",
        "as i said",
        "like i said",
        "i already said",
        "i already told",
        "i told you",
        "i asked for",
        "i asked you to",
        "let me rephrase",
        "let me clarify",
        "to clarify",
        "you misunderstood",
        "you misread",
        "you missed",
        "you ignored",
        "still wrong",
        "still broken",
        "still not",
        "still doesn't",
        "still does not",
        "still fails",
        "didn't work",
        "did not work",
        "please re-read",
        "read it again",
    ];
    OPENERS.iter().any(|o| text.starts_with(o)) || PHRASES.iter().any(|p| text.contains(p))
}

/// What the small model is asked: the first prompt and the corrections only, as quoted material.
pub fn rewrite_prompt(first: &str, corrections: &[String]) -> String {
    let mut out = String::from(
        "A person asked a coding agent for something, then had to correct it several times before \
         the result was right. Rewrite their first message as the one message that would have got \
         it right the first time: keep their goal and voice, and add every file, constraint, tool \
         and detail the corrections reveal. Write it as the person, to the agent. Answer with the \
         rewritten message only: no preamble, no quotes, no explanation, no markdown heading. Keep \
         it about as short as it can be.\n\n<first_message>\n",
    );
    out.push_str(&cut(first, MAX_PROMPT_CHARS));
    out.push_str("\n</first_message>\n");
    for (n, correction) in corrections.iter().enumerate() {
        out.push_str(&format!("\n<correction n=\"{}\">\n{correction}\n</correction>\n", n + 1));
    }
    out
}

/// The rewrite as kept: trimmed, wrapping quotes or a fence removed, capped; None when empty.
pub fn clean_rewrite(text: &str) -> Option<String> {
    let mut text = text.trim();
    if let Some(inner) = text.strip_prefix("```").and_then(|t| t.strip_suffix("```")) {
        // A fence's first line may name a language.
        text = inner.split_once('\n').map_or(inner, |(head, rest)| {
            if head.trim().chars().all(|c| c.is_alphanumeric()) { rest } else { inner }
        });
        text = text.trim();
    }
    for (open, close) in [('"', '"'), ('“', '”')] {
        if let Some(inner) = text.strip_prefix(open).and_then(|t| t.strip_suffix(close)) {
            text = inner.trim();
        }
    }
    (!text.is_empty()).then(|| cut(text, MAX_REWRITE_CHARS))
}

#[cfg(test)]
#[path = "prompt_coach_tests.rs"]
mod tests;
