//! What bounds a chat's inbox and keeps a thread read fast (hq `docs/handbook/notice-flood.md`).
//!
//! 1. A program's notices fold: one thread per source and kind (`notice_key`), and a new notice
//!    replaces the older ones of its thread that nothing holds, the thread keeping a count of
//!    what it folded ([`Inbox::folded`]). The journal keeps every original.
//! 2. A read message past [`ARCHIVE_AGE_MS`] leaves memory for the chat's compact archive file
//!    (`inbox-archive.jsonl`, one message a line). Anything a person addressed stays.
//! 3. A thread read takes memory, then the archive file for the threads it names: never the
//!    chat's whole journal, which is gigabytes for a coordinator.
use super::*;
use std::collections::{HashMap, HashSet};
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// A read message older than this leaves memory for the archive file.
pub(super) const ARCHIVE_AGE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// The archive file in a chat's folder.
const ARCHIVE_FILE: &str = "inbox-archive.jsonl";
/// The header of a program notice: `[notice from SRC on HOST · LEVEL] ...` (`inbox_notice_text`).
const NOTICE_HEAD: &str = "[notice from ";

/// The level (`FIRE`, `WARN`, ...) a program notice's header names, lowercased.
fn notice_level(text: &str) -> Option<String> {
    let head = text.strip_prefix(NOTICE_HEAD)?.split(']').next()?;
    let level = head.rsplit_once(" \u{b7} ")?.1.trim();
    (!level.is_empty() && level.len() <= 16 && level.bytes().all(|b| b.is_ascii_alphanumeric()))
        .then(|| level.to_ascii_lowercase())
}

/// Whether `text` is a program's notice.
pub(super) fn is_program_notice(text: &str) -> bool {
    text.starts_with(NOTICE_HEAD)
}

/// A notice's thread: its sender and kind, never the pull request its first line happens to name
/// (one `ws-check-coverage` FIRE listing eight PRs opened a thread per PR). None for a message
/// that is no notice.
pub(super) fn notice_key(prefix: &str, text: &str) -> Option<String> {
    if !is_program_notice(text) {
        return None;
    }
    Some(match notice_level(text) {
        Some(level) => format!("{prefix}/{level}"),
        None => prefix.to_owned(),
    })
}

/// `thread` as a notice's thread reads now: `from:SRC/pr:N` journaled before the fold is
/// `from:SRC/kind`. A thread of no notice, or one a person named, is as it was.
pub(super) fn refolded(thread: String, text: &str) -> String {
    if !is_program_notice(text) {
        return thread;
    }
    let prefix = match thread.rsplit_once("/pr:") {
        Some((prefix, n)) if n.bytes().all(|b| b.is_ascii_digit()) => prefix,
        _ if thread.starts_with("from:") || thread.starts_with("declared:") => &thread,
        _ => return thread,
    };
    if !(prefix.starts_with("from:") || prefix.starts_with("declared:")) {
        return thread;
    }
    // Already `.../level`: the level it names is the one it has.
    let level = notice_level(text);
    match level {
        Some(l) if prefix.ends_with(&format!("/{l}")) => prefix.to_owned(),
        _ => notice_key(prefix, text).unwrap_or(thread),
    }
}

/// Whether `item` may be folded into a newer notice of its thread: a program's notice nothing
/// holds. A notice an agent carries, a sender waits on, or a person asked is never folded.
fn foldable(item: &Item, carried: &HashSet<String>) -> bool {
    is_program_notice(&item.text)
        && item.asker.is_none()
        && item.reader.is_none()
        && item.answer.is_none()
        && !item.surge_held
        && !carried.contains(&item.prompt_id)
}

fn carried_ids(inbox: &Inbox) -> HashSet<String> {
    inbox
        .in_flight
        .iter()
        .map(|(_, ids)| ids)
        .chain(inbox.carrying.iter().map(|c| &c.ids))
        .flat_map(|ids| ids.iter().cloned())
        .collect()
}

/// Folds `thread`'s older program notices into its newest one; answers how many went.
pub(super) fn fold_thread(inbox: &mut Inbox, thread: &str) -> u64 {
    // The common case, a thread of no notice, costs one pass over the items and no allocation.
    let newest = inbox
        .items
        .iter()
        .filter(|i| i.thread == thread && is_program_notice(&i.text))
        .map(|i| i.at)
        .max();
    let Some(newest) = newest else { return 0 };
    let carried = carried_ids(inbox);
    let mut gone = 0u64;
    let items = std::mem::take(&mut inbox.items);
    let mut kept = Vec::with_capacity(items.len());
    // The newest is the one at `newest` that comes last; every earlier one that may fold does.
    let last = items.iter().rposition(|i| i.thread == thread && i.at == newest);
    for (at, item) in items.into_iter().enumerate() {
        if item.thread == thread && Some(at) != last && foldable(&item, &carried) {
            inbox.trimmed.insert(item.prompt_id);
            gone += 1;
        } else {
            kept.push(item);
        }
    }
    inbox.items = kept;
    if gone > 0 {
        *inbox.folded.entry(thread.to_owned()).or_default() += gone;
    }
    gone
}

/// [`fold_thread`] for every thread, in one pass: a restore folds what the journal replayed.
pub(super) fn fold_all(inbox: &mut Inbox) -> u64 {
    let carried = carried_ids(inbox);
    let mut last: HashMap<&str, usize> = HashMap::new();
    for (at, item) in inbox.items.iter().enumerate() {
        if is_program_notice(&item.text) {
            let slot = last.entry(item.thread.as_str()).or_insert(at);
            if inbox_at(&inbox.items, *slot) <= item.at {
                *slot = at;
            }
        }
    }
    let last: HashMap<String, usize> = last.into_iter().map(|(k, v)| (k.to_owned(), v)).collect();
    let mut gone: HashMap<String, u64> = HashMap::new();
    let items = std::mem::take(&mut inbox.items);
    let mut kept = Vec::with_capacity(items.len());
    for (at, item) in items.into_iter().enumerate() {
        let newest = last.get(&item.thread).copied();
        if newest.is_some_and(|n| n != at) && foldable(&item, &carried) {
            *gone.entry(item.thread.clone()).or_default() += 1;
            inbox.trimmed.insert(item.prompt_id);
        } else {
            kept.push(item);
        }
    }
    inbox.items = kept;
    let total = gone.values().sum();
    for (thread, n) in gone {
        *inbox.folded.entry(thread).or_default() += n;
    }
    total
}

fn inbox_at(items: &[Item], at: usize) -> u64 {
    items.get(at).map_or(0, |i| i.at)
}

/// An archive line: the message as a thread read shows it, and its thread.
pub(super) fn archive_line(item: &Item) -> Value {
    let mut line = message_json(item);
    if let Some(map) = line.as_object_mut() {
        map.insert("thread".into(), Value::String(item.thread.clone()));
    }
    line
}

/// The message as a thread read shows it.
fn message_json(item: &Item) -> Value {
    json!({
        "promptId": item.prompt_id, "from": display_sender(&item.sender, &item.from),
        "fromName": shown_sender(&item.sender, &item.from), "fromSession": item.from_session,
        "sender": item.sender, "class": item.class, "kind": kind_of(item.class), "at": item.at,
        "text": item.text, "read": item.read, "details": item.details,
        "notice": item.tool_notice, "surgeHeld": item.surge_held,
    })
}

/// Moves the read, noticed messages older than `now - age` out of memory, into
/// `inbox.archive_pending`. A message nobody read, a carried one, a person's question or answer
/// stays. Answers how many went.
pub(super) fn age_out(inbox: &mut Inbox, now: u64, age: u64) -> usize {
    let cutoff = now.saturating_sub(age);
    let carried = carried_ids(inbox);
    let aged = |i: &Item| {
        i.read
            && i.noticed
            && i.at < cutoff
            && i.asker.is_none()
            && i.reader.is_none()
            && !i.surge_held
            && !carried.contains(&i.prompt_id)
            && !person_addressed(i)
    };
    if !inbox.items.iter().any(aged) {
        return 0;
    }
    let items = std::mem::take(&mut inbox.items);
    let mut kept = Vec::with_capacity(items.len());
    let mut n = 0;
    for item in items {
        if aged(&item) {
            inbox.archive_pending.push(archive_line(&item));
            inbox.archived_threads.insert(item.thread.clone());
            inbox.trimmed.insert(item.prompt_id);
            n += 1;
        } else {
            kept.push(item);
        }
    }
    inbox.items = kept;
    n
}

/// A message the person wrote or was asked: never archived.
fn person_addressed(item: &Item) -> bool {
    item.sender.get("actorKind").and_then(Value::as_str) == Some("person")
        || crate::surge_triage::needs_person(
            item.class.as_str(),
            &item.text,
            super::presence::owner_name(),
        )
}

/// Appends `lines` to the archive in `dir`, skipping ids it holds. One write, one file.
pub(super) fn append_archive(dir: &Path, lines: &[Value]) -> std::io::Result<()> {
    if lines.is_empty() {
        return Ok(());
    }
    let path = dir.join(ARCHIVE_FILE);
    let have: HashSet<String> = read_archive(&path, |_| true)
        .into_iter()
        .filter_map(|l| l.get("promptId").and_then(Value::as_str).map(str::to_owned))
        .collect();
    let mut out = String::new();
    for line in lines {
        if line.get("promptId").and_then(Value::as_str).is_some_and(|id| have.contains(id)) {
            continue;
        }
        out.push_str(&line.to_string());
        out.push('\n');
    }
    if out.is_empty() {
        return Ok(());
    }
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    file.write_all(out.as_bytes())
}

/// The archive's lines `keep` keeps. A line that does not read is skipped: the file is a cache
/// of the journal, which keeps every original.
fn read_archive(path: &Path, mut keep: impl FnMut(&Value) -> bool) -> Vec<Value> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    text.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter(|v| keep(v)).collect()
}

/// The threads the archive holds, and the ones a journal read already filled it with.
pub(super) fn archive_threads(dir: &Path) -> (HashSet<String>, HashSet<String>) {
    let (mut held, mut scanned) = (HashSet::new(), HashSet::new());
    for line in read_archive(&dir.join(ARCHIVE_FILE), |_| true) {
        if let Some(t) = line.get("thread").and_then(Value::as_str) {
            held.insert(t.to_owned());
        } else if let Some(t) = line.get("scanned").and_then(Value::as_str) {
            scanned.insert(t.to_owned());
        }
    }
    (held, scanned)
}

/// `thread`'s archived messages, newest first.
pub(super) fn archived_thread(dir: &Path, thread: &str) -> Vec<Value> {
    let mut found = read_archive(&dir.join(ARCHIVE_FILE), |l| l["thread"].as_str() == Some(thread));
    for line in &mut found {
        if let Some(map) = line.as_object_mut() {
            map.remove("thread");
        }
    }
    found.sort_by_key(|m| std::cmp::Reverse(m["at"].as_u64().unwrap_or(0)));
    found
}

/// Records that `thread` was read from the journal, whole, and is in the archive from now on.
pub(super) fn mark_scanned(dir: &Path, thread: &str) -> std::io::Result<()> {
    let mut file =
        std::fs::OpenOptions::new().create(true).append(true).open(dir.join(ARCHIVE_FILE))?;
    writeln!(file, "{}", json!({"scanned": thread}))
}

impl Hub {
    fn inbox_archive_dir(&self, session: &Session) -> Option<PathBuf> {
        self.store.session_path(&session.id).filter(|p| p.is_dir())
    }

    /// Ages out the old read messages and writes what left memory to the chat's archive.
    /// A chat with no folder (the memory store) keeps everything in memory.
    pub(super) fn archive_aged_inbox(&self, session: &Session) {
        let Some(dir) = self.inbox_archive_dir(session) else {
            // Nowhere to write: nothing leaves memory, and nothing waits to.
            session.inbox().archive_pending.clear();
            return;
        };
        let pending = {
            let mut inbox = session.inbox();
            age_out(&mut inbox, now_ms(), ARCHIVE_AGE_MS);
            std::mem::take(&mut inbox.archive_pending)
        };
        self.write_archive(session, &dir, pending);
    }

    /// Writes `lines`; a write that fails puts the messages back where they were (the journal
    /// holds them either way, so a thread read still finds them).
    pub(super) fn write_archive(&self, session: &Session, dir: &Path, lines: Vec<Value>) {
        if lines.is_empty() {
            return;
        }
        if let Err(e) = append_archive(dir, &lines) {
            tracing::warn!(session = %session.id, "inbox archive write failed: {e}");
        }
    }

    /// The messages of `thread` that left memory, newest first: the archive's, and, for a thread
    /// whose held messages [`trim`] let go before the archive existed, the journal's, read once
    /// and kept in the archive from then on.
    pub(super) fn archived_inbox_thread(
        &self,
        session: &Session,
        thread: &str,
        journal_fallback: bool,
    ) -> Vec<Value> {
        let Some(dir) = self.inbox_archive_dir(session) else { return Vec::new() };
        if !journal_fallback || archive_threads(&dir).1.contains(thread) {
            return archived_thread(&dir, thread);
        }
        let mut found: Vec<Value> = Vec::new();
        let scan = self.scan_for_rebuild(session, &["inbox"], &mut |record| {
            let msg = &record.msg;
            if msg["surgeHeld"].as_bool() == Some(true) && msg["threadId"].as_str() == Some(thread)
            {
                let from = msg["from"].as_str().unwrap_or_default();
                let sender = &msg["sender"];
                found.push(json!({
                    "promptId": msg["promptId"], "thread": thread,
                    "from": display_sender(sender, from),
                    "fromName": shown_sender(sender, from), "fromSession": msg["fromSession"],
                    "sender": sender, "class": msg["class"], "kind": msg["kind"],
                    "at": record.at, "text": msg["text"], "read": false,
                    "details": msg.pointer("/_meta/provenance/details").cloned(),
                    "notice": Value::Null, "surgeHeld": true,
                }));
            }
            true
        });
        if scan.is_err() {
            return Vec::new();
        }
        let _ = append_archive(&dir, &found);
        let _ = mark_scanned(&dir, thread);
        archived_thread(&dir, thread)
    }
}
