//! A chat's last agent replies, kept beside its log so a read is O(1), not a scan
//! (`_acpmux/last_replies`, `acpmux session last-message`).
//!
//! `acpmux last` read the newest transcript records back in growing pages and folded them on the
//! client: a Codex chat whose last reply sat behind a long run of command output (each update
//! carries the whole output so far, `store/superseded.rs`) made the daemon parse about 100 MB of
//! log for 271 records, 2.7 s of a 2 s-plus `acpmux last` (13,642 events, 110 MB of segments,
//! 2026-11-27). The replies themselves are a few KB.
//!
//! [`ReplyFold`] is the state machine of the daemon's own reply read (`subsessions.rs`
//! `masked_reply`): a reply is a run of the chat's own `agent_message_chunk` updates, ended by a
//! tool call, its update, a thought, a plan, or a new prompt (`turn_started`, `user_message`);
//! replayed history and a harness subagent's updates change nothing. A chat's slot
//! ([`ReplySlot`]) folds each stored record on the append path, once it is seeded: the first read
//! after a daemon start walks the log back from its end only until it has [`KEEP`] whole replies
//! ([`seed`]), and every later read costs the records stored since the slot last saw one (none
//! while the append path keeps it current). A record stored by a path that skipped the fold is
//! read from the log by the next read, so the slot never misses one.
//!
//! Bounded: a slot holds at most [`KEEP`] replies of at most [`MAX_REPLY_BYTES`] each, and only
//! chats read at least once since the daemon started hold one.

use std::collections::VecDeque;

use serde_json::Value;

use crate::rpc::method;
use crate::store::EventRecord;

/// The most replies a slot keeps (`acpmux last -n` reads up to this many from it).
pub const KEEP: usize = 8;
/// The most bytes of one reply a slot keeps; past it, the reply's start is kept.
pub const MAX_REPLY_BYTES: usize = 256 << 10;
/// Records read per page by a seed or a gap fill.
const PAGE: usize = 512;

/// What one record does to the replies.
#[derive(Debug, PartialEq, Eq)]
enum Step<'a> {
    /// Changes nothing.
    Ignore,
    /// Ends the open reply.
    Close,
    /// Extends the open reply, or starts one.
    Chunk(&'a str),
}

fn step(e: &EventRecord) -> Step<'_> {
    if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "user_message") {
        return Step::Close;
    }
    let update = e.dir == "in"
        && !e.kind.ends_with(".replay")
        && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
        && e.msg.pointer("/params/_meta/acpmux/subagent").is_none();
    if !update {
        return Step::Ignore;
    }
    match e.kind.as_str() {
        "agent_message_chunk" => Step::Chunk(
            e.msg
                .pointer("/params/update/content/text")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        ),
        "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => Step::Close,
        _ => Step::Ignore,
    }
}

/// The kinds a seed reads: every other record is [`Step::Ignore`], so the store skips it by its
/// head, unparsed (a Codex chat's raw app-server lines, its usage and mode records).
const SEED_KINDS: &[&str] = &[
    "agent_message_chunk",
    "tool_call",
    "tool_call_update",
    "agent_thought_chunk",
    "plan",
    "turn_started",
    "user_message",
];

fn push_capped(into: &mut String, text: &str) {
    let room = MAX_REPLY_BYTES.saturating_sub(into.len());
    if text.len() <= room {
        into.push_str(text);
        return;
    }
    let mut cut = room;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    into.push_str(&text[..cut]);
}

/// The last [`KEEP`] replies of the records folded so far, oldest first.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ReplyFold {
    replies: VecDeque<String>,
    /// The newest reply still grows with the next chunk.
    open: bool,
}

impl ReplyFold {
    pub fn apply(&mut self, e: &EventRecord) {
        match step(e) {
            Step::Ignore => {}
            Step::Close => self.open = false,
            Step::Chunk(text) => {
                if !self.open {
                    if self.replies.len() == KEEP {
                        self.replies.pop_front();
                    }
                    self.replies.push_back(String::new());
                    self.open = true;
                }
                if let Some(last) = self.replies.back_mut() {
                    push_capped(last, text);
                }
            }
        }
    }

    /// The newest reply, trimmed; None before any or when it holds no words: `masked_reply`'s
    /// answer before its mask.
    #[cfg(test)]
    pub fn last(&self) -> Option<&str> {
        self.replies.back().map(|r| r.trim()).filter(|r| !r.is_empty())
    }

    /// The newest `count` replies with words in them, trimmed, oldest first.
    pub fn newest(&self, count: usize) -> Vec<&str> {
        let mut out: Vec<&str> = self
            .replies
            .iter()
            .rev()
            .map(|r| r.trim())
            .filter(|r| !r.is_empty())
            .take(count)
            .collect();
        out.reverse();
        out
    }
}

/// Builds the fold of a whole log from its records read newest first: exact once it has seen
/// [`KEEP`] whole replies, so a seed stops there ([`Seed::push`] returns false).
#[derive(Debug, Default)]
pub struct Seed {
    /// Whole replies, newest first.
    whole: Vec<String>,
    /// The chunks of the reply being read, newest first.
    current: Option<Vec<String>>,
    /// Whether the newest record that counts was a chunk (the fold's `open`); None before one.
    open: Option<bool>,
}

impl Seed {
    /// One record, older than every one before it. False: the fold is known, read no further.
    pub fn push(&mut self, e: &EventRecord) -> bool {
        match step(e) {
            Step::Ignore => {}
            Step::Chunk(text) => {
                self.open.get_or_insert(true);
                self.current.get_or_insert_with(Vec::new).push(text.to_owned());
            }
            Step::Close => {
                self.open.get_or_insert(false);
                self.end_reply();
            }
        }
        self.whole.len() < KEEP
    }

    fn end_reply(&mut self) {
        if let Some(chunks) = self.current.take() {
            let mut reply = String::new();
            for chunk in chunks.iter().rev() {
                push_capped(&mut reply, chunk);
            }
            self.whole.push(reply);
        }
    }

    /// The fold, after the log's first record (or once [`Seed::push`] said stop).
    pub fn finish(mut self) -> ReplyFold {
        if self.whole.len() < KEEP {
            self.end_reply();
        }
        let replies = self.whole.into_iter().take(KEEP).rev().collect();
        ReplyFold { replies, open: self.open.unwrap_or(false) }
    }
}

/// A chat's slot: its fold through `through`, once seeded.
#[derive(Debug, Default)]
pub struct ReplySlot {
    seeded: bool,
    through: u64,
    fold: ReplyFold,
}

impl ReplySlot {
    /// The append path's fold of one stored record: only the next one, so a record the fold did
    /// not see first is read from the log by the next read, in order.
    pub fn record(&mut self, e: &EventRecord) {
        if self.seeded && e.seq == self.through + 1 {
            self.fold.apply(e);
            self.through = e.seq;
        }
    }
}

fn last_seq(s: &super::Session) -> u64 {
    s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).last_seq
}

/// The most bytes of replies, as JSON, one answer carries: a reply page
/// ([`crate::rpc::REPLY_PAGE_BYTES`]) less room for the framing. [`KEEP`] replies of
/// [`MAX_REPLY_BYTES`] each would pass the frame cap, so the oldest are left out past it.
const ANSWER_BUDGET: usize = crate::rpc::REPLY_PAGE_BYTES - (16 << 10);

fn answer(fold: &ReplyFold, count: usize) -> Vec<String> {
    let masked: Vec<String> =
        fold.newest(count.clamp(1, KEEP)).into_iter().map(crate::secret_scan::mask).collect();
    within_budget(masked, ANSWER_BUDGET)
}

/// The newest of `replies` (oldest first) whose JSON fits in `budget` bytes; the newest one
/// always, cut to fit.
fn within_budget(mut replies: Vec<String>, budget: usize) -> Vec<String> {
    let json_len = |r: &str| serde_json::to_string(r).map_or(r.len(), |s| s.len()) + 1;
    // The array's brackets; each reply counts its comma.
    let mut used = 2;
    let mut keep = 0;
    for r in replies.iter().rev() {
        let len = json_len(r);
        if keep > 0 && used + len > budget {
            break;
        }
        used += len;
        keep += 1;
    }
    let mut out = replies.split_off(replies.len() - keep);
    if let Some(newest) = out.last_mut() {
        while json_len(newest) + 2 > budget {
            let mut cut = newest.len() / 2;
            while !newest.is_char_boundary(cut) {
                cut -= 1;
            }
            newest.truncate(cut);
        }
    }
    out
}

impl super::Hub {
    /// The chat's newest `count` replies (at most [`KEEP`]), masked, oldest first, and the last
    /// record they are of.
    pub fn last_replies(
        &self,
        s: &super::Session,
        count: usize,
    ) -> anyhow::Result<(Vec<String>, u64)> {
        let lock = || s.reply_slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for _ in 0..2 {
            let seeded = lock().seeded;
            if !seeded {
                let upto = last_seq(s);
                let fold = self.seed_replies(&s.id, upto)?;
                let mut slot = lock();
                if !slot.seeded {
                    *slot = ReplySlot { seeded: true, through: upto, fold };
                }
            }
            // Records stored that the fold has not seen: those a seed's read began after, or a
            // write the append path's fold skipped. Read off the lock, folded under it in order.
            loop {
                let (through, last) = (lock().through, last_seq(s));
                if last < through {
                    // The log is not the one the slot was made from (a reset): seed again.
                    *lock() = ReplySlot::default();
                    break;
                }
                if last == through {
                    let slot = lock();
                    return Ok((answer(&slot.fold, count), slot.through));
                }
                let page = self.events(&s.id, through, PAGE)?;
                let mut slot = lock();
                if page.is_empty() {
                    // The meta ran ahead of the store: answer with what the log holds.
                    let replies = answer(&slot.fold, count);
                    return Ok((replies, slot.through));
                }
                // In order; past a gap in the seqs too (a refused write leaves one).
                for e in &page {
                    if e.seq > slot.through {
                        slot.fold.apply(e);
                        slot.through = e.seq;
                    }
                }
            }
        }
        anyhow::bail!("the chat's log changed under the read twice")
    }

    /// The fold of the chat's records up to `upto`, read from its end back only as far as the
    /// last [`KEEP`] replies.
    fn seed_replies(&self, id: &str, upto: u64) -> anyhow::Result<ReplyFold> {
        let mut seed = Seed::default();
        let kinds = Value::from(SEED_KINDS.to_vec());
        let filter = super::paging::EventFilter::parse(Some(&kinds))
            .map_err(|e| anyhow::anyhow!("{e:?}"))?;
        let mut before = upto.saturating_add(1);
        loop {
            let page = self.events_page(id, 0, Some(before), PAGE, None, true, &filter)?;
            let Some(first) = page.events.first().map(|e| e.seq) else { break };
            let mut more = true;
            for e in page.events.iter().rev() {
                if !seed.push(e) {
                    more = false;
                    break;
                }
            }
            before = first;
            if !more || !page.has_more {
                break;
            }
        }
        Ok(seed.finish())
    }
}

#[cfg(test)]
#[path = "reply_slot_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "reply_slot_bench_tests.rs"]
mod bench_tests;
