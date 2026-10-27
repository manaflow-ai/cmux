//! Sessions an agent offers the person (cx-807da): work it noticed outside
//! the task at hand, as a chip in the chat that starts a parallel session.
//!
//! The agent's `offer_session` tool (`offer_mcp.rs`) calls
//! `_acpmux/offer_session {sessionId, title, prompt, cwd?, worktree?,
//! harness?, model?}`, which records `session_offer` and returns at once:
//! the turn goes on, and the chat shows the chip. The person accepts it (the
//! pane starts the new session, in a new git worktree when asked, and sends
//! the prompt) or dismisses it: `_acpmux/offer_respond {sessionId, offerId,
//! outcome, childSessionId?}`, accepted only from the person's connection,
//! records `session_offer_decision`. An accepted offer's new session records
//! the offering session as its parent (`parentId`, with no `forkSeq`: it is
//! not a fork), and becomes its sub-session (`Hub::offer_link`). Outcome `here` (cx-lo9yf) starts no chat: the page sends the
//! prompt to this chat itself.
//!
//! Suggested tasks (cx-lo9yf): the agent's `suggest_tasks` tool offers each
//! task with one shared `groupId`, which `session_offer` records, so the chat
//! shows them as one card. When an accepted offer's chat ends its first turn,
//! its reply comes back to this chat (`offer_results.rs`).
//!
//! - The records are the state: an offer is open until its decision is
//!   recorded, across daemon restarts. The daemon reads a chat's records
//!   once, at its first offer call, and keeps its open offers from then on.
//!   A chat holds at most [`OPEN_LIMIT`] open offers.
//! - Only a chat started after the offer takes it, and only one without a
//!   parent. A chat a remote device started offers none.
//! - Title, prompt and folder are the agent's text: the chip shows them as
//!   plain text, and nothing runs before the person accepts.

use super::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex as StdMutex};

pub(super) const MAX_TITLE_CHARS: usize = 80;
pub(super) const MAX_PROMPT_CHARS: usize = 20_000;
pub(super) const OPEN_LIMIT: usize = 8;
const MAX_NAME_CHARS: usize = 120;
/// Longest `groupId`, in bytes.
const MAX_GROUP_BYTES: usize = 64;

/// Each chat's open offers (id to when it was made, Unix ms), read from its
/// records at its first offer call.
#[derive(Default)]
pub(crate) struct Offers {
    open: StdMutex<HashMap<String, HashMap<String, u64>>>,
    /// Chats whose suggested-task result this daemon sends or sent (`offer_results.rs`).
    pub(super) results: StdMutex<HashSet<String>>,
}

impl Offers {
    /// Drop chat `id`'s open offers on import: its records may have moved on
    /// on another daemon, so the next use reads them again.
    pub(crate) fn forget(&self, id: &str) {
        self.open.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }
}

/// The offer `params` describe, checked: what `session_offer` records.
fn offer_record(session: &Session, params: &Value) -> Result<Value, RpcError> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).map(str::trim).unwrap_or("");
    let title = text("title");
    if title.is_empty() || title.chars().count() > MAX_TITLE_CHARS {
        return Err(RpcError::invalid_params(format!(
            "title must be 1 to {MAX_TITLE_CHARS} characters"
        )));
    }
    let prompt = text("prompt");
    if prompt.is_empty() || prompt.chars().count() > MAX_PROMPT_CHARS {
        return Err(RpcError::invalid_params(format!(
            "prompt must be 1 to {MAX_PROMPT_CHARS} characters"
        )));
    }
    let cwd = match text("cwd") {
        "" => session.meta().cwd,
        given => {
            let path = Path::new(given);
            if !path.is_absolute() || !path.is_dir() {
                return Err(RpcError::invalid_params("cwd must be an existing absolute folder"));
            }
            path.to_path_buf()
        }
    };
    let worktree = match params.get("worktree") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(RpcError::invalid_params("worktree must be true or false")),
    };
    let mut record = json!({
        "offerId": super::person::new_nonce(),
        "title": title,
        "prompt": prompt,
        "cwd": cwd,
        "worktree": worktree,
    });
    match params.get("groupId") {
        None | Some(Value::Null) => {}
        Some(Value::String(group)) if one_line(group, MAX_GROUP_BYTES) => {
            record["groupId"] = Value::String(group.clone());
        }
        Some(_) => {
            return Err(RpcError::invalid_params(format!(
                "groupId must be one line of 1 to {MAX_GROUP_BYTES} bytes"
            )));
        }
    }
    for key in ["harness", "model"] {
        let value = text(key);
        if value.chars().count() > MAX_NAME_CHARS {
            return Err(RpcError::invalid_params(format!("{key} is too long")));
        }
        if !value.is_empty() {
            record[key] = Value::String(value.to_owned());
        }
    }
    Ok(record)
}

/// Whether `value` is one line of 1 to `max` bytes: no control or line break.
fn one_line(value: &str, max: usize) -> bool {
    let shown = |c: char| !c.is_control() && (c == ' ' || !c.is_whitespace());
    !value.trim().is_empty() && value.len() <= max && value.chars().all(shown)
}

impl Hub {
    /// Records the agent's offer; the chat shows it as a chip.
    pub fn offer_session(&self, session: &Session, params: &Value) -> Result<Value, RpcError> {
        if session.meta().remote_origin {
            return Err(RpcError::invalid_params("a chat a remote device started offers no chats"));
        }
        let record = offer_record(session, params)?;
        let offer_id = record["offerId"].as_str().unwrap_or_default().to_owned();
        self.with_open_offers(session, |open| {
            if open.len() >= OPEN_LIMIT {
                return Err(RpcError::invalid_params(format!(
                    "this chat already has {OPEN_LIMIT} open offers; wait for the user to answer them"
                )));
            }
            open.insert(offer_id.clone(), crate::store::now_ms());
            Ok(())
        })?;
        self.append(session, "mux", "session_offer", record);
        Ok(json!({"offerId": offer_id, "outcome": "offered"}))
    }

    /// The person's answer to an open offer: `accepted` names the session it
    /// started (`childSessionId`), which takes this chat as its parent;
    /// `here` and `dismissed` start none.
    pub fn answer_offer(
        self: &Arc<Self>,
        session: &Session,
        offer_id: &str,
        outcome: &str,
        child: Option<&str>,
    ) -> Result<Value, RpcError> {
        let child = match (outcome, child) {
            ("dismissed" | "here", None) => None,
            ("accepted", Some(key)) => {
                let child = self.resolve(key)?;
                if child.id == session.id {
                    return Err(RpcError::invalid_params("an offer cannot start its own chat"));
                }
                Some(child)
            }
            ("accepted", None) => {
                return Err(RpcError::invalid_params("an accepted offer names childSessionId"));
            }
            _ => {
                return Err(RpcError::invalid_params(
                    "outcome must be accepted (with childSessionId), here or dismissed",
                ));
            }
        };
        let no_offer = || RpcError::invalid_params("no open offer has that offerId");
        let offered_at = self
            .with_open_offers(session, |open| Ok(open.get(offer_id).copied()))?
            .ok_or_else(no_offer)?;
        // The task's title names the sub-session (`subsessions.rs`).
        let title = child.as_ref().and_then(|_| self.offer_title(session, offer_id));
        // Made before the chat's lock is taken: `offer_link` reads this
        // chat's meta, and two chats never hold each other's meta locks.
        let link = child.as_ref().map(|_| self.offer_link(session, title.as_deref()));
        let lineage = child.as_ref().map(|_| self.lineage_under(&session.meta(), None));
        if let Some(child) = &child {
            // Checked and set under the chat's lock: one parent, and only a chat
            // started for this offer.
            let mut meta = child.meta.lock().unwrap_or_else(|e| e.into_inner());
            if meta.parent_id.is_some() || meta.fork_seq.is_some() || meta.created_at < offered_at {
                return Err(RpcError::invalid_params(
                    "childSessionId must be a new chat started for this offer",
                ));
            }
            // Closed under the offers lock: a second answer is refused.
            if !self.with_open_offers(session, |open| Ok(open.remove(offer_id).is_some()))? {
                return Err(no_offer());
            }
            meta.parent_id = Some(session.id.clone());
            // Its sub-session too, unless something already linked it.
            if meta.subsession.is_none() {
                meta.subsession = link.map(|mut link| {
                    link.short_name = self.subsessions.claim_name(&session.id, &link.short_name);
                    link
                });
                // And its place in the offering chat's tree (`lineage.rs`).
                if meta.lineage.is_none() {
                    meta.lineage = lineage;
                }
                if meta.status != super::SessionStatus::Closed {
                    self.subsessions.set_open(&session.id, &child.id, true);
                }
            }
        } else if !self.with_open_offers(session, |open| Ok(open.remove(offer_id).is_some()))? {
            return Err(no_offer());
        }
        let mut decision = json!({"offerId": offer_id, "outcome": outcome});
        if let Some(child) = &child {
            self.save_meta(child);
            // A running chat linked as a sub-session works below its new parent.
            self.refresh_parent_work_below(child);
            decision["childSessionId"] = Value::String(child.id.clone());
        }
        self.append(session, "mux", "session_offer_decision", decision.clone());
        // A chat whose first turn ended before this answer sends its result now.
        if let Some(child) = &child {
            self.send_offer_result(child);
        }
        Ok(decision)
    }

    /// Runs `f` on the chat's open offer ids, read from its records the first time.
    fn with_open_offers<T>(
        &self,
        session: &Session,
        f: impl FnOnce(&mut HashMap<String, u64>) -> Result<T, RpcError>,
    ) -> Result<T, RpcError> {
        let loaded =
            self.offers.open.lock().unwrap_or_else(|e| e.into_inner()).contains_key(&session.id);
        let read = if loaded { None } else { Some(self.recorded_open_offers(session)?) };
        let mut all = self.offers.open.lock().unwrap_or_else(|e| e.into_inner());
        let open = all.entry(session.id.clone()).or_insert_with(|| read.unwrap_or_default());
        f(open)
    }

    /// The title of the chat's recorded offer `offer_id`.
    fn offer_title(&self, session: &Session, offer_id: &str) -> Option<String> {
        let mut title = None;
        let _ = self.store.scan(&session.id, 0, &mut |event: EventRecord| {
            if event.dir == "mux"
                && event.kind == "session_offer"
                && event.msg.get("offerId").and_then(Value::as_str) == Some(offer_id)
            {
                title = event.msg.get("title").and_then(Value::as_str).map(str::to_owned);
                return false;
            }
            true
        });
        title
    }

    /// The ids of the chat's recorded offers without a recorded decision.
    fn recorded_open_offers(&self, session: &Session) -> Result<HashMap<String, u64>, RpcError> {
        // Streamed, not collected: a long chat's log stays on disk.
        let mut open = HashMap::new();
        self.store
            .scan(&session.id, 0, &mut |event: EventRecord| {
                if event.dir == "mux"
                    && let Some(id) = event.msg.get("offerId").and_then(Value::as_str)
                {
                    match event.kind.as_str() {
                        "session_offer" => {
                            open.insert(id.to_owned(), event.at);
                        }
                        "session_offer_decision" => {
                            open.remove(id);
                        }
                        _ => {}
                    }
                }
                true
            })
            .map_err(|e| RpcError::internal(format!("{e:#}")))?;
        Ok(open)
    }
}
