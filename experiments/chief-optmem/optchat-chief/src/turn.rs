//! One turn (section 7): a fresh acpmux session in the constant session
//! directory, the prompt `[view, new messages]`, and everything the session
//! does folded into the log as it happens. The brain has already settled the
//! view, rendered it and logged the new messages; this runs on its own thread
//! so the brain keeps reading the conversation while the turn works.

use std::sync::mpsc::{TryRecvError, channel};

use optchat_host::OptChat;
use serde_json::Value;

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::fold::{Entry, TurnFold};

/// Everything a turn needs, decided by the brain.
#[derive(Clone, Debug, PartialEq)]
pub struct TurnStart {
    /// The reply's idempotency key: `turn:optchat:<first new message id>`.
    pub key: String,
    /// The acpmux promptId (acpmux runs one id once).
    pub prompt_id: String,
    pub session: SessionSpec,
    /// `[view, new messages]` (prompt::turn_blocks).
    pub blocks: Vec<Value>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TurnOutcome {
    /// The turn's final assistant text.
    pub reply: Option<String>,
    pub error: Option<String>,
}

/// Runs the turn to its end; never panics on a port failure (it becomes the
/// outcome's error, and the brain posts it).
pub fn run(
    agents: &dyn AgentPort,
    chat: &OptChat,
    start: &TurnStart,
    log: &dyn Fn(&str),
) -> TurnOutcome {
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
                reply: None,
                error: Some(e),
            };
        }
    };
    let (tx, rx) = channel();
    if let Err(e) = agents.start_prompt(&session, start.blocks.clone(), &start.prompt_id, tx) {
        let _ = agents.end_session(&session);
        return TurnOutcome {
            reply: None,
            error: Some(e),
        };
    }
    let fetch = |fold: &mut TurnFold| -> Result<(), String> {
        for event in agents.events(&session, fold.seq())? {
            append(fold.apply(&event));
        }
        Ok(())
    };
    loop {
        let signal = rx.recv().unwrap_or(TurnSignal::Lost);
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
                let fetched = fetch(&mut fold);
                let error = answer.err().or_else(|| fetched.err());
                append(fold.finish(error));
                break;
            }
            TurnSignal::Lost => {
                append(fold.finish(Some(
                    "the acpmux connection was lost during the turn".into(),
                )));
                break;
            }
        }
    }
    if let Err(e) = agents.end_session(&session) {
        log(&format!("ending turn session {}: {e}", start.session.name));
    }
    let ended = fold.ended().cloned();
    TurnOutcome {
        reply: fold.final_text().map(str::to_owned),
        error: ended.and_then(|e| e.error),
    }
}
