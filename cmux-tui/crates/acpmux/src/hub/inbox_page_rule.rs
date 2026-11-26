//! Part of the inbox (`inbox.rs`). The page rule: in a coordinator's chat (config `pageRule`,
//! the coordinator list), another agent's message starts a turn only when it is a page. RFD 0041
//! slice 1 (cmuxterm-hq docs/rfd/0041-coordinator-load.md, hq#18716). Leo, 2026-11-22 13:47Z:
//! "i wonder if sometimes you have too much work/messages coming to you? ... the inbox/forum
//! situation ... keep trying to improve stuff". In 24 h three coordinators ran 1,292 turns; 85%
//! of the turns an agent's message started were status or FYI, and 273 were `[inbox]` notices
//! carrying a `[blocker]`, at least 120 of them from programs repeating a standing alarm.
//!
//! A page ([`Verdict::Page`]) is:
//! - a message from the person, or tagged for the person (`[leo]`, `[taste]`, `[irreversible]`,
//!   `[outward]`, `[physical]`);
//! - a block or a question from a session (a lane);
//! - a FIRE or a block or question from a sender with no session behind it (a program), the
//!   first time its text is seen; the same text again folds ([`Verdict::Fold`]) while it keeps
//!   coming, forgotten [`FOLD_MS`] after it was last seen, and pages again once [`REPAGE_MS`]
//!   passed since its last page. Changed text is a new page.
//!
//! Everything else (a result, an FYI, a report, a receipt) is held ([`Verdict::Hold`]): it wakes
//! no one, goes with the next notice (one line per thread, with its thread id, `render`), and
//! the inbox's flush brings it by itself once [`super::FLUSH_MS`] old (under the RFD's 20-minute
//! ceiling). A folded repeat starts no flush of its own: it goes with the next notice, which an
//! hourly repage of a standing alarm brings.
//!
//! Fail open: a message the rule cannot read (no text, no sender) has no verdict and wakes as it
//! did before the rule, and so does a message restored after a restart (the fold table is in
//! memory only, so a restart's first repeat pages again).

use super::*;
use std::collections::HashMap;

/// How long a program's repeated text stays folded after it was last seen.
pub(super) const FOLD_MS: u64 = 6 * 60 * 60 * 1000;
/// While a folded text keeps coming, it pages again this long after its last page.
pub(super) const REPAGE_MS: u64 = 60 * 60 * 1000;
/// The most texts the fold table remembers; the least recently seen go first.
const FOLDS_MAX: usize = 1024;
/// The tags that mark a message for the person (CLAUDE.md: "ask Leo only about taste, the
/// irreversible, outward or physical, tagged").
const PERSON_TAGS: [&str; 5] = ["[leo]", "[taste]", "[irreversible]", "[outward]", "[physical]"];

/// What the rule makes of a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::hub) enum Verdict {
    /// It wakes the chat.
    Page,
    /// It waits for the next notice or the flush.
    Hold,
    /// A repeat of a program's page: it waits for the next notice, and starts no flush.
    Fold,
}

/// What the rule reads of a message.
pub(super) struct Message<'a> {
    pub(super) class: PromptClass,
    pub(super) from: &'a str,
    /// A session sent it (this host's or a peer's), not a program.
    pub(super) has_session: bool,
    /// The person sent it (an authenticated human).
    pub(super) human: bool,
    /// A tool's notice of severity `fire`, or text that starts with `FIRE`.
    pub(super) fire: bool,
    /// A tool's notice's title.
    pub(super) title: Option<&'a str>,
    pub(super) text: &'a str,
}

/// One text the fold table remembers.
#[derive(Debug, Clone)]
struct Fold {
    last_page: u64,
    last_seen: u64,
    folded: u64,
}

/// A chat's fold table (`Inbox::folds`), keyed by sender and text.
#[derive(Default)]
pub(in crate::hub) struct Folds {
    by_key: HashMap<String, Fold>,
}

impl Folds {
    /// How many repeats of `m`'s text folded since it was last paged.
    #[cfg(test)]
    pub(super) fn folded(&self, m: &Message<'_>) -> u64 {
        self.by_key.get(&fold_key(m)).map_or(0, |f| f.folded)
    }
}

/// Whether chat `name` is on the coordinator list.
pub(in crate::hub) fn listed(cfg: &crate::config::Config, name: &str) -> bool {
    let name = name.trim();
    let Some(rule) = cfg.page_rule.as_ref() else { return false };
    !name.is_empty()
        && rule
            .sessions
            .iter()
            .map(|s| s.trim())
            .any(|s| s == name || s.rsplit_once('/').is_some_and(|(_, session)| session == name))
}

impl Hub {
    /// Leaves a background task's end that went well (`bg_notify.rs`) in the inbox of chat
    /// `session`, held as the page rule holds a result: it wakes no one, goes with the next
    /// notice, and the flush brings it by itself in time. RFD 0041 card rc-b18ea2ea: a
    /// coordinator's own exit-0 task ends were 13.6 turns an hour. Quiet: its sender waits for
    /// nothing. False when this chat's inbox cannot carry it (a review box, an agent that cannot
    /// read it, a chat closing): the caller sends it as a prompt, as before.
    ///
    /// Idempotent by `prompt_id`: one the inbox holds, carries or let go of is left as it is, so
    /// a restart between this and the caller's `.notified` mark adds it no second time (the log
    /// restores the first, `restore_inbox`; a restored item has no verdict and wakes as before
    /// the rule).
    pub(in crate::hub) fn inbox_hold_end(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        text: &str,
        provenance: &Value,
    ) -> bool {
        if super::queue::closing(session) || review_box(session) || !reads_inbox(session) {
            return false;
        }
        let from = provenance.get("fromName").and_then(Value::as_str).unwrap_or("acpmux");
        let thread = thread_key(None, &thread_sender(Some(provenance), from), text);
        let sender = crate::prompt_provenance::sender_record(Some(provenance), None, None);
        let fresh = {
            let mut inbox = session.inbox();
            if session.meta().status == SessionStatus::Closed {
                return false;
            }
            let known = inbox.items.iter().any(|i| i.prompt_id == prompt_id)
                || inbox.trimmed.contains(prompt_id)
                || inbox.removed.contains(prompt_id)
                || inbox.carrying.iter().any(|c| c.ids.iter().any(|id| id == prompt_id));
            if !known {
                inbox.items.push(Item {
                    surge_held: false,
                    verdict: Some(Verdict::Hold),
                    prompt_id: prompt_id.to_owned(),
                    notice: None,
                    answered: None,
                    thread: thread.clone(),
                    from: from.to_owned(),
                    from_session: None,
                    asker: None,
                    sender: sender.clone(),
                    class: PromptClass::Result,
                    report: false,
                    waited: false,
                    at: now_ms(),
                    within: None,
                    text: text.to_owned(),
                    details: None,
                    fire: false,
                    tool_notice: notice_of(Some(provenance), text),
                    noticed: false,
                    read: false,
                    answer: None,
                    reader: None,
                });
                trim(&mut inbox);
            }
            !known
        };
        if fresh {
            let msg = json!({
                "promptId": prompt_id, "threadId": thread, "from": from, "class": PromptClass::Result,
                "kind": kind_of(PromptClass::Result), "client": "acpmux", "text": text,
                "prompt": [{"type": "text", "text": text}], "sender": sender,
            });
            self.append(
                session,
                "mux",
                "inbox",
                crate::prompt_provenance::marked(msg, Some(provenance)),
            );
        }
        self.inbox_review(session);
        true
    }
}

/// Whether `text`'s first line says FIRE.
pub(super) fn fire_text(text: &str) -> bool {
    let first = text.trim_start().lines().next().unwrap_or("");
    let first = first.trim_start_matches(['[', '*', ' ']);
    first.starts_with("FIRE")
}

fn for_person(text: &str) -> bool {
    let lower = text.to_lowercase();
    PERSON_TAGS.iter().any(|t| lower.contains(t))
}

/// Whether `m` is a program's alarm, which folds when repeated.
fn foldable(m: &Message<'_>) -> bool {
    !m.has_session && (m.fire || m.class.urgent())
}

/// A notice folds by its condition (`notice_read::condition_key`): a repeat whose counts moved
/// ("9 queued", then "12 queued") is the same alarm, so it starts no new turn. A message with no
/// notice folds only when repeated word for word.
fn fold_key(m: &Message<'_>) -> String {
    match m.title.map(str::trim).filter(|t| !t.is_empty()) {
        Some(title) => {
            format!("{}\n{}", m.from.trim(), crate::notice_read::condition_key("", title))
        }
        None => format!("{}\n\n{}", m.from.trim(), m.text.trim()),
    }
}

/// The verdict on `m` at `now` (Unix ms); `None` when it cannot be read: it wakes as before.
pub(super) fn judge(folds: &Folds, m: &Message<'_>, now: u64) -> Option<Verdict> {
    if m.from.trim().is_empty() || (m.text.trim().is_empty() && m.title.is_none_or(str::is_empty)) {
        return None;
    }
    if m.human || for_person(m.text) || m.title.is_some_and(for_person) {
        return Some(Verdict::Page);
    }
    if foldable(m) {
        return Some(match folds.by_key.get(&fold_key(m)) {
            Some(f) if now.saturating_sub(f.last_seen) < FOLD_MS => {
                if now.saturating_sub(f.last_page) >= REPAGE_MS {
                    Verdict::Page
                } else {
                    Verdict::Fold
                }
            }
            _ => Verdict::Page,
        });
    }
    if m.class.urgent() || m.fire {
        return Some(Verdict::Page);
    }
    Some(Verdict::Hold)
}

/// Records `m`, judged `verdict` at `now`, in the fold table: only a program's alarm is kept.
pub(super) fn record(folds: &mut Folds, m: &Message<'_>, verdict: Verdict, now: u64) {
    if !foldable(m) {
        return;
    }
    folds.by_key.retain(|_, f| now.saturating_sub(f.last_seen) < FOLD_MS);
    let key = fold_key(m);
    if !folds.by_key.contains_key(&key) && folds.by_key.len() >= FOLDS_MAX {
        let oldest = folds.by_key.iter().min_by_key(|(_, f)| f.last_seen).map(|(k, _)| k.clone());
        if let Some(oldest) = oldest {
            folds.by_key.remove(&oldest);
        }
    }
    let f = folds.by_key.entry(key).or_insert(Fold { last_page: now, last_seen: now, folded: 0 });
    f.last_seen = now;
    match verdict {
        Verdict::Fold => f.folded += 1,
        _ => {
            f.last_page = now;
            f.folded = 0;
        }
    }
}
