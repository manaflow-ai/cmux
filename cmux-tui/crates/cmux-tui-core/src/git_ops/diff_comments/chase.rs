//! The chase: a thread the agent took and never answered goes back to it, so
//! no person has to relay it (Leo, 2026-11-22: "there's no point of me simply
//! being a fucking relay.").
//!
//! A threaded send marks each thread it carried as awaiting the agent that
//! took it: `sentTo` (the acpmux session), `sentAtMs`, and
//! `agentRepliesAtSend` (how many agent replies the thread had then). The
//! thread is answered once it has more agent replies than that, or is
//! resolved. One that is neither past its bound is overdue: the session host
//! hands that session one prompt naming every overdue thread it took, queued
//! behind a running turn and never steered into it, and counts the chase
//! (`chases`, `chasedAtMs`). Each chase doubles the wait before the next; after
//! [`MAX_CHASES`] the thread is `stalled`, for the page to show, and nothing
//! chases it again until the next send of it. The wait is read when the
//! timer fires, never when the send was made, so a reply that came in time
//! sends nothing.
//!
//! One timer thread per root, armed by a threaded send and, once per process,
//! for every stored root (a restart's awaiting threads), sleeping until the
//! next thread is due and ending when none awaits.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};
use std::time::Duration;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{File, Store, hex};
use crate::Mux;
use crate::mux::agent_message_pump::Handover;

/// The wait before the first chase, unless `CMUX_COMMENT_CHASE_BOUND_MS` sets it.
pub(super) const BOUND_MS: u64 = 10 * 60 * 1000;
/// The most chases of one send of a thread; then it is `stalled`.
pub(super) const MAX_CHASES: u64 = 3;
/// The shortest wait a bound may set, so a bad value never spins.
const MIN_BOUND_MS: u64 = 250;

/// The daemon's chase fields of a comment, kept through a page save.
pub(super) const FIELDS: [&str; 6] =
    ["sentTo", "sentAtMs", "agentRepliesAtSend", "chases", "chasedAtMs", "stalled"];

/// The first chase's wait.
pub(super) fn bound_ms() -> u64 {
    std::env::var("CMUX_COMMENT_CHASE_BOUND_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(BOUND_MS)
        .max(MIN_BOUND_MS)
}

fn number(comment: &Map<String, Value>, name: &str) -> Option<u64> {
    comment.get(name).and_then(Value::as_u64)
}

fn agent_replies(comment: &Map<String, Value>) -> u64 {
    comment
        .get("replies")
        .and_then(Value::as_array)
        .map(|replies| {
            replies
                .iter()
                .filter(|reply| reply.get("author").and_then(Value::as_str) == Some("agent"))
                .count() as u64
        })
        .unwrap_or(0)
}

/// Marks the threads a delivered send carried (`ids`) as awaiting `session`'s
/// answer from `now_ms`; a new send starts the thread's chases over.
pub(super) fn mark_awaiting(file: &mut File, ids: &[String], session: &str, now_ms: u64) {
    for comment in file.comments.iter_mut() {
        let Some(id) = comment.get("id").and_then(Value::as_str) else { continue };
        if !ids.iter().any(|named| named == id) {
            continue;
        }
        let answered = agent_replies(comment);
        comment.insert("sentTo".into(), Value::String(session.to_owned()));
        comment.insert("sentAtMs".into(), json!(now_ms));
        comment.insert("agentRepliesAtSend".into(), json!(answered));
        comment.insert("chases".into(), json!(0));
        comment.remove("chasedAtMs");
        comment.remove("stalled");
    }
}

/// Whether the thread waits on the agent: sent to a session, not resolved,
/// not stalled, with no agent reply since the send.
pub(super) fn awaiting(comment: &Map<String, Value>) -> bool {
    let sent = comment.get("sentTo").is_some_and(Value::is_string)
        && number(comment, "sentAtMs").is_some();
    let resolved = comment.get("resolved").and_then(Value::as_bool).unwrap_or(false);
    let stalled = comment.get("stalled").and_then(Value::as_bool).unwrap_or(false);
    let answered = agent_replies(comment) > number(comment, "agentRepliesAtSend").unwrap_or(0);
    sent && !resolved && !stalled && !answered
}

/// When an awaiting thread is next due: the send (or the last chase) plus
/// the bound, doubled per chase already made.
pub(super) fn due_ms(comment: &Map<String, Value>, bound_ms: u64) -> Option<u64> {
    if !awaiting(comment) {
        return None;
    }
    let chases = number(comment, "chases").unwrap_or(0);
    let since = number(comment, "chasedAtMs").or_else(|| number(comment, "sentAtMs"))?;
    let wait = bound_ms.saturating_mul(1u64 << chases.min(16));
    Some(since.saturating_add(wait))
}

/// One chase to hand over: a session and the overdue threads it took.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Chase {
    pub(super) session: String,
    pub(super) ids: Vec<String>,
    pub(super) prompt_id: String,
    pub(super) text: String,
}

/// The chases due at `now_ms`, one per session, threads in store order.
pub(super) fn plan(file: &File, root: &str, now_ms: u64, bound_ms: u64) -> Vec<Chase> {
    let mut chases: Vec<(String, Vec<&Map<String, Value>>)> = Vec::new();
    for comment in file.sorted() {
        if !due_ms(comment, bound_ms).is_some_and(|due| due <= now_ms) {
            continue;
        }
        let Some(session) = comment.get("sentTo").and_then(Value::as_str) else { continue };
        match chases.iter_mut().find(|(named, _)| named == session) {
            Some((_, threads)) => threads.push(comment),
            None => chases.push((session.to_owned(), vec![comment])),
        }
    }
    chases
        .into_iter()
        .map(|(session, threads)| {
            let ids: Vec<String> = threads
                .iter()
                .filter_map(|comment| comment.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect();
            let prompt_id = prompt_id(root, &session, &threads);
            let text = render(root, &threads, now_ms);
            Chase { session, ids, prompt_id, text }
        })
        .collect()
}

/// Stable for the same threads at the same chase, so a resend after a
/// restart never runs twice in acpmux.
fn prompt_id(root: &str, session: &str, threads: &[&Map<String, Value>]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("diff-comment-chase\0{root}\0{session}").as_bytes());
    for comment in threads {
        let id = comment.get("id").and_then(Value::as_str).unwrap_or_default();
        let sent = number(comment, "sentAtMs").unwrap_or(0);
        let chases = number(comment, "chases").unwrap_or(0);
        hasher.update(format!("\0{id}\0{sent}\0{chases}").as_bytes());
    }
    format!("dchase_{}", hex(hasher.finalize().get(..16).unwrap_or_default()))
}

fn render(root: &str, threads: &[&Map<String, Value>], now_ms: u64) -> String {
    let root_arg = format!("'{}'", root.replace('\'', r"'\''"));
    let count = threads.len();
    let mut text = format!(
        "{count} review thread{} you took {} no answer in {} yet.\n\n\
         Answer each in its thread with\n\
         `cmux git comments reply <thread id> --root {root_arg} --text '<your answer>'`\n\
         or resolve one you finished with\n\
         `cmux git comments resolve <thread id> --root {root_arg}`.\n\
         If you are still working on one, reply in it saying so.\n",
        if count == 1 { "" } else { "s" },
        if count == 1 { "has" } else { "have" },
        if count == 1 { "it" } else { "them" },
    );
    for comment in threads {
        let id = comment.get("id").and_then(Value::as_str).unwrap_or_default();
        let message = comment.get("message").and_then(Value::as_str).unwrap_or_default();
        let message = message.split_whitespace().collect::<Vec<_>>().join(" ");
        let minutes = now_ms.saturating_sub(number(comment, "sentAtMs").unwrap_or(now_ms)) / 60_000;
        text.push_str(&format!("\n- Thread {id} (sent {minutes} min ago): {message}\n"));
    }
    text
}

/// Counts a chase of `ids` at `now_ms`; a thread at [`MAX_CHASES`] is
/// `stalled`. Returns the ids now stalled.
pub(super) fn mark_chased(file: &mut File, ids: &[String], now_ms: u64) -> Vec<String> {
    let mut stalled = Vec::new();
    for comment in file.comments.iter_mut() {
        let Some(id) = comment.get("id").and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if !ids.contains(&id) || !awaiting(comment) {
            continue;
        }
        let chases = number(comment, "chases").unwrap_or(0) + 1;
        comment.insert("chases".into(), json!(chases));
        comment.insert("chasedAtMs".into(), json!(now_ms));
        if chases >= MAX_CHASES {
            comment.insert("stalled".into(), Value::Bool(true));
            stalled.push(id);
        }
    }
    stalled
}

/// The next time any thread of `file` is due.
pub(super) fn next_due_ms(file: &File, bound_ms: u64) -> Option<u64> {
    file.comments.iter().filter_map(|comment| due_ms(comment, bound_ms)).min()
}

/// One pass over `root`: hands over each due chase and counts it, under the
/// root's lock for the read and the mark (the hand-over runs outside it).
/// Returns when the root is next due, or `None` when nothing awaits.
pub(super) fn pass(
    store: &Store,
    root: &str,
    now_ms: u64,
    bound_ms: u64,
    mut hand_over: impl FnMut(&str, &str, String, Value) -> Handover,
) -> Option<u64> {
    let file = store.exclusive(root, || store.read(root)).ok()?;
    for chase in plan(&file, root, now_ms, bound_ms) {
        let meta = json!({"steer": false, "promptId": chase.prompt_id, "resend": true});
        // Counted whatever acpmux answers: a session that never takes one
        // still ends stalled, where the page shows it, instead of waiting on.
        let _ = hand_over(&chase.session, &chase.prompt_id, chase.text, meta);
        let _ = store.exclusive(root, || -> std::io::Result<()> {
            let mut file = store.read(root)?;
            mark_chased(&mut file, &chase.ids, now_ms);
            store.write(root, &file)
        });
    }
    let file = store.exclusive(root, || store.read(root)).ok()?;
    next_due_ms(&file, bound_ms)
}

fn armed() -> &'static Mutex<HashSet<PathBuf>> {
    static ARMED: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    ARMED.get_or_init(Mutex::default)
}

/// Starts `root`'s timer unless one runs. It holds the daemon weakly and
/// ends with it, or when nothing under the root awaits an answer.
pub(super) fn arm(mux: &Arc<Mux>, directory: PathBuf, root: String) {
    let key = directory.join(&root);
    if !armed().lock().unwrap_or_else(PoisonError::into_inner).insert(key.clone()) {
        return;
    }
    let mux: Weak<Mux> = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new().name("diff-comment-chase".into()).spawn({
        let key = key.clone();
        move || {
            let store = Store::at(directory);
            let bound = bound_ms();
            loop {
                let now = super::now_ms();
                let next = {
                    let Some(mux) = mux.upgrade() else { break };
                    pass(&store, &root, now, bound, |session, prompt_id, text, meta| {
                        mux.acp_prompt_diff_comments(session, prompt_id, text, meta)
                    })
                };
                let Some(next) = next else { break };
                let wait = next.saturating_sub(super::now_ms()).max(MIN_BOUND_MS);
                std::thread::sleep(Duration::from_millis(wait));
            }
            armed().lock().unwrap_or_else(PoisonError::into_inner).remove(&key);
        }
    });
    if spawned.is_err() {
        armed().lock().unwrap_or_else(PoisonError::into_inner).remove(&key);
    }
}

/// Once per process: a timer for each stored root with a thread awaiting an
/// answer, so a restart chases what the last process sent.
pub(super) fn arm_stored_once(mux: &Arc<Mux>, store: &Store) {
    static ONCE: OnceLock<()> = OnceLock::new();
    if ONCE.set(()).is_err() {
        return;
    }
    let bound = bound_ms();
    let Ok(entries) = std::fs::read_dir(&store.directory) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let Ok(Some(file)) = super::read_json::<File>(&path) else { continue };
        if next_due_ms(&file, bound).is_some() {
            arm(mux, store.directory.clone(), file.root().to_owned());
        }
    }
}

#[cfg(test)]
#[path = "chase_tests.rs"]
mod tests;
