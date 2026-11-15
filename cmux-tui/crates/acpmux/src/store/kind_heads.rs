//! A record's head for [`Store::scan_kinds_keyed`]: its kind and the ids a prompt's state follows,
//! not its text.
//!
//! A resend's prompt state (`hub/prompt_ledger.rs` `logged_prompt_state`) and an inbox answer
//! (`hub/inbox.rs` `logged_inbox_answer`) each want the few records of one prompt out of a chat's
//! indexed kinds, and a restart's resume pass asks them per session, per retry and per queued
//! prompt. A keyed scan shows the caller each record's head first and parses, and hands over, only
//! the records whose head it keeps.

use super::*;

/// What [`Store::scan_kinds_keyed`] shows of a record before it is read whole.
#[derive(Clone, Copy, Debug, Default)]
pub struct KindHead<'a> {
    pub kind: &'a str,
    /// `msg.promptId`.
    pub prompt_id: Option<&'a str>,
    /// `msg.turnId`.
    pub turn_id: Option<&'a str>,
    /// `msg.joinedTurnId` (a prompt that went into another's turn, `digest.rs`).
    pub joined_turn_id: Option<&'a str>,
    /// `msg.digestPromptId` (a prompt an inbox digest took, `inbox_digest.rs`).
    pub digest_prompt_id: Option<&'a str>,
    /// The record names other prompts by a list (`msg.promptIds`, `msg.took`,
    /// `msg._meta.provenance.parts`), which the head does not hold.
    pub names_many: bool,
    /// The head could not be read (an id that is not a string, a line that does not parse): a
    /// caller keeps it to learn.
    pub unread: bool,
}

impl<'a> KindHead<'a> {
    /// The head of a record read whole.
    pub fn of(rec: &'a EventRecord) -> Self {
        let field = |k: &str| rec.msg.get(k).and_then(Value::as_str);
        let unread = ["promptId", "turnId", "joinedTurnId", "digestPromptId"]
            .iter()
            .any(|k| rec.msg.get(*k).is_some_and(|v| !v.is_string() && !v.is_null()));
        Self {
            kind: &rec.kind,
            prompt_id: field("promptId"),
            turn_id: field("turnId"),
            joined_turn_id: field("joinedTurnId"),
            digest_prompt_id: field("digestPromptId"),
            names_many: rec.msg.get("promptIds").is_some()
                || rec.msg.get("took").is_some()
                || rec.msg.pointer("/_meta/provenance/parts").is_some(),
            unread,
        }
    }
}
