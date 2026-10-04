//! One turn (section 7): a fresh acpmux session in the constant session
//! directory, the prompt `[view, new messages]`, and everything the session
//! does folded into the log as it happens. The brain has already settled the
//! view, rendered it and logged the new messages; this runs on its own thread
//! so the brain keeps reading the conversation while the turn works.

use std::sync::mpsc::{RecvTimeoutError, TryRecvError, channel};
use std::time::{Duration, Instant};

use optchat_host::OptChat;
use serde_json::Value;

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::fold::{Entry, TurnFold, Usage, is_cancelled, stop_error};

/// Everything a turn needs, decided by the brain.
#[derive(Clone, Debug, PartialEq)]
pub struct TurnStart {
    /// The reply's idempotency key: `turn:optchat:<first new message id>`.
    pub key: String,
    /// The acpmux promptId (acpmux runs one id once).
    pub prompt_id: String,
    pub session: SessionSpec,
    /// The view pieces, then the new messages (prompt::turn_blocks).
    pub blocks: Vec<Value>,
    /// Longest a turn may run; past it the session is removed and the turn
    /// fails, so a turn that hangs in the harness cannot block every later
    /// message. None: no limit.
    pub limit: Option<Duration>,
}

/// A turn session that kept running after its acpmux connection was lost:
/// its later events are folded into the log, and it is removed, once acpmux
/// is back (section 7: everything the agent does is logged).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Orphan {
    pub session: String,
    /// The last event seq already folded.
    pub after: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TurnOutcome {
    /// The turn's final assistant text.
    pub reply: Option<String>,
    pub error: Option<String>,
    pub orphan: Option<Orphan>,
    /// The turn ended with stop reason `cancelled` (stopped for a newer message).
    pub cancelled: bool,
}

/// Runs the turn to its end; never panics on a port failure (it becomes the
/// outcome's error, and the brain posts it). `progress` hears the session id
/// once it exists and the fold position after each fetch that moved it.
pub fn run(
    agents: &dyn AgentPort,
    chat: &OptChat,
    start: &TurnStart,
    log: &dyn Fn(&str),
    progress: &dyn Fn(&str, u64),
) -> TurnOutcome {
    // The limit covers the session's start too: a harness that never
    // initializes must not hold the turn (and every later message) forever.
    let deadline = start.limit.map(|limit| Instant::now() + limit);
    let mut fold = TurnFold::new();
    let append = |entries: Vec<Entry>| {
        for entry in entries {
            if let Err(e) = chat.append(entry.kind, &entry.text) {
                log(&format!(
                    "logging a {} entry failed: {e}",
                    entry.kind.as_str()
                ));
            }
        }
    };
    // A session of this name is left from a host that stopped mid-turn.
    if let Ok(Some(old)) = agents.find(&start.session.name) {
        let _ = agents.end_session(&old);
    }
    let session = match agents.new_session(&start.session) {
        Ok(id) => id,
        Err(e) => {
            return TurnOutcome {
                error: Some(e),
                ..TurnOutcome::default()
            };
        }
    };
    progress(&session, 0);
    let (tx, rx) = channel();
    if let Err(e) = agents.start_prompt(&session, start.blocks.clone(), &start.prompt_id, tx) {
        let _ = agents.end_session(&session);
        return TurnOutcome {
            error: Some(e),
            ..TurnOutcome::default()
        };
    }
    let fetch = |fold: &mut TurnFold| -> Result<(), String> {
        let before = fold.seq();
        for event in agents.events(&session, fold.seq())? {
            append(fold.apply(&event));
        }
        if fold.seq() != before {
            progress(&session, fold.seq());
        }
        Ok(())
    };
    let mut orphan = None;
    let mut totals = None;
    loop {
        let signal = match deadline {
            None => rx.recv().unwrap_or(TurnSignal::Lost),
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(signal) => signal,
                Err(RecvTimeoutError::Timeout) => {
                    let _ = fetch(&mut fold);
                    let limit = start.limit.unwrap_or_default();
                    append(fold.finish(Some(format!(
                        "the turn ran past its limit of {} minutes and was stopped",
                        limit.as_secs() / 60
                    ))));
                    break;
                }
                Err(RecvTimeoutError::Disconnected) => TurnSignal::Lost,
            },
        };
        // Coalesce a burst of change signals into one fetch.
        let signal = match signal {
            TurnSignal::Changed => {
                let mut last = TurnSignal::Changed;
                loop {
                    match rx.try_recv() {
                        Ok(TurnSignal::Changed) => {}
                        Ok(other) => {
                            last = other;
                            break;
                        }
                        Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                    }
                }
                last
            }
            other => other,
        };
        match signal {
            TurnSignal::Changed => {
                if let Err(e) = fetch(&mut fold) {
                    log(&format!("turn {}: {e}", start.key));
                }
                if fold.ended().is_some() {
                    break;
                }
            }
            TurnSignal::Done(answer) => {
                totals = answer
                    .as_ref()
                    .ok()
                    .and_then(|v| v.pointer("/_meta/claude/usage"))
                    .and_then(Usage::parse);
                let stopped = answer
                    .as_ref()
                    .ok()
                    .and_then(|v| v.get("stopReason"))
                    .and_then(Value::as_str)
                    .and_then(stop_error);
                let fetched = fetch(&mut fold);
                let error = answer.err().or_else(|| fetched.err()).or(stopped);
                append(fold.finish(error));
                break;
            }
            TurnSignal::Lost => {
                // The session may still run and act: it cannot be ended now
                // (no connection), so the brain keeps it as an orphan. What
                // can still be read is folded now (a fetch fails harmlessly
                // when the connection is really gone).
                let _ = fetch(&mut fold);
                orphan = Some(Orphan {
                    session: session.clone(),
                    after: fold.seq(),
                });
                append(fold.finish(Some(
                    "the acpmux connection was lost during the turn".into(),
                )));
                break;
            }
        }
    }
    log(&usage_line(&start.key, fold.first_usage(), totals));
    if orphan.is_none()
        && let Err(e) = agents.end_session(&session)
    {
        log(&format!("ending turn session {}: {e}", start.session.name));
    }
    let error = fold.ended().and_then(|e| e.error.clone());
    TurnOutcome {
        reply: fold.final_text().map(str::to_owned),
        cancelled: is_cancelled(error.as_deref()),
        error,
        orphan,
    }
}

/// One host.log line per turn with its cache use (section 8: verify with the
/// usage fields). The first request shows what this turn read of the view
/// another turn cached; the totals cover the whole tool loop.
pub fn usage_line(key: &str, first: Option<Usage>, totals: Option<Usage>) -> String {
    let show = |u: Option<Usage>| match u {
        Some(u) => format!(
            "read {} written {} uncached {} output {}",
            u.cache_read, u.cache_write, u.input, u.output
        ),
        None => "not reported".to_owned(),
    };
    format!(
        "turn {key} cache: first request {}; turn total {}",
        show(first),
        show(totals)
    )
}

/// Folds the rest of an orphaned turn into the log, then removes its
/// session. Err leaves the orphan for the next connect.
pub fn adopt_orphan(
    agents: &dyn AgentPort,
    chat: &OptChat,
    orphan: &Orphan,
    log: &dyn Fn(&str),
) -> Result<(), String> {
    let mut fold = TurnFold::after(orphan.after);
    for event in agents.events(&orphan.session, orphan.after)? {
        for entry in fold.apply(&event) {
            if let Err(e) = chat.append(entry.kind, &entry.text) {
                log(&format!(
                    "logging an orphan's {} entry failed: {e}",
                    entry.kind.as_str()
                ));
            }
        }
    }
    // Whatever it was still saying when it was removed.
    for entry in fold.finish(None) {
        if let Err(e) = chat.append(entry.kind, &entry.text) {
            log(&format!(
                "logging an orphan's {} entry failed: {e}",
                entry.kind.as_str()
            ));
        }
    }
    agents.end_session(&orphan.session)
}
